/// 模型调用的请求 / 响应 / 错误类型（与具体服务商无关）。
library;

import '../util/json.dart';

enum LlmRole { system, user, assistant }

class LlmMessage {
  const LlmMessage(this.role, this.content);
  const LlmMessage.system(this.content) : role = LlmRole.system;
  const LlmMessage.user(this.content) : role = LlmRole.user;
  const LlmMessage.assistant(this.content) : role = LlmRole.assistant;

  final LlmRole role;
  final String content;

  Map<String, Object?> toJson() => {'role': role.name, 'content': content};

  @override
  String toString() => '${role.name}: $content';
}

class LlmRequest {
  const LlmRequest({required this.messages, this.maxTokens, this.temperature, this.jsonMode});
  final List<LlmMessage> messages;

  /// 覆盖 [LlmConfig] 的同名参数；null = 用配置。
  final int? maxTokens;
  final double? temperature;
  final bool? jsonMode;
}

/// token 用量。DeepSeek / OpenAI 的 completion_tokens 已包含推理 token。
class TokenUsage {
  const TokenUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.reasoningTokens = 0,
    this.cachedTokens = 0,
  });

  static const zero = TokenUsage();

  final int promptTokens;
  final int completionTokens;

  /// completion 中用于思考的部分（已计入 [completionTokens]）。
  final int reasoningTokens;

  /// prompt 中命中前缀缓存的部分（已计入 [promptTokens]）。
  final int cachedTokens;

  int get totalTokens => promptTokens + completionTokens;

  TokenUsage operator +(TokenUsage o) => TokenUsage(
    promptTokens: promptTokens + o.promptTokens,
    completionTokens: completionTokens + o.completionTokens,
    reasoningTokens: reasoningTokens + o.reasoningTokens,
    cachedTokens: cachedTokens + o.cachedTokens,
  );

  /// 解析 OpenAI 兼容 `usage`：兼容 OpenAI（`*_tokens_details`）与
  /// DeepSeek（`prompt_cache_hit_tokens`）两种写法。
  factory TokenUsage.fromOpenAi(Object? raw) {
    final u = asMap(raw);
    final pd = asMap(u['prompt_tokens_details']);
    final cd = asMap(u['completion_tokens_details']);
    return TokenUsage(
      promptTokens: asInt(u['prompt_tokens']) ?? 0,
      completionTokens: asInt(u['completion_tokens']) ?? 0,
      reasoningTokens: asInt(cd['reasoning_tokens']) ?? asInt(u['reasoning_tokens']) ?? 0,
      cachedTokens: asInt(pd['cached_tokens']) ?? asInt(u['prompt_cache_hit_tokens']) ?? 0,
    );
  }

  Map<String, Object?> toJson() => {
    'promptTokens': promptTokens,
    'completionTokens': completionTokens,
    'reasoningTokens': reasoningTokens,
    'cachedTokens': cachedTokens,
  };

  factory TokenUsage.fromJson(Map<String, Object?> j) => TokenUsage(
    promptTokens: asInt(j['promptTokens']) ?? 0,
    completionTokens: asInt(j['completionTokens']) ?? 0,
    reasoningTokens: asInt(j['reasoningTokens']) ?? 0,
    cachedTokens: asInt(j['cachedTokens']) ?? 0,
  );

  @override
  String toString() =>
      'TokenUsage(prompt $promptTokens [cached $cachedTokens], completion $completionTokens [reasoning $reasoningTokens])';
}

class LlmResponse {
  const LlmResponse({
    required this.content,
    this.reasoning,
    this.usage = TokenUsage.zero,
    this.model,
    this.finishReason,
    this.latency = Duration.zero,
    this.httpAttempts = 1,
  });

  /// 正文（期望是 JSON）。
  final String content;

  /// 推理模型的 `reasoning_content`（只记录，不解析、不展示）。
  final String? reasoning;
  final TokenUsage usage;

  /// 服务端回报的模型名。
  final String? model;
  final String? finishReason;

  /// 从发出第一次请求到拿到结果（含重试）。
  final Duration latency;
  final int httpAttempts;
}

enum LlmErrorKind {
  /// 断网、DNS、连接被拒等。
  network,
  timeout,

  /// 鉴权失败（401/403）。
  auth,

  /// 被限流（429）。
  rateLimited,

  /// 其他 4xx / 5xx。
  http,

  /// 返回体不是预期结构，或正文为空。
  badResponse,

  /// finish_reason=length：被 max_tokens 截断（推理模型常见，调大 maxTokens）。
  truncated,
  cancelled,
}

class LlmException implements Exception {
  const LlmException(
    this.kind,
    this.message, {
    this.statusCode,
    this.usage = TokenUsage.zero,
    this.latency = Duration.zero,
    this.httpAttempts = 1,
  });

  final LlmErrorKind kind;
  final String message;
  final int? statusCode;

  /// 失败但已计费的用量（如被截断）。
  final TokenUsage usage;
  final Duration latency;
  final int httpAttempts;

  /// 换个时间可能就好了的错误（会重试）。
  bool get isTransient =>
      kind == LlmErrorKind.network ||
      kind == LlmErrorKind.timeout ||
      kind == LlmErrorKind.rateLimited ||
      (kind == LlmErrorKind.http && (statusCode ?? 0) >= 500);

  @override
  String toString() => 'LlmException(${kind.name}${statusCode == null ? '' : ' $statusCode'}): $message';
}
