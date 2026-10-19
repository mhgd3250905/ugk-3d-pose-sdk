import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_coach/ugk_coach_io.dart';

UsageRecord rec(String id, String turn, TurnOutcome t, {String model = 'm', double? cost}) => UsageRecord(
  id: id,
  turnId: turn,
  at: DateTime.utc(2026, 10, 20),
  appId: 'hiplab',
  profileId: 'hiplab',
  model: model,
  promptVersion: 'kernel-x@hiplab-1',
  promptHash: 'abcdefabcdef',
  catalogVersion: '0.1.0',
  attempt: 1,
  usage: const TokenUsage(promptTokens: 1000, completionTokens: 100, reasoningTokens: 80, cachedTokens: 500),
  latency: const Duration(milliseconds: 1234),
  outcome: CallOutcome.passed,
  turnOutcome: t,
  issueCodes: const ['reps_range'],
  cost: cost,
  currency: cost == null ? null : 'CNY',
);

void main() {
  test('Pricing：缓存与未缓存分开计价，推理 token 按输出价', () {
    const p = Pricing(inputPerMillion: 2, cachedInputPerMillion: 0.2, outputPerMillion: 8);
    const u = TokenUsage(promptTokens: 1000000, completionTokens: 500000, reasoningTokens: 400000, cachedTokens: 600000);
    expect(p.cost(u), closeTo(400000 * 2 / 1e6 + 600000 * 0.2 / 1e6 + 500000 * 8 / 1e6, 1e-9));
    expect(const Pricing(inputPerMillion: 1, outputPerMillion: 1).cachedInputPerMillion, 1, reason: '未给缓存价按原价');
  });

  test('UsageRecord JSON 往返', () {
    final r = rec('c1', 't1', TurnOutcome.rewritten, cost: 0.0012345);
    final back = UsageRecord.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, Object?>);
    expect(back.toJson(), r.toJson());
    expect(r.toJson()['latencyMs'], 1234);
    expect(r.toJson()['cachedTokens'], 500);
  });

  test('MemoryUsageSink 汇总：按轮统计走向、按模型统计 token', () async {
    final s = MemoryUsageSink();
    await s.record(rec('1', 'a', TurnOutcome.rewritten, cost: 0.01));
    await s.record(rec('2', 'a', TurnOutcome.rewritten, cost: 0.01));
    await s.record(rec('3', 'b', TurnOutcome.fallback, model: 'n', cost: 0.02));
    final sum = s.summary;
    expect(sum.calls, 3);
    expect(sum.turns, 2);
    expect(sum.turnOutcomes, {TurnOutcome.rewritten: 1, TurnOutcome.fallback: 1});
    expect(sum.usage.promptTokens, 3000);
    expect(sum.cost, closeTo(0.04, 1e-12));
    expect(sum.byModel['n']!.completionTokens, 100);
  });

  test('JsonlUsageSink：一行一条，可读回，坏行跳过', () async {
    final dir = await Directory.systemTemp.createTemp('ugk');
    final f = File('${dir.path}/logs/usage.jsonl');
    final s = JsonlUsageSink(f);
    await s.record(rec('1', 'a', TurnOutcome.model));
    await s.record(rec('2', 'b', TurnOutcome.fallback));
    await f.writeAsString('坏行\n', mode: FileMode.append);
    expect(f.readAsLinesSync(), hasLength(3));
    final back = await s.readAll();
    expect(back.map((r) => r.id), ['1', '2']);
    await dir.delete(recursive: true);
  });

  test('MultiUsageSink：一个出错不影响其他；CallbackUsageSink 回调', () async {
    final got = <String>[];
    final s = MultiUsageSink([
      CallbackUsageSink((_) => throw StateError('x')),
      CallbackUsageSink((r) => got.add(r.id)),
    ]);
    await s.record(rec('1', 'a', TurnOutcome.model));
    expect(got, ['1']);
  });
}
