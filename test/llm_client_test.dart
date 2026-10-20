import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

Map<String, Object?> okBody({String content = '{"kind":"reply","text":"好"}', String finish = 'stop', Map<String, Object?>? usage}) => {
  'model': 'deepseek-v4.1-flash-1017',
  'choices': [
    {'message': {'role': 'assistant', 'content': content, 'reasoning_content': '用户想…'}, 'finish_reason': finish},
  ],
  'usage': usage ??
      {
        'prompt_tokens': 5000,
        'completion_tokens': 900,
        'total_tokens': 5900,
        'prompt_cache_hit_tokens': 4096,
        'completion_tokens_details': {'reasoning_tokens': 700},
      },
};

http.Response res(String body, [int status = 200]) => http.Response.bytes(utf8.encode(body), status);

/// 支持中止的假服务端：一直不回，直到 abortTrigger（MockClient 不传递 Abortable）。
class _HangingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final done = Completer<http.StreamedResponse>();
    if (request is http.Abortable) {
      unawaited(request.abortTrigger?.then((_) {
        if (!done.isCompleted) done.completeError(http.RequestAbortedException(request.url));
      }));
    }
    return done.future;
  }
}

void main() {
  const config = LlmConfig(baseUrl: 'https://gw.example.com/v1/', model: 'deepseek-v4.1-flash-1017', maxTokens: 6000, maxRetries: 2);
  const req = LlmRequest(messages: [LlmMessage.system('s'), LlmMessage.user('u')]);
  final sleeps = <Duration>[];
  Future<void> noSleep(Duration d) async => sleeps.add(d);
  setUp(sleeps.clear);

  test('请求：地址、头、请求体（max_tokens、json 模式；temperature 未设则不传）', () async {
    late http.Request seen;
    final c = OpenAiCompatibleClient(
      config: config,
      auth: ApiKeyAuth('sk-test'),
      httpClient: MockClient((r) async {
        seen = r;
        return res(jsonEncode(okBody()));
      }),
    );
    await c.complete(req);
    expect(seen.url.toString(), 'https://gw.example.com/v1/chat/completions');
    expect(seen.headers['Authorization'], 'Bearer sk-test');
    final body = jsonDecode(seen.body) as Map;
    expect(body['model'], 'deepseek-v4.1-flash-1017');
    expect(body['max_tokens'], 6000);
    expect(body['response_format'], {'type': 'json_object'});
    expect(body.containsKey('temperature'), isFalse);
    expect((body['messages'] as List).first, {'role': 'system', 'content': 's'});
  });

  test('NoAuth / RelayAuth 不带 Authorization；RelayAuth 带 App 令牌；extraBody 合并', () async {
    final heads = <Map<String, String>>[];
    http.Client mock() => MockClient((r) async {
      heads.add(r.headers);
      return res(jsonEncode(okBody()));
    });
    await OpenAiCompatibleClient(config: config, httpClient: mock()).complete(req);
    await OpenAiCompatibleClient(config: config, auth: RelayAuth(appToken: () async => 'app-123'), httpClient: mock()).complete(req);
    expect(heads[0].containsKey('Authorization'), isFalse);
    expect(heads[1]['X-App-Token'], 'app-123');
    final body = OpenAiCompatibleClient(config: config.copyWith(temperature: 0.3, extraBody: {'top_p': 0.9})).buildBody(req);
    expect(body['temperature'], 0.3);
    expect(body['top_p'], 0.9);
  });

  test('响应：正文、推理内容、token（DeepSeek 缓存字段）', () async {
    final c = OpenAiCompatibleClient(config: config, httpClient: MockClient((_) async => res(jsonEncode(okBody()))));
    final r = await c.complete(req);
    expect(r.content, '{"kind":"reply","text":"好"}');
    expect(r.reasoning, '用户想…');
    expect(r.usage.promptTokens, 5000);
    expect(r.usage.cachedTokens, 4096);
    expect(r.usage.reasoningTokens, 700);
    expect(r.model, 'deepseek-v4.1-flash-1017');
    expect(r.httpAttempts, 1);
  });

  test('OpenAI 风格 usage 字段', () {
    final u = TokenUsage.fromOpenAi({
      'prompt_tokens': 100,
      'completion_tokens': 50,
      'prompt_tokens_details': {'cached_tokens': 64},
      'completion_tokens_details': {'reasoning_tokens': 30},
    });
    expect((u.cachedTokens, u.reasoningTokens), (64, 30));
  });

  test('500 → 退避重试 → 成功', () async {
    var n = 0;
    final c = OpenAiCompatibleClient(
      config: config,
      sleep: noSleep,
      httpClient: MockClient((_) async => ++n < 3 ? http.Response('{"error":{"message":"busy"}}', 502) : res(jsonEncode(okBody()))),
    );
    final r = await c.complete(req);
    expect(r.httpAttempts, 3);
    expect(sleeps, [const Duration(milliseconds: 800), const Duration(milliseconds: 1600)]);
  });

  test('重试用完：抛 http 错误，带错误信息', () async {
    final c = OpenAiCompatibleClient(
      config: config.copyWith(maxRetries: 1),
      sleep: noSleep,
      httpClient: MockClient((_) async => http.Response('{"error":{"message":"busy"}}', 503)),
    );
    await expectLater(c.complete(req), throwsA(isA<LlmException>()
        .having((e) => e.kind, 'kind', LlmErrorKind.http)
        .having((e) => e.message, 'message', 'busy')
        .having((e) => e.httpAttempts, 'attempts', 2)));
  });

  test('401 不重试', () async {
    var n = 0;
    final c = OpenAiCompatibleClient(config: config, sleep: noSleep, httpClient: MockClient((_) async {
      n++;
      return http.Response('{"error":"bad key"}', 401);
    }));
    await expectLater(c.complete(req), throwsA(isA<LlmException>().having((e) => e.kind, 'kind', LlmErrorKind.auth)));
    expect(n, 1);
  });

  test('429 按 Retry-After 等待', () async {
    var n = 0;
    final c = OpenAiCompatibleClient(config: config, sleep: noSleep, httpClient: MockClient((_) async =>
        ++n == 1 ? http.Response('limited', 429, headers: {'retry-after': '3'}) : res(jsonEncode(okBody()))));
    await c.complete(req);
    expect(sleeps, [const Duration(seconds: 3)]);
  });

  test('finish_reason=length → truncated，带已计费用量', () async {
    final c = OpenAiCompatibleClient(config: config, httpClient: MockClient((_) async =>
        res(jsonEncode(okBody(content: '', finish: 'length')))));
    await expectLater(c.complete(req), throwsA(isA<LlmException>()
        .having((e) => e.kind, 'kind', LlmErrorKind.truncated)
        .having((e) => e.usage.completionTokens, 'usage', 900)));
  });

  test('正文为空 / 返回体不是 JSON → badResponse', () async {
    for (final body in [jsonEncode(okBody(content: '  ')), '<html>gateway</html>']) {
      final c = OpenAiCompatibleClient(config: config, httpClient: MockClient((_) async => res(body)));
      await expectLater(c.complete(req), throwsA(isA<LlmException>().having((e) => e.kind, 'kind', LlmErrorKind.badResponse)));
    }
  });

  test('断网 → network（会重试）', () async {
    var n = 0;
    final c = OpenAiCompatibleClient(config: config, sleep: noSleep, httpClient: MockClient((_) async {
      n++;
      throw http.ClientException('Failed host lookup');
    }));
    await expectLater(c.complete(req), throwsA(isA<LlmException>().having((e) => e.kind, 'kind', LlmErrorKind.network)));
    expect(n, 3);
  });

  http.Client hanging() => _HangingClient();

  test('超时：中止请求 → timeout', () async {
    final c = OpenAiCompatibleClient(config: config.copyWith(timeout: const Duration(milliseconds: 30), maxRetries: 0), httpClient: hanging());
    await expectLater(c.complete(req), throwsA(isA<LlmException>().having((e) => e.kind, 'kind', LlmErrorKind.timeout)));
  });

  test('取消：中止请求 → cancelled，不重试', () async {
    final c = OpenAiCompatibleClient(config: config, sleep: noSleep, httpClient: hanging());
    final t = CancelToken();
    final f = c.complete(req, cancel: t);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    t.cancel();
    await expectLater(f, throwsA(isA<LlmException>().having((e) => e.kind, 'kind', LlmErrorKind.cancelled)));
    expect(sleeps, isEmpty);
  });

  test('退避等待中取消 → 立即 cancelled，不再发第二次请求', () async {
    var n = 0;
    final gate = Completer<void>();
    var sleeping = false;
    final c = OpenAiCompatibleClient(
      config: config,
      sleep: (_) {
        sleeping = true;
        return gate.future; // 不释放：取消必须自己打断等待
      },
      httpClient: MockClient((_) async {
        n++;
        return http.Response('limited', 429, headers: {'retry-after': '30'});
      }),
    );
    final t = CancelToken();
    final f = c.complete(req, cancel: t);
    while (!sleeping) {
      await Future<void>.delayed(Duration.zero);
    }
    t.cancel();
    await expectLater(
        f.timeout(const Duration(seconds: 1)),
        throwsA(isA<LlmException>()
            .having((e) => e.kind, 'kind', LlmErrorKind.cancelled)
            .having((e) => e.httpAttempts, 'attempts', 1)));
    expect(n, 1);
  });

  test('ApiKeyAuth.lazy 每次读最新 key', () async {
    var k = 'a';
    final auth = ApiKeyAuth.lazy(() async => k);
    expect((await auth.headers())['Authorization'], 'Bearer a');
    k = 'b';
    expect((await auth.headers())['Authorization'], 'Bearer b');
  });
  test(
    'async auth failure cancels its attempt timer and never sends HTTP or retries',
    () async {
      final timers = <Timer>[];
      var headersRead = 0;
      var sent = 0;
      await runZoned(
        () async {
          final c = OpenAiCompatibleClient(
            config: config,
            auth: ApiKeyAuth.lazy(() async {
              headersRead++;
              await Future<void>.delayed(Duration.zero);
              throw StateError('local auth preparation failed');
            }),
            sleep: noSleep,
            httpClient: MockClient((_) async {
              sent++;
              return res(jsonEncode(okBody()));
            }),
          );
          await expectLater(
            c.complete(req),
            throwsA(
              isA<LlmException>().having(
                (e) => e.kind,
                'kind',
                LlmErrorKind.auth,
              ),
            ),
          );
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            final timer = parent.createTimer(zone, duration, callback);
            if (duration == config.timeout) timers.add(timer);
            return timer;
          },
        ),
      );
      expect(headersRead, 1);
      expect(sent, 0);
      expect(sleeps, isEmpty);
      expect(timers, hasLength(1));
      expect(timers.single.isActive, isFalse);
    },
  );

  test(
    'cancel pending auth promptly, cancel timer, and ignore late headers',
    () async {
      final timers = <Timer>[];
      final headers = Completer<String>();
      final cancel = CancelToken();
      var sent = 0;
      await runZoned(
        () async {
          final c = OpenAiCompatibleClient(
            config: config,
            auth: ApiKeyAuth.lazy(() => headers.future),
            sleep: noSleep,
            httpClient: MockClient((_) async {
              sent++;
              return res(jsonEncode(okBody()));
            }),
          );
          final request = c.complete(req, cancel: cancel);
          await Future<void>.delayed(Duration.zero);
          cancel.cancel('auth cancelled');
          await expectLater(
            request.timeout(const Duration(seconds: 1)),
            throwsA(
              isA<LlmException>().having(
                (e) => e.kind,
                'kind',
                LlmErrorKind.cancelled,
              ),
            ),
          );
          headers.complete('late');
          await Future<void>.delayed(Duration.zero);
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            final timer = parent.createTimer(zone, duration, callback);
            if (duration == config.timeout) timers.add(timer);
            return timer;
          },
        ),
      );
      expect(sent, 0);
      expect(sleeps, isEmpty);
      expect(timers, hasLength(1));
      expect(timers.single.isActive, isFalse);
    },
  );

  test(
    'pending auth times out without HTTP; a late auth error is handled',
    () async {
      final headers = Completer<String>();
      var sent = 0;
      final c = OpenAiCompatibleClient(
        config: config.copyWith(
          timeout: const Duration(milliseconds: 30),
          maxRetries: 0,
        ),
        auth: ApiKeyAuth.lazy(() => headers.future),
        httpClient: MockClient((_) async {
          sent++;
          return res(jsonEncode(okBody()));
        }),
      );
      await expectLater(
        c.complete(req).timeout(const Duration(seconds: 1)),
        throwsA(
          isA<LlmException>().having(
            (e) => e.kind,
            'kind',
            LlmErrorKind.timeout,
          ),
        ),
      );
      headers.completeError(StateError('late auth failure'));
      await Future<void>.delayed(Duration.zero);
      expect(sent, 0);
    },
  );
}
