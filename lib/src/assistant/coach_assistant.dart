/// 编排一轮对话：preflight → 拼提示词 → 调模型 → 解析信封 → 校验计划 →（失败）带错误重写一次 →（仍失败 / 网络错误）回落。
/// 每次模型调用写一条 [UsageRecord]。
library;

import 'dart:async';

import '../catalog/asset_resolver.dart';
import '../catalog/catalog.dart';
import '../envelope/coach_reply.dart';
import '../llm/cancel_token.dart';
import '../llm/llm_client.dart';
import '../llm/llm_types.dart';
import '../plan/coach_context.dart';
import '../plan/plan_issue.dart';
import '../plan/plan_validator.dart';
import '../plan/training_plan.dart';
import '../profile/coach_profile.dart';
import '../prompt/prompt_builder.dart';
import '../usage/usage.dart';
import '../util/clock.dart';
import 'conversation.dart';
import 'fallback.dart';

/// App 的前置拦截：返回非 null 就直接用它回复，不调模型（安全话术、本地命令、省钱）。
typedef Preflight = FutureOr<CoachReply?> Function(String userText, CoachContext context, CoachConversation conversation);

class CoachResult {
  const CoachResult({
    required this.turnId,
    required this.outcome,
    this.reply,
    this.issues = const [],
    this.fallbackReason,
    this.error,
    this.records = const [],
  });

  final String turnId;
  final TurnOutcome outcome;

  /// 给用户的回复；cancelled、或出错且没有回落时为 null。
  final CoachReply? reply;

  /// 最终采用的输出上的问题（通过时只剩警告；回落时是最后一次模型输出的错误）。
  final List<PlanIssue> issues;
  final FallbackReason? fallbackReason;
  final Object? error;

  /// 本轮的调用记录（已写入 sink）。
  final List<UsageRecord> records;

  bool get fromModel => outcome == TurnOutcome.model || outcome == TurnOutcome.rewritten;
  TokenUsage get usage => records.fold(TokenUsage.zero, (a, r) => a + r.usage);
  double? get cost => records.any((r) => r.cost != null) ? records.fold<double>(0, (a, r) => a + (r.cost ?? 0)) : null;
}

class CoachAssistant {
  CoachAssistant({
    required this.client,
    required Catalog Function() catalog,
    required this.profile,
    this.fallback,
    UsageSink? usage,
    PromptBuilder? prompts,
    this.preflight,
    this.maxRewrites = 1,
    String? appId,
    this.extraRules = const [],
    this.enforceDrillDoseRange = false,
    Clock clock = systemClock,
    IdGenerator? ids,
  }) : _catalog = catalog,
       usage = usage ?? MemoryUsageSink(),
       prompts = prompts ?? PromptBuilder(),
       appId = appId ?? profile.id,
       _clock = clock,
       _ids = ids ?? IdGenerator(clock: clock);

  final LlmClient client;
  final CoachProfile profile;
  final FallbackPlanner? fallback;
  final UsageSink usage;
  final PromptBuilder prompts;
  final Preflight? preflight;

  /// 校验失败后让模型重写的次数（默认 1；0 = 直接回落）。
  final int maxRewrites;
  final String appId;
  final List<PlanRule> extraRules;
  final bool enforceDrillDoseRange;
  final Catalog Function() _catalog;
  final Clock _clock;
  final IdGenerator _ids;

  /// 当前目录（热更新后自动是新的）。
  Catalog get catalog => _catalog();

  PlanValidator validatorFor(Catalog c) =>
      PlanValidator(catalog: c, profile: profile, extraRules: extraRules, enforceDrillDoseRange: enforceDrillDoseRange);

  /// 校验任意计划（模板计划、已存计划在目录更新后复核）。
  ValidationReport validate(TrainingPlan plan, [CoachContext context = const CoachContext()]) =>
      validatorFor(catalog).validate(plan, context);

