import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_coach_chat/src/core/chat_failure.dart';
import 'package:ugk_coach_chat/ugk_coach_chat.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

import 'chat_controller_test.dart' show ChatHarness, chatCatalog;

void main() {
  const strings = CoachChatStrings();

  test('local and provider context limits use context copy', () {
    expect(
      ChatFailureKind.of(
        error: const coach.AgentContextBudgetExceeded(70000, 65536),
      ).message(strings),
      strings.contextFailure,
    );
    expect(
      ChatFailureKind.of(
        error: const coach.AgentRequestFailed(
          coach.AgentFailureKind.nonRetryable,
          errorClass: coach.RequestErrorClass.contextTooLong,
        ),
      ),
      ChatFailureKind.context,
    );
  });

  test('authentication failures use authentication copy', () {
    expect(
      ChatFailureKind.of(
        error: const coach.AgentRequestFailed(
          coach.AgentFailureKind.nonRetryable,
          errorClass: coach.RequestErrorClass.auth,
        ),
      ).message(strings),
      strings.authenticationFailure,
    );
  });

  test('the existing conversation limit asks for a new conversation', () {
    expect(
      ChatFailureKind.of(
        result: const coach.CoachTurnResult(
          turnId: 'length-limit',
          status: coach.TurnStatus.limitReached,
        ),
      ).message(strings),
      strings.conversationLimitReached,
    );
    expect(strings.conversationLimitReached, isNot(strings.contextFailure));
  });

  test('exhausted network retries alone use network copy', () {
    expect(
      ChatFailureKind.of(
        error: const coach.AgentRequestFailed(
          coach.AgentFailureKind.retriesExhausted,
          errorClass: coach.RequestErrorClass.network,
          attempts: 5,
        ),
      ).message(strings),
      strings.networkFailure,
    );
  });

  test('rejected plans use plan gate copy', () {
    expect(
      ChatFailureKind.of(
        result: const coach.CoachTurnResult(
          turnId: 'failed-plan',
          status: coach.TurnStatus.error,
          issues: [coach.PlanIssue('duration_fit_failed', 'not delivered')],
        ),
      ).message(strings),
      strings.planGateFailure,
    );
  });

  test('server and unknown errors do not claim a network failure', () {
    expect(
      ChatFailureKind.of(
        error: const coach.LlmException(
          coach.LlmErrorKind.http,
          'unavailable',
          statusCode: 503,
        ),
      ).message(strings),
      strings.serviceFailure,
    );
    expect(
      ChatFailureKind.of(error: StateError('local')).message(strings),
      strings.generationFailure,
    );
  });

  test(
    'each turn emits only its own byte diagnostics and typed failure',
    () async {
      final records = <Map<String, Object?>>[];
      final h = ChatHarness(
        script: [
          const coach.LlmResponse(content: 'response-private-marker'),
          const coach.LlmException(
            coach.LlmErrorKind.auth,
            'exception-private-marker',
            statusCode: 401,
          ),
        ],
        observer: (event, detail) {
          if (event == 'chat.turn.result') {
            records.add(Map<String, Object?>.from(detail! as Map));
          }
        },
      );
      addTearDown(h.close);
      await h.controller.send('user-private-marker');
      await h.controller.send('second-private-marker');
      expect(records, hasLength(2));
      expect(records.first['status'], 'ok');
      expect(records.first['errorType'], isNull);
      final failure = records.last;
      expect(failure['status'], 'error');
      expect(failure['errorType'], 'AgentRequestFailed');
      expect(failure['failureKind'], 'authentication');
      for (final record in records) {
        final contexts = record['contextRequests']! as List;
        expect(contexts, hasLength(1));
        final context = contexts.single as Map;
        expect(context['beforeBytes'], isA<int>());
        expect(context['afterBytes'], isA<int>());
        expect(context['tailStateBytes'], isA<int>());
        expect(context['completedTurnsFolded'], isA<int>());
        expect(context['fitsHardLimit'], isTrue);
      }
      final serialized = jsonEncode(records);
      expect(serialized, isNot(contains('private-marker')));
      expect(
        h.controller.messages.last.text,
        h.controller.profile.strings.authenticationFailure,
      );
      expect(h.controller.messages.last.isPlanningFailure, isTrue);
    },
  );

  test(
    'wrapped OpenAI client diagnostics equal actual HTTP body bytes',
    () async {
      final httpBytes = <int>[];
      final client = coach.OpenAiCompatibleClient(
        config: const coach.LlmConfig(
          baseUrl: 'https://offline.invalid/v1',
          model: 'wire-byte-test',
          maxRetries: 0,
          extraBody: {'enable_thinking': false, 'test_label': 'UTF-8 字节'},
        ),
        httpClient: MockClient((request) async {
          httpBytes.add(request.bodyBytes.length);
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'choices': [
                  {
                    'message': {'role': 'assistant', 'content': '你好。'},
                    'finish_reason': 'stop',
                  },
                ],
              }),
            ),
            200,
          );
        }),
      );
      final h = ChatHarness();
      final original = h.controller;
      final binding = original.bindings;
      final controller = CoachChatController(
        profile: original.profile,
        catalog: chatCatalog(),
        replyDelay: Duration.zero,
        bindings: CoachChatBindings(
          storageNamespace: binding.storageNamespace,
          gateway: CoachGatewayBinding.shared(client),
          plans: binding.plans,
          history: binding.history,
          preferences: binding.preferences,
          actions: binding.actions,
        ),
      );
      addTearDown(() async {
        await controller.close();
        controller.dispose();
        await h.close();
        client.close();
      });
      final result = await controller.send('你好');
      expect(result?.status, coach.TurnStatus.ok);
      expect(httpBytes, hasLength(1));
      final diagnostic = controller.agent.contextRequestDiagnostics.single;
      expect(diagnostic.measurement, 'caller-supplied');
      expect(diagnostic.afterBytes, httpBytes.single);
    },
  );

  testWidgets('the failure bubble renders typed copy and legacy generic copy', (
    tester,
  ) async {
    final h = ChatHarness(
      script: [
        const coach.LlmException(
          coach.LlmErrorKind.auth,
          'credentials rejected',
          statusCode: 401,
        ),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(h.close);
    });
    await tester.runAsync(() => h.controller.send('你好'));
    await tester.pumpWidget(
      MaterialApp(home: CoachChatPage(controller: h.controller)),
    );
    await tester.pump(const Duration(milliseconds: 1));
    expect(
      tester
          .widget<CoachFailureBubble>(find.byType(CoachFailureBubble))
          .message,
      strings.authenticationFailure,
    );
    final snapshot = Map<String, Object?>.from(
      jsonDecode(jsonEncode(h.controller.exportSnapshot().toJson())) as Map,
    );
    final messages = snapshot['messages']! as List;
    (messages.last as Map).remove('text');
    final restored = await tester.runAsync(
      () => h.controller.restoreSnapshot(CoachChatSnapshot.fromJson(snapshot)),
    );
    expect(restored!.ok, isTrue);
    await tester.pump();
    expect(
      tester
          .widget<CoachFailureBubble>(find.byType(CoachFailureBubble))
          .message,
      strings.generationFailure,
    );
  });
}
