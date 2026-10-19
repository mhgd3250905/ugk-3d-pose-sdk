/// 调用记录：每次模型调用一条（重写算第二条），便于上线后核算消费、看通过率。
library;

import 'dart:async';

import '../llm/llm_types.dart';
import '../util/json.dart';

/// 单次调用的结果。
enum CallOutcome {
  /// 输出通过校验并被采用（首轮）。
  passed,

  /// 重写轮的输出通过校验并被采用。
  rewritten,

  /// 输出没过校验（触发了重写或回落）。
  rejected,

  /// 网络 / HTTP / 截断等错误。
  error,
  cancelled,
}

/// 这一轮 ask 的最终走向（同一 turnId 的每条记录都带上）。
enum TurnOutcome {
  /// 模型首轮输出直接用。
  model,

  /// 模型重写后用。
  rewritten,

  /// 回落到 App 的模板生成器。
  fallback,

  /// 失败且没有回落。
  error,
  cancelled,

  /// App 的 preflight 直接回答（未调用模型，不产生调用记录）。
  preflight,
}

class UsageRecord {
  const UsageRecord({
    required this.id,
    required this.turnId,
    required this.at,
    required this.appId,
    required this.profileId,
    required this.model,
    required this.promptVersion,
    required this.promptHash,
    required this.catalogVersion,
    required this.attempt,
    required this.usage,
    required this.latency,
    required this.outcome,
    required this.turnOutcome,
    this.httpAttempts = 1,
    this.finishReason,
    this.errorKind,
    this.errorMessage,
    this.issueCodes = const [],
    this.cost,
    this.currency,
  });

  final String id;
  final String turnId;

  /// UTC（JSON 里带 Z）。
  final DateTime at;
  final String appId;
  final String profileId;
  final String model;
  final String promptVersion;
  final String promptHash;
  final String catalogVersion;

  /// 1 = 首轮，2 = 重写。
  final int attempt;
  final TokenUsage usage;
  final Duration latency;
  final CallOutcome outcome;
  final TurnOutcome turnOutcome;
  final int httpAttempts;
  final String? finishReason;
  final String? errorKind;
  final String? errorMessage;

  /// 没过校验时的问题代码（统计哪类错最多）。
  final List<String> issueCodes;

  /// 按 [Pricing] 估算；null = 没配单价。
  final double? cost;
  final String? currency;

  Map<String, Object?> toJson() => {
    'id': id,
    'turnId': turnId,
    'at': at.toIso8601String(),
    'appId': appId,
    'profileId': profileId,
    'model': model,
    'promptVersion': promptVersion,
    'promptHash': promptHash,
    'catalogVersion': catalogVersion,
    'attempt': attempt,
    ...usage.toJson(),
    'latencyMs': latency.inMilliseconds,
    'httpAttempts': httpAttempts,
    'outcome': outcome.name,
    'turnOutcome': turnOutcome.name,
    if (finishReason != null) 'finishReason': finishReason,
    if (errorKind != null) 'errorKind': errorKind,
    if (errorMessage != null) 'errorMessage': errorMessage,
    if (issueCodes.isNotEmpty) 'issueCodes': issueCodes,
    if (cost != null) 'cost': double.parse(cost!.toStringAsFixed(8)),
    if (currency != null) 'currency': currency,
  };

  factory UsageRecord.fromJson(Map<String, Object?> j) => UsageRecord(
    id: asString(j['id']) ?? '',
    turnId: asString(j['turnId']) ?? '',
    at: DateTime.parse(asString(j['at'])!),
    appId: asString(j['appId']) ?? '',
    profileId: asString(j['profileId']) ?? '',
    model: asString(j['model']) ?? '',
    promptVersion: asString(j['promptVersion']) ?? '',
    promptHash: asString(j['promptHash']) ?? '',
    catalogVersion: asString(j['catalogVersion']) ?? '',
    attempt: asInt(j['attempt']) ?? 1,
    usage: TokenUsage.fromJson(j),
    latency: Duration(milliseconds: asInt(j['latencyMs']) ?? 0),
    httpAttempts: asInt(j['httpAttempts']) ?? 1,
    outcome: CallOutcome.values.byName(asString(j['outcome'])!),
    turnOutcome: TurnOutcome.values.byName(asString(j['turnOutcome'])!),
    finishReason: asString(j['finishReason']),
    errorKind: asString(j['errorKind']),
    errorMessage: asString(j['errorMessage']),
    issueCodes: asStringList(j['issueCodes']),
    cost: asDouble(j['cost']),
    currency: asString(j['currency']),
  );
}

/// 记录去处。实现应尽量不抛错（记账失败不能影响用户对话）；SDK 也会吞掉并忽略 sink 的异常。
abstract interface class UsageSink {
  Future<void> record(UsageRecord r);
}

/// 内存（测试、调试页）。
class MemoryUsageSink implements UsageSink {
  final List<UsageRecord> records = [];
  @override
  Future<void> record(UsageRecord r) async => records.add(r);

  UsageSummary get summary => UsageSummary.of(records);
}

/// 回调（上报到自己的服务 / 统计平台）。
class CallbackUsageSink implements UsageSink {
  CallbackUsageSink(this.onRecord);
  final FutureOr<void> Function(UsageRecord r) onRecord;
  @override
  Future<void> record(UsageRecord r) async => onRecord(r);
}

/// 同时写多个去处；单个出错不影响其他。
class MultiUsageSink implements UsageSink {
  MultiUsageSink(this.sinks);
  final List<UsageSink> sinks;
  @override
  Future<void> record(UsageRecord r) async {
    for (final s in sinks) {
      try {
        await s.record(r);
      } on Object {
        // 记账失败不影响其他 sink。
      }
    }
  }
}

/// 汇总：调用数、token、花费、各走向的轮数。
class UsageSummary {
  const UsageSummary({
    required this.calls,
    required this.turns,
    required this.usage,
    required this.cost,
    required this.turnOutcomes,
    required this.byModel,
  });

  final int calls;
  final int turns;
  final TokenUsage usage;
  final double cost;
  final Map<TurnOutcome, int> turnOutcomes;
  final Map<String, TokenUsage> byModel;

  factory UsageSummary.of(Iterable<UsageRecord> rs) {
    var usage = TokenUsage.zero;
    var cost = 0.0;
    final turns = <String, TurnOutcome>{};
    final byModel = <String, TokenUsage>{};
    var calls = 0;
    for (final r in rs) {
      calls++;
      usage += r.usage;
      cost += r.cost ?? 0;
      turns[r.turnId] = r.turnOutcome;
      byModel[r.model] = (byModel[r.model] ?? TokenUsage.zero) + r.usage;
    }
    final outcomes = <TurnOutcome, int>{};
    for (final o in turns.values) {
      outcomes[o] = (outcomes[o] ?? 0) + 1;
    }
    return UsageSummary(calls: calls, turns: turns.length, usage: usage, cost: cost, turnOutcomes: outcomes, byModel: byModel);
  }
}