  /// 按本 App 的素材偏好解析一个动作的整套素材。
  ResolvedDrill? resolve(String id, {String? variant, Map<String, String> baseByApp = const {}}) =>
      AssetResolver(appOrder: profile.resolvedAssetApps, variant: variant, baseByApp: baseByApp).resolveId(catalog, id);

  Future<CoachResult> ask(
    String userText, {
    CoachContext context = const CoachContext(),
    CoachConversation? conversation,
    CancelToken? cancel,
  }) async {
    final turnId = _ids.next('turn');
    final conv = conversation ?? CoachConversation();
    final text = userText.trim();

    if (preflight != null) {
      final pre = await preflight!(text, context, conv);
      if (pre != null) {
        _remember(conv, text, pre);
        return CoachResult(turnId: turnId, outcome: TurnOutcome.preflight, reply: pre);
      }
    }

    final cat = catalog;
    final validator = validatorFor(cat);
    final built = prompts.build(profile: profile, catalog: cat, context: context, userText: text, conversation: conv);
    final pending = <_Call>[];
    var messages = built.messages;
    List<PlanIssue> lastIssues = const [];
    FallbackReason? reason;
    Object? error;

    for (var attempt = 1; attempt <= 1 + maxRewrites; attempt++) {
      LlmResponse res;
      try {
        res = await client.complete(LlmRequest(messages: messages), cancel: cancel);
      } on LlmException catch (e) {
        pending.add(_Call.failed(attempt, e));
        if (e.kind == LlmErrorKind.cancelled) {
          return _finish(turnId, built, cat, pending, TurnOutcome.cancelled, error: e);
        }
        reason = _reasonFor(e.kind);
        error = e;
        break;
      } on Object catch (e) {
        if (cancel?.isCancelled ?? false) {
          pending.add(_Call.failed(attempt, const LlmException(LlmErrorKind.cancelled, 'cancelled')));
          return _finish(turnId, built, cat, pending, TurnOutcome.cancelled, error: e);
        }
        pending.add(_Call.failed(attempt, LlmException(LlmErrorKind.badResponse, '$e')));
        reason = FallbackReason.server;
        error = e;
        break;
      }

      final parsed = const EnvelopeParser().parse(
        res.content,
        planId: _ids.next('plan'),
        scene: context.scene,
        level: context.level,
        minutes: context.minutes,
      );
      var issues = parsed.issues;
      var reply = parsed.reply;
      if (reply?.plan != null && parsed.ok) {
        final plan = _normalize(reply!.plan!, context);
        reply = CoachReply(kind: reply.kind, text: reply.text, options: reply.options, plan: plan);
        issues = [...issues, ...validator.validate(plan, context).issues];
      }
      final errors = [for (final i in issues) if (i.isError) i];
      if (reply != null && errors.isEmpty) {
        pending.add(_Call.ok(attempt, res, attempt == 1 ? CallOutcome.passed : CallOutcome.rewritten));
        _remember(conv, text, reply);
        return _finish(turnId, built, cat, pending, attempt == 1 ? TurnOutcome.model : TurnOutcome.rewritten,
            reply: reply, issues: issues);
      }
      pending.add(_Call.ok(attempt, res, CallOutcome.rejected, issues: errors));
      lastIssues = issues;
      reason = FallbackReason.invalidOutput;
      if (attempt <= maxRewrites) messages = prompts.rewrite(messages, res.content, errors);
    }

    // 回落。
    if (cancel?.isCancelled ?? false) return _finish(turnId, built, cat, pending, TurnOutcome.cancelled);
    final fb = fallback;
    if (fb == null) {
      return _finish(turnId, built, cat, pending, TurnOutcome.error,
          issues: lastIssues, reason: reason, error: error);
    }
    try {
      final reply = await fb.reply(FallbackRequest(
        userText: text,
        context: context,
        conversation: conv,
        reason: reason!,
        issues: lastIssues,
        error: error,
      ));
      _remember(conv, text, reply);
      return _finish(turnId, built, cat, pending, TurnOutcome.fallback,
          reply: reply, issues: lastIssues, reason: reason, error: error);
    } on Object catch (e) {
      return _finish(turnId, built, cat, pending, TurnOutcome.error, issues: lastIssues, reason: reason, error: e);
    }
  }

