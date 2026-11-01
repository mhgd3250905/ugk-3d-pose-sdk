import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_coach_chat/ugk_coach_chat.dart';

import 'chat_controller_test.dart';

void main() {
  test(
    'diagnostics receive raw input while display and model stay trimmed',
    () async {
      final inputs = <CoachChatUserInput>[];
      final h = ChatHarness(
        script: [const coach.LlmResponse(content: '你好。')],
        observer: (event, detail) {
          if (event == 'chat.user') inputs.add(detail! as CoachChatUserInput);
        },
      );
      addTearDown(h.close);
      const raw = '  在家拉伸一下\n保留原话。  ';
      await h.controller.send(raw);
      expect(inputs, hasLength(1));
      expect(inputs.single.rawText, raw);
      expect(inputs.single.sentText, raw.trim());
      expect(
        h.controller.messages.singleWhere((m) => m.isUser).text,
        raw.trim(),
      );
      expect(
        h.controller.conversation.state.messages
            .singleWhere((m) => m.isUser)
            .text,
        raw.trim(),
      );
    },
  );

  test(
    'archives the complete old session before reset and queues new input',
    () async {
      final snapshots = <CoachChatSnapshot>[];
      final gate = Completer<void>();
      final h = ChatHarness(
        script: [
          ...chatPlanScript(),
          const coach.LlmResponse(content: '你好。'),
        ],
        beforeNewConversation: (snapshot) {
          snapshots.add(snapshot);
          return gate.future;
        },
      );
      addTearDown(h.close);
      final result = await h.controller.send('在家拉伸5分钟');
      expect(result?.plan, isNotNull);
      final previous = h.controller.exportSnapshot().toJson();
      final calls = h.client.requests.length;
      final reset = h.controller.newConversation();
      Future<Object?>? queued;
      try {
        expect(snapshots, hasLength(1));
        expect(snapshots.single.toJson(), previous);
        expect(h.controller.agent.sessionState.plans, isNotEmpty);
        queued = h.controller.send('你好');
        await Future<void>.delayed(Duration.zero);
        expect(h.client.requests.length, calls);
        expect(h.controller.agent.sessionState.plans, isNotEmpty);
      } finally {
        gate.complete();
        await reset;
        await queued;
      }
      expect(h.client.requests.length, calls + 1);
      expect(h.controller.agent.sessionState.userTurns.map((t) => t.text), [
        '你好',
      ]);
    },
  );

  test('diagnostic archive failure still starts a new conversation', () async {
    final errors = <Object?>[];
    final h = ChatHarness(
      script: [const coach.LlmResponse(content: '你好。')],
      beforeNewConversation: (_) => Future.error(StateError('archive failed')),
      observer: (event, detail) {
        if (event == 'chat.archive.error') errors.add(detail);
      },
    );
    addTearDown(h.close);
    await h.controller.send('你好');
    final reset = await h.controller.newConversation();
    expect(reset.ok, isTrue);
    expect(errors, hasLength(1));
    expect(h.controller.agent.sessionState.userTurns, isEmpty);
    expect(
      h.controller.messages.any((m) => m.text.contains('archive failed')),
      isFalse,
    );
  });
}
