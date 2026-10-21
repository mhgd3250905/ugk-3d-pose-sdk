/// Agent 版会话（0.3 推荐入口）：渐进式披露 + Pi 式工具循环。
///
/// 每轮：调模型 → 执行全部工具调用（read / ls / check_plan / remember / forget），结果追加 → 再调 →
/// 直到纯文字或 show_actions / show_plan 通过门禁。show_* 不过门禁就把错误作为工具结果回给模型重交
/// （最多 [CoachAgent.maxResubmits] 次）。步数超过 [CoachAgent.maxSteps]、网络错、超时、暗号泄露 → 回落 App 模板。
///
/// 对外与 [CoachSession] 同风格：[CoachAgent.send] / [CoachAgent.reset] / 取消、busy、reset 或取消后不回写；
/// 结果同为 [CoachTurnResult]，卡片只接受门禁产出的 [ValidatedPlan] / [ValidatedActions]。
/// 过程事件见 [CoachAgent.events]。0.2 的 [CoachSession] 保留作降级。
library;

import 'dart:async';
import 'dart:convert';

import '../assistant/fallback.dart';
import '../catalog/catalog.dart';
import '../llm/cancel_token.dart';
import '../llm/llm_client.dart';
import '../llm/llm_types.dart';
import '../plan/coach_context.dart';
import '../plan/plan_codec.dart';
import '../plan/plan_issue.dart';
import '../plan/plan_validator.dart';
import '../plan/training_plan.dart';
import '../profile/coach_profile.dart';
import '../tools/coach_session.dart';
import '../tools/tool_gate.dart';
import '../usage/usage.dart';
import '../util/clock.dart';
import 'agent_prompt.dart';
import 'skill_files.dart';
import 'user_memory.dart';

enum AgentEventKind {
  /// 第 [AgentEvent.step] 次调模型。
  thinking,

  /// 读文件 [AgentEvent.path]。
  reading,

  /// 列目录 [AgentEvent.path]。
  listing,

  /// check_plan 自检。
  checking,

  /// remember / forget（[AgentEvent.path] = kind）。
  memory,

  /// 本轮结束（[AgentEvent.status]）。
  done,
}

/// 过程事件：供 App 显示进度（「正在查动作库…」）。作废的轮次（reset / 取消）不再发事件。
class AgentEvent {
  const AgentEvent(this.turnId, this.kind, {this.step = 0, this.path, this.status});
  final String turnId;
  final AgentEventKind kind;
  final int step;
  final String? path;
  final TurnStatus? status;

  @override
  String toString() =>
      'AgentEvent(${kind.name}${path == null ? '' : ' $path'}${status == null ? '' : ' ${status!.name}'})';
}

/// 步数超限（回落时放在 [CoachTurnResult.error]）。
class AgentStepLimitExceeded implements Exception {
  const AgentStepLimitExceeded(this.maxSteps);
  final int maxSteps;
  @override
  String toString() => 'AgentStepLimitExceeded($maxSteps)';
}

class CoachAgent {
  CoachAgent({
    required this.client,
    required Catalog Function() catalog,
    required this.profile,
    this.fallback,
    UsageSink? usage,
    AgentPromptBuilder? prompts,
    this.maxSteps = 10,
    this.maxResubmits = 2,
    this.maxInputChars = 500,
    this.maxTurns = 20,
    this.maxHistoryChars = 40000,
    this.extraRules = const [],
    this.enforceDrillDoseRange = false,
    this.enableUserMemory = true,
    UserMemoryStore? memoryStore,
    this.memoryLimits = const MemoryLimits(),
    String? appId,
    Clock clock = systemClock,
    IdGenerator? ids,
  }) : _catalog = catalog,
       usage = usage ?? MemoryUsageSink(),
       prompts = prompts ?? AgentPromptBuilder(),
       memoryStore = memoryStore ?? InMemoryUserMemoryStore(),
       appId = appId ?? profile.id,
       _clock = clock,
       _ids = ids ?? IdGenerator(clock: clock);

