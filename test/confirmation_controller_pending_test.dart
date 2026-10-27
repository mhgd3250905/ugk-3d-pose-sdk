import 'dart:async';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'support.dart';

void main() {
  test('a casual turn preserves the pending confirmation card', () async {
    final catalog = loadCatalog();
    final client = FakeLlmClient(['你好，有什么可以帮你？']);
    final controller = CoachConversationController(
      agent: CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: loadProfile('smartfit'),
        enableUserMemory: false,
      ),
    );
    addTearDown(controller.dispose);
    await controller.send('我想针对大腿内侧进行拉伸');
    final question = controller.state.pendingQuestion!;
    expect(question.question!.isConfirmation, isTrue);
    await controller.send('你好');
    expect(controller.state.pendingQuestion?.id, question.id);
    expect(controller.canAnswer(question.id), isTrue);
    expect(
      controller.state.messages
          .firstWhere((m) => m.id == question.id)
          .questionAnswered,
      isFalse,
    );
    expect(controller.state.messages.last.text, '你好，有什么可以帮你？');
  });

  test('cancelling a confirmation invalidates it in both layers', () async {
    final catalog = loadCatalog();
    final controller = CoachConversationController(
      agent: CoachAgent(
        client: FakeLlmClient(['明白。']),
        catalog: () => catalog,
        profile: loadProfile('smartfit'),
        enableUserMemory: false,
      ),
    );
    addTearDown(controller.dispose);
    await controller.send('我想针对大腿内侧进行拉伸');
    final question = controller.state.pendingQuestion!;
    controller.cancel();
    expect(controller.state.pendingQuestion, isNull);
    expect(controller.agent.pendingConfirmation, isNull);
    expect(controller.canAnswer(question.id), isFalse);
    expect(await controller.skipQuestion(question.id), isNull);
  });

  test('conversation limit has a visible failure message', () async {
    final catalog = loadCatalog();
    final controller = CoachConversationController(
      agent: CoachAgent(
        client: FakeLlmClient(['你好。']),
        catalog: () => catalog,
        profile: loadProfile('smartfit'),
        enableUserMemory: false,
        maxTurns: 1,
      ),
    );
    addTearDown(controller.dispose);
    await controller.send('你好');
    final result = await controller.send('再说一句');
    expect(result!.status, TurnStatus.limitReached);
    expect(controller.state.messages.last.isFailure, isTrue);
    expect(controller.state.messages.last.isPlanningFailure, isFalse);
  });

  test(
    'unexpected setup errors create a failure message without details',
    () async {
      final controller = CoachConversationController(
        agent: CoachAgent(
          client: FakeLlmClient([]),
          catalog: () => throw StateError('private catalog diagnostic'),
          profile: loadProfile('smartfit'),
          enableUserMemory: false,
        ),
      );
      addTearDown(controller.dispose);
      await expectLater(controller.send('你好'), throwsStateError);
      expect(controller.state.messages.last.isFailure, isTrue);
      expect(controller.state.messages.last.text, isEmpty);
      expect(
        controller.state.messages.any((m) => m.text.contains('private')),
        isFalse,
      );
    },
  );

  test('confirmed card collapses before the model finishes', () async {
    final catalog = loadCatalog();
    final response = Completer<Object>();
    final controller = CoachConversationController(
      agent: CoachAgent(
        client: FakeLlmClient([(LlmRequest _) => response.future]),
        catalog: () => catalog,
        profile: loadProfile('smartfit'),
        enableUserMemory: false,
        maxRequestRetries: 0,
      ),
    );
    addTearDown(controller.dispose);
    await controller.send('我想针对大腿内侧进行拉伸');
    final question = controller.state.pendingQuestion!;
    final scene = question.question!.fields
        .firstWhere((f) => f.key == 'scene')
        .options
        .first;
    final answer = {
      'scene': [scene],
      'equipment': ['徒手'],
      'minutes': ['10 分钟'],
    };
    final future = controller.answerForm(question.id, answer);
    expect(controller.state.isWaiting, isTrue);
    final card = controller.state.messages.firstWhere(
      (m) => m.id == question.id,
    );
    expect(card.questionAnswered, isTrue);
    expect(card.answeredForm, answer);
    expect(controller.state.messages.last.isUser, isTrue);
    expect(controller.state.messages.last.text, '$scene，徒手，10 分钟');
    response.complete(
      const LlmException(LlmErrorKind.network, 'private diagnostic'),
    );
    await future;
    expect(controller.state.messages.last.isPlanningFailure, isTrue);
    expect(controller.state.messages.last.text, isEmpty);
    expect(
      controller.state.messages.where(
        (m) => m.isUser && m.text == '$scene，徒手，10 分钟',
      ),
      hasLength(1),
    );
  });
}
