/// OpenAI 兼容 `/chat/completions` 客户端（DeepSeek、OpenCSG 网关、中转 Worker 均适用）。
/// 非流式；支持工具调用（tools / tool_calls）；超时与取消都会真正中止 HTTP 请求。
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
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
    if (r.tools.isNotEmpty) 'tools': [for (final t in r.tools) t.toJson()],
    if (r.tools.isNotEmpty && r.toolChoice != null) 'tool_choice': r.toolChoice,
    if (r.tools.isEmpty && (r.jsonMode ?? config.jsonMode))
      'response_format': {'type': 'json_object'},
    'stream': false,
    ...config.extraBody,
  };

  @override
  Future<LlmResponse> complete(
    LlmRequest request, {
    CancelToken? cancel,
  }) async {
    final sw = Stopwatch()..start();
    final body = jsonEncode(buildBody(request));
    var attempt = 0;
    while (true) {
      attempt++;
      if (cancel?.isCancelled ?? false) {
        throw LlmException(
          LlmErrorKind.cancelled,
          cancel!.reason ?? 'cancelled',
          latency: sw.elapsed,
          httpAttempts: attempt - 1,
        );
      }
      try {
        final r = await _once(body, cancel);
        return r.withMeta(sw.elapsed, attempt);
      } on LlmException catch (e) {
        final retry =
            e.isTransient &&
            attempt <= config.maxRetries &&
            !(cancel?.isCancelled ?? false);
        if (!retry) {
          _retryAfter = null;
          throw LlmException(
            e.kind,
            e.message,
            statusCode: e.statusCode,
            usage: e.usage,
            latency: sw.elapsed,
            httpAttempts: attempt,
            retryAfter: e.retryAfter,
            finishReason: e.finishReason,
            responseDiagnostic: e.responseDiagnostic,
          );
        }
        final wait = _retryAfter ?? config.retryBackoff * (1 << (attempt - 1));
        _retryAfter = null;
        // 退避等待可被取消：取消后立即结束，不再发下一次请求。
        await Future.any<void>([
          _sleep(wait),
          if (cancel != null) cancel.whenCancelled,
        ]);
        if (cancel?.isCancelled ?? false) {
          throw LlmException(
            LlmErrorKind.cancelled,
            cancel!.reason ?? 'cancelled',
            statusCode: e.statusCode,
            latency: sw.elapsed,
            httpAttempts: attempt,
          );
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
              ...config.headers,
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
      if (status == 401 || status == 403) {
        throw LlmException(LlmErrorKind.auth, msg, statusCode: status);
      }
      final ra = int.tryParse(res.headers['retry-after'] ?? '');
      final retryAfter = ra == null || (status != 429 && status != 503)
          ? null
          : Duration(seconds: ra.clamp(0, 30));
      if (retryAfter != null) _retryAfter = retryAfter;
      if (status == 429) {
        throw LlmException(
          LlmErrorKind.rateLimited,
          msg,
          statusCode: status,
          retryAfter: retryAfter,
        );
      }
      throw LlmException(
        LlmErrorKind.http,
        msg,
        statusCode: status,
        retryAfter: retryAfter,
      );
    }
    Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      final eventStream =
          res.headers['content-type']?.split(';').first.trim().toLowerCase() ==
              'text/event-stream' ||
          RegExp(r'^\s*(?:data|event):').hasMatch(text);
      throw _badResponse(
        res,
        eventStream
            ? LlmResponseProblem.eventStream
            : LlmResponseProblem.nonJson,
        eventStream ? '返回体不是 JSON（收到 SSE）' : '返回体不是 JSON',
      );
    }
    final j = asMap(json);
    final usage = TokenUsage.fromOpenAi(j['usage']);
    final choices = asList(j['choices']);
    if (choices.isEmpty) {
      final hasError = j['error'] != null;
      throw _badResponse(
        res,
        hasError
            ? LlmResponseProblem.errorEnvelope
            : json is! Map ||
                  (j.containsKey('choices') && j['choices'] is! List)
            ? LlmResponseProblem.invalidShape
            : LlmResponseProblem.noChoices,
        hasError ? '没有 choices（HTTP 200 error 信封）' : '没有 choices',
        json: json,
        usage: usage,
      );
    }
    final choice = asMap(choices.first);
    final msg = asMap(choice['message']);
    final content = asString(msg['content']) ?? '';
    final finish = asString(choice['finish_reason']);
    if (finish == 'length') {
      throw LlmException(
        LlmErrorKind.truncated,
        '输出被 max_tokens 截断（completion ${usage.completionTokens}，其中推理 ${usage.reasoningTokens}）',
        usage: usage,
        statusCode: status,
        finishReason: finish,
      );
    }
    final calls = [
      for (final (i, c) in asList(msg['tool_calls']).indexed)
        LlmToolCall.fromOpenAi(c, i),
    ];
    if (content.trim().isEmpty && calls.isEmpty) {
      final invalidShape =
          choices.first is! Map ||
          choice['message'] is! Map ||
          (msg['content'] != null && msg['content'] is! String) ||
          (msg['tool_calls'] != null && msg['tool_calls'] is! List) ||
          (msg['reasoning_content'] != null &&
              msg['reasoning_content'] is! String);
      final reasoningOnly =
          (asString(msg['reasoning_content'])?.trim().isNotEmpty ?? false);
      throw _badResponse(
        res,
        invalidShape
            ? LlmResponseProblem.invalidShape
            : reasoningOnly
            ? LlmResponseProblem.reasoningOnly
            : LlmResponseProblem.emptyContent,
        invalidShape
            ? '正文为空（响应结构无效）'
            : reasoningOnly
            ? '正文为空（仅有推理）'
            : '正文为空',
        json: json,
        usage: usage,
        finishReason: finish,
      );
    }
    return _Raw(
      content,
      asString(msg['reasoning_content']),
      usage,
      asString(j['model']),
      finish,
      calls,
    );
  }

  static LlmException _badResponse(
    http.Response res,
    LlmResponseProblem subtype,
    String message, {
    Object? json,
    TokenUsage usage = TokenUsage.zero,
    String? finishReason,
  }) {
    final j = asMap(json);
    final choices = j['choices'];
    final first = choices is List && choices.isNotEmpty ? choices.first : null;
    final choice = asMap(first);
    final msg = asMap(choice['message']);
    final safeFinish = _safeFinishReason(finishReason);
    final unknownFinish = safeFinish == 'unknown' && finishReason != null;
    String fieldShape(Map<String, Object?> map, String key) =>
        map.containsKey(key) ? _shape(map[key]) : 'missing';
    final diagnostic = LlmResponseDiagnostic(
      subtype: subtype,
      statusCode: res.statusCode,
      bodyBytes: res.bodyBytes.length,
      bodySha256: sha256.convert(res.bodyBytes).toString(),
      shapes: Map.unmodifiable({
        if (subtype != LlmResponseProblem.nonJson &&
            subtype != LlmResponseProblem.eventStream) ...{
          'root': _shape(json),
          'choices': fieldShape(j, 'choices'),
          if (choices is List && choices.isNotEmpty) ...{
            'choices[0]': _shape(first),
            'message': fieldShape(choice, 'message'),
            'finish_reason': fieldShape(choice, 'finish_reason'),
            if (choice['message'] is Map) ...{
              'content': fieldShape(msg, 'content'),
              'tool_calls': fieldShape(msg, 'tool_calls'),
              'reasoning_content': fieldShape(msg, 'reasoning_content'),
            },
          },
        },
      }),
      choicesCount: choices is List ? choices.length : null,
      toolCallsCount: msg['tool_calls'] is List
          ? (msg['tool_calls'] as List).length
          : null,
      contentLength: asString(msg['content'])?.length,
      reasoningLength: asString(msg['reasoning_content'])?.length,
      finishReason: safeFinish,
      finishReasonLength: unknownFinish ? finishReason.length : null,
      finishReasonSha256: unknownFinish
          ? sha256.convert(utf8.encode(finishReason)).toString()
          : null,
      hasError: j['error'] != null,
    );
    return LlmException(
      LlmErrorKind.badResponse,
      '$message [response: ${jsonEncode(diagnostic.toJson())}]',
      statusCode: res.statusCode,
      usage: usage,
      finishReason: safeFinish,
      responseDiagnostic: diagnostic,
    );
  }

  // 仅失败诊断使用：异常网关可能把正文塞进 finish_reason，不能原样记账。
  // 成功响应仍按原协议回传此字段。
  static String? _safeFinishReason(String? value) => switch (value) {
    null => null,
    'stop' ||
    'length' ||
    'tool_calls' ||
    'function_call' ||
    'content_filter' ||
    'insufficient_system_resource' ||
    'error' => value,
    _ => 'unknown',
  };

  static String _shape(Object? value) => switch (value) {
    null => 'null',
    Map() => 'object',
    List() => 'array',
    String() => 'string',
    num() => 'number',
    bool() => 'boolean',
    _ => 'other',
  };

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

  static String _clip(String s) =>
      s.length <= 200 ? s : '${s.substring(0, 200)}…';

  void close() => _http.close();
}

class _Raw {
  const _Raw(
    this.content,
    this.reasoning,
    this.usage,
    this.model,
    this.finish, [
    this.toolCalls = const [],
  ]);
  final List<LlmToolCall> toolCalls;
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
    toolCalls: toolCalls,
  );
}
