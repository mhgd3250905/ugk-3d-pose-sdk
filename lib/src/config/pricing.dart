/// 每百万 token 单价，用于估算花费（以服务商账单为准）。
library;

import '../llm/llm_types.dart';

class Pricing {
  const Pricing({
    required this.inputPerMillion,
    required this.outputPerMillion,
    double? cachedInputPerMillion,
    this.currency = 'CNY',
  }) : cachedInputPerMillion = cachedInputPerMillion ?? inputPerMillion;

  /// 未命中缓存的输入。
  final double inputPerMillion;

  /// 命中前缀缓存的输入（DeepSeek 等通常便宜很多）。
  final double cachedInputPerMillion;

  /// 输出；推理 token 计入 completion_tokens，按输出价计。
  final double outputPerMillion;
  final String currency;

  double cost(TokenUsage u) {
    final cached = u.cachedTokens.clamp(0, u.promptTokens);
    return ((u.promptTokens - cached) * inputPerMillion +
            cached * cachedInputPerMillion +
            u.completionTokens * outputPerMillion) /
        1e6;
  }

  Map<String, Object?> toJson() => {
    'inputPerMillion': inputPerMillion,
    'cachedInputPerMillion': cachedInputPerMillion,
    'outputPerMillion': outputPerMillion,
    'currency': currency,
  };

  factory Pricing.fromJson(Map<String, Object?> j) => Pricing(
    inputPerMillion: (j['inputPerMillion'] as num).toDouble(),
    outputPerMillion: (j['outputPerMillion'] as num).toDouble(),
    cachedInputPerMillion: (j['cachedInputPerMillion'] as num?)?.toDouble(),
    currency: j['currency'] as String? ?? 'CNY',
  );
}
