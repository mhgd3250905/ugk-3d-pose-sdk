/// 工具版会话（0.2 推荐入口）：一个 App 维护一个 [CoachSession]，每轮 [send]，关弹窗不清空，[reset] 重开。
///
/// 并发策略：同一会话一次只处理一轮，进行中再 [send] 直接返回 [TurnStatus.busy]（不排队、不调模型）；
/// [reset] 让进行中的旧轮作废，旧轮返回时不写历史、不计轮数（返回 [TurnStatus.cancelled]）。
///
/// 每轮：输入长度检查 → 硬上限检查 → 调模型（带 show_actions / show_plan）→ 门禁 →
/// 不过就把全部错误作为 tool 结果回给模型重交（最多 [maxResubmits] 次）→ 仍不过 / 网络错 / 暗号泄露 → 回落 App 模板。
/// 绝不渲染未通过门禁的内容：结果里只有 [ValidatedPlan] / [ValidatedActions]。
library;

import 'dart:async';

import '../assistant/fallback.dart';
import '../catalog/catalog.dart';
import '../llm/cancel_token.dart';
import '../llm/llm_client.dart';
import '../llm/llm_types.dart';
import '../plan/coach_context.dart';
import '../plan/plan_issue.dart';
import '../plan/plan_validator.dart';
import '../plan/training_plan.dart';
import '../profile/coach_profile.dart';
import '../prompt/tool_prompt.dart';
import '../usage/usage.dart';
import '../util/clock.dart';
import 'tool_gate.dart';

enum TurnStatus {
  /// 模型回复通过门禁（可能经过重交）。
  ok,

  /// 用了 App 模板（模型不可用、重交用尽、或暗号泄露）。
  fallback,

  /// 会话到达硬上限，没有调用模型：App 提示用户重置。
  limitReached,

  /// 用户输入过长，没有调用模型。
  inputTooLong,

  /// 被取消；或在返回前会话已 [CoachSession.reset]（旧轮作废）。历史与轮数不变。
  cancelled,

  /// 上一轮还在进行：本次被拒绝，没有调用模型（同一会话一次只处理一轮）。
  busy,

  /// 需要回落但没有配置回落（或回落本身出错）。
  error,
}

/// 回落请求：App 用自己的模板 / 规则生成回复。
class SessionFallbackRequest {
  const SessionFallbackRequest({
    required this.userText,
    required this.context,
    required this.reason,
    this.issues = const [],
    this.error,
  });
  final String userText;
  final CoachContext context;
  final FallbackReason reason;

  /// 最后一次提交的门禁错误（invalidOutput 时）。
  final List<PlanIssue> issues;
  final Object? error;
}

/// 回落回复。[plan] 也要过门禁（[ToolGate.admitTemplate]），不合格就只给文字。
class SessionFallbackReply {
  const SessionFallbackReply(this.text, {this.plan});
  final String text;
  final TrainingPlan? plan;
}

typedef SessionFallback = FutureOr<SessionFallbackReply> Function(SessionFallbackRequest request);

class CoachTurnResult {
  const CoachTurnResult({
    required this.turnId,
    required this.status,
    this.text = '',
    this.plan,
    this.actions,
    this.warnings = const [],
    this.issues = const [],
    this.submissions = 0,
    this.fallbackReason,
    this.leaked = false,
    this.error,
    this.records = const [],
    this.steps = 0,
    this.reads = const [],
  });

  final String turnId;
  final TurnStatus status;

  /// 给用户的文字。
  final String text;

  /// 只有通过门禁的计划 / 动作卡。
  final ValidatedPlan? plan;
  final ValidatedActions? actions;
  final List<PlanIssue> warnings;

  /// 回落时：最后一次提交的错误。
  final List<PlanIssue> issues;

  /// 模型提交次数（1 = 首次即过；0 = 没调模型）。
  final int submissions;
  int get resubmits => submissions > 1 ? submissions - 1 : 0;
  final FallbackReason? fallbackReason;

  /// 回复里出现提示词暗号（已丢弃）。
  final bool leaked;
  final Object? error;
  final List<UsageRecord> records;

  /// Agent 版：本轮调模型的步数（0.2 会话为 0）。
  final int steps;