  final LlmClient client;
  final CoachProfile profile;
  final SessionFallback? fallback;
  final UsageSink usage;
  final AgentPromptBuilder prompts;

  /// 每轮最多调模型几次（含读文件、自检、重交）。
  final int maxSteps;

  /// show_* 门禁不过时允许重交的次数。
  final int maxResubmits;
  final int maxInputChars;
  final int maxTurns;
  final int maxHistoryChars;
  final List<PlanRule> extraRules;
  final bool enforceDrillDoseRange;

  /// 用户记忆开关（运行时可切）。关闭时 remember / forget 工具、user-memory skill、记忆摘要都不出现。
  bool enableUserMemory;
  final UserMemoryStore memoryStore;
  final MemoryLimits memoryLimits;
  final String appId;
  final Catalog Function() _catalog;
  final Clock _clock;
  final IdGenerator _ids;

  final _events = StreamController<AgentEvent>.broadcast(sync: true);

  /// 过程事件流（broadcast）。
  Stream<AgentEvent> get events => _events.stream;

  final List<LlmMessage> _history = [];
  // 只追踪曾看过用户记忆的响应；记忆从未开启的工具推理必须完整回传。
  final Set<LlmMessage> _memoryReasoning = {};
  int _turns = 0;
  int _generation = 0;
  int? _busyGen;

  List<MemoryEntry>? _memory;

  /// 记忆世代：[clearMemory] 递增，使此前发起的 load 结果和各轮暂存的记忆操作全部失效。
  int _memEpoch = 0;
  Future<void> _saving = Future.value();

  ({CoachProfile p, Catalog c, bool m})? _filesKey;
  SkillFiles? _files;

  List<LlmMessage> get history => List.unmodifiable(_history);
  int get turnCount => _turns;
  int get historyChars => _history.fold(0, (n, m) => n + _chars(m));
  bool get isBusy => _busyGen == _generation;
  bool get isFull => _turns + (isBusy ? 1 : 0) >= maxTurns || historyChars >= maxHistoryChars;

  /// 清空对话。进行中的旧轮作废，返回时不写历史、不改记忆。
  void reset() {
    _generation++;
    _history.clear();
    _memoryReasoning.clear();
    _turns = 0;
  }

  /// 当前虚拟文件系统（按 profile + 目录实例 + 记忆开关缓存；目录更新后自动重建）。
  SkillFiles files([Catalog? catalog]) {
    final c = catalog ?? _catalog();
    final key = (p: profile, c: c, m: enableUserMemory);
    if (_files != null && _filesKey == key) return _files!;
    _filesKey = key;
    return _files = SkillFiles.build(profile, c, memory: enableUserMemory);
  }

  /// 当前记忆（未加载时从 store 读）。
  Future<List<MemoryEntry>> memory() async {
    final cached = _memory;
    if (cached != null) return List.unmodifiable(cached);
    final epoch = _memEpoch;
    final loaded = await memoryStore.load();
    // 加载期间被清除：迟到的旧结果作废。
    if (epoch != _memEpoch) return List.unmodifiable(_memory ?? const <MemoryEntry>[]);
    return List.unmodifiable(_memory ??= loaded);
  }

  /// 清空用户记忆（App 的「清除 AI 记忆」）。在途的 load 与各轮待提交的记忆操作一并作废。
  Future<void> clearMemory() {
    _memEpoch++;
    _memory = [];
    return _save(const []);
  }

  Future<void> _save(List<MemoryEntry> list) {
    final snapshot = List<MemoryEntry>.of(list);
    return _saving = _saving.then((_) => memoryStore.save(snapshot)).catchError((Object _) {});
  }

  Future<void> dispose() => _events.close();

