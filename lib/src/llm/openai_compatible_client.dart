/// OpenAI 兼容 `/chat/completions` 客户端（DeepSeek、OpenCSG 网关、中转 Worker 均适用）。
/// 非流式；超时与取消都会真正中止 HTTP 请求。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/auth.dart';
import '../config/llm_config.dart';
import '../config/pricing.dart';
import '../util/json.dart';
import 'cancel_token.dart';
import 'llm_client.dart';
import 'llm_types.dart';

class OpenAiCompatibleClient implements LlmClient {
  OpenAiCompatibleClient({
    required this.config,
    this.auth = const NoAuth(),
    http.Client? httpClient,
    Future<void> Function(Duration)? sleep,
  }) : _http = httpClient ?? http.Client(),
       _sleep = sleep ?? Future<void>.delayed;

  final LlmConfig config;
  final AuthProvider auth;
  final http.Client _http;
  final Future<void> Function(Duration) _sleep;

  @override
  String get model => config.model;

  @override
  Pricing? get pricing => config.pricing;

  Map<String, Object?> buildBody(LlmRequest r) => {
    'model': config.model,
    'messages': [for (final m in r.messages) m.toJson()],
    'max_tokens': r.maxTokens ?? config.maxTokens,
    if ((r.temperature ?? config.temperature) != null)
      'temperature': r.temperature ?? config.temperature,
    if (r.jsonMode ?? config.jsonMode) 'response_format': {'type': 'json_object'},
    'stream': false,
    ...config.extraBody,
  };

  @override
  Future<LlmResponse> complete(LlmRequest request, {CancelToken? cancel}) async {
    final sw = Stopwatch()..start();
    final body = jsonEncode(buildBody(request));
    var attempt = 0;
    while (true) {
      attempt++;
      if (cancel?.isCancelled ?? false) {
        throw LlmException(LlmErrorKind.cancelled, cancel!.reason ?? 'cancelled',
            latency: sw.elapsed, httpAttempts: attempt - 1);
      }
      try {
        final r = await _once(body, cancel);
        return r.withMeta(sw.elapsed, attempt);
      } on LlmException catch (e) {
        final retry = e.isTransient && attempt <= config.maxRetries && !(cancel?.isCancelled ?? false);
        if (!retry) {
          throw LlmException(e.kind, e.message,
              statusCode: e.statusCode, usage: e.usage, latency: sw.elapsed, httpAttempts: attempt);
        }
        final wait = _retryAfter ?? config.retryBackoff * (1 << (attempt - 1));
        _retryAfter = null;
        // 退避等待可被取消：取消后立即结束，不再发下一次请求。
        await Future.any<void>([_sleep(wait), if (cancel != null) cancel.whenCancelled]);
        if (cancel?.isCancelled ?? false) {
          throw LlmException(LlmErrorKind.cancelled, cancel!.reason ?? 'cancelled',
              statusCode: e.statusCode, latency: sw.elapsed, httpAttempts: attempt);
        }
      }
    }
  }

  Duration? _retryAfter;

