import '../config/pricing.dart';
import 'cancel_token.dart';
import 'llm_types.dart';

/// 模型客户端接口。实现：[OpenAiCompatibleClient]（真实）、[FakeLlmClient]（测试）。
abstract interface class LlmClient {
  /// 失败时抛 [LlmException]。
  Future<LlmResponse> complete(LlmRequest request, {CancelToken? cancel});

  /// 用于调用记录的模型名。
  String get model;

  /// 估算花费用的单价；null = 不估算。
  Pricing? get pricing;
}