  /// Agent 版：本轮读过的文件路径（按顺序）。
  final List<String> reads;

  TokenUsage get usage => records.fold(TokenUsage.zero, (a, r) => a + r.usage);
}

class CoachSession {
  CoachSession({
    required this.client,
    required Catalog Function() catalog,
    required this.profile,
    this.fallback,
    UsageSink? usage,
    ToolPromptBuilder? prompts,
    this.maxResubmits = 2,
    this.maxInputChars = 500,
    this.maxTurns = 20,
    this.maxHistoryChars = 40000,
    this.extraRules = const [],
    this.enforceDrillDoseRange = false,
    String? appId,
    Clock clock = systemClock,
    IdGenerator? ids,
  }) : _catalog = catalog,
       usage = usage ?? MemoryUsageSink(),
       prompts = prompts ?? ToolPromptBuilder(),
       appId = appId ?? profile.id,
       _clock = clock,
       _ids = ids ?? IdGenerator(clock: clock);

  final LlmClient client;
  final CoachProfile profile;
  final SessionFallback? fallback;
  final UsageSink usage;
  final ToolPromptBuilder prompts;

  /// 门禁不过时让模型重交的次数（默认 2，即最多 3 次提交）。
  final int maxResubmits;

  /// 用户单条输入上限（字符）。
  final int maxInputChars;

  /// 会话硬上限：用户轮数 / 历史总字符。到了返回 [TurnStatus.limitReached]。
  final int maxTurns;
  final int maxHistoryChars;
  final List<PlanRule> extraRules;
  final bool enforceDrillDoseRange;
  final String appId;
  final Catalog Function() _catalog;
  final Clock _clock;
  final IdGenerator _ids;

  final List<LlmMessage> _history = [];
  int _turns = 0;

  /// 会话世代：[reset] 加一，进行中的旧轮据此作废。
  int _generation = 0;

  /// 进行中轮次所属的世代；null = 空闲。
  int? _busyGen;

  /// 已送入上下文的消息（不含系统消息）。
  List<LlmMessage> get history => List.unmodifiable(_history);
  int get turnCount => _turns;
  int get historyChars => _history.fold(0, (n, m) => n + _chars(m));

  /// 本会话有一轮正在进行。
  bool get isBusy => _busyGen == _generation;

  /// 硬上限：进行中的一轮也计入。
  bool get isFull => _turns + (isBusy ? 1 : 0) >= maxTurns || historyChars >= maxHistoryChars;

  /// 清空对话（App 的「重新开始」）。进行中的旧轮作废，返回时不会写回历史。
  void reset() {
    _generation++;
    _history.clear();
    _turns = 0;
  }

  ToolGate gateFor(Catalog c) => ToolGate(
    catalog: c,
    profile: profile,
    canary: prompts.canary,
    extraRules: extraRules,
    enforceDrillDoseRange: enforceDrillDoseRange,
  );

  Future<CoachTurnResult> send(
    String userText, {
    CoachContext context = const CoachContext(),
    CancelToken? cancel,
  }) async {
    final turnId = _ids.next('turn');
    final text = userText.trim();
    if (text.length > maxInputChars) return CoachTurnResult(turnId: turnId, status: TurnStatus.inputTooLong);
    if (isBusy) return CoachTurnResult(turnId: turnId, status: TurnStatus.busy);
    if (isFull) return CoachTurnResult(turnId: turnId, status: TurnStatus.limitReached);
    final gen = _generation;
    _busyGen = gen;
    try {
      return await _run(turnId, text, context, cancel, gen);
    } finally {
      if (_busyGen == gen) _busyGen = null;
    }
  }

