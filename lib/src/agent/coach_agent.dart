/// Agent 版会话（0.3 推荐入口）：渐进式披露 + Pi 式工具循环。
///
/// 每轮：调模型 → 执行全部工具调用（read / ls / check_plan / remember / forget），结果追加 → 再调 →
/// 直到纯文字或 ask_user / show_actions / show_plan 通过门禁。最终工具不过门禁就把错误作为工具结果回给模型重交
/// （最多 [CoachAgent.maxResubmits] 次）。步数超过 [CoachAgent.maxSteps]、请求重试用尽 / 不可重试、整轮超时、
/// 空转、暗号泄露 → 回落 App 模板。单步请求失败只重试那一步（指数退避 + 抖动，可被取消 / reset 打断）；
/// 上下文超预算时把较早的 read / ls 结果压成一行摘要。见 docs/agent-plan.md「步数、上下文预算与失败重试」。
///
/// 对外与 [CoachSession] 同风格：[CoachAgent.send] / [CoachAgent.reset] / 取消、busy、reset 或取消后不回写；
/// 结果同为 [CoachTurnResult]，卡片只接受门禁产出的 [ValidatedPlan] / [ValidatedActions]。
/// 过程事件见 [CoachAgent.events]。0.2 的 [CoachSession] 保留作降级。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

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
import '../tools/ask_user.dart';
import '../tools/coach_session.dart';
import '../tools/tool_gate.dart';
import '../usage/usage.dart';
import '../util/clock.dart';
import 'action_tags.dart';
import 'agent_prompt.dart';
import 'agent_resilience.dart';
import 'agent_task.dart';
import 'batch_handler.dart';
import 'node_gates.dart';
import 'session_params.dart';
import 'session_state.dart';
import 'skill_files.dart';
import 'skill_tool_handler.dart';
import 'structured_tool_handler.dart';
import 'terminal_tool_handler.dart';
import 'training_confirmation.dart';
import 'training_parameters.dart';
import 'user_memory.dart';

export 'agent_resilience.dart';

part 'memory_tool_handler.dart';
part 'ask_commit_handler.dart';
part 'output_commit_handler.dart';

/// Persist alongside a delivered plan card to restore its planning conditions.
/// [planId] binds the snapshot to that exact card. A snapshot for another plan
/// is ignored. Missing fields in older snapshots are inferred from the plan.
class CoachPlanState {
  const CoachPlanState({
    required this.planId,
    this.context = const CoachContext(),
    this.focus,
    this.goal,
    this.relativeDurationPolicy,
    this.sessionState,
  });

  final String planId;
  final CoachContext context;
  final String? focus;
  final String? goal;
  final bool? relativeDurationPolicy;

  /// Structured session snapshot; absent in older persisted plan states.
  final CoachSessionState? sessionState;

  Map<String, Object?> toJson() => {
    'planId': planId,
    'context': context.toJson(),
    if (focus != null) 'focus': focus,
    if (goal != null) 'goal': goal,
    if (relativeDurationPolicy != null)
      'relativeDurationPolicy': relativeDurationPolicy,
    if (sessionState != null) 'sessionState': sessionState!.toJson(),
  };

  factory CoachPlanState.fromJson(Map<String, dynamic> json) {
    final raw = json['context'];
    final map = raw is Map ? raw : const {};
    Set<String>? stringSet(Object? value) =>
        value is List ? value.whereType<String>().toSet() : null;
    return CoachPlanState(
      planId: json['planId'] is String ? json['planId'] as String : '',
      context: CoachContext(
        scene: map['scene'] is String ? map['scene'] as String : null,
        equipment: stringSet(map['equipment']),
        avoid: stringSet(map['avoid']),
        level: map['level'] is int ? map['level'] as int : null,
        minutes: map['minutes'] is int ? map['minutes'] as int : null,
        goal: map['goal'] is String ? map['goal'] as String : null,
        language: map['language'] is String ? map['language'] as String : 'zh',
        notes: map['notes'] is List
            ? (map['notes'] as List).whereType<String>().toList()
            : const [],
      ),
      focus: json['focus'] is String ? json['focus'] as String : null,
      goal: json['goal'] is String ? json['goal'] as String : null,
      relativeDurationPolicy: json['relativeDurationPolicy'] is bool
          ? json['relativeDurationPolicy'] as bool
          : null,
      sessionState: json['sessionState'] is Map
          ? CoachSessionState.fromJson(
              (json['sessionState'] as Map).cast<String, Object?>(),
            )
          : null,
    );
  }
}

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

  /// 已通过门禁的澄清问题：[AgentEvent.question]。本轮随即结束，回答通过下一次 send。
  askUser,

  /// 本轮结束（[AgentEvent.status]）。
  done,

  /// 单步请求失败、即将重试：[AgentEvent.attempt] / [AgentEvent.maxAttempts]、[AgentEvent.reason]、
  /// [AgentEvent.delay]（如「网络不稳，正在重试（2/4）…」）。上下文超长压缩后的重试 reason = contextTooLong、delay = 0。
  retrying,

  /// 单步超过 [CoachAgent.slowAfter] 仍未返回（每步最多一次）。
  slow,

  /// 任务节点状态变更；[AgentEvent.task] 是变更后的任务快照。
  node,
}

/// 过程事件：供 App 显示进度（「正在查动作库…」）。作废的轮次（reset / 取消）不再发事件。
class AgentEvent {
  const AgentEvent(
    this.turnId,
    this.kind, {
    this.step = 0,
    this.path,
    this.status,
    this.attempt = 0,
    this.maxAttempts = 0,
    this.reason,
    this.delay,
    this.question,
    this.node,
    this.task,
  });
  final String turnId;
  final AgentEventKind kind;
  final int step;
  final String? path;
  final TurnStatus? status;
  final AskUserQuestion? question;
  final CoachNodeState? node;
  final CoachTaskState? task;

  /// retrying：第几次重试（从 1 起）/ 最多几次。
  final int attempt;
  final int maxAttempts;

  /// retrying：失败分类。
  final RequestErrorClass? reason;

  /// retrying：退避等待时长。
  final Duration? delay;

  @override
  String toString() =>
      'AgentEvent(${kind.name}${path == null ? '' : ' $path'}${status == null ? '' : ' ${status!.name}'}'
      '${kind == AgentEventKind.retrying ? ' $attempt/$maxAttempts ${reason?.name} ${delay?.inMilliseconds}ms' : ''})';
}

/// 步数超限（回落时放在 [CoachTurnResult.error]）。
class AgentStepLimitExceeded implements Exception {
  const AgentStepLimitExceeded(this.maxSteps);
  final int maxSteps;
  @override
  String toString() => 'AgentStepLimitExceeded($maxSteps)';
}

class CoachAgent {
  /// 一次任务最多一轮；同一表单可同时补齐多个条件。
  static const maxQuestionsPerTask = 1;