  /// 记忆关闭后的本轮消息：已执行的 remember / forget 调用项连同其 tool 回复整对移除（参数里可能有记忆原文），
  /// 删空（无正文、无工具调用）的 assistant 消息整条移除；关闭后才发出、被当作未知工具的 remember / forget
  /// 保留回复、参数脱敏为 {}；读 user-memory/ 的结果替换为占位。
  static List<LlmMessage> _withoutMemory(
    List<LlmMessage> msgs,
    Set<String> memResultIds, {
    Set<LlmMessage> privateReasoning = const {},
  }) {
    bool isMem(LlmToolCall t) => t.name == AgentTools.remember || t.name == AgentTools.forget;
    final dropIds = {
      for (final m in msgs)
        for (final t in m.toolCalls)
          if (isMem(t) && memResultIds.contains(t.id)) t.id,
    };
    final out = <LlmMessage>[];
    for (final m in msgs) {
      if (m.role == LlmRole.tool) {
        if (dropIds.contains(m.toolCallId)) continue;
        out.add(memResultIds.contains(m.toolCallId) ? LlmMessage.tool(m.toolCallId!, '（用户记忆已关闭）') : m);
      } else if (m.role == LlmRole.assistant && m.toolCalls.any(isMem)) {
        final kept = [
          for (final t in m.toolCalls)
            if (!dropIds.contains(t.id)) isMem(t) ? LlmToolCall(id: t.id, name: t.name, arguments: '{}') : t,
        ];
        if (m.content.isEmpty && kept.isEmpty) continue;
        out.add(LlmMessage.assistant(m.content, toolCalls: kept, reasoning: m.reasoning == null ? null : ''));
      } else if (m.role == LlmRole.assistant && m.reasoning != null && privateReasoning.contains(m)) {
        // 推理可能引用记忆摘要，即使这一条没有调用 remember / forget 也必须脱敏。
        // 保留空协议字段，不能因脱敏又触发上游要求 reasoning_content 的 400。
        out.add(LlmMessage.assistant(m.content, toolCalls: m.toolCalls, reasoning: ''));
      } else {
        out.add(m);
      }
    }
    return out;
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
    bool dead() => gen != _generation || (cancel?.isCancelled ?? false);
    void emit(AgentEventKind k, {int step = 0, String? path, TurnStatus? status}) {
      if (!dead() && !_events.isClosed) _events.add(AgentEvent(turnId, k, step: step, path: path, status: status));
    }

    final memEpoch = _memEpoch;
    final cat = _catalog();
    final gate = gateFor(cat);
    // 记忆开关、系统提示、工具、文件系统在每次调模型前按当前开关重建（运行时可切）。
    var memoryOn = enableUserMemory;
    var fs = files(cat);
    Future<String> systemNow() async {
      var summary = '';
      if (memoryOn) {
        try {
          summary = UserMemoryOps.summary(await memory());
        } on Object {
          summary = '';
        }
      }
      return prompts.system(profile, fs, memory: memoryOn, memorySummary: summary);
    }

    var system = '';
    // 每次异步加载之后复查当前开关：加载期间被切换就按当前状态重建，直到稳定（或本轮作废）。
    Future<void> rebuild() async {
      do {
        memoryOn = enableUserMemory;
        fs = files(cat);
        system = await systemNow();
      } while (memoryOn != enableUserMemory && !dead());
    }

    await rebuild();
    final meta = (version: prompts.version(profile), hash: prompts.hash(system), catalog: cat.version);
    final userMsg = LlmMessage.user(prompts.userMessage(profile, cat, context, text));
    final turnMsgs = <LlmMessage>[];
    // 与记忆相关的工具结果（读 user-memory/ 文件、remember / forget）：关闭记忆后在后续请求里替换。
    final memResultIds = <String>{};
    final memoryReasoning = <LlmMessage>{};
    LlmMessage assistant(LlmResponse response, {String? content, List<LlmToolCall>? toolCalls, bool history = false}) {
      final msg = LlmMessage.assistant(
        content ?? response.content,
        toolCalls: toolCalls ?? response.toolCalls,
        // Worker 的不同上游可能在无推理正文时返回 null / 不返回字段。
        // 后续思考模型仍要求字段存在，显式空串不会编造任何推理内容。
        reasoning: response.reasoning ?? '',
      );
      if (memoryOn) (history ? _memoryReasoning : memoryReasoning).add(msg);
      return msg;
    }
    final calls = <_Call>[];
    final reads = <String>[];
    final readSet = <String>{};
    final memOps = <List<MemoryEntry> Function(List<MemoryEntry>)>[];
    var submissions = 0;
    var rejected = 0;
    List<PlanIssue> lastErrors = const [];
    FallbackReason reason = FallbackReason.invalidOutput;
    Object? error;
    var leaked = false;

    // 取消 / reset：保留已发生调用的记账与元数据，但不返回可渲染内容、不写历史和记忆。
    Future<CoachTurnResult> cancelled(int step) async {
      final records = await _record(turnId, meta, calls, TurnOutcome.cancelled);
      return CoachTurnResult(
        turnId: turnId,
        status: TurnStatus.cancelled,
        submissions: submissions,
        records: records,
        steps: step,
        reads: List.unmodifiable(reads),
      );
    }

    Future<CoachTurnResult> done(
      TurnStatus status,
      TurnOutcome outcome,
      int step, {
      String text = '',
      ValidatedPlan? plan,
      ValidatedActions? actions,
      List<PlanIssue> warnings = const [],
      void Function()? commit,
    }) async {
      final r = await _finish(
        turnId,
        meta,
        calls,
        status,
        outcome,
        text: text,
        plan: plan,
        actions: actions,
        warnings: warnings,
        issues: status == TurnStatus.ok ? const [] : lastErrors,
        reason: reason,
        error: status == TurnStatus.ok ? null : error,
        leaked: leaked,
        submissions: submissions,
        steps: step,
        reads: reads,
        dead: dead,
        commit: commit == null
            ? null
            : () {
                commit();
                if (enableUserMemory && memEpoch == _memEpoch && memOps.isNotEmpty && _memory != null) {
                  var m = _memory!;
                  for (final op in memOps) {
                    m = op(m);
                  }
                  _memory = m;
                  _save(m);
                }
              },
      );
      emit(AgentEventKind.done, step: step, status: r.status);
      return r;
    }

    var step = 0;
    while (step < maxSteps) {
      step++;
      emit(AgentEventKind.thinking, step: step);
      if (step > 1 || memoryOn != enableUserMemory) await rebuild();
      if (!memoryOn) memOps.clear();
      // 记忆加载等异步之后、实际调模型之前复查世代与取消。
      if (dead()) return cancelled(step - 1);
      final memOff = !memoryOn;
      LlmResponse res;
      try {
        res = await client.complete(
          LlmRequest(
            messages: [
              LlmMessage.system(system),
              ...(memOff ? _withoutMemory(_history, const {}, privateReasoning: _memoryReasoning) : _history),
              userMsg,
              ...(memOff ? _withoutMemory(turnMsgs, memResultIds, privateReasoning: memoryReasoning) : turnMsgs),
            ],
            tools: AgentTools.build(profile, cat, memory: memoryOn),
            toolChoice: 'auto',
          ),
          cancel: cancel,
        );
      } on LlmException catch (e) {
        calls.add(_Call.failed(step, e));
        if (e.kind == LlmErrorKind.cancelled || dead()) {
          return cancelled(step);
        }
        reason = _reasonFor(e.kind);
        error = e;
        break;
      } on Object catch (e) {
        if (dead()) {
          calls.add(_Call.failed(step, const LlmException(LlmErrorKind.cancelled, 'cancelled')));
          return cancelled(step);
        }
        calls.add(_Call.failed(step, LlmException(LlmErrorKind.badResponse, '$e')));
        reason = FallbackReason.server;
        error = e;
        break;
      }
      if (dead()) {
        calls.add(_Call.ok(step, res, CallOutcome.cancelled));
        return cancelled(step);
      }

      // 纯文字：结束本轮（过门禁：非空、无暗号）。
      if (res.toolCalls.isEmpty) {
        submissions++;
        final g = gate.check(res.content, const [], context: context);
        if (g.leaked) {
          calls.add(_Call.ok(step, res, CallOutcome.rejected, codes: const ['canary_leak']));
          leaked = true;
          break;
        }
        if (g.ok) {
          calls.add(_Call.ok(step, res, rejected == 0 ? CallOutcome.passed : CallOutcome.rewritten));
          return done(
            TurnStatus.ok,
            rejected == 0 ? TurnOutcome.model : TurnOutcome.rewritten,
            step,
            text: g.text,
            commit: () {
              _turns++;
              _history
                ..add(userMsg)
                ..add(assistant(res, content: g.text, history: true));
            },
          );
        }
        calls.add(_Call.ok(step, res, CallOutcome.rejected, codes: [for (final e in g.errors) e.code]));
        lastErrors = g.errors;
        if (++rejected > maxResubmits) break;
        turnMsgs
          ..add(assistant(res))
          ..add(LlmMessage.user(_feedback(g.errors, remaining: 1 + maxResubmits - rejected)));
        continue;
      }

      // 执行任何工具之前统一查暗号（正文、工具名、解码后的全部参数字符串）：命中整轮回落，不提交记忆。
      if (gate.leaks(res.content, res.toolCalls)) {
        calls.add(_Call.ok(step, res, CallOutcome.rejected, codes: const ['canary_leak']));
        leaked = true;
        break;
      }

      // 先执行中间工具，再判最终 show_*。
      final results = <String, String>{};
      final finals = <LlmToolCall>[];
      for (final t in res.toolCalls) {
        switch (t.name) {
          case AgentTools.read:
            final path = SkillFiles.normalize(_arg(t, 'path') ?? '');
            emit(AgentEventKind.reading, step: step, path: path);
            if (path.startsWith('${SkillFiles.userMemory}/')) memResultIds.add(t.id);
            results[t.id] = _read(fs, path, readSet, reads);
          case AgentTools.ls:
            final dir = SkillFiles.normalize(_arg(t, 'dir') ?? '');
            emit(AgentEventKind.listing, step: step, path: dir);
            final l = fs.ls(dir);
            results[t.id] = l == null ? '没有这个目录：$dir' : l.join('\n');
          case AgentTools.checkPlan:
            emit(AgentEventKind.checking, step: step);
            final r = _checkPlan(t, gate, context, cat);
            if (r == null) {
              leaked = true;
            } else {
              results[t.id] = r;
            }
          case AgentTools.remember || AgentTools.forget when memoryOn:
            final kindName = _arg(t, 'kind');
            emit(AgentEventKind.memory, step: step, path: kindName);
            memResultIds.add(t.id);
            results[t.id] = _memoryOp(t, memOps);
          case AgentTools.showActions || AgentTools.showPlan:
            finals.add(t);
          default:
            results[t.id] = jsonEncode({'ok': false, 'error': '没有工具「${t.name}」，只能用已提供的工具'});
        }
      }
      if (leaked) {
        calls.add(_Call.ok(step, res, CallOutcome.rejected, codes: const ['canary_leak']));
        break;
      }

      if (finals.isEmpty) {
        calls.add(_Call.ok(step, res, CallOutcome.toolStep));
        turnMsgs
          ..add(assistant(res))
          ..addAll([for (final t in res.toolCalls) LlmMessage.tool(t.id, results[t.id]!)]);
        continue;
      }

      submissions++;
      final g = gate.check(res.content, finals, context: context, planId: _ids.next('plan'));
      if (g.leaked) {
        calls.add(_Call.ok(step, res, CallOutcome.rejected, codes: const ['canary_leak']));
        leaked = true;
        break;
      }
      if (g.ok) {
        calls.add(_Call.ok(step, res, rejected == 0 ? CallOutcome.passed : CallOutcome.rewritten));
        return done(
          TurnStatus.ok,
          rejected == 0 ? TurnOutcome.model : TurnOutcome.rewritten,
          step,
          text: g.text,
          plan: g.plan,
          actions: g.actions,
          warnings: g.warnings,
          commit: () {
            _turns++;
            _history
              ..add(userMsg)
              ..add(assistant(res, content: g.text, toolCalls: finals, history: true))
              ..addAll([for (final t in finals) LlmMessage.tool(t.id, g.feedback())]);
          },
        );
      }
      calls.add(_Call.ok(step, res, CallOutcome.rejected, codes: [for (final e in g.errors) e.code]));
      lastErrors = g.errors;
      if (++rejected > maxResubmits) break;
      final fb = _feedback(g.errors, remaining: 1 + maxResubmits - rejected);
      turnMsgs
        ..add(assistant(res))
        ..addAll([for (final t in res.toolCalls) LlmMessage.tool(t.id, results[t.id] ?? fb)]);
    }
    if (step >= maxSteps && error == null && !leaked && rejected <= maxResubmits) {
      error = AgentStepLimitExceeded(maxSteps);
    }

    // 暗号泄露的轮次不提交任何记忆操作。
    if (leaked) memOps.clear();

    // 回落：绝不渲染未通过的内容。
    if (dead()) {
      return cancelled(step);
    }
    final fbFn = fallback;
    if (fbFn == null) return done(TurnStatus.error, TurnOutcome.error, step);
    try {
      final r = await fbFn(
        SessionFallbackRequest(userText: text, context: context, reason: reason, issues: lastErrors, error: error),
      );
      if (dead()) {
        return cancelled(step);
      }
      final plan = r.plan == null ? null : gate.admitTemplate(r.plan!, context);
      return done(
        TurnStatus.fallback,
        TurnOutcome.fallback,
        step,
        text: r.text,
        plan: plan,
        commit: () {
          _turns++;
          _history
            ..add(userMsg)
            ..add(LlmMessage.assistant(r.text, reasoning: ''));
        },
      );
    } on Object catch (e) {
      if (dead()) {
        return cancelled(step);
      }
      error = e;
      return done(TurnStatus.error, TurnOutcome.error, step);
    }
  }