  Future<CoachTurnResult> _run(String turnId, String text, CoachContext context, CancelToken? cancel, int gen) async {
    // 取消或已 reset：本轮作废，不写历史、不计轮数。
    bool dead() => gen != _generation || (cancel?.isCancelled ?? false);

    final cat = _catalog();
    final gate = gateFor(cat);
    final system = prompts.system(profile, cat);
    final meta = (version: prompts.version(profile), hash: prompts.hash(profile, cat), catalog: cat.version);
    final userMsg = LlmMessage.user(prompts.userMessage(profile, cat, context, text));
    final tools = prompts.tools(profile, cat);
    final attempts = <LlmMessage>[]; // 本轮被打回的提交与反馈
    final calls = <_Call>[];
    List<PlanIssue> lastErrors = const [];
    FallbackReason reason = FallbackReason.invalidOutput;
    Object? error;
    var leaked = false;

    for (var n = 1; n <= 1 + maxResubmits; n++) {
      final messages = [LlmMessage.system(system), ..._history, userMsg, ...attempts];
      LlmResponse res;
      try {
        res = await client.complete(
          LlmRequest(messages: messages, tools: tools, toolChoice: 'auto'),
          cancel: cancel,
        );
      } on LlmException catch (e) {
        calls.add(_Call.failed(n, e));
        if (e.kind == LlmErrorKind.cancelled || dead()) {
          return _finish(turnId, meta, calls, TurnStatus.cancelled, TurnOutcome.cancelled, error: e, submissions: n);
        }
        reason = _reasonFor(e.kind);
        error = e;
        break;
      } on Object catch (e) {
        if (dead()) {
          calls.add(_Call.failed(n, const LlmException(LlmErrorKind.cancelled, 'cancelled')));
          return _finish(turnId, meta, calls, TurnStatus.cancelled, TurnOutcome.cancelled, error: e, submissions: n);
        }
        calls.add(_Call.failed(n, LlmException(LlmErrorKind.badResponse, '$e')));
        reason = FallbackReason.server;
        error = e;
        break;
      }

      if (dead()) {
        calls.add(_Call.ok(n, res, CallOutcome.cancelled));
        return _finish(turnId, meta, calls, TurnStatus.cancelled, TurnOutcome.cancelled, submissions: n);
      }
      final g = gate.check(res.content, res.toolCalls, context: context, planId: _ids.next('plan'));
      if (g.leaked) {
        calls.add(_Call.ok(n, res, CallOutcome.rejected, codes: const ['canary_leak']));
        leaked = true;
        reason = FallbackReason.invalidOutput;
        break;
      }
      if (g.ok) {
        calls.add(_Call.ok(n, res, n == 1 ? CallOutcome.passed : CallOutcome.rewritten));
        return _finish(
          turnId,
          meta,
          calls,
          TurnStatus.ok,
          n == 1 ? TurnOutcome.model : TurnOutcome.rewritten,
          text: g.text,
          plan: g.plan,
          actions: g.actions,
          warnings: g.warnings,
          submissions: n,
          dead: dead,
          commit: () {
            _turns++;
            _history
              ..add(userMsg)
              ..add(LlmMessage.assistant(res.content, toolCalls: res.toolCalls, reasoning: res.reasoning))
              ..addAll([for (final t in res.toolCalls) LlmMessage.tool(t.id, g.feedback())]);
          },
        );
      }
      calls.add(_Call.ok(n, res, CallOutcome.rejected, codes: [for (final e in g.errors) e.code]));
      lastErrors = g.errors;
      final fb = g.feedback(remaining: 1 + maxResubmits - n);
      attempts.add(LlmMessage.assistant(res.content, toolCalls: res.toolCalls, reasoning: res.reasoning));
      if (res.toolCalls.isEmpty) {
        attempts.add(LlmMessage.user(fb));
      } else {
        attempts.addAll([for (final t in res.toolCalls) LlmMessage.tool(t.id, fb)]);
      }
    }

    // 回落：绝不渲染未通过的内容。
    if (dead()) {
      return _finish(turnId, meta, calls, TurnStatus.cancelled, TurnOutcome.cancelled, submissions: calls.length);
    }
    final fbFn = fallback;
    if (fbFn == null) {
      return _finish(
        turnId,
        meta,
        calls,
        TurnStatus.error,
        TurnOutcome.error,
        issues: lastErrors,
        reason: reason,
        error: error,
        leaked: leaked,
        submissions: calls.length,
        dead: dead,
      );
    }
    try {
      final r = await fbFn(
        SessionFallbackRequest(userText: text, context: context, reason: reason, issues: lastErrors, error: error),
      );
      // 回落是异步的：返回后复查取消与世代，作废就不接纳、不改状态。
      if (dead()) {
        return _finish(turnId, meta, calls, TurnStatus.cancelled, TurnOutcome.cancelled, submissions: calls.length);
      }
      final plan = r.plan == null ? null : gate.admitTemplate(r.plan!, context);
      return _finish(
        turnId,
        meta,
        calls,
        TurnStatus.fallback,
        TurnOutcome.fallback,
        text: r.text,
        plan: plan,
        issues: lastErrors,
        reason: reason,
        error: error,
        leaked: leaked,
        submissions: calls.length,
        dead: dead,
        commit: () {
          _turns++;
          _history
            ..add(userMsg)
            ..add(LlmMessage.assistant(r.text));
        },
      );
    } on Object catch (e) {
      if (dead()) {
        return _finish(turnId, meta, calls, TurnStatus.cancelled, TurnOutcome.cancelled, submissions: calls.length);
      }
      return _finish(
        turnId,
        meta,
        calls,
        TurnStatus.error,
        TurnOutcome.error,
        issues: lastErrors,
        reason: reason,
        error: e,
        leaked: leaked,
        submissions: calls.length,
        dead: dead,
      );
    }
  }

