import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import '../tool/eval_coach_agent_v2.dart';

void main() {
  test('app key rejects prose and header controls without echoing input', () {
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
        () => validateEvaluationAppKey(invalid),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'static message',
            'UGK_APP_KEY must be a single nonempty ASCII token without whitespace or header controls',
          ),
        ),
      );
    }
    expect(
      validateEvaluationAppKey('synthetic-token_0123.abc'),
      'synthetic-token_0123.abc',
    );
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
