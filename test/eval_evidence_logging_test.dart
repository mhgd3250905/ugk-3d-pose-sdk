import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../tool/eval_api_config.dart';
import '../tool/eval_coach_agent_v2.dart';
import '../tool/eval_context_stats.dart';
import '../tool/eval_thinking_mode.dart';
import 'support.dart';

void main() {
  test(
    'real CoachAgent getter is read at wire time and matches exact OpenAI body size',
    () async {
      final catalog = loadCatalog();
      final wire = EvaluationWireClient(
        MockClient(
          (request) async => http.Response(
            jsonEncode({
              'model': evaluationModel,
              'choices': [
                {
                  'finish_reason': 'stop',
                  'message': {
                    'role': 'assistant',
                    'content': '公开回答',
                    'reasoning_content': '保留在本地协议内存',
                  },
                },
              ],
              'usage': {
                'prompt_tokens': 10,
                'completion_tokens': 2,
                'total_tokens': 12,
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
        EvaluationRedactor([]),
        (_) {},
      );
      final client = OpenAiCompatibleClient(
        config: evaluationLlmConfig(EvaluationThinkingMode.on),
        httpClient: wire,
      );
      final agent = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: loadProfile('smartfit'),
        enableUserMemory: false,
      );
      addTearDown(agent.dispose);
      addTearDown(client.close);
      wire.contextDiagnosticsProvider = () {
        final diagnostics = agent.contextRequestDiagnostics;
        return diagnostics.isEmpty
            ? null
            : {
                'sdkDiagnosticIndex': diagnostics.length - 1,
                ...diagnostics.last.toJson(),
              };
      };
      expect((await agent.send('你好')).status, TurnStatus.ok);
      expect((await agent.send('谢谢')).status, TurnStatus.ok);
      expect(wire.calls, hasLength(2));
      for (final call in wire.calls) {
        final context = call['contextStats'] as Map;
        expect(context['wireMinusSdkAfterBytes'], 0);
        expect((context['tailState'] as Map)['observed'], isTrue);
        expect(context['sdkDiagnostics'], isNotNull);
      }
      expect(
        ((wire.calls.last['contextStats'] as Map)['prefixValidation']
            as Map)['status'],
        'pass',
      );
      expect(jsonEncode(wire.calls), isNot(contains('保留在本地协议内存')));
    },
  );

  test(
    'wire reads current SDK diagnostics before HTTP and records actual prefix/cache measurements',
    () async {
      var sent = 0;
      var diagnosticReads = 0;
      var epoch = 1;
      final wire = EvaluationWireClient(
        MockClient((request) async {
          sent++;
          expect(diagnosticReads, sent);
          return http.Response(
            jsonEncode({
              'model': 'deepseek-flash',
              'choices': [],
              if (sent == 1) 'usage': {'prompt_cache_hit_tokens': 0},
              if (sent == 2)
                'usage': {
                  'prompt_tokens_details': {'cached_tokens': 7},
                },
            }),
            200,
          );
        }),
        EvaluationRedactor([]),
        (_) {},
      );
      addTearDown(wire.close);
      wire.contextDiagnosticsProvider = () {
        diagnosticReads++;
        return {
          'sdkDiagnosticIndex': diagnosticReads - 1,
          'epoch': epoch,
          'beforeBytes': 80000,
          'afterBytes': 1,
          'completedTurnsFolded': epoch == 2 ? 1 : 0,
          'receiptBodiesFolded': 0,
          'measurement': 'SDK diagnostic only',
          'privateReasoning': 'must-not-log',
        };
      };
      final history = <Json>[
        {'role': 'user', 'content': 'public input'},
        {
          'role': 'assistant',
          'content': '',
          'reasoning_content': 'retained-private-reasoning',
        },
      ];
      for (var i = 1; i <= 3; i++) {
        if (i == 3) epoch = 2;
        final request =
            http.Request('POST', Uri.parse('https://example.invalid'))
              ..body = jsonEncode({
                'model': 'deepseek-flash',
                'thinking': {'type': 'enabled'},
                'tools': <Object?>[],
                'messages': [
                  {'role': 'system', 'content': 'role'},
                  if (i < 3)
                    ...history
                  else
                    {'role': 'user', 'content': 'completed summary'},
                  if (i == 2) {'role': 'assistant', 'content': 'appended'},
                  {'role': 'user', 'content': '$evaluationTailStatePrefix$i'},
                ],
              });
        final response = await wire.send(request);
        await response.stream.drain<void>();
      }
      expect(wire.calls[0]['cacheObservation'], containsPair('hitTokens', 0));
      expect(wire.calls[1]['cacheObservation'], containsPair('hitTokens', 7));
      expect(
        wire.calls[2]['cacheObservation'],
        containsPair('status', 'unknown'),
      );
      final second = wire.calls[1]['contextStats'] as Map;
      expect(second['historyPrefixFullyPreserved'], isTrue);
      expect((second['prefixValidation'] as Map)['status'], 'pass');
      expect(
        second['wireMinusSdkAfterBytes'],
        (wire.calls[1]['requestBytes'] as int) - 1,
      );
      final third = wire.calls[2]['contextStats'] as Map;
      expect(third['foldType'], 'completed_turns');
      expect((third['prefixValidation'] as Map)['status'], 'not_applicable');
      expect(
        jsonEncode(wire.calls),
        isNot(contains('retained-private-reasoning')),
      );
      expect(jsonEncode(wire.calls), isNot(contains('must-not-log')));
      expect(
        (evaluationContextStatistics(wire.calls)['cache']
            as Map)['unknownCalls'],
        1,
      );
    },
  );

  test('API key rejects prose and header controls without echoing input', () {
    for (final invalid in [
      '',
      'token with spaces',
      'token\r\nconfiguration notes',
      'token\nnotes',
      'token\tnotes',
      'token\u0000notes',
      '说明token',
      ' token',
      'token ',
    ]) {
      expect(
        () => validateEvaluationApiKey(invalid),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'static message',
            'UGK_API_KEY must be a single nonempty ASCII token without whitespace or header controls',
          ),
        ),
      );
    }
    expect(
      validateEvaluationApiKey('synthetic-token_0123.abc'),
      'synthetic-token_0123.abc',
    );
  });

  test(
    'direct evaluation uses only bearer auth and retains App defaults',
    () async {
      for (final mode in EvaluationThinkingMode.values) {
        final config = evaluationLlmConfig(mode);
        expect(config.baseUrl, 'https://ai.uuugk.win/v1');
        expect(config.model, 'deepseek-flash');
        expect(config.headers, isEmpty);
        expect(config.maxRetries, 0);
        expect(config.extraBody, mode.extraBody);
      }
      expect(await ApiKeyAuth('synthetic-key').headers(), {
        'Authorization': 'Bearer synthetic-key',
      });
      expect(LlmConfig.ugkWorker.baseUrl, 'https://api.uuugk.win/v1');
    },
  );

  test(
    'environment key takes priority without reading local credentials',
    () async {
      final key = await readEvaluationApiKey({
        'UGK_API_KEY': ' synthetic-env ',
      }, readFile: (_) => throw StateError('Must not read fallback'));
      expect(key, 'synthetic-env');
    },
  );

  test('fallback extracts only API Key line, never the Worker key', () async {
    expect(
      await readEvaluationApiKey(
        {},
        readFile: (path) async {
          expect(path, evaluationKeyFile);
          return 'Other notes\r\nX-App-Key: worker-unused\r\nAPI Key: synthetic-api  \r\n';
        },
      ),
      'synthetic-api',
    );
    for (final text in [
      'X-App-Key: worker-unused',
      'API Key: \n',
      'API Key: \nnext-line-must-not-be-a-key',
      'API Key: first\nAPI Key: second',
      'API Key: synthetic key with spaces',
    ]) {
      await expectLater(
        readEvaluationApiKey({}, readFile: (_) async => text),
        throwsA(isA<StateError>()),
      );
    }
  });

  test('only exact deepseek-flash response label is accepted', () async {
    for (final label in [
      'deepseek-flash',
      'deepseek-v4.1-flash-1017',
      'deepseek-v4-1-flash-261017',
      null,
    ]) {
      var stopped = false;
      final wire = EvaluationWireClient(
        MockClient(
          (_) async =>
              http.Response(jsonEncode({'model': label, 'choices': []}), 200),
        ),
        EvaluationRedactor([]),
        (_) {},
      )..onModelMismatch = () => stopped = true;
      final request = http.Request('POST', Uri.parse('https://example.invalid'))
        ..body = '{"model":"deepseek-flash","messages":[]}';
      final response = await wire.send(request);
      await response.stream.drain<void>();
      expect(
        wire.calls.single['modelMatchesRequest'],
        label == 'deepseek-flash',
      );
      expect(stopped, label != 'deepseek-flash');
      wire.close();
    }
  });

  test('redactor hides raw and JSON-escaped registered secrets', () {
    const secret = 'synthetic-key\r\nnotes "quoted" \\path';
    final redactor = EvaluationRedactor([secret]);
    var variant = secret;
    for (var depth = 0; depth < 3; depth++) {
      final clean = redactor.text('Header error: $variant');
      expect(clean, 'Header error: [REDACTED]');
      expect(clean, isNot(contains('synthetic-key')));
      final encoded = jsonEncode(variant);
      variant = encoded.substring(1, encoded.length - 1);
    }
  });

  test(
    'wire records request replay bytes and excludes private response text',
    () async {
      final journal = <Json>[];
      final redactor = EvaluationRedactor([
        'private-app-key',
        'private-device',
      ]);
      final wire = EvaluationWireClient(
        MockClient(
          (request) async => http.Response(
            jsonEncode({
              'model': 'expected-model',
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': '公开回答',
                    'reasoning_content': '新',
                  },
                },
              ],
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
        redactor,
        journal.add,
      );
      addTearDown(wire.close);
      final request =
          http.Request('POST', Uri.parse('https://example.invalid/v1'))
            ..body = jsonEncode({
              'model': 'expected-model',
              'messages': [
                {
                  'role': 'assistant',
                  'content': '',
                  'reasoning_content': '旧想法',
                },
                {'role': 'user', 'content': 'private-app-key private-device'},
              ],
            });
      final response = await wire.send(request);
      await response.stream.drain<void>();
      final record = wire.calls.single;
      expect((record['reasoningReplay'] as Map)['totalUtf8Bytes'], 9);
      final choice =
          ((record['response'] as Map)['choices'] as List).single as Map;
      expect((choice['message'] as Map)['reasoningUtf8Bytes'], 3);
      expect(record['modelMatchesRequest'], isTrue);
      final public = jsonEncode(redactor.clean(journal));
      expect(public, isNot(contains('旧想法')));
      expect(public, isNot(contains('"reasoning_content"')));
      expect(public, isNot(contains('"新"')));
      expect(public, isNot(contains('private-app-key')));
      expect(public, isNot(contains('private-device')));
      expect(public, contains('公开回答'));
    },
  );

  test('malformed response never logs partial private reasoning', () async {
    final journal = <Json>[];
    final wire = EvaluationWireClient(
      MockClient(
        (_) async =>
            http.Response('{"reasoning_content":"unfinished-secret', 200),
      ),
      EvaluationRedactor([]),
      journal.add,
    );
    addTearDown(wire.close);
    final request = http.Request(
      'POST',
      Uri.parse('https://example.invalid/v1'),
    )..body = '{"model":"expected-model","messages":[]}';
    final response = await wire.send(request);
    await response.stream.drain<void>();
    expect((wire.calls.single['response'] as Map)['bodyTextExcluded'], isTrue);
    expect(jsonEncode(journal), isNot(contains('unfinished-secret')));
    expect(wire.calls.single['responseBytes'], greaterThan(0));
    expect(wire.calls.single['responseSha256'], isNotEmpty);
  });

  test('model mismatch signals case stop and preserves actual label', () async {
    var stopped = 0;
    final wire = EvaluationWireClient(
      MockClient(
        (_) async =>
            http.Response('{"model":"unexpected-free","choices":[]}', 200),
      ),
      EvaluationRedactor([]),
      (_) {},
    )..onModelMismatch = () => stopped++;
    addTearDown(wire.close);
    final request = http.Request(
      'POST',
      Uri.parse('https://example.invalid/v1'),
    )..body = '{"model":"expected-model","messages":[]}';
    final response = await wire.send(request);
    await response.stream.drain<void>();
    expect(stopped, 1);
    expect(wire.calls, hasLength(1));
    expect(wire.calls.single['modelMatchesRequest'], isFalse);
    expect((wire.calls.single['response'] as Map)['model'], 'unexpected-free');
  });

  test('nested reasoning fields are excluded from protocol errors too', () {
    final evidence = publicEvaluationResponse({
      'error': {'message': 'failure', 'reasoning_content': 'secret-thought'},
      'choices': [
        {
          'message': {
            'role': 'assistant',
            'reasoning': 'alternate-secret',
            'content': 'answer',
          },
        },
      ],
    }, EvaluationRedactor([]));
    final encoded = jsonEncode(evidence);
    expect(encoded, isNot(contains('secret-thought')));
    expect(encoded, isNot(contains('alternate-secret')));
    expect(encoded, contains('answer'));
  });
}