  CoachAgent({
    required this.client,
    required Catalog Function() catalog,
    required this.profile,
    this.fallback,
    UsageSink? usage,
    AgentPromptBuilder? prompts,
    this.maxSteps = 100,
    this.maxResubmits = 2,
    this.maxRequestRetries = 4,
    this.retryBaseDelay = const Duration(seconds: 1),
    this.retryMaxDelay = const Duration(seconds: 15),
    this.requestTimeout = const Duration(seconds: 60),
    this.turnTimeout = const Duration(seconds: 360),
    this.slowAfter = const Duration(seconds: 30),
    this.contextBudgetTokens = 60000,
    this.keepRecentSteps = 3,
    this.maxStallSteps = 3,
    Future<void> Function(Duration)? sleep,
    double Function()? random,
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
       _ids = ids ?? IdGenerator(clock: clock),
       _sleep = sleep ?? Future<void>.delayed,
       _random = random ?? math.Random().nextDouble;

  final LlmClient client;
  final CoachProfile profile;
  final SessionFallback? fallback;
  final UsageSink usage;
  final AgentPromptBuilder prompts;

  /// 每轮最多调模型几次（含读文件、自检、重交；不含同一步的失败重试）。
  final int maxSteps;

  /// 单步请求失败后最多重试几次（只重试这一步）。
  final int maxRequestRetries;

  /// 退避：第 n 次重试等 `retryBaseDelay × 2^(n-1)`（±20% 抖动），封顶 [retryMaxDelay]；Retry-After 优先（同样封顶）。
  final Duration retryBaseDelay;
  final Duration retryMaxDelay;

  /// 单次模型请求超时（超时按可重试处理）。
  final Duration requestTimeout;

  /// 整轮总时限（含重试与退避），超出回落模板。
  final Duration turnTimeout;

  /// 单步多久未返回发一次 [AgentEventKind.slow]。
  final Duration slowAfter;

  /// 上下文预算（估算 token，不计 reasoning）：超过时压缩较早的 read / ls 结果。
  final int contextBudgetTokens;

  /// 压缩时完整保留最近几个工具步。
  final int keepRecentSteps;

  /// 连续几次完全相同的工具调用、或连续几步没有新信息算空转：先提示，再犯回落。
  final int maxStallSteps;

  /// show_* / ask_user 门禁不过时允许重交的次数。
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
  final Future<void> Function(Duration) _sleep;
  final double Function() _random;

  /// reset 信号：打断在途请求与退避等待。
  Completer<void> _resetSig = Completer<void>();

  final _events = StreamController<AgentEvent>.broadcast(sync: true);
  final _eventQueue = Queue<(AgentEvent, int)>();
  bool _emittingEvents = false;

  /// 过程事件流（broadcast）。
  Stream<AgentEvent> get events => _events.stream;

  // Synchronous listeners may update host conditions and emit another node.
  // Queue reentrant events so StreamController is never fired recursively.
  void _emitEvent(AgentEvent event) {
    if (_events.isClosed) return;
    _eventQueue.add((event, _generation));
    if (_emittingEvents) return;
    _emittingEvents = true;
    try {
      while (_eventQueue.isNotEmpty && !_events.isClosed) {
        final (next, generation) = _eventQueue.removeFirst();
        if (generation != _generation) continue;
        if (next.kind == AgentEventKind.node &&
            !identical(next.task, _sessionState.task)) {
          continue;
        }
        _events.add(next);
      }
    } finally {
      _emittingEvents = false;
      if (_events.isClosed) _eventQueue.clear();
    }
  }

  void _emitNodeChanges(String turnId, NodeResult result) {
    for (final node in result.changes) {
      if (_events.isClosed ||
          !identical(_sessionState.task, result.state.task)) {
        return;
      }
      _emitEvent(
        AgentEvent(
          turnId,
          AgentEventKind.node,
          node: node,
          task: result.state.task,
        ),
      );
    }
  }

  void _emitTaskRollback(String turnId, CoachTaskState? before) {
    final task = _sessionState.task;
    if (jsonEncode(before?.toJson()) == jsonEncode(task?.toJson()) ||
        _events.isClosed) {
      return;
    }
    if (task == null) {
      _emitEvent(AgentEvent(turnId, AgentEventKind.node));
      return;
    }
    final oldNodes = {
      for (final node in before?.nodes ?? const <CoachNodeState>[])
        node.id: node,
    };
    var emitted = false;
    for (final node in task.nodes) {
      if (!identical(_sessionState.task, task) || _events.isClosed) return;
      if (jsonEncode(oldNodes[node.id]?.toJson()) !=
          jsonEncode(node.toJson())) {
        emitted = true;
        _emitEvent(
          AgentEvent(turnId, AgentEventKind.node, node: node, task: task),
        );
      }
    }
    if (!emitted && identical(_sessionState.task, task) && !_events.isClosed) {
      _emitEvent(AgentEvent(turnId, AgentEventKind.node, task: task));
    }
  }

  final List<LlmMessage> _history = [];
  CoachSessionState _sessionState = CoachSessionState();
  int _hostSafetyRevision = 0;
  Set<String>? _latestExplicitAvoid;
  // 只追踪曾看过用户记忆的响应；记忆从未开启的工具推理必须完整回传。
  final Set<LlmMessage> _memoryReasoning = {};
  int _turns = 0;
  int _questionsAsked = 0;
  bool _parameterTask = false;
  // Only messages belonging to the current plan contribute its parameters.
  // Chat history remains intact for the model and the conversation UI.
  final List<String> _planParameterMessages = [];
  AskUserQuestion? _pendingConfirmation;
  int _confirmationDismissRevision = 0;
  CoachContext? _confirmedPlanContext;
  // The last admitted plan is the only reliable baseline for relative time
  // adjustments. Failed submissions never replace it.
  double? _lastAdmittedPlanSeconds;
  bool _relativeDurationPolicy = false;
  String? _pendingAdjustment;
  CoachContext? _taskSafetyContext;
  String? _planFocus;
  String? _planGoal;
  Map<String, List<String>>? _lastConfirmedForm;
  bool _safetyBlocked = false;
  bool _planningFailure = false;
  int _generation = 0;
  int? _busyGen;

  List<MemoryEntry>? _memory;

  /// 记忆世代：[clearMemory] 递增，使此前发起的 load 结果和各轮暂存的记忆操作全部失效。
  int _memEpoch = 0;
  Future<void> _saving = Future.value();

  ({CoachProfile p, Catalog c, bool m})? _filesKey;
  SkillFiles? _files;

  List<LlmMessage> get history => List.unmodifiable(_history);

  /// Immutable structured state, including original accepted user messages.
  CoachSessionState get sessionState => _sessionState;
  int get turnCount => _turns;

  /// 本次任务已成功交付的澄清问题数；跨 send 保留，成功交付计划/动作卡或 reset 时清零。
  int get questionsAsked => _questionsAsked;

  /// The three conditions last confirmed for the active planning task.
  /// Failure and retry preserve this snapshot; a new task or reset clears it.
  Map<String, List<String>>? get lastConfirmedForm => _lastConfirmedForm;

  /// Capture the active conditions for persistence with an admitted plan.
  CoachPlanState planStateFor(ValidatedPlan admitted) {
    final plan = admitted.plan;
    final context = _confirmedPlanContext ?? const CoachContext();
    final safety = _taskSafetyContext;
    return CoachPlanState(
      planId: plan.id,
      context: CoachContext(
        scene: context.scene,
        equipment: context.equipment,
        minutes: context.minutes,
        avoid: {...plan.avoid, ...context.avoid, ...?safety?.avoid},
        level: context.level ?? safety?.level,
        goal: context.goal ?? safety?.goal,
        language: context.language,
        notes: {...context.notes, ...?safety?.notes}.toList(),
      ),
      focus: _planFocus,
      goal: _planGoal,
      relativeDurationPolicy: _relativeDurationPolicy,
      sessionState: _sessionState,
    );
  }

  /// Rebuild the active task from a previously re-admitted plan. This does not
  /// restore or replay old tool calls or pending questions. Call after reset.
  void restorePlan(
    ValidatedPlan admitted, {
    CoachPlanState? planState,
    String? focusHint,
    String? goalHint,
    List<String> restoredUserTurns = const [],
  }) {
    final plan = admitted.plan;
    final stored = planState?.planId == plan.id ? planState : null;
    _sessionState = stored?.sessionState ?? CoachSessionState();
    final saved = stored?.context;
    final context = CoachContext(
      scene: saved?.scene ?? plan.scene,
      equipment: saved?.equipment ?? plan.equipment.toSet(),
      minutes: saved?.minutes ?? plan.targetMinutes,
      avoid: {...plan.avoid, ...?saved?.avoid},
      level: saved?.level ?? plan.level,
      goal: saved?.goal,
      language: saved?.language ?? 'zh',
      notes: saved?.notes ?? const [],
    );
    final cat = _catalog();
    if (stored?.sessionState == null) {
      // Older plan snapshots had no sourced ledger. The context supplied by
      // the host (or the legacy card fallback) remains available without
      // fabricating a user quote or guessing a structured goal.
      final restored = SessionParams(ActionTags(profile, cat))
          .applyHost(_sessionState, context);
      if (restored.ok) _sessionState = restored.state;
      for (final text in restoredUserTurns) {
        _sessionState = _sessionState.appendUserTurn(text);
        _history.add(LlmMessage.user(text));
      }
    }
    if (stored?.sessionState == null && _sessionState.lastDeliveredPlanId == null) {
      // Snapshots predating delivered-version tracking can still use the
      // admitted card as their actual previous delivery, without pretending
      // that newer task nodes were completed.
      final versions = _sessionState.plans[plan.id] ?? const <CoachPlanVersion>[];
      final matching = versions.where((v) => jsonEncode(v.plan) == jsonEncode(plan.toJson())).lastOrNull;
      final previous = matching ?? CoachPlanVersion(
        version: versions.isEmpty ? 1 : versions.map((v) => v.version).reduce(math.max) + 1,
        plan: plan.toJson(),
        estimateSec: const PlanDuration().estimateSeconds(plan, cat),
        fitLog: const [],
      );
      _sessionState = _sessionState.copyWith(
        plans: {
          ..._sessionState.plans,
          plan.id: matching == null ? [...versions, previous] : versions,
        },
        lastDeliveredPlanId: plan.id,
        lastDeliveredVersion: previous.version,
        lastDeliveredTurn: _sessionState.userTurns.isEmpty
            ? 0 : _sessionState.userTurns.last.turn,
      );
    }
    final actual = const PlanDuration().estimateSeconds(plan, cat);
    _confirmedPlanContext = context;
    _taskSafetyContext = context;
    _planFocus =
        stored?.focus ??
        focusHint ??
        trainingFocus('${plan.title} ${plan.summary}');
    _planGoal =
        stored?.goal ??
        goalHint ??
        trainingGoal('${plan.title} ${plan.summary}');
    _lastConfirmedForm = trainingSelections(context, cat);
    _lastAdmittedPlanSeconds = actual;
    _relativeDurationPolicy =
        stored?.relativeDurationPolicy ??
        (plan.targetMinutes > 0 &&
            (actual / 60 - plan.targetMinutes).abs() / plan.targetMinutes >
                .25);
    _planParameterMessages
      ..clear()
      ..add('已恢复的当前计划');
    _history.add(
      LlmMessage.assistant(
        '已恢复的当前计划（供后续调整使用）：${jsonEncode(plan.toJson())}',
        reasoning: '',
      ),
    );
  }

  /// The still-active local confirmation, including while unrelated chat is
  /// handled. Successful answer, a replacement task, or reset clears it.
  AskUserQuestion? get pendingConfirmation => _pendingConfirmation;

  /// Explicitly replaces protected body areas after host/user confirmation.
  /// Merely omitting [CoachContext.avoid] never clears prior protection and
  /// this does not override a separate unresolved red-flag safety state.
  void replaceSafetyAvoid(Set<String> avoid) {
    final nextAvoid = Set<String>.unmodifiable(avoid);
    _hostSafetyRevision++;
    _latestExplicitAvoid = nextAvoid;
    final cat = _catalog();
    final updated = SessionParams(
      ActionTags(profile, cat),
    ).applyHost(_sessionState, CoachContext(avoid: nextAvoid));
    final nodes = updated.changedFields.isEmpty
        ? NodeResult(updated.state)
        : NodeGates(
            profile,
            cat,
            minPicks: profile.minActions,
          ).parametersChanged(
            updated.state,
            changedFields: updated.changedFields,
            valueChangedFields: updated.valueChangedFields,
            language:
                _taskSafetyContext?.language ??
                _confirmedPlanContext?.language ??
                'zh',
          );
    _sessionState = nodes.state;
    CoachContext replace(CoachContext c) => CoachContext(
      scene: c.scene,
      equipment: c.equipment,
      minutes: c.minutes,
      avoid: nextAvoid,
      level: c.level,
      goal: c.goal,
      language: c.language,
      notes: c.notes,
    );
    _taskSafetyContext = replace(_taskSafetyContext ?? const CoachContext());
    if (_confirmedPlanContext != null) {
      _confirmedPlanContext = replace(_confirmedPlanContext!);
    }
    if (nodes.changes.isNotEmpty) _emitNodeChanges(_ids.next('host'), nodes);
  }

  /// Explicitly invalidate an unanswered confirmation. A previously confirmed
  /// snapshot is retained so that a failed generation remains retryable.
  void dismissConfirmation() {
    _confirmationDismissRevision++;
    if (_pendingConfirmation == null) return;
    _pendingConfirmation = null;
    _questionsAsked = 0;
    _parameterTask = false;
    if (_confirmedPlanContext == null) {
      _planParameterMessages.clear();
      _planFocus = null;
      _planGoal = null;
    }
  }

  /// True only when a host-provided preset both targets this task's verified
  /// focus and passes the same catalog, safety and confirmed-condition gate.
  bool canOfferPreset(TrainingPlan plan) =>
      _planningFailure && !isBusy && !isFull && _admitPreset(plan) != null;

  /// Delivers a preset only after the user has explicitly selected it.
  /// Unknown or mismatched focus and any gate failure return null.
  CoachTurnResult? requestPreset(TrainingPlan plan) {
    if (!_planningFailure || isBusy || isFull) return null;
    final admitted = _admitPreset(plan);
    if (admitted == null) return null;
    final text = _planSummary(admitted.plan, _catalog());
    _questionsAsked = 0;
    _parameterTask = false;
    _planningFailure = false;
    _pendingAdjustment = null;
    _relativeDurationPolicy = false;
    _lastAdmittedPlanSeconds = const PlanDuration().estimateSeconds(
      admitted.plan,
      _catalog(),
    );
    _turns++;
    _history
      ..add(const LlmMessage.user('用预设方案'))
      ..add(LlmMessage.assistant(text, reasoning: ''));
    return CoachTurnResult(
      turnId: _ids.next('turn'),
      status: TurnStatus.fallback,
      text: text,
      plan: admitted,
    );
  }

  ValidatedPlan? _admitPreset(TrainingPlan plan) {
    final context = _confirmedPlanContext;
    // A preset checked against the old plan could contradict a failed edit.
    if (_safetyBlocked ||
        _pendingAdjustment != null ||
        context == null ||
        _planFocus == null) {
      return null;
    }
    final catalog = _catalog();
    if (!presetMatchesFocus(plan, catalog, _planFocus)) return null;
    final parameters = TrainingParameters.infer(
      [''],
      context,
      catalog,
      profile,
    );
    return ToolGate(
      catalog: catalog,
      profile: profile,
      canary: prompts.canary,
      extraRules: [...extraRules, parameters.validate],
      enforceDrillDoseRange: enforceDrillDoseRange,
    ).admitTemplate(plan, context);
  }

  int get historyChars => _history.fold(0, (n, m) => n + _chars(m));
  bool get isBusy => _busyGen == _generation;
  bool get isFull =>
      _turns + (isBusy ? 1 : 0) >= maxTurns || historyChars >= maxHistoryChars;

  /// 清空对话。进行中的旧轮作废，返回时不写历史、不改记忆。
  void reset() {
    _generation++;
    _history.clear();
    _sessionState = CoachSessionState();
    _hostSafetyRevision++;
    _latestExplicitAvoid = null;
    _memoryReasoning.clear();
    _turns = 0;
    _questionsAsked = 0;
    _parameterTask = false;
    _planParameterMessages.clear();
    _pendingConfirmation = null;
    _confirmedPlanContext = null;
    _lastAdmittedPlanSeconds = null;
    _relativeDurationPolicy = false;
    _pendingAdjustment = null;
    _taskSafetyContext = null;
    _planFocus = null;
    _planGoal = null;
    _lastConfirmedForm = null;
    _safetyBlocked = false;
    _planningFailure = false;
    _resetSig.complete();
    _resetSig = Completer<void>();
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
    if (epoch != _memEpoch) {
      return List.unmodifiable(_memory ?? const <MemoryEntry>[]);
    }
    return List.unmodifiable(_memory ??= loaded);
  }

  /// 清空用户记忆（App 的「清除 AI 记忆」）。在途的 load 与各轮待提交的记忆操作一并作废。
  Future<void> clearMemory() {
    _memEpoch++;
    _memory = [];
    final safeHistory = _withoutMemory(
      _history,
      const {},
      privateReasoning: _memoryReasoning,
    );
    _history
      ..clear()
      ..addAll(safeHistory);
    _memoryReasoning.clear();
    return _save(const []);
  }

  Future<void> _save(List<MemoryEntry> list) {
    final snapshot = List<MemoryEntry>.of(list);
    return _queueMemory(() => memoryStore.save(snapshot));
  }

  // 保存错误交给本次调用者处理；队列自身恢复，以免一次失败阻塞后续工具或清除。
  Future<T> _queueMemory<T>(Future<T> Function() action) {
    final pending = _saving.then((_) => action());
    _saving = pending.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return pending;
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
    bool isMem(LlmToolCall t) =>
        t.name == AgentTools.remember || t.name == AgentTools.forget;
    final dropIds = {
      for (final m in msgs)
        for (final t in m.toolCalls)
          if (isMem(t) && memResultIds.contains(t.id)) t.id,
    };
    final out = <LlmMessage>[];
    for (final m in msgs) {
      if (m.role == LlmRole.tool) {
        if (dropIds.contains(m.toolCallId)) continue;
        out.add(
          memResultIds.contains(m.toolCallId)
              ? LlmMessage.tool(m.toolCallId!, '（用户记忆已关闭）')
              : m,
        );
      } else if (m.role == LlmRole.assistant && m.toolCalls.any(isMem)) {
        final kept = [
          for (final t in m.toolCalls)
            if (!dropIds.contains(t.id))
              isMem(t)
                  ? LlmToolCall(id: t.id, name: t.name, arguments: '{}')
                  : t,
        ];
        if (m.content.isEmpty && kept.isEmpty) continue;
        out.add(
          LlmMessage.assistant(
            m.content,
            toolCalls: kept,
            reasoning: m.reasoning == null ? null : '',
          ),
        );
      } else if (m.role == LlmRole.assistant &&
          m.reasoning != null &&
          privateReasoning.contains(m)) {
        // 推理可能引用记忆摘要，即使这一条没有调用 remember / forget 也必须脱敏。
        // 保留空协议字段，不能因脱敏又触发上游要求 reasoning_content 的 400。
        out.add(
          LlmMessage.assistant(
            m.content,
            toolCalls: m.toolCalls,
            reasoning: '',
          ),
        );
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
    Map<String, List<String>>? confirmedForm,
  }) async {
    final turnId = _ids.next('turn');
    final text = userText.trim();
    if (text.length > maxInputChars) {
      return CoachTurnResult(turnId: turnId, status: TurnStatus.inputTooLong);
    }
    if (isBusy) return CoachTurnResult(turnId: turnId, status: TurnStatus.busy);
    if (isFull) {
      return CoachTurnResult(turnId: turnId, status: TurnStatus.limitReached);
    }
    _planningFailure = false;
    final gen = _generation;
    _busyGen = gen;
    final previousSession = _sessionState;
    final previousQuestion = _pendingConfirmation;
    final dismissRevision = _confirmationDismissRevision;
    final safetyRevision = _hostSafetyRevision;
    var rollbackSession = previousSession;
    var acceptedInput = false;
    CoachSessionState rollback() {
      final currentAvoid = _latestExplicitAvoid;
      if (_hostSafetyRevision != safetyRevision && currentAvoid != null) {
        final cat = _catalog();
        final host = SessionParams(
          ActionTags(profile, cat),
        ).applyHost(rollbackSession, CoachContext(avoid: currentAvoid));
        return host.changedFields.isEmpty
            ? host.state
            : NodeGates(
                profile,
                cat,
                minPicks: profile.minActions,
              ).parametersChanged(host.state, language: context.language, changedFields: host.changedFields, valueChangedFields: host.valueChangedFields).state;
      }
      return rollbackSession;
    }

    try {
      final cat = _catalog();
      final host = SessionParams(
        ActionTags(profile, cat),
      ).applyHost(_sessionState, context);
      if (!host.ok) {
        return CoachTurnResult(
          turnId: turnId,
          status: TurnStatus.error,
          error: FormatException(jsonEncode(host.error)),
        );
      }
      final nodes = host.changedFields.isEmpty
          ? NodeResult(host.state)
          : NodeGates(
              profile,
              cat,
              minPicks: profile.minActions,
            ).parametersChanged(host.state, language: context.language, changedFields: host.changedFields, valueChangedFields: host.valueChangedFields);
      _sessionState = nodes.state;
      if (nodes.changes.isNotEmpty) _emitNodeChanges(turnId, nodes);
      if (_generation != gen || (cancel?.isCancelled ?? false)) {
        return CoachTurnResult(turnId: turnId, status: TurnStatus.cancelled);
      }
      rollbackSession = _sessionState;
      _sessionState = _sessionState.appendUserTurn(userText);
      acceptedInput = true;
      final result = await _run(
        turnId,
        text,
        context,
        cancel,
        gen,
        confirmedForm,
      );
      if (result.status == TurnStatus.cancelled && _generation == gen) {
        final before = _sessionState.task;
        _sessionState = rollback();
        _emitTaskRollback(turnId, before);
        if (_generation == gen &&
            _confirmationDismissRevision == dismissRevision) {
          _pendingConfirmation = previousQuestion;
        }
      }
      return result;
    } on Object {
      if (_generation == gen) {
        final before = _sessionState.task;
        _sessionState = acceptedInput
            ? rollback().appendUserTurn(userText)
            : rollback();
        _emitTaskRollback(turnId, before);
        if (_generation == gen &&
            _confirmationDismissRevision == dismissRevision) {
          _pendingConfirmation = previousQuestion;
        }
      }
      rethrow;
    } finally {
      if (_busyGen == gen) _busyGen = null;
    }
  }

  Future<CoachTurnResult> _run(
    String turnId,
    String text,
    CoachContext context,
    CancelToken? cancel,
    int gen,
    Map<String, List<String>>? confirmedForm,
  ) async {
    bool dead() => gen != _generation || (cancel?.isCancelled ?? false);
    // 清除记忆也作废本轮先前请求取得的记忆操作；下一轮才重新允许记忆。
    final turnMemoryEpoch = _memEpoch;
    bool memoryAllowed() => enableUserMemory && turnMemoryEpoch == _memEpoch;
    // 固定本轮的 reset 信号：reset() 会替换 _resetSig，之后再读到的是新轮的信号。
    final resetSig = _resetSig;
    void emit(
      AgentEventKind k, {
      int step = 0,
      String? path,
      TurnStatus? status,
      int attempt = 0,
      int maxAttempts = 0,
      RequestErrorClass? reason,
      Duration? delay,
      AskUserQuestion? question,
    }) {
      if (!dead() && !_events.isClosed) {
        _emitEvent(
          AgentEvent(
            turnId,
            k,
            step: step,
            path: path,
            status: status,
            attempt: attempt,
            maxAttempts: maxAttempts,
            reason: reason,
            delay: delay,
            question: question,
          ),
        );
      }
    }

    final turnWatch = Stopwatch()..start();

    final originalText = text;
    final retry = RegExp(r'^(?:再)?(?:重试|重新尝试|再试一次)').hasMatch(text);
    // A failed edit must be retried with the same explicit conditions and
    // relative direction, while the previously admitted plan stays intact.
    if (retry && _pendingAdjustment != null) text = _pendingAdjustment!;
    final requestedText = text;
    final cat = _catalog();
    final focus = trainingFocus(text);
    final goal = trainingGoal(text);
    final newRedFlag = hasTrainingRedFlag(text);
    final correctsRedFlag =
        !newRedFlag &&
        RegExp(
          r'(?:之前|刚才|上次).{0,18}(?:误报|说错|误会|搞错|弄错)|(?:误报|说错|误会|搞错|弄错).{0,18}(?:之前|刚才|上次)',
        ).hasMatch(text) &&
        RegExp(r'没有|并无|不存在|不是|无').hasMatch(text);
    final redFlag = newRedFlag || (_safetyBlocked && !correctsRedFlag);
    final hasPlanWords = RegExp(
      r'训练组|计划|方案|排课|(?:一套|一组|一份).*(?:训练|动作|拉伸|放松)|\b(?:plan|routine|workout)\b',
      caseSensitive: false,
    ).hasMatch(text);
    final trainingDomain =
        RegExp(r'训练|锻炼|健身|运动|拉伸|放松|热身|瑜伽|徒手|器械|哑铃|弹力带|开胯|肌群').hasMatch(text) ||
        focus != null ||
        goal != null;
    final explicitPlan = hasPlanWords && trainingDomain;
    final explainingAction = RegExp(
      r'怎么做|如何做|怎么练|如何练|怎么放松|如何放松|讲解|要领|姿势|区别|展示|看看|找动作|是什么|为什么',
    ).hasMatch(text);
    final explicitlyCreatesPlan =
        explicitPlan &&
        RegExp(r'(?:做|排|制定|生成|设计|安排|创建|编排).{0,18}(?:计划|训练组|方案)').hasMatch(text);
    final onlyExplanation = explainingAction && !explicitlyCreatesPlan;
    final revision = RegExp(
      r'(?:这个|这套|这份|上个|上一|原来|之前|刚才|现有|当前|原方案|原计划).{0,20}(?:改|换|调整|缩短|延长|增加|减少|替换)|(?:改|调整|修改|优化|更换|替换|缩短|延长).{0,20}(?:这个|这套|这份|上个|原来|之前|刚才|现有|当前|方案|计划|训练组)',
    ).hasMatch(text);
    final explicitlyNew = RegExp(
      r'新(?:的|建|做|排|制定|生成|一套|一份)|另外|再(?:做|排|生成|来|设计)|重新(?:做|排|生成|制定|设计)',
    ).hasMatch(text);
    final asksFocusTraining =
        focus != null &&
        RegExp(r'练|训练|锻炼|放松|拉伸|热身').hasMatch(text) &&
        !onlyExplanation;
    final asksGoalTraining =
        goal != null &&
        RegExp(r'想|要|练|训练|锻炼|改善|提升|增加|增强|减|燃|塑形').hasMatch(text) &&
        !onlyExplanation;
    final asksRoutine =
        RegExp(
          r'(?:排|做|给我|来|制定|设计|编排).{0,24}(?:开胯|拉伸|热身|放松|锻炼|运动|力量|训练)',
        ).hasMatch(text) &&
        !onlyExplanation;
    final answerFacts = TrainingParameters.infer(
      [text],
      const CoachContext(),
      cat,
      profile,
    );
    final answersConfirmation =
        answerFacts.missing.length < 3 ||
        answerFacts.skipped ||
        RegExp(r'按默认来|直接出方案|默认就好|不确定|你决定').hasMatch(text);
    final changesFocus =
        focus != null &&
        focus != _planFocus &&
        _planParameterMessages.isNotEmpty &&
        RegExp(r'换|改|变成|改成|想|练|做').hasMatch(text) &&
        !onlyExplanation;
    final wantsPlan =
        explicitPlan ||
        asksFocusTraining ||
        asksGoalTraining ||
        asksRoutine ||
        changesFocus ||
        (text.contains('训练') && !onlyExplanation);
    final newFocus = (asksFocusTraining || changesFocus) && focus != _planFocus;
    final newGoal = asksGoalTraining && goal != _planGoal;
    final changesCurrent =
        !newGoal &&
        !newFocus &&
        (revision ||
            (_planParameterMessages.isNotEmpty &&
                RegExp(
                  r'短一点|短一些|短些|更短|长一点|长一些|长些|更长|难一点|简单一点|轻一点|换掉|换成|换到|换(?:一个|个)(?:别的)?(?:动作|哑铃|椅子|瑜伽垫)|改成|改为|改到|调整一下|缩短|延长|加长|(?:加|增|减|降)(?:到|至|为)',
                ).hasMatch(text)));
    final parameterTask =
        !redFlag &&
        ((wantsPlan && !onlyExplanation) ||
            (changesCurrent && _planParameterMessages.isNotEmpty) ||
            (retry && _confirmedPlanContext != null) ||
            confirmedForm != null ||
            (_parameterTask && !onlyExplanation && answersConfirmation));
    final startsNewPlan =
        parameterTask &&
        wantsPlan &&
        !changesCurrent &&
        confirmedForm == null &&
        (!_parameterTask || explicitlyNew || newFocus || newGoal);
    final questionsAsked = startsNewPlan ? 0 : _questionsAsked;
    // A new planning task cannot silently inherit stale environment settings.
    // Other context, especially safety screening, remains unchanged.
    final safety = _taskSafetyContext ?? _confirmedPlanContext;
    final cleanContext = CoachContext(
      avoid: {...?safety?.avoid, ...context.avoid},
      level: context.level ?? safety?.level,
      goal: context.goal ?? (startsNewPlan ? null : safety?.goal),
      language: context.language,
      notes: {...?safety?.notes, ...context.notes}.toList(),
    );
    final prior = startsNewPlan ? null : _confirmedPlanContext;
    final parameterContext = parameterTask
        ? (prior == null
              ? cleanContext
              : CoachContext(
                  scene: prior.scene,
                  equipment: prior.equipment,
                  minutes: prior.minutes,
                  avoid: cleanContext.avoid,
                  level: cleanContext.level,
                  goal: cleanContext.goal,
                  language: cleanContext.language,
                  notes: cleanContext.notes,
                ))
        : context;
    final typedConfirmed = confirmedForm == null
        ? null
        : (_pendingConfirmation == null
              ? null
              : confirmedTrainingContext(
                  _pendingConfirmation!,
                  confirmedForm,
                  parameterContext,
                  cat,
                ));
    if (confirmedForm != null && typedConfirmed == null) {
      return CoachTurnResult(
        turnId: turnId,
        status: TurnStatus.error,
        error: const FormatException('Invalid training confirmation'),
      );
    }
    final parameters = TrainingParameters.infer(
      typedConfirmed != null
          ? const ['']
          : parameterTask
          ? [
              if (!startsNewPlan && prior == null) ..._planParameterMessages,
              text,
            ]
          : [text],
      typedConfirmed ?? parameterContext,
      cat,
      profile,
    );
    // Only explicit facts constrain admission. Defaults guide generation and
    // are explained to the user; they do not turn guesses into user facts.
    context = parameterTask
        ? parameters.resolved(
            profile,
            clarificationFinished: questionsAsked >= maxQuestionsPerTask,
          )
        : parameters.context;
    final tags = ActionTags(profile, cat);
    CoachContext ledgerContext(CoachContext previous) {
      final values = _sessionState.params;
      final equipment = values['equipment']?.value as List<Object?>?;
      final limits = values['limits']?.value as List<Object?>?;
      return CoachContext(
        scene: values['scene']?.value as String? ?? previous.scene,
        equipment: equipment == null
            ? previous.equipment
            : {
                for (final code in equipment.cast<String>())
                  ?tags.equipmentId(code),
              },
        minutes: values['minutes']?.value as int? ?? previous.minutes,
        level: values['level']?.value as int? ?? previous.level,
        avoid: limits == null
            ? previous.avoid
            : {
                for (final code in limits.cast<String>())
                  ?tags.limitValue(code),
              },
        goal: previous.goal,
        language: previous.language,
        notes: previous.notes,
      );
    }

    context = ledgerContext(context);
    // An explicit duration takes precedence over the old value and is
    // validated as an absolute request, even if the sentence says 缩短/延长.
    final relativeDuration =
        changesCurrent && answerFacts.context.minutes == null;
    final shortensPlan =
        relativeDuration && RegExp(r'短一点|短一些|短些|更短|缩短|少一点时间').hasMatch(text);
    final lengthensPlan =
        relativeDuration && RegExp(r'长一点|长一些|长些|更长|延长|加长|多一点时间').hasMatch(text);
    final adjustsDuration = shortensPlan || lengthensPlan;
    final oldDuration = prior?.minutes;
    final oldPlanSeconds = _lastAdmittedPlanSeconds;
    final carryRelativeDurationPolicy =
        _relativeDurationPolicy &&
        changesCurrent &&
        answerFacts.context.minutes == null &&
        !adjustsDuration;
    if (adjustsDuration && oldDuration != null) {
      context = CoachContext(
        scene: context.scene,
        equipment: context.equipment,
        avoid: context.avoid,
        level: context.level,
        goal: context.goal,
        language: context.language,
        notes: context.notes,
      );
    }
    final gate = ToolGate(
      catalog: cat,
      profile: profile,
      canary: prompts.canary,
      extraRules: [
        ...extraRules,
        (plan, catalog, effective) => parameters.validate(
          plan,
          catalog,
          effective,
          enforceDurationEstimate: !carryRelativeDurationPolicy,
        ),
        if (parameterTask)
          (plan, catalog, context) => [
            if (planTouchesFocus(
                  plan,
                  catalog,
                  startsNewPlan ? focus ?? goal : _planFocus ?? focus ?? goal,
                ) ==
                false)
              const PlanIssue(
                'focus_conflict',
                '训练动作没有覆盖用户的重点部位',
                path: 'blocks',
              ),
          ],
        if (!parameterTask)
          (plan, catalog, context) => [
            const PlanIssue('plan_not_requested', '当前请求不应生成训练计划'),
          ],
        if (adjustsDuration && oldDuration != null)
          (plan, catalog, context) => [
            if ((shortensPlan && plan.targetMinutes >= oldDuration) ||
                (lengthensPlan && plan.targetMinutes <= oldDuration))
              PlanIssue(
                IssueCodes.contextConflict,
                '调整后的训练时长与用户要求不符',
                path: 'targetMinutes',
                expected: '${shortensPlan ? '少于' : '多于'} $oldDuration 分钟',
                actual: '${plan.targetMinutes} 分钟',
              ),
            if (oldPlanSeconds != null &&
                ((shortensPlan &&
                        const PlanDuration().estimateSeconds(plan, catalog) >=
                            oldPlanSeconds) ||
                    (lengthensPlan &&
                        const PlanDuration().estimateSeconds(plan, catalog) <=
                            oldPlanSeconds)))
              const PlanIssue(
                IssueCodes.contextConflict,
                '调整后的实际训练时长未按要求变化',
                path: 'blocks',
              ),
          ],
      ],
      enforceDrillDoseRange: enforceDrillDoseRange,
    );
    // 记忆开关、系统提示、工具、文件系统在每次调模型前按当前开关重建（运行时可切）。
    var memoryOn = memoryAllowed();
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
      final recorded = jsonEncode({
        for (final entry in _sessionState.params.entries)
          entry.key: entry.value.toJson(),
      });
      final training =
          (redFlag
              ? '# 安全优先\n本次或先前提到的严重症状尚未明确纠正，'
                    '不要推荐或生成训练，建议停止训练并咨询专业医疗人员。'
              : adjustsDuration && oldDuration != null
              ? '# 本次训练调整\n'
                    '当前已确认条件：${jsonEncode(context.toJson())}\n'
                    '用户要求${shortensPlan ? '短' : '长'}一点，目标时长必须${shortensPlan ? '小于' : '大于'}$oldDuration分钟；'
                    '按方向调整实际训练量，${shortensPlan ? '减少' : '增加'}实际估时，不因标注时长与估时偏差重问或拒绝。'
                    '沿用未修改的场景、器械和安全条件，不重新追问。'
              : parameters.prompt(
                      profile,
                      clarificationFinished:
                          questionsAsked >= maxQuestionsPerTask,
                    ) +
                    (carryRelativeDurationPolicy
                        ? '\n上一方案时长来自相对调整；沿用其目标时长，不将目标与估时的25%偏差作为拒绝条件。'
                        : ''));
      return prompts.system(
        profile,
        fs,
        memory: memoryOn,
        memorySummary: summary,
        userText: text,
        questionsAsked: questionsAsked,
        trainingParameters:
            '$training\n当前结构化会话条件：$recorded。host 为 App 已确认条件，不重复询问。',
      );
    }

    var system = '';
    // 每次异步加载之后复查当前开关：加载期间被切换就按当前状态重建，直到稳定（或本轮作废）。
    Future<void> rebuild() async {
      do {
        memoryOn = memoryAllowed();
        fs = memoryOn
            ? files(cat)
            : SkillFiles.build(profile, cat, memory: false);
        system = await systemNow();
      } while (memoryOn != memoryAllowed() && !dead());
    }

    await rebuild();
    final meta = (
      version: prompts.version(profile),
      hash: prompts.hash(system),
      catalog: cat.version,
    );
    final userMsg = LlmMessage.user(
      prompts.userMessage(
        profile,
        cat,
        context,
        retry && text != originalText ? '重试：$text' : text,
      ),
    );
    final turnMsgs = <LlmMessage>[];
    // 与记忆相关的工具结果（读 user-memory/ 文件、remember / forget）：关闭记忆后在后续请求里替换。
    final memResultIds = <String>{};
    final memoryReasoning = <LlmMessage>{};
    LlmMessage assistant(
      LlmResponse response, {
      String? content,
      List<LlmToolCall>? toolCalls,
      bool history = false,
    }) {
      final msg = LlmMessage.assistant(
        content ?? response.content,
        toolCalls: toolCalls ?? response.toolCalls,
        // Worker 的不同上游可能在无推理正文时返回 null / 不返回字段。
        // 后续思考模型仍要求字段存在，显式空串不会编造任何推理内容。
        reasoning: memoryOn && !memoryAllowed() ? '' : response.reasoning ?? '',
      );
      if (memoryOn && memoryAllowed()) {
        (history ? _memoryReasoning : memoryReasoning).add(msg);
      }
      return msg;
    }

    final calls = <_Call>[];
    final reads = <String>[];
    final readSet = <String>{};
    var submissions = 0;
    var attemptedOutput = false;
    var rejected = 0;
    List<PlanIssue> lastErrors = const [];
    FallbackReason reason = FallbackReason.invalidOutput;
    Object? error;
    var leaked = false;
    // 上下文压缩：可压缩的 read / ls 结果；防空转状态。
    // 按具体 tool 消息（对象身份）关联，避免跨步骤复用同一 tool_call_id 时元数据错配。
    final compressible =
        LinkedHashMap<LlmMessage, CompressibleResult>.identity();
    final listed = <String>{};
    String? lastSig;
    var repeat = 0, idle = 0;
    var warned = false;

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
      AskUserQuestion? question,
      List<PlanIssue> warnings = const [],
      void Function()? commit,
      bool Function()? commitValid,
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
        question: question,
        warnings: warnings,
        issues: status == TurnStatus.ok ? const [] : lastErrors,
        reason: reason,
        error: status == TurnStatus.ok ? null : error,
        isPlanningFailure: parameterTask && status == TurnStatus.error,
        leaked: leaked,
        submissions: submissions,
        steps: step,
        reads: reads,
        dead: () => dead() || (commitValid != null && !commitValid()),
        commit:
            (commit == null &&
                !(parameterTask &&
                    (typedConfirmed != null ||
                        (_pendingConfirmation != null && !startsNewPlan) ||
                        (startsNewPlan &&
                            (parameters.missing.isEmpty ||
                                parameters.skipped)))))
            ? null
            : () {
                if (startsNewPlan &&
                    (commit != null ||
                        parameters.missing.isEmpty ||
                        parameters.skipped)) {
                  _questionsAsked = 0;
                  _parameterTask = false;
                  _planParameterMessages.clear();
                  _confirmedPlanContext = null;
                  _lastConfirmedForm = null;
                  _lastAdmittedPlanSeconds = null;
                  _relativeDurationPolicy = false;
                  _pendingAdjustment = null;
                  _planFocus = focus ?? goal;
                  _planGoal = goal;
                }
                commit?.call();
                if (dead() || (commitValid != null && !commitValid())) return;
                if (plan != null) {
                  _relativeDurationPolicy =
                      adjustsDuration ||
                      (!startsNewPlan &&
                          typedConfirmed == null &&
                          answerFacts.context.minutes == null &&
                          _relativeDurationPolicy);
                  _lastAdmittedPlanSeconds = const PlanDuration()
                      .estimateSeconds(plan.plan, cat);
                  _pendingAdjustment = null;
                }
                if (parameterTask) {
                  _planParameterMessages.add(requestedText);
                  _taskSafetyContext = cleanContext;
                }
                if (question == null &&
                    parameterTask &&
                    (typedConfirmed != null ||
                        (_pendingConfirmation != null && !startsNewPlan) ||
                        (startsNewPlan &&
                            (parameters.missing.isEmpty ||
                                parameters.skipped)))) {
                  _confirmedPlanContext = context;
                  _lastConfirmedForm = trainingSelections(context, cat);
                }
              },
        beforeCommit: question == null
            ? null
            : () =>
                  emit(AgentEventKind.askUser, step: step, question: question),
      );
      if (!dead() && redFlag && r.status != TurnStatus.cancelled) {
        _safetyBlocked = true;
      }
      if (!dead() && correctsRedFlag && r.status != TurnStatus.cancelled) {
        _safetyBlocked = false;
      }
      if (!dead() && changesCurrent && r.status == TurnStatus.error) {
        _pendingAdjustment = requestedText;
      }
      if (!dead()) _planningFailure = r.isPlanningFailure;
      emit(AgentEventKind.done, step: step, status: r.status);
      return r;
    }

    var step = 0;
    agentSteps:
    while (step < maxSteps) {
      step++;
      emit(AgentEventKind.thinking, step: step);
      if (step > 1 || memoryOn != memoryAllowed()) await rebuild();
      // 记忆加载等异步之后、实际调模型之前复查世代与取消。
      if (dead()) return cancelled(step - 1);
      var memOff = !memoryOn;
      var tools = <LlmTool>[];
      var fixedTokens = 0;
      // 按当前 memoryOn 生成工具与固定开销。
      void prepare() {
        memOff = !memoryOn;
        tools = AgentTools.build(
          profile,
          cat,
          memory: memoryOn,
          sessionState: _sessionState,
          includeCheckPlan: true,
        );
        fixedTokens =
            estimateTokens(system) +
            estimateTokens(jsonEncode([for (final t in tools) t.toJson()])) +
            _history.fold<int>(0, (n, m) => n + estimateMessageTokens(m)) +
            estimateMessageTokens(userMsg);
      }

      prepare();
      void compress({bool force = false}) {
        final freed = compressContext(
          turnMsgs,
          fixedTokens: fixedTokens,
          budget: contextBudgetTokens,
          keepRecent: force ? 1 : keepRecentSteps,
          compressible: compressible,
          force: force,
        );
        // 压掉的文件允许再读全文。
        readSet.removeAll(freed);
      }

      // 只重试这一步：已完成的步骤、读过的文件都保留。
      LlmResponse? res;
      var tag = 0; // 本步第几次请求 - 1（记账 retry）
      var retries = 0;
      var forced = false;
      var slowSent = false;
      LlmException? failure;
      while (true) {
        if (dead()) return cancelled(step);
        // 每次实际请求前复查记忆开关（退避期间或在途失败前可能被关闭），必要时重建 system / tools / files。
        if (memoryOn != memoryAllowed()) {
          await rebuild();
          if (dead()) return cancelled(step);
          prepare();
        }
        final left = turnTimeout - turnWatch.elapsed;
        if (left <= Duration.zero) {
          error = AgentRequestFailed(
            AgentFailureKind.turnTimeout,
            errorClass: failure == null ? null : RequestErrorClass.of(failure),
            attempts: tag,
            cause: failure,
          );
          reason = FallbackReason.timeout;
          break;
        }
        compress();
        final req = LlmRequest(
          messages: [
            LlmMessage.system(system),
            ...(memOff
                ? _withoutMemory(
                    _history,
                    const {},
                    privateReasoning: _memoryReasoning,
                  )
                : _history),
            userMsg,
            ...(memOff
                ? _withoutMemory(
                    turnMsgs,
                    memResultIds,
                    privateReasoning: memoryReasoning,
                  )
                : turnMsgs),
          ],
          tools: tools,
          toolChoice: 'auto',
        );
        final turnLimited = left < requestTimeout;
        final child = CancelToken();
        var timedOut = false;
        final timer = Timer(turnLimited ? left : requestTimeout, () {
          timedOut = true;
          child.cancel('timeout');
        });
        final slowTimer = slowSent
            ? null
            : Timer(slowAfter, () {
                slowSent = true;
                emit(AgentEventKind.slow, step: step);
              });
        unawaited(
          cancel?.whenCancelled.then(
            (_) => child.cancel(cancel.reason ?? 'cancelled'),
          ),
        );
        unawaited(resetSig.future.then((_) => child.cancel('reset')));
        final sw = Stopwatch()..start();
        try {
          final f = client.complete(req, cancel: child)..ignore();
          res = await Future.any<LlmResponse>([
            f,
            child.whenCancelled.then<LlmResponse>(
              (_) => throw const _Aborted(),
            ),
          ]);
          break;
        } on Object catch (e) {
          if (dead() ||
              (e is LlmException &&
                  e.kind == LlmErrorKind.cancelled &&
                  !timedOut)) {
            calls.add(
              _Call.failed(
                step,
                e is LlmException
                    ? e
                    : LlmException(
                        LlmErrorKind.cancelled,
                        'cancelled',
                        latency: sw.elapsed,
                      ),
                retry: tag,
              ),
            );
            return cancelled(step);
          }
          final le = timedOut
              ? LlmException(
                  LlmErrorKind.timeout,
                  '超过 ${(turnLimited ? left : requestTimeout).inSeconds}s 未响应',
                  latency: sw.elapsed,
                )
              : e is LlmException
              ? e
              : LlmException(
                  LlmErrorKind.badResponse,
                  '$e',
                  latency: sw.elapsed,
                );
          calls.add(_Call.failed(step, le, retry: tag));
          failure = le;
          tag++;
          final cls = e is LlmException || timedOut
              ? RequestErrorClass.of(le)
              : RequestErrorClass.other;
          AgentFailureKind? fail;
          var delay = Duration.zero;
          if (timedOut && turnLimited) {
            fail = AgentFailureKind.turnTimeout;
          } else if (cls == RequestErrorClass.contextTooLong && !forced) {
            // 上下文超长：强制压一次再重试一次（不计入重试次数）。
            forced = true;
            compress(force: true);
            emit(
              AgentEventKind.retrying,
              step: step,
              attempt: 1,
              maxAttempts: 1,
              reason: cls,
              delay: delay,
            );
            continue;
          } else if (!cls.retryable) {
            fail = AgentFailureKind.nonRetryable;
          } else if (retries >= maxRequestRetries) {
            fail = AgentFailureKind.retriesExhausted;
          } else {
            retries++;
            delay = retryDelay(
              retries,
              base: retryBaseDelay,
              max: retryMaxDelay,
              retryAfter: le.retryAfter,
              random: _random,
            );
            if (delay >= turnTimeout - turnWatch.elapsed) {
              fail = AgentFailureKind.turnTimeout;
            }
          }
          if (fail != null) {
            error = AgentRequestFailed(
              fail,
              errorClass: cls,
              attempts: tag,
              cause: e is LlmException || timedOut ? le : e,
            );
            reason = fail == AgentFailureKind.turnTimeout
                ? FallbackReason.timeout
                : cls == RequestErrorClass.other
                ? FallbackReason.server
                : _reasonFor(le.kind);
            break;
          }
          emit(
            AgentEventKind.retrying,
            step: step,
            attempt: retries,
            maxAttempts: maxRequestRetries,
            reason: cls,
            delay: delay,
          );
          // 同步监听器可能在 retrying 里直接 cancel / reset：先复查再退避。
          if (dead()) return cancelled(step);
          // 退避可被取消 / reset 立即打断；打断后不回写。
          await Future.any<void>([
            _sleep(delay),
            ?cancel?.whenCancelled,
            resetSig.future,
          ]);
          if (dead()) return cancelled(step);
        } finally {
          timer.cancel();
          slowTimer?.cancel();
        }
      }
      if (res == null) break;
      final response = res;
      if (dead()) {
        calls.add(_Call.ok(step, res, CallOutcome.cancelled, retry: tag));
        return cancelled(step);
      }

      // 纯文字：结束本轮（过门禁：非空、无暗号）。
      if (res.toolCalls.isEmpty) {
        submissions++;
        final g = gate.check(res.content, const [], context: context);
        if (g.leaked) {
          calls.add(
            _Call.ok(
              step,
              res,
              retry: tag,
              CallOutcome.rejected,
              codes: const ['canary_leak'],
            ),
          );
          leaked = true;
          break;
        }
        if (g.ok &&
            parameterTask &&
            !RegExp(
              r'无法|不能|不建议|不适合|请就医|建议就医|咨询医生|联系医生|求医|cannot|unable',
              caseSensitive: false,
            ).hasMatch(g.text)) {
          lastErrors = const [PlanIssue('missing_plan', '训练计划未生成')];
          error = StateError('Plan was not generated');
          calls.add(
            _Call.ok(
              step,
              res,
              CallOutcome.rejected,
              codes: const ['missing_plan'],
            ),
          );
          break;
        }
        if (g.ok) {
          calls.add(
            _Call.ok(
              step,
              res,
              retry: tag,
              rejected == 0 ? CallOutcome.passed : CallOutcome.rewritten,
            ),
          );
          return done(
            TurnStatus.ok,
            rejected == 0 ? TurnOutcome.model : TurnOutcome.rewritten,
            step,
            text: g.text,
            commit: () {
              _turns++;
              _history
                ..add(userMsg)
                ..add(assistant(response, content: g.text, history: true));
            },
          );
        }
        calls.add(
          _Call.ok(
            step,
            response,
            retry: tag,
            CallOutcome.rejected,
            codes: [for (final e in g.errors) e.code],
          ),
        );
        lastErrors = g.errors;
        if (++rejected > maxResubmits) break;
        turnMsgs
          ..add(assistant(res))
          ..add(
            LlmMessage.user(
              _feedback(g.errors, remaining: 1 + maxResubmits - rejected),
            ),
          );
        continue;
      }

      // 执行任何工具之前统一查暗号（正文、工具名、解码后的全部参数字符串）：命中整轮回落，不提交记忆。
      if (gate.leaks(res.content, res.toolCalls)) {
        calls.add(
          _Call.ok(
            step,
            res,
            retry: tag,
            CallOutcome.rejected,
            codes: const ['canary_leak'],
          ),
        );
        leaked = true;
        break;
      }

      // Execute the batch in order; a failed call blocks every later call.
      final batch = ToolBatch();
      final structured = StructuredToolHandler(profile, cat,
          newPlanId: () => _ids.next('plan'), extraRules: extraRules,
          enforceDrillDoseRange: enforceDrillDoseRange);
      final skills = SkillToolHandler(fs, readSet, reads, listed);
      final terminal = TerminalToolHandler(gate);
      final results = batch.results;
      final orderedResults = <String>[];
      final callIds = <String>{};
      final pendingCompress = <String, CompressibleResult>{};
      AgentOutputResult? terminalOutput;
      AskUserQuestion? terminalQuestion;
      bool terminalRejected = false;
      var fresh = false;
      for (var toolIndex = 0; toolIndex < res.toolCalls.length; toolIndex++) {
        final t = res.toolCalls[toolIndex];
        if (batch.failed) {
          batch.skipped(t.id);
          orderedResults.add(results[t.id]!);
          continue;
        }
        if (!callIds.add(t.id)) {
          orderedResults.add(jsonEncode(nodeError('duplicate_tool_call_id', 'tool_calls[$toolIndex].id',
              '每个 tool_call_id 唯一', t.id, '为每个工具调用提供不同的 ID。')));
          batch.mark(toolIndex + 1, t.id, failure: true);
          continue;
        }
        // Host settings may change while the model request is in flight.
        context = ledgerContext(context);
        bool? toolFailure;
        switch (t.name) {
          case AgentTools.draftPlan:
            final handled = structured.draft(_sessionState, t.arguments, context.language);
            _sessionState = handled.state;
            if (handled.changes.isNotEmpty) {
              _emitNodeChanges(turnId, NodeResult(handled.state, changes: handled.changes));
            }
            fresh = fresh || handled.fresh;
            results[t.id] = handled.response;
          case AgentTools.searchActions || AgentTools.getAction:
            final handled = structured.search(_sessionState, t.name, t.arguments, context.language);
            _sessionState = handled.state;
            fresh = fresh || handled.fresh;
            for (final id in handled.accessed) {
              if (readSet.add('get_action:$id')) fresh = true;
            }
            results[t.id] = handled.response;
          case AgentTools.startTask || AgentTools.check:
            final handled = structured.task(_sessionState, t.name, t.arguments, context.language);
            _sessionState = handled.state;
            if (handled.changes.isNotEmpty) {
              _emitNodeChanges(turnId, NodeResult(handled.state, changes: handled.changes));
            }
            fresh = fresh || handled.fresh;
            results[t.id] = handled.response;
          case AgentTools.setParams:
            Object? args;
            try {
              args = jsonDecode(t.arguments);
            } on FormatException {
              results[t.id] = jsonEncode(nodeError('invalid_json', 'arguments',
                  '合法 JSON 对象', '无效 JSON', '提供包含 fields 的合法 JSON 对象。'));
              break;
            }
            List<MemoryEntry> savedMemory = const [];
            if (memoryOn && memoryAllowed()) {
              try { savedMemory = await memory(); } on Object { savedMemory = const []; }
            }
            if (dead()) return cancelled(step);
            if (!memoryAllowed()) savedMemory = const [];
            final handled = structured.setParams(_sessionState, args, context.language, savedMemory);
            _sessionState = handled.state;
            context = ledgerContext(context);
            if (handled.changes.isNotEmpty) {
              _emitNodeChanges(turnId, NodeResult(handled.state, changes: handled.changes));
            }
            if (handled.fresh) {
              fresh = true;
              _pendingConfirmation = null;
            }
            results[t.id] = handled.response;
          case AgentTools.read || AgentTools.ls:
            final read = t.name == AgentTools.read;
            final path = SkillFiles.normalize(_arg(t, read ? 'path' : 'dir') ?? '');
            if (!skills.blocked(path, read: read, hasTask: _sessionState.task != null)) {
              emit(read ? AgentEventKind.reading : AgentEventKind.listing, step: step, path: path);
              if (dead()) return cancelled(step);
              if (read && path.startsWith('${SkillFiles.userMemory}/')) memResultIds.add(t.id);
            }
            final handled = skills.execute(t.id, path, read: read, hasTask: _sessionState.task != null);
            results[t.id] = handled.response;
            toolFailure = handled.failed;
            fresh = fresh || handled.fresh;
            if (handled.compressible != null) pendingCompress[t.id] = handled.compressible!;
          case AgentTools.checkPlan:
            emit(AgentEventKind.checking, step: step);
            if (dead()) return cancelled(step);
            final handled = structured.checkPlan(_sessionState, t.arguments);
            _sessionState = handled.state;
            if (handled.changes.isNotEmpty) {
              _emitNodeChanges(turnId, NodeResult(handled.state, changes: handled.changes));
            }
            fresh = fresh || handled.fresh;
            results[t.id] = handled.response;
          case AgentTools.remember || AgentTools.forget when memoryOn:
            final kindName = _arg(t, 'kind');
            final memoryEpoch = turnMemoryEpoch;
            emit(AgentEventKind.memory, step: step, path: kindName);
            if (dead()) return cancelled(step);
            memResultIds.add(t.id);
            fresh = true;
            var memoryTimedOut = false;
            final pending = _memoryOp(
              t,
              valid: () =>
                  !dead() &&
                  !memoryTimedOut &&
                  enableUserMemory &&
                  memoryEpoch == _memEpoch,
              epoch: memoryEpoch,
            );
            results[t.id] =
                await Future.any<String>([
                  pending,
                  if (cancel != null)
                    cancel.whenCancelled.then((_) => _memoryError('cancelled')),
                  resetSig.future.then((_) => _memoryError('cancelled')),
                ]).timeout(
                  turnTimeout - turnWatch.elapsed,
                  onTimeout: () {
                    memoryTimedOut = true;
                    return _memoryError('timeout');
                  },
                );
            if (dead()) {
              calls.add(_Call.ok(step, res, CallOutcome.cancelled, retry: tag));
              return cancelled(step);
            }
            if (memoryTimedOut) {
              calls.add(_Call.ok(step, res, CallOutcome.toolStep, retry: tag));
              error = AgentRequestFailed(
                AgentFailureKind.turnTimeout,
                errorClass: RequestErrorClass.timeout,
                attempts: tag + 1,
              );
              reason = FallbackReason.timeout;
              break agentSteps;
            }
          case AgentTools.askUser:
            final handled = terminal.ask(t.arguments, toolIndex + 1, res.toolCalls.length);
            terminalRejected = handled.rejected;
            terminalQuestion = handled.question;
            results[t.id] = handled.response;
          case AgentTools.showActions || AgentTools.showPlan:
            attemptedOutput = true;
            final handled = terminal.show(_sessionState, t.name, t.arguments,
                language: context.language, redFlag: redFlag);
            terminalRejected = handled.rejected;
            terminalOutput = handled.output;
            results[t.id] = handled.response;
          default:
            results[t.id] = jsonEncode(nodeError('unknown_tool', 'tool', '已提供的工具', t.name, '使用当前工具列表中的名称。'));
        }
        if (dead()) return cancelled(step);
        batch.mark(toolIndex + 1, t.id, failure: toolFailure);
        orderedResults.add(results[t.id]!);
        if (terminalOutput != null) {
          for (var later = toolIndex + 1; later < res.toolCalls.length; later++) {
            batch.skippedAfterCompletion(res.toolCalls[later].id, toolIndex + 1);
            orderedResults.add(results[res.toolCalls[later].id]!);
          }
          break;
        }
      }
      if (leaked) {
        calls.add(
          _Call.ok(
            step,
            res,
            retry: tag,
            CallOutcome.rejected,
            codes: const ['canary_leak'],
          ),
        );
        break;
      }

      if (terminalQuestion != null) {
        submissions++;
        final question = terminalQuestion;
        calls.add(_Call.ok(step, res,
          rejected == 0 ? CallOutcome.passed : CallOutcome.rewritten, retry: tag));
        return done(
          TurnStatus.ok,
          rejected == 0 ? TurnOutcome.model : TurnOutcome.rewritten,
          step,
          text: question.question,
          question: question,
          commit: () => _commitAsk(
            question: question,
            questionsAsked: questionsAsked,
            parameterTask: parameterTask,
            userMessage: userMsg,
            turnMessages: turnMsgs,
            assistantMessage: assistant(response, content: question.question, history: true),
            calls: response.toolCalls,
            results: orderedResults,
            memoryResultIds: memResultIds,
            privateReasoning: memoryReasoning,
          ),
        );
      }

      if (terminalOutput == null) {
        if (terminalRejected) {
          submissions++;
          final detail = jsonDecode(orderedResults[batch.firstFailure! - 1]) as Map;
          lastErrors = [PlanIssue('${detail['code']}', '${detail['fix']}')];
          calls.add(_Call.ok(step, res, retry: tag,
              CallOutcome.rejected, codes: [for (final issue in lastErrors) issue.code]));
          if (++rejected > maxResubmits) {
            break;
          }
        } else {
          calls.add(_Call.ok(step, res, retry: tag, CallOutcome.toolStep));
        }
        turnMsgs.add(assistant(res));
        for (var i = 0; i < res.toolCalls.length; i++) {
          final t = res.toolCalls[i];
          final m = LlmMessage.tool(t.id, orderedResults[i]);
          turnMsgs.add(m);
          final c = res.toolCalls.indexWhere((call) => call.id == t.id) == i
              ? pendingCompress[t.id] : null;
          if (c != null) compressible[m] = c;
        }
        // 防空转：连续相同的工具调用（同名同参数）或连续无新信息。
        final sig = [
          for (final t in res.toolCalls) '${t.name}\u0000${t.arguments}',
        ].join('\u0001');
        repeat = sig == lastSig ? repeat + 1 : 1;
        lastSig = sig;
        idle = fresh ? 0 : idle + 1;
        if (warned
            ? (repeat >= 2 || idle >= 1)
            : (repeat >= maxStallSteps || idle >= maxStallSteps)) {
          if (warned) {
            error = AgentStalled(
              repeat >= 2 ? 'repeated_tool_call' : 'no_new_info',
            );
            reason = FallbackReason.invalidOutput;
            break;
          }
          warned = true;
          idle = 0;
          turnMsgs.add(
            LlmMessage.user(
              repeat >= maxStallSteps
                  ? '（系统提示）你已连续 $repeat 次发出完全相同的工具调用，结果不会变。请换个做法，或直接用已有信息交付。'
                  : '（系统提示）最近几步没有获得新信息。请直接用已读到的信息交付，或换个明确的文件路径。',
            ),
          );
        }
        continue;
      }

      submissions++;
      final output = terminalOutput;
      final g = output.card!;
      if (g.ok) {
        var admittedTask = _sessionState.task;
        final admittedSafetyRevision = _hostSafetyRevision;
        calls.add(
          _Call.ok(
            step,
            res,
            retry: tag,
            rejected == 0 ? CallOutcome.passed : CallOutcome.rewritten,
          ),
        );
        return done(
          TurnStatus.ok,
          rejected == 0 ? TurnOutcome.model : TurnOutcome.rewritten,
          step,
          text: g.text,
          plan: g.plan,
          actions: g.actions,
          warnings: g.warnings,
          commitValid: () =>
              identical(_sessionState.task, admittedTask) &&
              _hostSafetyRevision == admittedSafetyRevision,
          commit: () => _commitOutput(
            output: output,
            card: g,
            safetyRevision: admittedSafetyRevision,
            turnId: turnId,
            context: context,
            catalog: cat,
            dead: dead,
            updateAdmittedTask: (task) => admittedTask = task,
            userMessage: userMsg,
            visibleAssistant: () => assistant(response, content: g.text,
                toolCalls: const [], history: true),
          ),
        );
      }
      calls.add(
        _Call.ok(
          step,
          res,
          retry: tag,
          CallOutcome.rejected,
          codes: [for (final e in g.errors) e.code],
        ),
      );
      lastErrors = g.errors;
      if (++rejected > maxResubmits) break;
      turnMsgs.add(assistant(res));
      for (var i = 0; i < res.toolCalls.length; i++) {
        final t = res.toolCalls[i];
        final m = LlmMessage.tool(t.id, orderedResults[i]);
        turnMsgs.add(m);
        final c = res.toolCalls.indexWhere((call) => call.id == t.id) == i
            ? pendingCompress[t.id] : null;
        if (c != null) compressible[m] = c;
      }
    }
    if (step >= maxSteps &&
        error == null &&
        !leaked &&
        rejected <= maxResubmits) {
      reason = FallbackReason.invalidOutput;
      error = AgentStepLimitExceeded(maxSteps);
    }

    // 回落：绝不渲染未通过的内容。
    if (dead()) {
      return cancelled(step);
    }
    // A failed planning task must not silently invoke a preset. The host may
    // present an explicit, separately validated preset action instead.
    if (parameterTask || redFlag || _sessionState.task != null || attemptedOutput) {
      return done(TurnStatus.error, TurnOutcome.error, step);
    }
    final fbFn = fallback;
    if (fbFn == null) return done(TurnStatus.error, TurnOutcome.error, step);
    try {
      final r = await fbFn(
        SessionFallbackRequest(
          userText: text,
          context: context,
          reason: reason,
          issues: lastErrors,
          error: error,
        ),
      );
      if (dead()) {
        return await cancelled(step);
      }
      final plan = r.plan == null ? null : gate.admitTemplate(r.plan!, context);
      if (r.plan != null && plan == null) {
        error = StateError('Fallback plan did not pass admission');
        return await done(TurnStatus.error, TurnOutcome.error, step);
      }
      return await done(
        TurnStatus.fallback,
        TurnOutcome.fallback,
        step,
        text: r.text,
        plan: plan,
        commit: () {
          if (plan != null) {
            _questionsAsked = 0;
            _parameterTask = false;
          }
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
      return await done(TurnStatus.error, TurnOutcome.error, step);
    }
  }

  // ---- 工具执行 ----

  static String _planSummary(TrainingPlan plan, Catalog catalog) {
    final used = <String>{
      for (final item in plan.items)
        for (final id
            in item.segments.isEmpty
                ? [item.exerciseId]
                : item.segments.map((segment) => segment.exerciseId))
          ...?catalog[id]?.equipment,
    }..remove('none');
    final gear = used.isEmpty
        ? '徒手'
        : used.map(catalog.taxonomy.equipmentLabel).join('、');
    return '已按${plan.targetMinutes}分钟安排，器械：$gear。';
  }

  static String? _arg(LlmToolCall t, String key) {
    try {
      final m = jsonDecode(t.arguments);
      if (m is Map && m[key] is String) return m[key] as String;
    } on FormatException {
      // 参数坏了按缺失处理。
    }
    return null;
  }

  /// show_* 被打回时回给模型的结果（改法换成 Agent 口径：id 来自读到的文件）。
  static String _feedback(List<PlanIssue> errors, {required int remaining}) =>
      jsonEncode({
        'ok': false,
        'remainingAttempts': remaining,
        'errors': [for (final e in errors) _issueJson(e)],
        'instruction': '逐条改完后重新提交（可先 check_plan）；不要向用户解释这些错误。',
      });

  static Map<String, Object?> _issueJson(PlanIssue e) {
    final j = ToolGate.issueJson(e);
    final fix = switch (e.code) {
      IssueCodes.unknownExercise ||
      IssueCodes.outOfProfile => '换成你在 action-library 索引里读到的 id，逐字拷贝',
      IssueCodes.modeMismatch =>
        '按 details 里的默认剂量：mode=reps 填 reps；mode=time 填 workSeconds',
      IssueCodes.avoid => '换成 details 里注意部位不含该部位的动作，或删掉这一项',
      IssueCodes.unknownTool => '只用已提供的工具',
      IssueCodes.multipleTools => '一次回复只调用一个 show_* 工具',
      _ => null,
    };
    if (fix != null && e.fix == null) j['fix'] = fix;
    return j;
  }

  static int _chars(LlmMessage m) =>
      m.content.length +
      (m.reasoning?.length ?? 0) +
      m.toolCalls.fold(0, (n, t) => n + t.arguments.length);

  static FallbackReason _reasonFor(LlmErrorKind k) => switch (k) {
    LlmErrorKind.network => FallbackReason.offline,
    LlmErrorKind.timeout => FallbackReason.timeout,
    LlmErrorKind.rateLimited => FallbackReason.rateLimited,
    LlmErrorKind.auth => FallbackReason.auth,
    LlmErrorKind.truncated => FallbackReason.truncated,
    LlmErrorKind.http ||
    LlmErrorKind.badResponse ||
    LlmErrorKind.cancelled => FallbackReason.server,
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
          retry: c.retry,
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
    AskUserQuestion? question,
    List<PlanIssue> warnings = const [],
    List<PlanIssue> issues = const [],
    FallbackReason? reason,
    Object? error,
    bool isPlanningFailure = false,
    bool leaked = false,
    int submissions = 0,
    int steps = 0,
    List<String> reads = const [],
    required bool Function() dead,
    void Function()? commit,
    void Function()? beforeCommit,
  }) async {
    final records = await _record(turnId, meta, calls, outcome);
    // 记账是最后一个异步边界：其间 reset / 取消则本轮作废，不写历史 / 轮数 / 记忆。
    if (!dead()) beforeCommit?.call();
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
    return CoachTurnResult(
      turnId: turnId,
      status: status,
      text: text,
      plan: plan,
      actions: actions,
      question: question,
      warnings: warnings,
      issues: issues,
      submissions: submissions,
      fallbackReason:
          status == TurnStatus.fallback || status == TurnStatus.error
          ? reason
          : null,
      leaked: leaked,
      error: error,
      isPlanningFailure: isPlanningFailure,
      records: records,
      steps: steps,
      reads: List.unmodifiable(reads),
    );
  }
}

class _Call {
  _Call.ok(
    this.attempt,
    LlmResponse r,
    this.outcome, {
    this.codes = const [],
    this.retry = 0,
  }) : usage = r.usage,
       latency = r.latency,
       httpAttempts = r.httpAttempts,
       model = r.model,
       finishReason = r.finishReason,
       error = null;

  _Call.failed(this.attempt, LlmException e, {this.retry = 0})
    : usage = e.usage,
      latency = e.latency,
      httpAttempts = e.httpAttempts,
      model = null,
      finishReason =
          e.finishReason ??
          (e.kind == LlmErrorKind.truncated ? 'length' : null),
      outcome = e.kind == LlmErrorKind.cancelled
          ? CallOutcome.cancelled
          : CallOutcome.error,
      codes = const [],
      error = e;

  final int attempt;
  final int retry;
  final TokenUsage usage;
  final Duration latency;
  final int httpAttempts;
  final String? model;
  final String? finishReason;
  final CallOutcome outcome;
  final List<String> codes;
  final LlmException? error;
}

class _Aborted implements Exception {
  const _Aborted();
}