  // ---- 工具执行 ----

  static String? _arg(LlmToolCall t, String key) {
    try {
      final m = jsonDecode(t.arguments);
      if (m is Map && m[key] is String) return m[key] as String;
    } on FormatException {
      // 参数坏了按缺失处理。
    }
    return null;
  }

  static String _read(SkillFiles fs, String path, Set<String> readSet, List<String> reads) {
    final text = fs.read(path);
    if (text == null) {
      final l = fs.ls(path);
      if (l != null) return '$path 是目录，包含：\n${l.join('\n')}';
      return '没有这个文件：$path。入口见系统提示里的技能列表，可用 ls 查看目录。';
    }
    if (!readSet.add(path)) return '（已读过 $path，见前文）';
    reads.add(path);
    return text;
  }

  /// check_plan：复用门禁校验 + SDK 估算时长。返回 null 表示参数里有暗号（整轮回落）。
  String? _checkPlan(LlmToolCall t, ToolGate gate, CoachContext ctx, Catalog cat) {
    Object? args;
    try {
      args = jsonDecode(t.arguments);
    } on FormatException catch (e) {
      return jsonEncode({
        'ok': false,
        'errors': [
          {
            'path': 'arguments',
            'code': IssueCodes.invalidJson,
            'fix': ToolGate.fixFor(IssueCodes.invalidJson),
            'message': e.message,
          },
        ],
      });
    }
    // 自检宽容一层包装：{"plan": {...}}。
    if (args is Map && args.length == 1 && args['plan'] is Map) args = args['plan'];
    final argText = jsonEncode(args);
    final g = gate.check('', [LlmToolCall(id: t.id, name: AgentTools.showPlan, arguments: argText)], context: ctx);
    if (g.leaked) return null;
    double? est;
    int? target;
    if (args is Map) {
      final decoded = const PlanCodec().decodeStrict(
        args.cast<String, Object?>(),
        scene: ctx.scene,
        level: ctx.level,
        minutes: ctx.minutes,
      );
      final p = decoded.plan;
      if (p != null) {
        est = const PlanDuration().estimateSeconds(p, cat) / 60;
        target = p.targetMinutes;
      }
    }
    final ok = g.errors.isEmpty;
    return jsonEncode({
      'ok': ok,
      if (!ok) 'errors': [for (final e in g.errors) _issueJson(e)],
      if (g.warnings.isNotEmpty) 'warnings': [for (final w in g.warnings) w.message],
      'estimatedMinutes': ?est == null ? null : (est * 10).round() / 10,
      'targetMinutes': ?target,
      'diffMinutes': ?(est == null || target == null) ? null : ((est - target) * 10).round() / 10,
      'next': ok ? '没有错误：用 show_plan 提交同样的参数（时长差太大可先调整）。' : '逐条改完再 check_plan。',
    });
  }

