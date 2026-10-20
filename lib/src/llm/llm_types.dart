/// 模型调用的请求 / 响应 / 错误类型（与具体服务商无关）。
library;

import 'dart:convert';

import '../util/json.dart';

enum LlmRole { system, user, assistant, tool }

class LlmMessage {
  const LlmMessage(this.role, this.content, {this.toolCalls = const [], this.toolCallId});
  const LlmMessage.system(this.content) : role = LlmRole.system, toolCalls = const [], toolCallId = null;
  const LlmMessage.user(this.content) : role = LlmRole.user, toolCalls = const [], toolCallId = null;
  const LlmMessage.assistant(this.content, {this.toolCalls = const []}) : role = LlmRole.assistant, toolCallId = null;

  /// 工具结果（回给模型的门禁结论）。
  const LlmMessage.tool(String this.toolCallId, this.content) : role = LlmRole.tool, toolCalls = const [];

  final LlmRole role;
  final String content;

  /// assistant 消息里的工具调用（原样回传，多轮时保持上下文）。
  final List<LlmToolCall> toolCalls;

  /// tool 消息对应的调用 id。
  final String? toolCallId;

  Map<String, Object?> toJson() => {
    'role': role.name,
    'content': role == LlmRole.assistant && toolCalls.isNotEmpty && content.isEmpty ? null : content,
    if (toolCalls.isNotEmpty) 'tool_calls': [for (final c in toolCalls) c.toJson()],
    if (toolCallId != null) 'tool_call_id': toolCallId,
  };

  @override
  String toString() => '${role.name}: $content${toolCalls.isEmpty ? '' : ' $toolCalls'}';
}

/// 模型发起的一次工具调用。[arguments] 是原始 JSON 字符串（门禁负责解析，不做修复）。
class LlmToolCall {
  const LlmToolCall({required this.id, required this.name, required this.arguments});
  final String id;
  final String name;
  final String arguments;

  Map<String, Object?> toJson() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': arguments},
  };

  factory LlmToolCall.fromOpenAi(Object? raw, int index) {
    final j = asMap(raw);
    final f = asMap(j['function']);
    final args = f['arguments'];
    return LlmToolCall(
      id: asString(j['id']) ?? 'call_$index',
      name: asString(f['name']) ?? '',
      arguments: args is String ? args : (args == null ? '' : _encode(args)),
    );
  }

  @override
  String toString() => '$name($arguments)';
}

String _encode(Object? v) => jsonEncode(v);

/// 提供给模型的工具（OpenAI function 格式）。
class LlmTool {
  const LlmTool({required this.name, required this.description, required this.parameters});
  final String name;
  final String description;

  /// JSON Schema。
  final Map<String, Object?> parameters;

  Map<String, Object?> toJson() => {
    'type': 'function',
    'function': {'name': name, 'description': description, 'parameters': parameters},
  };
}

class LlmRequest {
  const LlmRequest({required this.messages, this.maxTokens, this.temperature, this.jsonMode, this.tools = const [], this.toolChoice});
  final List<LlmMessage> messages;

  /// 覆盖 [LlmConfig] 的同名参数；null = 用配置。
  final int? maxTokens;
  final double? temperature;

  /// 带 [tools] 时不发 response_format（工具与 JSON 模式互斥）。
  final bool? jsonMode;
  final List<LlmTool> tools;

  /// `auto` / `none` / `required`；null = 不传（服务端默认 auto）。
  final String? toolChoice;
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
    this.toolCalls = const [],
  });

  /// 正文（旧接口期望是 JSON；工具版是给用户的文字，可为空）。
  final String content;

  /// 工具调用（工具版）。
  final List<LlmToolCall> toolCalls;

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
