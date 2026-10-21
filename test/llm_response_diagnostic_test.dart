import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

const _usage = {
  'prompt_tokens': 123,
  'completion_tokens': 45,
  'completion_tokens_details': {'reasoning_tokens': 40},
};
const _request = LlmRequest(messages: [LlmMessage.user('test')]);

Map<String, Object?> _body(Object? message, {String finish = 'stop'}) => {
  'choices': [
    {'message': message, 'finish_reason': finish},
  ],
  'usage': _usage,
};

Future<LlmException> _failure(
  Object? body, {
  bool raw = false,
  Map<String, String> headers = const {},
}) async {
  final client = OpenAiCompatibleClient(
    config: const LlmConfig(
      baseUrl: 'https://example.invalid/v1',
      model: 'test',
      maxRetries: 0,
    ),
    httpClient: MockClient(
      (_) async => http.Response.bytes(
        utf8.encode(raw ? body as String : jsonEncode(body)),
        200,
        headers: headers,
      ),
    ),
  );
  addTearDown(client.close);
  try {
    await client.complete(_request);
    fail('Expected LlmException');
  } on LlmException catch (e) {
    return e;
  }
}

void main() {
  test(
    'non-JSON diagnosis retains byte count/hash without response text',
    () async {
      const body = '<html>私密正文-private-response</html>';
      final e = await _failure(body, raw: true);
      final d = e.responseDiagnostic!;
      expect(e.kind, LlmErrorKind.badResponse);
      expect(e.statusCode, 200);
      expect(e.message, contains('返回体不是 JSON'));
      expect(e.message, isNot(contains('私密正文')));
      expect(e.message, isNot(contains('private-response')));
      expect(d.subtype, LlmResponseProblem.nonJson);
      expect(d.bodyBytes, utf8.encode(body).length);
      expect(d.bodyBytes, greaterThan(body.length));
      expect(d.bodySha256, sha256.convert(utf8.encode(body)).toString());
      expect(d.shapes, isEmpty);
    },
  );

  test(
    'an empty HTTP body is non-JSON, distinct from an empty message',
    () async {
      final d = (await _failure('', raw: true)).responseDiagnostic!;
      expect(d.subtype, LlmResponseProblem.nonJson);
      expect(d.bodyBytes, 0);
      expect(
        d.bodySha256,
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    },
  );

  test(
    'unexpected SSE is diagnosed without treating it as completed JSON',
    () async {
      for (final headers in <Map<String, String>>[
        {},
        {'content-type': 'text/event-stream; charset=utf-8'},
      ]) {
        final e = await _failure(
          'data: {"delta":"private-stream"}\n\ndata: [DONE]\n',
          raw: true,
          headers: headers,
        );
        expect(e.kind, LlmErrorKind.badResponse);
        expect(e.responseDiagnostic!.subtype, LlmResponseProblem.eventStream);
        expect(e.message, isNot(contains('private-stream')));
      }
    },
  );

  test(
    'missing/empty choices preserve known usage and safe JSON shapes',
    () async {
      for (final body in <Map<String, Object?>>[
        {'usage': _usage},
        {'choices': [], 'usage': _usage},
      ]) {
        final e = await _failure(body);
        final d = e.responseDiagnostic!;
        expect(e.message, contains('没有 choices'));
        expect(e.kind, LlmErrorKind.badResponse);
        expect(e.statusCode, 200);
        expect(e.usage.promptTokens, 123);
        expect(e.usage.completionTokens, 45);
        expect(d.subtype, LlmResponseProblem.noChoices);
        expect(d.shapes['root'], 'object');
        expect(
          d.shapes['choices'],
          body.containsKey('choices') ? 'array' : 'missing',
        );
        expect(d.choicesCount, body.containsKey('choices') ? 0 : null);
      }
    },
  );

  test(
    'unexpected root/choices/message/content shapes remain badResponse',
    () async {
      for (final (body, key, shape) in <(Object?, String, String)>[
        (['private-root'], 'root', 'array'),
        ({'choices': 'private-choices'}, 'choices', 'string'),
        (
          {
            'choices': [42],
          },
          'choices[0]',
          'number',
        ),
        (_body('private-message'), 'message', 'string'),
        (
          _body({
            'content': [
              {'type': 'text', 'text': 'private-content'},
            ],
          }),
          'content',
          'array',
        ),
        (
          _body({
            'content': {'text': 'private-content'},
          }),
          'content',
          'object',
        ),
        (
          _body({'content': null, 'tool_calls': 'private-calls'}),
          'tool_calls',
          'string',
        ),
        (
          _body({
            'content': null,
            'reasoning_content': ['private-reasoning'],
          }),
          'reasoning_content',
          'array',
        ),
      ]) {
        final e = await _failure(body);
        expect(e.kind, LlmErrorKind.badResponse);
        expect(e.responseDiagnostic!.subtype, LlmResponseProblem.invalidShape);
        expect(e.responseDiagnostic!.shapes[key], shape);
        expect(e.message, isNot(contains('private-')));
      }
    },
  );

  test(
    'reasoning-only output keeps usage/status/finish but never reasoning text',
    () async {
      const reasoning = 'private-reasoning-from-model';
      final e = await _failure(
        _body({'content': null, 'reasoning_content': reasoning}),
      );
      final d = e.responseDiagnostic!;
      expect(e.message, contains('正文为空'));
      expect(e.message, contains('仅有推理'));
      expect(e.statusCode, 200);
      expect(e.finishReason, 'stop');
      expect(e.usage.reasoningTokens, 40);
      expect(d.subtype, LlmResponseProblem.reasoningOnly);
      expect(d.reasoningLength, reasoning.length);
      expect(d.finishReason, 'stop');
      expect(e.message, isNot(contains(reasoning)));
      expect(e.toString(), isNot(contains(reasoning)));
      expect(jsonEncode(d.toJson()), isNot(contains(reasoning)));
    },
  );

  test(
    'empty content retains finish reason and differs from reasoning-only',
    () async {
      final e = await _failure(
        _body({
          'content': '  ',
          'tool_calls': [],
          'reasoning_content': '',
        }, finish: 'content_filter'),
      );
      final d = e.responseDiagnostic!;
      expect(e.message, contains('正文为空'));
      expect(e.finishReason, 'content_filter');
      expect(e.usage.completionTokens, 45);
      expect(d.subtype, LlmResponseProblem.emptyContent);
      expect(d.contentLength, 2);
      expect(d.reasoningLength, 0);
      expect(d.toolCallsCount, 0);
    },
  );

  test(
    'unknown failure finish_reason retains only a safe tag, length and hash',
    () async {
      const finish = 'private-finish-正文-should-never-be-logged';
      final e = await _failure(_body({'content': null}, finish: finish));
      final d = e.responseDiagnostic!;
      expect(e.kind, LlmErrorKind.badResponse);
      expect(e.finishReason, 'unknown');
      expect(d.finishReason, 'unknown');
      expect(d.finishReasonLength, finish.length);
      expect(
        d.finishReasonSha256,
        sha256.convert(utf8.encode(finish)).toString(),
      );
      expect(d.shapes['finish_reason'], 'string');
      expect(e.message, isNot(contains('private-finish')));
      expect(e.message, isNot(contains('正文-should-never')));
      expect(e.toString(), isNot(contains(finish)));
      expect(jsonEncode(d.toJson()), isNot(contains(finish)));
      expect(e.usage.totalTokens, 168);
    },
  );

  test(
    'HTTP 200 error envelope is identified without raw error text',
    () async {
      final e = await _failure({
        'error': {'message': 'private-gateway-error', 'type': 'secret-type'},
        'usage': _usage,
      });
      expect(e.kind, LlmErrorKind.badResponse);
      expect(e.statusCode, 200);
      expect(e.usage.totalTokens, 168);
      expect(e.responseDiagnostic!.subtype, LlmResponseProblem.errorEnvelope);
      expect(e.responseDiagnostic!.hasError, isTrue);
      expect(e.message, isNot(contains('private-gateway-error')));
      expect(e.message, isNot(contains('secret-type')));
    },
  );

  test('terminal metadata survives a preceding internal HTTP retry', () async {
    var requests = 0;
    final client = OpenAiCompatibleClient(
      config: const LlmConfig(
        baseUrl: 'https://example.invalid/v1',
        model: 'test',
        maxRetries: 3,
      ),
      sleep: (_) async {},
      httpClient: MockClient(
        (_) async => ++requests == 1
            ? http.Response('busy', 503)
            : http.Response(
                jsonEncode(
                  _body({
                    'content': null,
                    'reasoning_content': 'private-reasoning',
                  }),
                ),
                200,
              ),
      ),
    );
    addTearDown(client.close);
    await expectLater(
      client.complete(_request),
      throwsA(
        isA<LlmException>()
            .having((e) => e.httpAttempts, 'httpAttempts', 2)
            .having((e) => e.finishReason, 'finishReason', 'stop')
            .having((e) => e.usage.totalTokens, 'usage', 168)
            .having(
              (e) => e.responseDiagnostic?.subtype,
              'subtype',
              LlmResponseProblem.reasoningOnly,
            ),
      ),
    );
    expect(
      requests,
      2,
      reason: 'badResponse remains an Agent retry, not an internal HTTP retry',
    );
  });

  test(
    'length truncation keeps its prior error kind plus response metadata',
    () async {
      final e = await _failure(
        _body({
          'content': '',
          'reasoning_content': 'private-reasoning',
        }, finish: 'length'),
      );
      expect(e.kind, LlmErrorKind.truncated);
      expect(e.statusCode, 200);
      expect(e.finishReason, 'length');
      expect(e.usage.completionTokens, 45);
      expect(e.message, isNot(contains('private-reasoning')));
    },
  );

  test(
    'valid content and tool calls retain their original reasoning',
    () async {
      final bodies = [
        _body({
          'content': 'public-reply',
          'reasoning_content': 'private-reasoning',
        }),
        _body({
          'content': null,
          'reasoning_content': 'private-reasoning',
          'tool_calls': [
            {
              'id': 'read-1',
              'type': 'function',
              'function': {'name': 'read', 'arguments': '{"path":"a"}'},
            },
          ],
        }, finish: 'tool_calls'),
      ];
      var index = 0;
      final client = OpenAiCompatibleClient(
        config: const LlmConfig(
          baseUrl: 'https://example.invalid/v1',
          model: 'test',
        ),
        httpClient: MockClient(
          (_) async => http.Response(jsonEncode(bodies[index++]), 200),
        ),
      );
      addTearDown(client.close);
      final text = await client.complete(_request);
      final tools = await client.complete(_request);
      expect(text.content, 'public-reply');
      expect(text.reasoning, 'private-reasoning');
      expect(tools.content, isEmpty);
      expect(tools.reasoning, 'private-reasoning');
      expect(tools.toolCalls.single.name, 'read');
      expect(tools.finishReason, 'tool_calls');
    },
  );

  test(
    'unknown finish_reason on a successful response remains unchanged',
    () async {
      const finish = 'custom-provider-finish';
      final client = OpenAiCompatibleClient(
        config: const LlmConfig(
          baseUrl: 'https://example.invalid/v1',
          model: 'test',
        ),
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode(_body({'content': 'ok'}, finish: finish)),
            200,
          ),
        ),
      );
      addTearDown(client.close);
      expect((await client.complete(_request)).finishReason, finish);
    },
  );
}
