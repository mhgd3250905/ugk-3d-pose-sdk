/// 模型调用配置：地址、模型名与参数。只放「怎么调」，不放 key（见 [AuthProvider]）。
library;

import 'pricing.dart';

class LlmConfig {
  const LlmConfig({
    required this.baseUrl,
    required this.model,
    this.maxTokens = 4096,
    this.temperature,
    this.timeout = const Duration(seconds: 60),
    this.maxRetries = 1,
    this.retryBackoff = const Duration(milliseconds: 800),
    this.jsonMode = true,
    this.extraBody = const {},
    this.pricing,
  });

  /// OpenAI 兼容地址，到 `/v1` 为止，SDK 自己拼 `/chat/completions`。
  /// 中转 Worker 也填这里（例如 `https://coach-relay.example.workers.dev/v1`）。
  final String baseUrl;
  final String model;

  /// 推理模型的思考过程也占 completion 配额：给足，否则正文会被截断。
  final int maxTokens;

  /// null = 不传（部分推理模型不接受 temperature）。
  final double? temperature;

  /// 单次 HTTP 尝试的超时。
  final Duration timeout;

  /// 网络错误 / 超时 / 429 / 5xx 的额外重试次数（0 = 不重试）。
  final int maxRetries;

  /// 第 n 次重试前等待 `retryBackoff × 2^(n-1)`；服务端给了 Retry-After 用它。
  final Duration retryBackoff;

  /// 请求 `response_format: {"type": "json_object"}`。
  final bool jsonMode;

  /// 原样合并进请求体的额外字段（如 `top_p`、厂商私有参数）。
  final Map<String, Object?> extraBody;

  /// 单价；null = 不估算花费。
  final Pricing? pricing;

  Uri get chatCompletionsUri {
    final b = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return Uri.parse('$b/chat/completions');
  }

  LlmConfig copyWith({
    String? baseUrl,
    String? model,
    int? maxTokens,
    double? temperature,
    Duration? timeout,
    int? maxRetries,
    Duration? retryBackoff,
    bool? jsonMode,
    Map<String, Object?>? extraBody,
    Pricing? pricing,
  }) => LlmConfig(
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    maxTokens: maxTokens ?? this.maxTokens,
    temperature: temperature ?? this.temperature,
    timeout: timeout ?? this.timeout,
    maxRetries: maxRetries ?? this.maxRetries,
    retryBackoff: retryBackoff ?? this.retryBackoff,
    jsonMode: jsonMode ?? this.jsonMode,
    extraBody: extraBody ?? this.extraBody,
    pricing: pricing ?? this.pricing,
  );

  /// 当前选定：OpenCSG 网关上的 DeepSeek（推理模型，返回 reasoning_content）。
  /// 单价不内置（以账单为准），由 App 通过 [pricing] 传入。
  static const deepSeekOpenCsg = LlmConfig(
    baseUrl: 'https://opencsg.com/aigateway/v1',
    model: 'deepseek-v4.1-flash-1017',
    maxTokens: 6000,
    timeout: Duration(seconds: 90),
  );
}