  /// 模型产出的计划：source=ai、保护部位并上本轮条件、场所/等级/时长以本轮条件为准。
  TrainingPlan _normalize(TrainingPlan p, CoachContext c) => p.copyWith(
    source: 'ai',
    scene: c.scene,
    level: c.level,
    targetMinutes: c.minutes,
    avoid: {...p.avoid, ...c.avoid},
  );

  void _remember(CoachConversation conv, String text, CoachReply reply) {
    final now = _clock();
    conv.addUser(text, now);
    conv.addAssistant(reply, now);
  }

  static FallbackReason _reasonFor(LlmErrorKind k) => switch (k) {
    LlmErrorKind.network => FallbackReason.offline,
    LlmErrorKind.timeout => FallbackReason.timeout,
    LlmErrorKind.rateLimited => FallbackReason.rateLimited,
    LlmErrorKind.auth => FallbackReason.auth,
    LlmErrorKind.truncated => FallbackReason.truncated,
    LlmErrorKind.http || LlmErrorKind.badResponse || LlmErrorKind.cancelled => FallbackReason.server,
  };

  Future<CoachResult> _finish(
    String turnId,
    BuiltPrompt built,
    Catalog cat,
    List<_Call> calls,
    TurnOutcome outcome, {
    CoachReply? reply,
    List<PlanIssue> issues = const [],
    FallbackReason? reason,
    Object? error,
  }) async {
    final pricing = client.pricing;
    final records = [
      for (final c in calls)
        UsageRecord(
          id: _ids.next('call'),
          turnId: turnId,
          at: _clock(),
          appId: appId,
          profileId: profile.id,
          model: c.model ?? client.model,
          promptVersion: built.version,
          promptHash: built.hash,
          catalogVersion: cat.version,
          attempt: c.attempt,
          usage: c.usage,
          latency: c.latency,
          httpAttempts: c.httpAttempts,
          outcome: c.outcome,
          turnOutcome: outcome,
          finishReason: c.finishReason,
          errorKind: c.error?.kind.name,
          errorMessage: c.error?.message,
          issueCodes: [for (final i in c.issues) i.code],
          cost: pricing?.cost(c.usage),
          currency: pricing?.currency,
        ),
    ];
    for (final r in records) {
      try {
        await usage.record(r);
      } on Object {
        // 记账失败不影响对话。
      }
    }
    return CoachResult(
      turnId: turnId,
      outcome: outcome,
      reply: reply,
      issues: issues,
      fallbackReason: outcome == TurnOutcome.fallback || outcome == TurnOutcome.error ? reason : null,
      error: error,
      records: records,
    );
  }
}

class _Call {
  _Call.ok(this.attempt, LlmResponse r, this.outcome, {this.issues = const []})
    : usage = r.usage,
      latency = r.latency,
      httpAttempts = r.httpAttempts,
      model = r.model,
      finishReason = r.finishReason,
      error = null;

  _Call.failed(this.attempt, LlmException e)
    : usage = e.usage,
      latency = e.latency,
      httpAttempts = e.httpAttempts,
      model = null,
      finishReason = e.kind == LlmErrorKind.truncated ? 'length' : null,
      outcome = e.kind == LlmErrorKind.cancelled ? CallOutcome.cancelled : CallOutcome.error,
      issues = const [],
      error = e;

  final int attempt;
  final TokenUsage usage;
  final Duration latency;
  final int httpAttempts;
  final String? model;
  final String? finishReason;
  final CallOutcome outcome;
  final List<PlanIssue> issues;
  final LlmException? error;
}
