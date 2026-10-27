import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'support.dart';

LlmResponse modelQuestion([String question = '准备在哪里、用什么器材、练多久？']) => LlmResponse(
  content: '',
  finishReason: 'tool_calls',
  toolCalls: [
    LlmToolCall(
      id: 'question',
      name: AgentTools.askUser,
      arguments: jsonEncode({
        'question': question,
        'mode': 'form',
        'fields': [
          {
            'key': 'scene',
            'label': '场景',
            'options': ['家里', '办公室'],
          },
          {
            'key': 'equipment',
            'label': '器械',
            'options': ['徒手', '瑜伽垫'],
            'multiple': true,
          },
          {
            'key': 'minutes',
            'label': '时长',
            'options': ['5 分钟', '10 分钟'],
          },
        ],
      }),
    ),
  ],
);

void main() {
  test('a casual turn preserves the pending question card', () async {
    final catalog = loadCatalog();
    final client = FakeLlmClient([modelQuestion(), '你好，有什么可以帮你？']);
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
    expect(question.question!.mode, AskUserMode.form);
    expect(question.question!.isConfirmation, isFalse);
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

  test('cancelling a question invalidates it in both layers', () async {
    final catalog = loadCatalog();
    final controller = CoachConversationController(
      agent: CoachAgent(
        client: FakeLlmClient([modelQuestion()]),
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

  test(
    'cancelling an in-flight form answer cannot restore its question',
    () async {
      final catalog = loadCatalog();
      final response = Completer<Object>();
      final controller = CoachConversationController(
        agent: CoachAgent(
          client: FakeLlmClient([
            modelQuestion(),
            (LlmRequest _) => response.future,
          ]),
          catalog: () => catalog,
          profile: loadProfile('smartfit'),
          enableUserMemory: false,
          maxRequestRetries: 0,
        ),
      );
      addTearDown(controller.dispose);
      await controller.send('我想针对大腿内侧进行拉伸');
      final question = controller.state.pendingQuestion!;
      final pending = controller.answerForm(question.id, {
        'scene': ['家里'],
        'equipment': ['徒手'],
        'minutes': ['10 分钟'],
      });
      await Future<void>.delayed(Duration.zero);
      controller.cancel();
      response.complete('迟到的模型答复');
      await pending;
      expect(controller.state.pendingQuestion, isNull);
      expect(controller.agent.pendingConfirmation, isNull);
      expect(controller.canAnswer(question.id), isFalse);
    },
  );

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
        client: FakeLlmClient([
          modelQuestion(),
          (LlmRequest _) => response.future,
        ]),
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
    final answerText = '场景：$scene；器械：徒手；时长：10 分钟';
    expect(controller.state.messages.last.text, answerText);
    response.complete(
      const LlmException(LlmErrorKind.network, 'private diagnostic'),
    );
    await future;
    expect(controller.state.messages.last.isPlanningFailure, isTrue);
    expect(controller.state.messages.last.text, isEmpty);
    expect(
      controller.state.messages.where((m) => m.isUser && m.text == answerText),
      hasLength(1),
    );
  });

  test('cancelling a submitted form cannot revive it from a late result', () async {
    final response = Completer<Object>();
    final controller = CoachConversationController(
      agent: CoachAgent(
        client: FakeLlmClient([modelQuestion(), (LlmRequest _) => response.future]),
        catalog: loadCatalog,
        profile: loadProfile('smartfit'),
        enableUserMemory: false,
        maxRequestRetries: 0,
      ),
    );
    addTearDown(controller.dispose);
    await controller.send('想拉伸');
    final question = controller.state.pendingQuestion!;
    final pending = controller.answerForm(question.id, {
      'scene': ['家里'],
      'equipment': ['徒手'],
      'minutes': ['10 分钟'],
    });
    expect(controller.state.isWaiting, isTrue);
    expect(controller.state.messages.firstWhere((m) => m.id == question.id).questionAnswered, isTrue);
    controller.cancel();
    response.complete('迟到的回复');
    await pending;
    expect(controller.state.pendingQuestion, isNull);
    expect(controller.agent.pendingConfirmation, isNull);
    expect(controller.canAnswer(question.id), isFalse);
    expect(controller.state.messages.any((m) => m.text == '迟到的回复'), isFalse);
  });

  test('submitting a form preserves the next model question', () async {
    final controller = CoachConversationController(
      agent: CoachAgent(
        client: FakeLlmClient([modelQuestion(), modelQuestion('还需确认什么？')]),
        catalog: loadCatalog,
        profile: loadProfile('smartfit'),
        enableUserMemory: false,
      ),
    );
    addTearDown(controller.dispose);
    await controller.send('想拉伸');
    final oldQuestion = controller.state.pendingQuestion!;
    await controller.answerForm(oldQuestion.id, {
      'scene': ['家里'],
      'equipment': ['徒手'],
      'minutes': ['10 分钟'],
    });
    final next = controller.state.pendingQuestion!;
    expect(next.id, isNot(oldQuestion.id));
    expect(next.question!.question, '还需确认什么？');
    expect(controller.canAnswer(next.id), isTrue);
    expect(controller.agent.pendingConfirmation, same(next.question));
  });
}
