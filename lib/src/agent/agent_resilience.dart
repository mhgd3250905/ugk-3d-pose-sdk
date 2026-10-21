/// Agent 循环的韧性部件：单步请求失败分类与退避、上下文预算压缩、失败原因。
library;

import 'dart:math' as math;

import '../llm/llm_types.dart';

/// 单次模型请求失败的分类。
enum RequestErrorClass {
  timeout,
  network,

  /// 429。
  rateLimited,

  /// 5xx / 408 / 409 / 425。
  server,

  /// 空响应、返回体解析失败、流中断。
  badResponse,

  /// 400 且错误信息指向上下文超长：先强制压缩再重试一次。
  contextTooLong,
  auth,

  /// 其他 400 / 4xx。
  badRequest,
  notFound,

  /// 输出被 max_tokens 截断。
  truncated,
  cancelled,
  other;

  bool get retryable =>
      this == timeout ||
      this == network ||
      this == rateLimited ||
      this == server ||
      this == badResponse;

  static final _ctxRe = RegExp(
    r'context|length|token|too long|maximum|exceed',
    caseSensitive: false,
  );

  static RequestErrorClass of(Object e) {
    if (e is! LlmException) return RequestErrorClass.other;
    final code = e.statusCode;
    switch (e.kind) {
      case LlmErrorKind.timeout:
        return timeout;
      case LlmErrorKind.network:
        return network;
      case LlmErrorKind.rateLimited:
        return rateLimited;
      case LlmErrorKind.auth:
        return auth;
      case LlmErrorKind.badResponse:
        return badResponse;
      case LlmErrorKind.truncated:
        return truncated;
      case LlmErrorKind.cancelled:
        return cancelled;
      case LlmErrorKind.http:
        if (code == null) return server;
        if (code == 429) return rateLimited;
        if (code >= 500 || code == 408 || code == 409 || code == 425) {
          return server;
        }
        if (code == 400 || code == 413) {
          return _ctxRe.hasMatch(e.message) ? contextTooLong : badRequest;
        }
        if (code == 401 || code == 403) return auth;
        if (code == 404) return notFound;
        return badRequest;
    }
  }
}

/// 本轮最终失败的方式（回落时放在 [AgentRequestFailed.kind]）。
enum AgentFailureKind {
  /// 可重试错误，重试次数用尽。
  retriesExhausted,

  /// 不可重试错误（400 / 401 / 403 / 404 / 截断 / 压缩后仍超长）。
  nonRetryable,

  /// 超过整轮总时限。
  turnTimeout,
}

/// 模型请求最终失败（回落时放在 `CoachTurnResult.error`）。
class AgentRequestFailed implements Exception {
  const AgentRequestFailed(
    this.kind, {
    this.errorClass,
    this.attempts = 1,
    this.cause,
  });
  final AgentFailureKind kind;

  /// 最后一次失败的分类（整轮超时且没有请求失败时为 null）。
  final RequestErrorClass? errorClass;

  /// 这一步共发起的请求次数（含首次）。
  final int attempts;
  final Object? cause;

  @override
  String toString() =>
      'AgentRequestFailed(${kind.name}${errorClass == null ? '' : ' ${errorClass!.name}'}, '
      'attempts=$attempts${cause == null ? '' : ', $cause'})';
}

/// 空转（相同工具调用 / 连续无新信息）提示后再犯（回落时放在 `CoachTurnResult.error`）。
class AgentStalled implements Exception {
  const AgentStalled(this.why);
  final String why;
  @override
  String toString() => 'AgentStalled($why)';
}

/// 单步退避：`base × 2^(n-1)` 封顶 [max]，乘 0.8–1.2 抖动（再封顶）；Retry-After 优先（封顶 [max]）。
Duration retryDelay(
  int retry, {
  required Duration base,
  required Duration max,
  Duration? retryAfter,
  required double Function() random,
}) {
  if (retryAfter != null) return retryAfter > max ? max : retryAfter;
  final raw = base.inMicroseconds * math.pow(2, retry - 1);
  final capped = math.min(raw.toDouble(), max.inMicroseconds.toDouble());
  final jittered = capped * (0.8 + 0.4 * random());
  return Duration(
    microseconds: math.min(jittered, max.inMicroseconds.toDouble()).round(),
  );
}

/// 粗估 token：ASCII 约 4 字符 1 token，其余（中文等）1 字符 1 token。
int estimateTokens(String s) {
  var ascii = 0, other = 0;
  for (final c in s.codeUnits) {
    if (c < 128) {
      ascii++;
    } else {
      other++;
    }
  }
  return other + (ascii / 4).ceil();
}

/// 推理仅作协议回放，不计入可用上下文预算；压缩只替换工具结果。
int estimateMessageTokens(LlmMessage m) =>
    4 +
    estimateTokens(m.content) +
    m.toolCalls.fold(
      0,
      (n, t) => n + estimateTokens(t.name) + estimateTokens(t.arguments),
    );

/// 可压缩的中间工具结果（read / ls）。
class CompressibleResult {
  const CompressibleResult(this.toolCallId, this.summary, {this.path});
  final String toolCallId;

  /// 一行摘要（如「已读 action-library/index/scene/home.md（略）」）。
  final String summary;

  /// read 的路径：压缩后从「已读」集合移除，模型再读时给全文。
  final String? path;
}

/// 把 [msgs]（本轮中间消息）里较早的 read / ls 结果替换成一行摘要，直到估算总量 ≤ [budget]
/// （[force] 时压掉全部可压缩项）。最近 [keepRecent] 个工具步完整保留；assistant 的 tool_calls
/// 与对应 tool 消息的 id 不变，协议保持有效。返回被压缩项的 read 路径。
Set<String> compressContext(
  List<LlmMessage> msgs, {
  required int fixedTokens,
  required int budget,
  required int keepRecent,
  required Map<LlmMessage, CompressibleResult> compressible,
  bool force = false,
}) {
  var total =
      fixedTokens + msgs.fold(0, (n, m) => n + estimateMessageTokens(m));
  if (!force && total <= budget) return const {};
  // 最近 keepRecent 个带工具调用的 assistant 消息之后的内容不动。
  var protectFrom = msgs.length;
  var seen = 0;
  for (var i = msgs.length - 1; i >= 0 && seen < keepRecent; i--) {
    if (msgs[i].role == LlmRole.assistant && msgs[i].toolCalls.isNotEmpty) {
      seen++;
      protectFrom = i;
    }
  }
  final freed = <String>{};
  for (var i = 0; i < protectFrom; i++) {
    if (!force && total <= budget) break;
    final m = msgs[i];
    if (m.role != LlmRole.tool) continue;
    final c = compressible.remove(m);
    if (c == null || m.content == c.summary) continue;
    final next = LlmMessage.tool(m.toolCallId!, c.summary);
    total += estimateMessageTokens(next) - estimateMessageTokens(m);
    msgs[i] = next;
    if (c.path != null) freed.add(c.path!);
  }
  return freed;
}