  static int _chars(LlmMessage m) =>
      m.content.length + (m.reasoning?.length ?? 0) + m.toolCalls.fold(0, (n, t) => n + t.arguments.length);

  static FallbackReason _reasonFor(LlmErrorKind k) => switch (k) {
    LlmErrorKind.network => FallbackReason.offline,
    LlmErrorKind.timeout => FallbackReason.timeout,
    LlmErrorKind.rateLimited => FallbackReason.rateLimited,
    LlmErrorKind.auth => FallbackReason.auth,
    LlmErrorKind.truncated => FallbackReason.truncated,
    LlmErrorKind.http || LlmErrorKind.badResponse || LlmErrorKind.cancelled => FallbackReason.server,
  };

  Future<CoachTurnResult> _finish(
    String turnId,
    ({String version, String hash, String catalog}) meta,
    List<_Call> calls,
    TurnStatus status,
    TurnOutcome outcome, {
    String text = '',
    ValidatedPlan? plan,
    ValidatedActions? actions,
    List<PlanIssue> warnings = const [],
    List<PlanIssue> issues = const [],
    FallbackReason? reason,
    Object? error,
    bool leaked = false,
    int submissions = 0,
    bool Function()? dead,
    void Function()? commit,
  }) async {
    final pricing = client.pricing;
    final records = [
      for (final c in calls)
        UsageRecord(
          id: _ids.next('call'),
          turnId: turnId,
          at: _clock().toUtc(),
          appId: appId,
          profileId: profile.id,
          model: c.model ?? client.model,
          promptVersion: meta.version,
          promptHash: meta.hash,
          catalogVersion: meta.catalog,
          attempt: c.attempt,
          usage: c.usage,
          latency: c.latency,
          httpAttempts: c.httpAttempts,
          outcome: c.outcome,
          turnOutcome: outcome,
          finishReason: c.finishReason,
          errorKind: c.error?.kind.name,
          errorMessage: c.error?.message,
          issueCodes: c.codes,
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
    // 记账是本轮最后一个异步边界：其间 reset / 取消则本轮作废——
    // 返回 cancelled、不带任何可渲染内容、不写历史 / 轮数。
    // 复查与提交之间没有 await，提交即生效。
    if (dead != null && dead()) {
      return CoachTurnResult(
        turnId: turnId,
        status: TurnStatus.cancelled,
        submissions: submissions,
        error: error,
        records: records,
      );
    }
    commit?.call();
    return CoachTurnResult(
      turnId: turnId,
      status: status,
      text: text,
      plan: plan,
      actions: actions,
      warnings: warnings,
      issues: issues,
      submissions: submissions,
      fallbackReason: status == TurnStatus.fallback || status == TurnStatus.error ? reason : null,
      leaked: leaked,
      error: error,
      records: records,
    );
  }
}

class _Call {
  _Call.ok(this.attempt, LlmResponse r, this.outcome, {this.codes = const []})
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
      codes = const [],
      error = e;

  final int attempt;
  final TokenUsage usage;
  final Duration latency;
  final int httpAttempts;
  final String? model;
  final String? finishReason;
  final CallOutcome outcome;
  final List<String> codes;
  final LlmException? error;
}
