// 编排流程：首轮通过 / 重写后通过 / 重写仍失败回落 / 网络错误回落 / 截断 / 取消 / preflight / 目录热更新。
import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();
  final hip = loadProfile('hiplab');
  const pricing = Pricing(inputPerMillion: 1, cachedInputPerMillion: 0.1, outputPerMillion: 4);
  final fixedNow = DateTime.utc(2026, 10, 20, 1);

  Map<String, Object?> badEnvelope() {
    final e = okEnvelope();
    itemOf(e, 1, 3)['reps'] = 40; // E_DOSE
    addItem(e, 1, {'exerciseId': 'burpee', 'mode': 'reps', 'sets': 1, 'reps': 10, 'perSide': false, 'restSeconds': 10});
    return e;
  }

  final templateReply = CoachReply.plan('离线模板计划', const PlanCodec().decode(planOf(okEnvelope())));
  late List<FallbackRequest> fallbackCalls;
  late MemoryUsageSink sink;

  CoachAssistant make(FakeLlmClient client, {Catalog Function()? cat, Preflight? preflight, bool withFallback = true, int maxRewrites = 1}) {
    fallbackCalls = [];
    sink = MemoryUsageSink();
    return CoachAssistant(
      client: client,
      catalog: cat ?? () => catalog,
      profile: hip,
      usage: sink,
      preflight: preflight,
      maxRewrites: maxRewrites,
      clock: () => fixedNow,
      fallback: withFallback
          ? FallbackFn((r) {
              fallbackCalls.add(r);
              return templateReply;
            })
          : null,
    );
  }

  test('首轮通过：采用模型计划，source=ai，一条 passed 记录', () async {
    final client = FakeLlmClient([okEnvelope()], pricing: pricing);
    final a = make(client);
    final conv = CoachConversation();
    final r = await a.ask('睡前开胯 10 分钟', context: const CoachContext(scene: 'home', avoid: {'腰'}), conversation: conv);
    expect(r.outcome, TurnOutcome.model);
    expect(r.reply!.plan!.source, 'ai');
    expect(r.reply!.plan!.avoid, contains('腰'), reason: '本轮保护部位并入计划');
    expect(r.records.single.outcome, CallOutcome.passed);
    expect(r.records.single.turnOutcome, TurnOutcome.model);
    expect(conv.turns, hasLength(2));
    expect(conv.lastPlan, isNotNull);
    expect(client.requests.single.messages.first.role, LlmRole.system);
    expect(client.requests.single.messages.last.content, contains('场所 居家（home）'));
  });

  test('首轮不合格 → 带错误重写 → 通过', () async {
    final client = FakeLlmClient([badEnvelope(), okEnvelope()]);
    final a = make(client);
    final r = await a.ask('来一套');
    expect(r.outcome, TurnOutcome.rewritten);
    expect(r.records.map((x) => x.outcome), [CallOutcome.rejected, CallOutcome.rewritten]);
    expect(r.records.first.issueCodes, containsAll([IssueCodes.repsRange, IssueCodes.unknownExercise]));
    expect(r.records.every((x) => x.turnOutcome == TurnOutcome.rewritten), isTrue);
    final second = client.requests[1].messages;
    expect(second[second.length - 2].role, LlmRole.assistant);
    expect(second.last.content, contains('E_UNKNOWN 未知动作 ID：burpee'));
    expect(second.last.content, contains('E_DOSE'));
  });

  test('重写仍不合格 → 回落模板（invalidOutput），带最后的问题', () async {
    final a = make(FakeLlmClient([badEnvelope(), badEnvelope()]));
    final r = await a.ask('来一套');
    expect(r.outcome, TurnOutcome.fallback);
    expect(r.fallbackReason, FallbackReason.invalidOutput);
    expect(r.reply, same(templateReply));
    expect(fallbackCalls.single.issues.where((i) => i.isError), isNotEmpty);
    expect(r.records.map((x) => x.outcome), [CallOutcome.rejected, CallOutcome.rejected]);
    expect(r.records.every((x) => x.turnOutcome == TurnOutcome.fallback), isTrue);
  });

  test('maxRewrites=0：不合格直接回落，只调一次', () async {
    final client = FakeLlmClient([badEnvelope()]);
    final r = await make(client, maxRewrites: 0).ask('来一套');
    expect(r.outcome, TurnOutcome.fallback);
    expect(client.requests, hasLength(1));
  });

  test('不是 JSON 也走重写', () async {
    final r = await make(FakeLlmClient(['好的，给你排一个计划', okEnvelope()])).ask('x');
    expect(r.outcome, TurnOutcome.rewritten);
    expect(r.records.first.issueCodes, [IssueCodes.notJson]);
  });

  test('断网 → 回落（offline），不重写', () async {
    final client = FakeLlmClient([const LlmException(LlmErrorKind.network, 'Failed host lookup')]);
    final r = await make(client).ask('x');
    expect(r.outcome, TurnOutcome.fallback);
    expect(r.fallbackReason, FallbackReason.offline);
    expect(client.requests, hasLength(1));
    expect(r.records.single.outcome, CallOutcome.error);
    expect(r.records.single.errorKind, 'network');
  });

  for (final (kind, reason) in [
    (LlmErrorKind.timeout, FallbackReason.timeout),
    (LlmErrorKind.auth, FallbackReason.auth),
    (LlmErrorKind.rateLimited, FallbackReason.rateLimited),
    (LlmErrorKind.http, FallbackReason.server),
  ]) {
    test('${kind.name} → 回落 ${reason.name}', () async {
      final r = await make(FakeLlmClient([LlmException(kind, 'x')])).ask('x');
      expect(r.fallbackReason, reason);
    });
  }

  test('截断：计费的 token 也记账，回落 truncated', () async {
    const used = TokenUsage(promptTokens: 9000, completionTokens: 6000, reasoningTokens: 5800);
    final r = await make(FakeLlmClient([const LlmException(LlmErrorKind.truncated, 'length', usage: used)], pricing: pricing)).ask('x');
    expect(r.fallbackReason, FallbackReason.truncated);
    expect(r.records.single.usage.completionTokens, 6000);
    expect(r.records.single.finishReason, 'length');
    expect(r.cost, closeTo((9000 * 1 + 6000 * 4) / 1e6, 1e-12));
  });

  test('没有回落生成器：outcome=error，reply 为空', () async {
    final r = await make(FakeLlmClient([const LlmException(LlmErrorKind.network, 'x')]), withFallback: false).ask('x');
    expect(r.outcome, TurnOutcome.error);
    expect(r.reply, isNull);
    expect(r.fallbackReason, FallbackReason.offline);
  });

  test('回落生成器自己出错：outcome=error', () async {
    final a = CoachAssistant(
      client: FakeLlmClient([const LlmException(LlmErrorKind.network, 'x')]),
      catalog: () => catalog,
      profile: hip,
      fallback: FallbackFn((_) => throw StateError('模板坏了')),
    );
    final r = await a.ask('x');
    expect(r.outcome, TurnOutcome.error);
    expect(r.error, isA<StateError>());
  });

  test('取消：结果 cancelled，不回落、会话不变，记一条 cancelled', () async {
    final client = FakeLlmClient([okEnvelope()], latency: const Duration(seconds: 5));
    final a = make(client);
    final conv = CoachConversation();
    final token = CancelToken();
    final f = a.ask('x', conversation: conv, cancel: token);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    token.cancel('用户点了停止');
    final r = await f.timeout(const Duration(seconds: 1));
    expect(r.outcome, TurnOutcome.cancelled);
    expect(r.reply, isNull);
    expect(fallbackCalls, isEmpty);
    expect(conv.turns, isEmpty);
    expect(sink.records.single.outcome, CallOutcome.cancelled);
  });

  test('preflight 命中：不调模型、不产生调用记录', () async {
    final client = FakeLlmClient([]);
    final a = make(client, preflight: (text, _, _) => text.contains('胸口疼') ? const CoachReply.text('先停下来休息，必要时就医。') : null);
    final r = await a.ask('练的时候胸口疼');
    expect(r.outcome, TurnOutcome.preflight);
    expect(client.requests, isEmpty);
    expect(sink.records, isEmpty);
  });

  test('ask / reply 类型直接通过', () async {
    final r = await make(FakeLlmClient([{'kind': 'ask', 'text': '在家还是办公室？', 'options': ['在家', '办公室']}])).ask('练练');
    expect(r.outcome, TurnOutcome.model);
    expect(r.reply!.kind, ReplyKind.ask);
  });

  test('调用记录：App/profile/模型/提示词版本/目录版本/token/耗时/花费', () async {
    final a = make(FakeLlmClient([okEnvelope()], pricing: pricing));
    final r = await a.ask('x');
    final rec = r.records.single;
    expect(rec.appId, 'hiplab');
    expect(rec.profileId, 'hiplab');
    expect(rec.model, 'fake-model');
    expect(rec.promptVersion, a.prompts.version(hip));
    expect(rec.catalogVersion, catalog.version);
    expect(rec.promptHash, hasLength(12));
    expect(rec.usage.cachedTokens, 600);
    expect(rec.at, fixedNow);
    // FakeLlmClient 默认：prompt 1000（缓存 600）、completion 200
    expect(rec.cost, closeTo((400 * 1 + 600 * 0.1 + 200 * 4) / 1e6, 1e-12));
    expect(rec.currency, 'CNY');
    expect(sink.records.single.id, rec.id);
  });

  test('目录热更新：下一轮的提示词与校验用新目录', () async {
    var current = catalog;
    final raw = jsonDecode(catalogText()) as Map<String, Object?>;
    (raw['drills']! as List).removeWhere((d) => (d as Map)['id'] == 's-butterfly');
    raw['version'] = '0.1.1';
    final next = Catalog.fromJson(raw);
    final client = FakeLlmClient([okEnvelope(), okEnvelope(), okEnvelope()]);
    final a = make(client, cat: () => current);
    final r1 = await a.ask('x');
    expect(r1.outcome, TurnOutcome.model);
    current = next;
    final r2 = await a.ask('x');
    expect(r2.records.first.catalogVersion, '0.1.1');
    expect(r2.records.first.issueCodes, contains(IssueCodes.unknownExercise));
    expect(client.requests[1].messages.first.content, isNot(contains('s-butterfly|')));
    expect(r1.records.first.promptHash, isNot(r2.records.first.promptHash));
  });

  test('会话历史随轮次带上，计划可被「再短一点」引用', () async {
    final client = FakeLlmClient([okEnvelope(), okEnvelope()]);
    final a = make(client);
    final conv = CoachConversation();
    await a.ask('睡前开胯', conversation: conv);
    await a.ask('再短一点', conversation: conv);
    final msgs = client.requests[1].messages;
    expect(msgs.map((m) => m.role), [LlmRole.system, LlmRole.user, LlmRole.assistant, LlmRole.user]);
    expect(msgs[2].content, contains('"blocks"'));
    expect(conv.turns, hasLength(4));
  });

  test('会话可序列化保存', () async {
    final conv = CoachConversation();
    await make(FakeLlmClient([okEnvelope()])).ask('x', conversation: conv);
    final back = CoachConversation.fromJson(jsonDecode(jsonEncode(conv.toJson())) as Map<String, Object?>);
    expect(back.lastPlan!.title, '睡前开胯');
  });

  test('resolve：按 profile 的素材偏好带出整套素材', () {
    final a = make(FakeLlmClient([]));
    final r = a.resolve('s-figure4')!;
    expect(r.cover!.source.app, 'hiplab');
    expect(r.voiceKeys.map((k) => k.uri), contains('assets/voice/zh/drill.s-figure4.m4a'));
  });

  test('sink 抛错不影响对话', () async {
    final a = CoachAssistant(
      client: FakeLlmClient([okEnvelope()]),
      catalog: () => catalog,
      profile: hip,
      usage: CallbackUsageSink((_) => throw StateError('上报失败')),
    );
    expect((await a.ask('x')).outcome, TurnOutcome.model);
  });
}