  String _memoryOp(LlmToolCall t, List<List<MemoryEntry> Function(List<MemoryEntry>)> ops) {
    final kindName = _arg(t, 'kind');
    final kind = MemoryKind.values.where((k) => k.name == kindName).firstOrNull;
    final text = _arg(t, 'text');
    if (t.name == AgentTools.remember) {
      if (kind == null || text == null || text.trim().isEmpty) {
        return jsonEncode({
          'ok': false,
          'error': 'remember 需要 kind（${MemoryKind.values.map((k) => k.name).join('/')}）和 text',
        });
      }
      final at = _clock().toUtc();
      ops.add((m) => UserMemoryOps.remember(m, MemoryEntry(kind, text, at: at), memoryLimits));
      return jsonEncode({'ok': true});
    }
    if (kind == null && (text == null || text.trim().isEmpty)) {
      return jsonEncode({'ok': false, 'error': 'forget 需要 kind 或 text'});
    }
    ops.add((m) => UserMemoryOps.forget(m, kind: kind, text: text));
    return jsonEncode({'ok': true});
  }

  /// show_* 被打回时回给模型的结果（改法换成 Agent 口径：id 来自读到的文件）。
  static String _feedback(List<PlanIssue> errors, {required int remaining}) => jsonEncode({
    'ok': false,
    'remainingAttempts': remaining,
    'errors': [for (final e in errors) _issueJson(e)],
    'instruction': '逐条改完后重新提交（可先 check_plan）；不要向用户解释这些错误。',
  });

