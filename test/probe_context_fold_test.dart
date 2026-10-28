import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/context_turn_ledger.dart';

import '../tool/probe_context_fold.dart';

const _key = 'private-test-key-must-not-appear';
const _reasoning = 'PRIVATE_REASONING_BODY_中文';

http.Response reply({
  bool tool = false,
  String content = 'FIRST_TURN_DONE',
  String? reasoning = _reasoning,
  String model = 'deepseek-flash',
}) => http.Response(
  jsonEncode({
    'model': model,
    'choices': [
      {
        'finish_reason': tool ? 'tool_calls' : 'stop',
        'message': {
          'role': 'assistant',
          'content': tool ? '' : content,
          'reasoning_content': ?reasoning,
          if (tool)
            'tool_calls': [
              {
                'id': 'actual-echo',
                'type': 'function',
                'function': {
                  'name': 'echo_probe',
                  'arguments': jsonEncode({'text': probeToken}),
                },
              },
            ],
        },
      },
    ],
    'usage': {
      'prompt_tokens': 11,
      'completion_tokens': 7,
      'total_tokens': 18,
      'completion_tokens_details': {'reasoning_tokens': 5},
    },
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test(
    'design is offline and requires explicit execute with a fixed four-attempt budget',
    () {
      final design = contextFoldProbeDesign();
      expect(design['httpAttempts'], 0);
      expect(design['executeFlagRequired'], isTrue);
      expect(design['maxHttpAttempts'], 4);
      expect(design['model'], 'deepseek-flash');
      expect(design['thinking'], {'type': 'enabled'});
      expect(design['secondTurnRoles'], ['system', 'user', 'user']);
    },
  );

  test(
    'real first-turn tool/reasoning roundtrip precedes a whole-turn user-summary fold',
    () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return switch (requests.length) {
          1 => reply(tool: true),
          2 => reply(),
          3 => reply(content: probeToken),
          _ => throw StateError('Unexpected extra HTTP attempt'),
        };
      });
      addTearDown(client.close);
      final report = await ContextFoldProbe(client: client, apiKey: _key).run();
      expect(report['status'], 'passed_http_compatibility');
      expect(report['mustStop'], isFalse);
      expect(report['httpAttempts'], 3);
      expect(report['successfulRealEchoToolCalls'], 1);
      expect(report['firstTurnCompleted'], isTrue);
      expect(report['foldedRequestAccepted'], isTrue);
      expect(report['allModelLabelsConsistent'], isTrue);
      for (final request in requests) {
        final body = jsonDecode(request.body) as Map;
        expect(
          request.url.toString(),
          'https://ai.uuugk.win/v1/chat/completions',
        );
        expect(body['model'], 'deepseek-flash');
        expect(body['thinking'], {'type': 'enabled'});
        expect(body['tools'], probeTools);
        expect(body.containsKey('tool_choice'), isFalse);
        expect(request.followRedirects, isFalse);
        expect(request.headers['Authorization'], 'Bearer $_key');
        expect(
          request.headers.keys.map((key) => key.toLowerCase()),
          isNot(contains(anyOf('x-app-key', 'x-device-id'))),
        );
      }
      final continued = jsonDecode(requests[1].body) as Map;
      final roundtrip = (continued['messages'] as List)
          .cast<Map<String, Object?>>();
      expect(roundtrip.map((message) => message['role']), [
        'system',
        'user',
        'assistant',
        'tool',
      ]);
      expect(roundtrip[2]['reasoning_content'], _reasoning);
      expect(roundtrip[3]['tool_call_id'], 'actual-echo');
      expect(jsonDecode(roundtrip[3]['content'] as String), {
        'ok': true,
        'echo': probeToken,
      });
      final folded = jsonDecode(requests[2].body) as Map;
      final messages = (folded['messages'] as List)
          .cast<Map<String, Object?>>();
      expect(messages.map((message) => message['role']), [
        'system',
        'user',
        'user',
      ]);
      expect(
        messages
            .take(1)
            .where(
              (message) => {'assistant', 'tool'}.contains(message['role']),
            ),
        isEmpty,
      );
      expect(messages[1]['content'], report['foldedSummaryContent']);
      expect(messages[1]['content'], startsWith(probeSummaryHeading));
      expect(
        messages[1]['content'],
        ContextTurnLedger([
          CompletedContextTurn(
            turn: 1,
            userText: probeFirstUser,
            finalDeliveryText: 'FIRST_TURN_DONE',
            params: const {},
            outcome: 'ok',
          ),
        ]).summaryMessage().content,
      );
      expect(messages[1]['content'], contains('FIRST_TURN_DONE'));
      expect(messages[1]['content'], isNot(contains('tool_call_id')));
      expect(report['secondTurnSemanticEchoMatches'], isTrue);
      expect(messages[2]['content'], probeSecondUser);
      expect(requests[2].body, isNot(contains('reasoning_content')));
      final evidence = jsonEncode(report);
      expect(evidence, isNot(contains(_reasoning)));
      expect(evidence, isNot(contains(_key)));
      expect(evidence, isNot(contains('Authorization')));
      expect(evidence, isNot(contains('headers')));
      final calls = (report['calls'] as List).cast<Map<String, Object?>>();
      expect(
        calls[1]['reasoningReplayedBytes'],
        utf8.encode(_reasoning).length,
      );
      expect(calls[2]['reasoningReplayedBytes'], 0);
      expect(
        calls.every(
          (call) =>
              call['reasoningReturnedBytes'] == utf8.encode(_reasoning).length,
        ),
        isTrue,
      );
      expect(calls[0]['usage'], {
        'prompt_tokens': 11,
        'completion_tokens': 7,
        'total_tokens': 18,
        'completion_tokens_details': {'reasoning_tokens': 5},
      });
      expect(calls[0]['requestBytes'], utf8.encode(requests[0].body).length);
      expect(
        calls[0]['requestSha256'],
        sha256.convert(utf8.encode(requests[0].body)).toString(),
      );
      expect(calls.every((call) => call['elapsedMs'] is int), isTrue);
    },
  );

  for (final failedAttempt in [1, 2, 3, 4]) {
    test(
      'HTTP 400 on attempt $failedAttempt immediately marks mustStop with no later request',
      () async {
        var sent = 0;
        final client = MockClient((request) async {
          sent++;
          if (sent == failedAttempt) {
            return http.Response.bytes(
              utf8.encode('private error $_key $_reasoning'),
              400,
            );
          }
          if (sent == 1 || failedAttempt == 4 && sent == 2) {
            return reply(tool: true);
          }
          return reply();
        });
        addTearDown(client.close);
        final report = await ContextFoldProbe(
          client: client,
          apiKey: _key,
        ).run();
        expect(report['status'], 'aborted_http_400');
        expect(report['mustStop'], isTrue);
        expect(report['httpAttempts'], failedAttempt);
        expect(sent, failedAttempt);
        expect(jsonEncode(report), isNot(contains(_key)));
        expect(jsonEncode(report), isNot(contains(_reasoning)));
      },
    );
  }

  test(
    'three first-turn tool batches exhaust the reserve without a fifth request',
    () async {
      var sent = 0;
      final client = MockClient((request) async {
        sent++;
        return reply(tool: true);
      });
      addTearDown(client.close);
      final report = await ContextFoldProbe(client: client, apiKey: _key).run();
      expect(report['status'], 'inconclusive_first_turn_budget');
      expect(report['mustStop'], isTrue);
      expect(report['httpAttempts'], 3);
      expect(sent, 3);
      expect(report['foldedRequestAccepted'], isFalse);
    },
  );

  test(
    'two actual tool batches and final text leave exactly one folded request',
    () async {
      var sent = 0;
      final client = MockClient((request) async {
        sent++;
        return sent <= 2 ? reply(tool: true) : reply();
      });
      addTearDown(client.close);
      final report = await ContextFoldProbe(client: client, apiKey: _key).run();
      expect(report['status'], 'passed_http_compatibility');
      expect(report['httpAttempts'], 4);
      expect(report['successfulRealEchoToolCalls'], 2);
      expect(report['foldedRequestAccepted'], isTrue);
      expect(report['secondTurnSemanticEchoMatches'], isFalse);
      expect(sent, 4);
    },
  );

  test(
    'no real tool call is reported inconclusive instead of inventing evidence',
    () async {
      var sent = 0;
      final client = MockClient((request) async {
        sent++;
        return reply();
      });
      addTearDown(client.close);
      final report = await ContextFoldProbe(client: client, apiKey: _key).run();
      expect(report['status'], 'inconclusive_no_real_tool_use');
      expect(report['successfulRealEchoToolCalls'], 0);
      expect(report['foldedRequestAccepted'], isFalse);
      expect(sent, 1);
    },
  );

  test(
    'model mismatch, rate limit and transport exceptions are never retried',
    () async {
      for (final kind in ['model', 'rate', 'network']) {
        var sent = 0;
        final client = MockClient((request) async {
          sent++;
          if (kind == 'network') throw http.ClientException('private $_key');
          if (kind == 'rate') return http.Response('private $_key', 429);
          return reply(tool: true, model: 'other-label');
        });
        addTearDown(client.close);
        final report = await ContextFoldProbe(
          client: client,
          apiKey: _key,
        ).run();
        expect(sent, 1);
        expect(report['mustStop'], isTrue);
        expect(report['foldedRequestAccepted'], isFalse);
        expect(jsonEncode(report), isNot(contains(_key)));
      }
    },
  );
}
