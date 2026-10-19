/// 测试 / 离线演示用的假模型：按脚本依次返回，记录收到的每个请求。
library;

import 'dart:async';
import 'dart:convert';

import '../config/pricing.dart';
import 'cancel_token.dart';
import 'llm_client.dart';
import 'llm_types.dart';

/// 一步脚本：返回正文，或抛错，或按请求动态生成。
typedef FakeStep = FutureOr<Object> Function(LlmRequest request);

class FakeLlmClient implements LlmClient {
  /// [script] 每项可以是：`String`（正文）、`Map`（会被 jsonEncode 成正文）、
  /// [LlmResponse]、[LlmException]（抛出）或 [FakeStep]。脚本用完后抛 [StateError]。
  FakeLlmClient(
    List<Object> script, {
    this.model = 'fake-model',
    this.usage = const TokenUsage(promptTokens: 1000, completionTokens: 200, reasoningTokens: 120, cachedTokens: 600),
    this.latency = const Duration(milliseconds: 5),
    this.pricing,
  }) : _script = List.of(script);

  @override
  final String model;
  final TokenUsage usage;
  final Duration latency;
  @override
  final Pricing? pricing;
  final List<Object> _script;

  /// 收到的请求，便于断言提示词。
  final List<LlmRequest> requests = [];

  int get remaining => _script.length;

  @override
  Future<LlmResponse> complete(LlmRequest request, {CancelToken? cancel}) async {
    requests.add(request);
    if (_script.isEmpty) throw StateError('FakeLlmClient: 脚本已用完（第 ${requests.length} 次调用）');
    var step = _script.removeAt(0);
    if (step is FakeStep) step = await step(request);
    if (latency > Duration.zero) {
      await Future.any([Future<void>.delayed(latency), if (cancel != null) cancel.whenCancelled]);
    }
    if (cancel?.isCancelled ?? false) throw const LlmException(LlmErrorKind.cancelled, 'cancelled');
    return switch (step) {
      final LlmException e => throw e,
      final LlmResponse r => r,
      final String s => LlmResponse(content: s, usage: usage, model: model, finishReason: 'stop', latency: latency),
      final Map<Object?, Object?> m => LlmResponse(
        content: jsonEncode(m),
        usage: usage,
        model: model,
        finishReason: 'stop',
        latency: latency,
      ),
      _ => throw ArgumentError('FakeLlmClient: 不支持的脚本项 ${step.runtimeType}'),
    };
  }
}