  static Map<String, Object?> _issueJson(PlanIssue e) {
    final j = ToolGate.issueJson(e);
    final fix = switch (e.code) {
      IssueCodes.unknownExercise || IssueCodes.outOfProfile => '换成你在 action-library 索引里读到的 id，逐字拷贝',
      IssueCodes.modeMismatch => '按 details 里的默认剂量：mode=reps 填 reps；mode=time 填 workSeconds',
      IssueCodes.avoid => '换成 details 里注意部位不含该部位的动作，或删掉这一项',
      IssueCodes.unknownTool => '只用已提供的工具',
      IssueCodes.multipleTools => '一次回复只调用一个 show_* 工具',
      _ => null,
    };
    if (fix != null && e.fix == null) j['fix'] = fix;
    return j;
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

  // ---- 记账 ----

  Future<List<UsageRecord>> _record(
    String turnId,
    ({String version, String hash, String catalog}) meta,
    List<_Call> calls,
    TurnOutcome outcome,
  ) async {
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
    return records;
  }

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
    int steps = 0,
    List<String> reads = const [],
    required bool Function() dead,
    void Function()? commit,
  }) async {
    final records = await _record(turnId, meta, calls, outcome);
    // 记账是最后一个异步边界：其间 reset / 取消则本轮作废，不写历史 / 轮数 / 记忆。
    if (dead()) {
      return CoachTurnResult(
        turnId: turnId,
        status: TurnStatus.cancelled,
        submissions: submissions,
        records: records,
        steps: steps,
        reads: List.unmodifiable(reads),
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
      steps: steps,
      reads: List.unmodifiable(reads),
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