  Future<_Raw> _once(String body, CancelToken? cancel) async {
    final abort = Completer<void>();
    var timedOut = false;
    final timer = Timer(config.timeout, () {
      timedOut = true;
      if (!abort.isCompleted) abort.complete();
    });
    unawaited(
      cancel?.whenCancelled.then((_) {
        if (!abort.isCompleted) abort.complete();
      }),
    );
    http.Response res;
    try {
      Map<String, String> headers;
      try {
        // Auth can involve local persistence or token refresh. It shares the
        // attempt deadline/cancellation, and a late result must never send HTTP.
        headers = await Future.any<Map<String, String>>([
          Future<Map<String, String>>.sync(auth.headers),
          abort.future.then<Map<String, String>>(
            (_) => throw http.RequestAbortedException(),
          ),
        ]);
      } on http.RequestAbortedException {
        rethrow;
      } on Object {
        throw LlmException(
          LlmErrorKind.auth,
          'Authentication headers unavailable',
        );
      }
      if (abort.isCompleted || (cancel?.isCancelled ?? false)) {
        throw http.RequestAbortedException();
      }
      final req =
          http.AbortableRequest(
              'POST',
              config.chatCompletionsUri,
              abortTrigger: abort.future,
            )
            ..headers.addAll({
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              ...headers,
            })
            ..body = body;
      res = await http.Response.fromStream(await _http.send(req));
    } on http.RequestAbortedException {
      if (timedOut) {
        throw LlmException(
          LlmErrorKind.timeout,
          '超过 ${config.timeout.inSeconds}s 未响应',
        );
      }
      throw LlmException(LlmErrorKind.cancelled, cancel?.reason ?? 'cancelled');
    } on LlmException {
      rethrow;
    } on http.ClientException catch (e) {
      throw LlmException(LlmErrorKind.network, e.message);
    } on Exception catch (e) {
      // dart:io SocketException / HandshakeException 等（不 import dart:io，保持 Web 可用）。
      throw LlmException(LlmErrorKind.network, '$e');
    } finally {
      timer.cancel();
      if (!abort.isCompleted) abort.complete();
    }
    return _parse(res);
  }

  _Raw _parse(http.Response res) {
    final status = res.statusCode;
    final text = utf8.decode(res.bodyBytes, allowMalformed: true);
    if (status != 200) {
      final msg = _errorMessage(text);
      if (status == 401 || status == 403) throw LlmException(LlmErrorKind.auth, msg, statusCode: status);
      if (status == 429) {
        final ra = int.tryParse(res.headers['retry-after'] ?? '');
        if (ra != null) _retryAfter = Duration(seconds: ra.clamp(0, 30));
        throw LlmException(LlmErrorKind.rateLimited, msg, statusCode: status);
      }
      throw LlmException(LlmErrorKind.http, msg, statusCode: status);
    }
    Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw LlmException(LlmErrorKind.badResponse, '返回体不是 JSON：${_clip(text)}', statusCode: status);
    }
    final j = asMap(json);
    final choices = asList(j['choices']);
    if (choices.isEmpty) {
      throw LlmException(LlmErrorKind.badResponse, '没有 choices：${_clip(text)}', statusCode: status);
    }
    final choice = asMap(choices.first);
    final msg = asMap(choice['message']);
    final usage = TokenUsage.fromOpenAi(j['usage']);
    final content = asString(msg['content']) ?? '';
    final finish = asString(choice['finish_reason']);
    if (finish == 'length') {
      throw LlmException(LlmErrorKind.truncated,
          '输出被 max_tokens 截断（completion ${usage.completionTokens}，其中推理 ${usage.reasoningTokens}）',
          usage: usage);
    }
    if (content.trim().isEmpty) {
      throw LlmException(LlmErrorKind.badResponse, '正文为空', usage: usage);
    }
    return _Raw(content, asString(msg['reasoning_content']), usage, asString(j['model']), finish);
  }

  static String _errorMessage(String body) {
    try {
      final e = asMap(jsonDecode(body))['error'];
      final m = e is Map ? asString(e['message']) : asString(e);
      if (m != null) return m;
    } on FormatException {
      // 不是 JSON，用原文。
    }
    return _clip(body);
  }

  static String _clip(String s) => s.length <= 200 ? s : '${s.substring(0, 200)}…';

  void close() => _http.close();
}

class _Raw {
  const _Raw(this.content, this.reasoning, this.usage, this.model, this.finish);
  final String content;
  final String? reasoning;
  final TokenUsage usage;
  final String? model;
  final String? finish;

  LlmResponse withMeta(Duration latency, int attempts) => LlmResponse(
    content: content,
    reasoning: reasoning,
    usage: usage,
    model: model,
    finishReason: finish,
    latency: latency,
    httpAttempts: attempts,
  );
}
