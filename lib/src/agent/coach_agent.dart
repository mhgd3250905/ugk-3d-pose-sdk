/// Agent 版会话（0.3 推荐入口）：渐进式披露 + Pi 式工具循环。
///
/// 每轮：调模型 → 执行全部工具调用（read / ls / check_plan / remember / forget），结果追加 → 再调 →
/// 直到纯文字或 ask_user / show_actions / show_plan 通过门禁。最终工具不过门禁就把错误作为工具结果回给模型重交
/// （最多 [CoachAgent.maxResubmits] 次）。步数超过 [CoachAgent.maxSteps]、请求重试用尽 / 不可重试、整轮超时、
/// 空转、暗号泄露 → 回落 App 模板。单步请求失败只重试那一步（指数退避 + 抖动，可被取消 / reset 打断）；
/// 模型历史只追加，动态状态置于末尾；超过字节软阈值才整轮折叠已结束的对话。
/// 硬上限仅归档已成功消费的工具回执，不改保留消息的推理。见 docs/coach-agent-context-append-fold.md。
///
/// 对外与 [CoachSession] 同风格：[CoachAgent.send] / [CoachAgent.reset] / 取消、busy、reset 或取消后不回写；
/// 结果同为 [CoachTurnResult]，卡片只接受门禁产出的 [ValidatedPlan] / [ValidatedActions]。
/// 过程事件见 [CoachAgent.events]。0.2 的 [CoachSession] 保留作降级。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;

import '../assistant/fallback.dart';
import '../catalog/catalog.dart';
import '../llm/cancel_token.dart';
import '../llm/llm_client.dart';
import '../llm/llm_types.dart';
import '../llm/openai_compatible_client.dart';
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
import 'append_only_context.dart';
import 'batch_handler.dart';
import 'context_budget.dart';
import 'context_turn_ledger.dart';
import 'node_gates.dart';
import 'plan_checker.dart';
import 'session_params.dart';
import 'session_state.dart';
import 'skill_disclosure.dart';
import 'skill_files.dart';
import 'skill_tool_handler.dart';
import 'structured_tool_handler.dart';
import 'terminal_tool_handler.dart';

import 'tool_arguments.dart';
import 'training_confirmation.dart';
import 'user_memory.dart';

export 'agent_resilience.dart';
export 'context_budget.dart'
    show ContextBudgetConfig, ContextRequestDiagnostics;

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
    this.contextBudgetConfig = const ContextBudgetConfig(),
    this.requestSizeBytes,
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
  final ContextBudgetConfig contextBudgetConfig;
  final int Function(LlmRequest)? requestSizeBytes;

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
  final Set<LlmMessage> _contextCoveredHistory = HashSet.identity();
  AppendOnlyContext? _modelContext;
  ({
    String catalog,
    String profile,
    String language,
    bool memory,
    int memoryEpoch,
  })?
  _modelEpochKey;
  int _modelEpochCounter = 0;
  final List<ContextRequestDiagnostics> _contextRequestDiagnostics = [];
  List<ContextRequestDiagnostics> get contextRequestDiagnostics =>
      List.unmodifiable(_contextRequestDiagnostics);
  CoachSessionState _sessionState = CoachSessionState();
  int _hostSafetyRevision = 0;
  Set<String>? _latestExplicitAvoid;
  // 只追踪曾看过用户记忆的响应；记忆从未开启的工具推理必须完整回传。
  final Set<LlmMessage> _memoryReasoning = {};
  int _turns = 0;
  int _questionsAsked = 0;
  AskUserQuestion? _pendingConfirmation;
  int _confirmationDismissRevision = 0;
  CoachContext? _confirmedPlanContext;
  bool _relativeDurationPolicy = false;
  CoachContext? _taskSafetyContext;
  String? _planFocus;
  String? _planGoal;
  Map<String, List<String>>? _lastConfirmedForm;
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
    List<LlmMessage> restoredMessages = const [],
  }) {
    _modelContext = null;
    _modelEpochKey = null;
    _contextCoveredHistory.clear();
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
      final restored = SessionParams(
        ActionTags(profile, cat),
      ).applyHost(_sessionState, context);
      if (restored.ok) _sessionState = restored.state;
      for (final text in restoredUserTurns) {
        _sessionState = _sessionState.appendUserTurn(text);
      }
    }
    if (stored?.sessionState == null &&
        _sessionState.lastDeliveredPlanId == null) {
      // Snapshots predating delivered-version tracking can still use the
      // admitted card as their actual previous delivery, without pretending
      // that newer task nodes were completed.
      final versions =
          _sessionState.plans[plan.id] ?? const <CoachPlanVersion>[];
      final matching = versions
          .where((v) => jsonEncode(v.plan) == jsonEncode(plan.toJson()))
          .lastOrNull;
      final previous =
          matching ??
          CoachPlanVersion(
            version: versions.isEmpty
                ? 1
                : versions.map((v) => v.version).reduce(math.max) + 1,
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
            ? 0
            : _sessionState.userTurns.last.turn,
      );
    }
    _confirmedPlanContext = context;
    _taskSafetyContext = context;
    _planFocus = stored?.focus ?? focusHint;
    _planGoal = stored?.goal ?? goalHint;
    _lastConfirmedForm = trainingSelections(context, cat);
    _relativeDurationPolicy = stored?.relativeDurationPolicy ?? false;
    if (restoredMessages.isNotEmpty) {
      _history.addAll(restoredMessages);
    } else {
      _history.addAll(
        _sessionState.userTurns.map((turn) => LlmMessage.user(turn.text)),
      );
    }
    _history.add(
      LlmMessage.assistant('已恢复当前计划：${plan.title}（${plan.id}）', reasoning: ''),
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
    final previousLedger = _completedLedger();
    const userMessage = LlmMessage.user('用预设方案');
    final deliveredMessage = LlmMessage.assistant(text, reasoning: '');
    _sessionState = _sessionState.appendUserTurn(userMessage.content);
    final delivered = admitted.plan;
    final previousVersions =
        _sessionState.plans[delivered.id] ?? const <CoachPlanVersion>[];
    final version = previousVersions.isEmpty
        ? 1
        : previousVersions.map((v) => v.version).reduce(math.max) + 1;
    _sessionState = _sessionState.copyWith(
      clearTask: true,
      plans: {
        ..._sessionState.plans,
        delivered.id: [
          ...previousVersions,
          CoachPlanVersion(
            version: version,
            plan: delivered.toJson(),
            estimateSec: const PlanDuration().estimateSeconds(
              delivered,
              _catalog(),
            ),
            fitLog: const [],
            createdAtTurn: _sessionState.userTurns.last.turn,
          ),
        ],
      },
      activePlanId: delivered.id,
      lastDeliveredPlanId: delivered.id,
      lastDeliveredVersion: version,
      lastDeliveredTurn: _sessionState.userTurns.last.turn,
    );
    _questionsAsked = 0;
    _pendingConfirmation = null;
    _planningFailure = false;
    _relativeDurationPolicy = false;
    _turns++;
    _history
      ..add(userMessage)
      ..add(deliveredMessage);
    _contextCoveredHistory.addAll([userMessage, deliveredMessage]);
    final result = CoachTurnResult(
      turnId: _ids.next('turn'),
      status: TurnStatus.fallback,
      text: text,
      plan: admitted,
    );
    _completeContextTurn(
      result: result,
      messages: [userMessage, deliveredMessage],
      catalog: _catalog(),
      language: _confirmedPlanContext?.language ?? 'zh',
      previousLedger: previousLedger,
      pendingAtStart: null,
      confirmedForm: null,
    );
    return result;
  }

  ValidatedPlan? _admitPreset(TrainingPlan plan) {
    final task = _sessionState.task;
    if (task?.type != 'plan' || task!.nodes.last.status == 'done') {
      return null;
    }
    final catalog = _catalog();
    final checked = PlanChecker(
      profile,
      catalog,
      minPicks: profile.minActions,
      extraRules: extraRules,
      enforceDrillDoseRange: enforceDrillDoseRange,
    ).validateTemplate(_sessionState, plan);
    if (!checked.ok) return null;
    final params = _sessionState.params;
    final tags = ActionTags(profile, catalog);
    final equipment = NodeGates(
      profile,
      catalog,
      minPicks: profile.minActions,
    ).effectiveEquipment(_sessionState);
    final limits = (params['limits']?.value as List<Object?>? ?? const [])
        .cast<String>();
    final context = CoachContext(
      scene: params['scene']?.value as String?,
      equipment: {for (final code in equipment) ?tags.equipmentId(code)},
      minutes: params['minutes']?.value as int?,
      level: params['level']?.value as int?,
      avoid: {for (final code in limits) tags.limitValue(code) ?? code},
    );
    return gateFor(catalog).admitTemplate(plan, context);
  }

  int get historyChars => _history.fold(0, (n, m) => n + _chars(m));
  bool get isBusy => _busyGen == _generation;
  bool get isFull =>
      _turns + (isBusy ? 1 : 0) >= maxTurns || historyChars >= maxHistoryChars;

  /// 清空对话。进行中的旧轮作废，返回时不写历史、不改记忆。
  void reset() {
    _generation++;
    _history.clear();
    _contextCoveredHistory.clear();
    _modelContext = null;
    _modelEpochKey = null;
    _contextRequestDiagnostics.clear();
    _sessionState = CoachSessionState();
    _hostSafetyRevision++;
    _latestExplicitAvoid = null;
    _memoryReasoning.clear();
    _turns = 0;
    _questionsAsked = 0;
    _pendingConfirmation = null;
    _confirmedPlanContext = null;
    _relativeDurationPolicy = false;
    _taskSafetyContext = null;
    _planFocus = null;
    _planGoal = null;
    _lastConfirmedForm = null;
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
    _modelContext = null;
    _modelEpochKey = null;
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
    Set<String> preserveMemoryResultIds = const {},
  }) {
    bool isMem(LlmToolCall t) =>
        t.name == AgentTools.remember || t.name == AgentTools.forget;
    final dropIds = {
      for (final m in msgs)
        for (final t in m.toolCalls)
          if (isMem(t) &&
              memResultIds.contains(t.id) &&
              !preserveMemoryResultIds.contains(t.id))
            t.id,
    };
    final out = <LlmMessage>[];
    for (final m in msgs) {
      if (m.role == LlmRole.tool) {
        if (dropIds.contains(m.toolCallId)) continue;
        if (preserveMemoryResultIds.contains(m.toolCallId)) {
          out.add(m);
          continue;
        }
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

  ContextTurnLedger _completedLedger() =>
      _sessionState.completedContextLedger == null
      ? ContextTurnLedger(const [])
      : ContextTurnLedger.fromJson(_sessionState.completedContextLedger!);

  List<LlmMessage> _uncoveredHistory(ContextTurnLedger ledger) {
    if (ledger.turns.isEmpty) return List.of(_history);
    final users = <String, int>{};
    final answers = <String, int>{};
    for (final turn in ledger.turns) {
      users.update(turn.userText, (n) => n + 1, ifAbsent: () => 1);
      if (turn.finalDeliveryText.isNotEmpty) {
        answers.update(turn.finalDeliveryText, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    final uncovered = <LlmMessage>[];
    for (final message in _history) {
      final counts = message.role == LlmRole.user
          ? users
          : message.role == LlmRole.assistant && message.toolCalls.isEmpty
          ? answers
          : null;
      final matches = (counts?[message.content] ?? 0) > 0;
      if (matches) counts![message.content] = counts[message.content]! - 1;
      if (_contextCoveredHistory.contains(message) || matches) {
        _contextCoveredHistory.add(message);
      } else {
        uncovered.add(message);
      }
    }
    return uncovered;
  }

  int _encodedRequestBytes(LlmRequest request) {
    final counter = requestSizeBytes;
    if (counter != null) return counter(request);
    final current = client;
    if (current is OpenAiCompatibleClient) {
      return utf8.encode(jsonEncode(current.buildBody(request))).length;
    }
    return utf8
            .encode(
              jsonEncode({
                'model': current.model,
                'messages': [
                  for (final message in request.messages) message.toJson(),
                ],
                'tools': [for (final tool in request.tools) tool.toJson()],
                'max_tokens': request.maxTokens ?? 6000,
                'tool_choice': request.toolChoice,
                'stream': false,
              }),
            )
            .length +
        1024;
  }

  void _completeContextTurn({
    required CoachTurnResult result,
    required List<LlmMessage> messages,
    required Catalog catalog,
    required String language,
    required ContextTurnLedger previousLedger,
    required AskUserQuestion? pendingAtStart,
    required Map<String, List<String>>? confirmedForm,
  }) {
    final actualUser = _sessionState.userTurns.lastOrNull;
    if (actualUser == null) return;
    List<String> actionIds(Object? value) {
      final found = <String>{};
      void walk(Object? node) {
        if (node is Map) {
          if (node['exerciseId'] case final String id) found.add(id);
          for (final child in node.values) {
            walk(child);
          }
        } else if (node is List) {
          for (final child in node) {
            walk(child);
          }
        }
      }

      walk(value);
      return found.toList();
    }

    final currentId = _sessionState.activePlanId;
    final currentPlan = _sessionState.plans[currentId]?.lastOrNull;
    final currentRef = currentPlan == null
        ? null
        : ContextDeliveryRef(
            type: 'plan',
            planId: currentId,
            version: currentPlan.version,
            actionIds: actionIds(currentPlan.plan),
          );
    final gate = NodeGates(profile, catalog, minPicks: profile.minActions);
    final candidates = <Object?>[
      for (final id in _sessionState.seenActionIds)
        if (gate.actionProblem(_sessionState, id) == null)
          [
            id,
            catalog[id]!.name.of(language),
            gate.tags
                .forActionId(id)
                .where((tag) => tag.startsWith('body.'))
                .firstOrNull,
            catalog[id]!.defaultDose.mode == DoseMode.reps ? 'reps' : 'seconds',
          ],
    ];
    final previousQuestion = pendingAtStart == null
        ? null
        : previousLedger.turns
              .where(
                (turn) => turn.askQuestions.any(
                  (q) => jsonEncode(q) == jsonEncode(pendingAtStart.toJson()),
                ),
              )
              .lastOrNull;
    final facts = CompletedContextTurn(
      turn: actualUser.turn,
      userText: actualUser.text,
      finalDeliveryText: result.text,
      params: _sessionState.params,
      task: _sessionState.task,
      picks: _sessionState.picks,
      candidates: candidates,
      currentPlanRef: currentRef,
      seenActionIds: _sessionState.seenActionIds.toList(),
      loadedSkillNames: SkillDisclosures.fromMessages(
        messages,
      ).sources.keys.map((path) => path.replaceFirst('/SKILL.md', '')).toList(),
      deliveries: [
        if (result.plan != null)
          ContextDeliveryRef(
            type: 'plan',
            planId: result.plan!.plan.id,
            version:
                _sessionState.plans[result.plan!.plan.id]?.lastOrNull?.version,
            actionIds: actionIds(result.plan!.plan.toJson()),
          ),
        if (result.actions != null)
          ContextDeliveryRef(
            type: 'actions',
            actionIds: result.actions!.items.map((item) => item.id).toList(),
          ),
      ],
      askQuestions: [if (result.question != null) result.question!.toJson()],
      answeredAsk: previousQuestion == null
          ? null
          : ContextAskReplyRef(
              questionTurn: previousQuestion.turn,
              questionIndex: previousQuestion.askQuestions.indexWhere(
                (q) => jsonEncode(q) == jsonEncode(pendingAtStart!.toJson()),
              ),
              answerJson: confirmedForm == null
                  ? {'text': actualUser.text}
                  : {'text': actualUser.text, 'selections': confirmedForm},
            ),
      outcome: result.question != null
          ? 'awaiting_user'
          : result.status == TurnStatus.error
          ? 'error'
          : 'completed',
    );
    final turns = [
      ..._completedLedger().turns.where((turn) => turn.turn != facts.turn),
      facts,
    ];
    _sessionState = _sessionState.copyWith(
      completedContextLedger: ContextTurnLedger(turns).toJson(),
    );
    _modelContext?.finishTurn(messages: messages);
  }

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
            : NodeGates(profile, cat, minPicks: profile.minActions)
                  .parametersChanged(
                    host.state,
                    language: context.language,
                    changedFields: host.changedFields,
                    valueChangedFields: host.valueChangedFields,
                  )
                  .state;
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
            ).parametersChanged(
              host.state,
              language: context.language,
              changedFields: host.changedFields,
              valueChangedFields: host.valueChangedFields,
            );
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
    final pendingAtStart = _pendingConfirmation;
    final ledgerAtStart = _completedLedger();
    final publicHistoryStart = _history.length;
    // 清除记忆也作废本轮先前请求取得的记忆操作；下一轮才重新允许记忆。
    var turnMemoryEpoch = _memEpoch;
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

    final cat = _catalog();
    final catalogContextKey = crypto.sha256
        .convert(utf8.encode(jsonEncode(cat.raw)))
        .toString();
    final profileContextKey = crypto.sha256
        .convert(utf8.encode(jsonEncode(profile.toJson())))
        .toString();
    final pending = _pendingConfirmation;
    if (confirmedForm != null) {
      final selected = pending == null
          ? null
          : confirmedTrainingContext(pending, confirmedForm, context, cat);
      if (selected == null) {
        return CoachTurnResult(
          turnId: turnId,
          status: TurnStatus.error,
          error: const FormatException('Invalid training confirmation'),
        );
      }
      final tags = ActionTags(profile, cat);
      final defaults = text == pending!.skipLabel;
      final quote = String.fromCharCodes(text.runes.take(30));
      Map<String, Object?> field(Object value) => {
        'value': value,
        'source': defaults ? 'default' : 'user',
        if (!defaults) 'quote': quote,
      };
      final mapped = SessionParams(tags).set(_sessionState, {
        'fields': {
          'scene': field(selected.scene!),
          'equipment': field(
            defaults
                ? <String>[]
                : [
                    for (final id in selected.equipment!)
                      ?tags.equipmentCode(id),
                  ],
          ),
          'minutes': field(selected.minutes!),
        },
      });
      if (!mapped.ok) {
        return CoachTurnResult(
          turnId: turnId,
          status: TurnStatus.error,
          error: FormatException(jsonEncode(mapped.error)),
        );
      }
      final nodes = NodeGates(profile, cat, minPicks: profile.minActions)
          .parametersChanged(
            mapped.state,
            changedFields: mapped.changedFields,
            valueChangedFields: mapped.valueChangedFields,
            language: context.language,
          );
      _sessionState = nodes.state;
      if (nodes.changes.isNotEmpty) _emitNodeChanges(turnId, nodes);
    }
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
        notes: {
          ...?_taskSafetyContext?.notes,
          ...?_confirmedPlanContext?.notes,
          ...previous.notes,
        }.toList(),
      );
    }

    context = ledgerContext(context);
    final gate = gateFor(cat);
    // 记忆开关、系统提示、工具、文件系统在每次调模型前按当前开关重建（运行时可切）。
    var memoryOn = memoryAllowed();
    var forceContextRebuild = false;
    var fs = files(cat);
    Future<String> systemNow() async {
      if (_modelContext != null &&
          _modelEpochKey ==
              (
                catalog: catalogContextKey,
                profile: profileContextKey,
                language: context.language,
                memory: memoryOn,
                memoryEpoch: _memEpoch,
              )) {
        return _modelContext!.system;
      }
      var summary = '';
      if (memoryOn) {
        try {
          summary = UserMemoryOps.summary(await memory());
        } on Object {
          summary = '';
        }
      }
      return prompts.system(
        profile,
        fs,
        memory: memoryOn,
        memorySummary: summary,
        userText: text,
        locale: context.language,
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
      forceContextRebuild = false;
    }

    await rebuild();
    final meta = (
      version: prompts.version(profile),
      hash: prompts.hash(system),
      catalog: cat.version,
    );
    final userMsg = LlmMessage.user(
      prompts.userMessage(profile, cat, context, text),
    );
    final turnMsgs = <LlmMessage>[];
    var lastRequestMessages = <LlmMessage>[];
    // 与记忆相关的工具结果（读 user-memory/ 文件、remember / forget）：关闭记忆后在后续请求里替换。
    final memResultIds = <String>{};
    final privacyPreservedReceipts = <String>{};
    final privacyRedactedResponses = HashSet<LlmResponse>.identity();
    final memoryReasoning = <LlmMessage>{};
    LlmMessage assistant(
      LlmResponse response, {
      String? content,
      List<LlmToolCall>? toolCalls,
      bool history = false,
    }) {
      final msg = LlmMessage.assistant(
        content ?? response.content,
        toolCalls: [
          for (final call in toolCalls ?? response.toolCalls)
            privacyRedactedResponses.contains(response) &&
                    call.name == AgentTools.forget
                ? LlmToolCall(id: call.id, name: call.name, arguments: '{}')
                : call,
        ],
        // Worker 的不同上游可能在无推理正文时返回 null / 不返回字段。
        // 后续思考模型仍要求字段存在，显式空串不会编造任何推理内容。
        reasoning:
            (memoryOn && !memoryAllowed()) ||
                privacyRedactedResponses.contains(response)
            ? ''
            : response.reasoning ?? '',
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
    var attemptedPlanning =
        _sessionState.task?.type == 'plan' && _pendingConfirmation != null;
    var rejected = 0;
    List<PlanIssue> lastErrors = const [];
    FallbackReason reason = FallbackReason.invalidOutput;
    Object? error;
    var leaked = false;
    // Context folding belongs to the model journal, never UI history.
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
        isPlanningFailure:
            attemptedPlanning &&
            _sessionState.task?.type == 'plan' &&
            _sessionState.task!.nodes.last.status != 'done' &&
            status == TurnStatus.error,
        leaked: leaked,
        submissions: submissions,
        steps: step,
        reads: reads,
        dead: () => dead() || (commitValid != null && !commitValid()),
        commit: commit == null
            ? null
            : () {
                commit();
                if (dead() || (commitValid != null && !commitValid())) return;
                final current = ledgerContext(context);
                _taskSafetyContext = current;
                if (_sessionState.params.isNotEmpty) {
                  _confirmedPlanContext = current;
                  _lastConfirmedForm = trainingSelections(current, cat);
                }
                _relativeDurationPolicy =
                    _sessionState.params['minutes']?.source == 'derived';
              },
        beforeCommit: question == null
            ? null
            : () =>
                  emit(AgentEventKind.askUser, step: step, question: question),
      );
      if (!dead()) {
        if (r.status != TurnStatus.cancelled) {
          _contextCoveredHistory.addAll(_history.skip(publicHistoryStart));
          if (r.status == TurnStatus.fallback && r.text.isNotEmpty) {
            // This is the actual delivered code fallback, with no invented
            // model reasoning; it belongs in the journal just as in UI history.
            turnMsgs.add(LlmMessage.assistant(r.text, reasoning: ''));
          }
          final rawMessages = <LlmMessage>[userMsg, ...turnMsgs];
          _completeContextTurn(
            result: r,
            messages: memoryAllowed()
                ? rawMessages
                : _withoutMemory(
                    rawMessages,
                    memResultIds,
                    privateReasoning: memoryReasoning,
                    preserveMemoryResultIds: privacyPreservedReceipts,
                  ),
            catalog: cat,
            language: context.language,
            previousLedger: ledgerAtStart,
            pendingAtStart: pendingAtStart,
            confirmedForm: confirmedForm,
          );
          if (memoryAllowed()) _memoryReasoning.addAll(memoryReasoning);
        }
        final current = ledgerContext(context);
        _taskSafetyContext = current;
        if (_sessionState.params.isNotEmpty) {
          _confirmedPlanContext = current;
          _lastConfirmedForm = trainingSelections(current, cat);
        }
        _planningFailure = r.isPlanningFailure;
      }
      emit(AgentEventKind.done, step: step, status: r.status);
      return r;
    }

    var step = 0;
    agentSteps:
    while (step < maxSteps) {
      step++;
      emit(AgentEventKind.thinking, step: step);
      if (memoryOn != memoryAllowed() || forceContextRebuild) await rebuild();
      // 记忆加载等异步之后、实际调模型之前复查世代与取消。
      if (dead()) return cancelled(step - 1);
      var memOff = !memoryOn;
      void prepare() {
        memOff = !memoryOn;
        final key = (
          catalog: catalogContextKey,
          profile: profileContextKey,
          language: context.language,
          memory: memoryOn,
          memoryEpoch: _memEpoch,
        );
        if (_modelContext != null && _modelEpochKey == key) return;
        final tools = AgentTools.build(
          profile,
          cat,
          memory: memoryOn,
          sessionState: _sessionState,
          includeCheckPlan: true,
          language: context.language,
        );
        final ledger = _completedLedger();
        _modelContext =
            AppendOnlyContext(
              budget: contextBudgetConfig,
              encodedBytes: _encodedRequestBytes,
              measurement: requestSizeBytes != null
                  ? 'caller-supplied'
                  : client is OpenAiCompatibleClient
                  ? 'OpenAiCompatibleClient.buildBody-exact'
                  : 'conservative-json-plus-1024',
              initialEpoch: _modelEpochCounter,
            )..activate(
              system: system,
              tools: tools,
              seedMessages: (memOff
                  ? _withoutMemory(
                      _uncoveredHistory(ledger),
                      const {},
                      privateReasoning: _memoryReasoning,
                    )
                  : _uncoveredHistory(ledger)),
              summarySeed: ledger.turns.isEmpty
                  ? null
                  : ledger.summaryMessage(),
            );
        _modelEpochKey = key;
        _modelEpochCounter = _modelContext!.epoch;
      }

      prepare();

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
        if (memoryOn != memoryAllowed() || forceContextRebuild) {
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
        final currentMessages = <LlmMessage>[
          userMsg,
          ...(memOff
              ? _withoutMemory(
                  turnMsgs,
                  memResultIds,
                  privateReasoning: memoryReasoning,
                  preserveMemoryResultIds: privacyPreservedReceipts,
                )
              : turnMsgs),
        ];
        final preparedContext = _modelContext!.compose(
          currentMessages: currentMessages,
          stateMessage: AppendOnlyContext.stateMessage(
            state: _sessionState,
            catalog: cat,
            profile: profile,
            language: context.language,
          ),
          ledger: _completedLedger(),
          thinking:
              client is OpenAiCompatibleClient &&
              (client as OpenAiCompatibleClient).config.extraBody['thinking']
                  is Map &&
              ((client as OpenAiCompatibleClient).config.extraBody['thinking']
                      as Map)['type'] ==
                  'enabled',
          forceHardFold: forced,
        );
        _contextRequestDiagnostics.add(preparedContext.diagnostics);
        _modelEpochCounter = preparedContext.diagnostics.epoch;
        if (!preparedContext.diagnostics.fitsHardLimit ||
            (forced && !preparedContext.diagnostics.folded)) {
          error = AgentContextBudgetExceeded(
            preparedContext.diagnostics.afterBytes,
            contextBudgetConfig.hardBytes,
            reason: forced
                ? 'upstream context limit; no safely foldable content'
                : 'hard byte limit',
          );
          reason = FallbackReason.invalidOutput;
          break;
        }
        final req = preparedContext.request;
        lastRequestMessages = req.messages;
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
          _modelContext?.markConsumed(req);
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
        turnMsgs.add(assistant(response));
        if (g.ok &&
            _sessionState.task?.type == 'plan' &&
            _sessionState.task!.nodes.last.status != 'done') {
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
        turnMsgs.add(
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

      final normalizedBatch = normalizeToolBatch(res);
      res = normalizedBatch.response;
      final executedResponse = res;

      // Execute the batch in order; a failed call blocks every later call.
      final batch = ToolBatch();
      final structured = StructuredToolHandler(
        profile,
        cat,
        newPlanId: () => _ids.next('plan'),
        extraRules: extraRules,
        enforceDrillDoseRange: enforceDrillDoseRange,
        files: fs,
      );
      final skills = SkillToolHandler(fs, readSet, reads, listed);
      final terminal = TerminalToolHandler(gate);
      final results = batch.results;
      final orderedResults = <String>[];
      final disclosuresByIndex = <int, SkillDisclosureMessage>{};
      final batchCalls = res.toolCalls;
      LlmMessage resultMessage(int index, String result) {
        final record = disclosuresByIndex[index];
        return record ?? LlmMessage.tool(batchCalls[index].id, result);
      }

      SkillDisclosures visibleDisclosures() => SkillDisclosures.fromMessages([
        ...lastRequestMessages,
        LlmMessage.assistant('', toolCalls: batchCalls),
        for (var i = 0; i < orderedResults.length; i++)
          resultMessage(i, orderedResults[i]),
      ]);
      AgentOutputResult? terminalOutput;
      AskUserQuestion? terminalQuestion;
      bool terminalRejected = false;
      var fresh = false;
      for (var toolIndex = 0; toolIndex < res.toolCalls.length; toolIndex++) {
        final t = res.toolCalls[toolIndex];
        if (terminalQuestion != null) {
          results[t.id] = jsonEncode({
            'ok': true,
            'deferred': true,
            'reason': 'awaiting_user',
            'notes': ['本批已暂停询问；此操作在收到用户回答后继续。'],
          });
          orderedResults.add(results[t.id]!);
          continue;
        }
        if (batch.failed) {
          batch.skipped(t.id);
          orderedResults.add(results[t.id]!);
          continue;
        }
        // Host settings may change while the model request is in flight.
        context = ledgerContext(context);
        bool? toolFailure;
        if (t.name == AgentTools.draftPlan ||
            t.name == AgentTools.checkPlan ||
            t.name == AgentTools.showPlan ||
            (t.name == AgentTools.startTask && _arg(t, 'type') == 'plan') ||
            (t.name == AgentTools.setParams &&
                _sessionState.task?.type == 'plan')) {
          attemptedPlanning = true;
        }
        switch (t.name) {
          case AgentTools.draftPlan:
            final handled = structured.draft(
              _sessionState,
              t.arguments,
              context.language,
            );
            _sessionState = handled.state;
            if (handled.changes.isNotEmpty) {
              _emitNodeChanges(
                turnId,
                NodeResult(handled.state, changes: handled.changes),
              );
            }
            fresh = fresh || handled.fresh;
            results[t.id] = handled.response;
          case AgentTools.searchActions || AgentTools.getAction:
            final handled = structured.search(
              _sessionState,
              t.name,
              t.arguments,
              context.language,
            );
            _sessionState = handled.state;
            fresh = fresh || handled.fresh;
            for (final id in handled.accessed) {
              if (readSet.add('get_action:$id')) fresh = true;
            }
            results[t.id] = handled.response;
          case AgentTools.startTask || AgentTools.check:
            final handled = structured.task(
              _sessionState,
              t.name,
              t.arguments,
              context.language,
              disclosures: visibleDisclosures(),
            );
            if (handled.requiredSkills.isNotEmpty) {
              disclosuresByIndex[toolIndex] = SkillDisclosureMessage(
                t.id,
                handled.response,
                fullSkills: handled.fullSkills,
                requiredSkills: handled.requiredSkills,
              );
            }
            _sessionState = handled.state;
            if (t.name == AgentTools.startTask && handled.fresh) {
              _questionsAsked = 0;
              _pendingConfirmation = null;
            }
            if (handled.changes.isNotEmpty) {
              _emitNodeChanges(
                turnId,
                NodeResult(handled.state, changes: handled.changes),
              );
            }
            fresh = fresh || handled.fresh;
            results[t.id] = handled.response;
          case AgentTools.setParams:
            Object? args;
            try {
              args = jsonDecode(t.arguments);
            } on FormatException {
              results[t.id] = jsonEncode(
                nodeError(
                  'invalid_json',
                  'arguments',
                  '合法 JSON 对象',
                  '无效 JSON',
                  '提供包含 fields 的合法 JSON 对象。',
                ),
              );
              break;
            }
            List<MemoryEntry> savedMemory = const [];
            if (memoryOn && memoryAllowed()) {
              try {
                savedMemory = await memory();
              } on Object {
                savedMemory = const [];
              }
            }
            if (dead()) return cancelled(step);
            if (!memoryAllowed()) savedMemory = const [];
            final handled = structured.setParams(
              _sessionState,
              args,
              context.language,
              savedMemory,
            );
            _sessionState = handled.state;
            context = ledgerContext(context);
            if (handled.changes.isNotEmpty) {
              _emitNodeChanges(
                turnId,
                NodeResult(handled.state, changes: handled.changes),
              );
            }
            if (handled.fresh) {
              fresh = true;
              _pendingConfirmation = null;
            }
            results[t.id] = handled.response;
          case AgentTools.read:
            final path = SkillFiles.normalize(_arg(t, 'path') ?? '');
            if (skills.blocked(path, read: true, hasTask: true) &&
                (fs.read(path) != null || fs.ls(path) != null)) {
              final handled = structured.readActions(
                _sessionState,
                path,
                context.language,
              );
              _sessionState = handled.state;
              results[t.id] = handled.response;
              fresh = fresh || handled.fresh;
              for (final id in handled.accessed) {
                if (readSet.add('get_action:$id')) fresh = true;
              }
              break;
            }
            if (!skills.blocked(
              path,
              read: true,
              hasTask: _sessionState.task != null,
            )) {
              emit(AgentEventKind.reading, step: step, path: path);
              if (dead()) return cancelled(step);
              if (path.startsWith('${SkillFiles.userMemory}/')) {
                memResultIds.add(t.id);
              }
            }
            final handled = skills.execute(
              t.id,
              path,
              read: true,
              hasTask: _sessionState.task != null,
              disclosures: visibleDisclosures(),
            );
            if (handled.fullRead) {
              disclosuresByIndex[toolIndex] = SkillDisclosureMessage(
                t.id,
                handled.response,
                fullRead: true,
              );
            }
            results[t.id] = handled.response;
            toolFailure = handled.failed;
            fresh = fresh || handled.fresh;
          case AgentTools.checkPlan:
            emit(AgentEventKind.checking, step: step);
            if (dead()) return cancelled(step);
            final handled = structured.checkPlan(
              _sessionState,
              t.arguments,
              language: context.language,
            );
            _sessionState = handled.state;
            if (handled.changes.isNotEmpty) {
              _emitNodeChanges(
                turnId,
                NodeResult(handled.state, changes: handled.changes),
              );
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
            if (t.name == AgentTools.forget &&
                memoryEpoch == _memEpoch &&
                jsonDecode(results[t.id]!) is Map &&
                (jsonDecode(results[t.id]!) as Map)['ok'] == true) {
              // Forgetting is an explicit privacy epoch, just like clearing.
              privacyPreservedReceipts.add(t.id);
              _memEpoch++;
              turnMemoryEpoch = _memEpoch;
              forceContextRebuild = true;
              privacyRedactedResponses.addAll([
                response,
                res,
                executedResponse,
              ]);
              final safeCurrent = _withoutMemory(
                turnMsgs,
                memResultIds,
                privateReasoning: memoryReasoning,
                preserveMemoryResultIds: privacyPreservedReceipts,
              );
              turnMsgs
                ..clear()
                ..addAll(safeCurrent);
              _modelContext = null;
              _modelEpochKey = null;
              final sanitized = _withoutMemory(
                _history,
                const {},
                privateReasoning: _memoryReasoning,
              );
              _history
                ..clear()
                ..addAll(sanitized);
              _memoryReasoning.clear();
            }
            if (memoryTimedOut) {
              calls.add(
                _Call.ok(
                  step,
                  res,
                  CallOutcome.toolStep,
                  retry: tag,
                  codes: const ['timeout'],
                ),
              );
              error = AgentRequestFailed(
                AgentFailureKind.turnTimeout,
                errorClass: RequestErrorClass.timeout,
                attempts: tag + 1,
              );
              reason = FallbackReason.timeout;
              break agentSteps;
            }
          case AgentTools.askUser:
            final handled = terminal.ask(
              t.arguments,
              toolIndex + 1,
              res.toolCalls.length,
              language: context.language,
            );
            terminalRejected = handled.rejected;
            terminalQuestion = handled.question;
            results[t.id] = handled.response;
          case AgentTools.showActions || AgentTools.showPlan:
            attemptedOutput = true;
            final handled = terminal.show(
              _sessionState,
              t.name,
              t.arguments,
              language: context.language,
            );
            terminalRejected = handled.rejected;
            terminalOutput = handled.output;
            _sessionState = handled.state ?? _sessionState;
            if (handled.changes.isNotEmpty) {
              _emitNodeChanges(
                turnId,
                NodeResult(_sessionState, changes: handled.changes),
              );
            }
            results[t.id] = handled.response;
          default:
            results[t.id] = jsonEncode(
              nodeError(
                'unknown_tool',
                'tool',
                '已提供的工具',
                t.name,
                '使用当前工具列表中的名称。',
              ),
            );
        }
        if (dead()) return cancelled(step);
        try {
          final receipt = jsonDecode(results[t.id]!);
          if (receipt is Map) {
            final extraNotes = <String>[...?normalizedBatch.notes[t.id]];
            if (receipt['status'] == 'infeasible') {
              final feasibility = receipt['feasibility'];
              final target = feasibility is Map
                  ? feasibility['targetSec']
                  : null;
              final reason = feasibility is Map ? feasibility['reason'] : null;
              final requiresRebuild =
                  feasibility is Map &&
                  feasibility['status'] == 'requires_rebuild';
              final targetMinutes = target is num
                  ? (target / 60).toStringAsFixed(1)
                  : null;
              final english = context.language.toLowerCase().startsWith('en');
              final providedQuestion = receipt['message'];
              final question =
                  providedQuestion is String &&
                      providedQuestion.trim().isNotEmpty
                  ? providedQuestion
                  : requiresRebuild
                  ? (english
                        ? 'This saved plan needs to be rebuilt before changing its duration. Would you prefer to rebuild the selected actions or keep the current plan?'
                        : '这份已保存计划需要重新编排后才能调整时长。你希望用已有动作重新编排，还是保留当前计划？')
                  : reason == 'derived_minutes_unavailable'
                  ? (english
                        ? 'The requested duration change has no supported value. Would you prefer to keep the current duration or adjust the request?'
                        : '当前支持的时长范围内没有符合这次调整要求的数值。你希望保留当前时长，还是调整本次要求？')
                  : english
                  ? 'The selected actions within the permitted dose ranges cannot fit${targetMinutes == null ? " the requested duration" : " $targetMinutes minutes"}. Would you prefer to change the duration, the dose, or the selected actions?'
                  : '当前动作在允许剂量范围内无法同时满足${targetMinutes == null ? "要求的时长" : "$targetMinutes 分钟"}。你希望调整时长、剂量，还是动作选择？';
              terminalQuestion = AskUserGate.check(
                jsonEncode({'question': question, 'mode': 'text'}),
                language: context.language,
              ).question;
              receipt['asked'] = true;
              receipt['awaitingUser'] = true;
              extraNotes.add('已根据结构化不可行原因暂停询问取舍，未要求模型继续试算。');
            }
            if (extraNotes.isNotEmpty) {
              results[t.id] = jsonEncode({
                ...receipt,
                'notes': [
                  if (receipt['notes'] is List) ...receipt['notes'] as List,
                  ...extraNotes,
                ],
              });
              final disclosure = disclosuresByIndex[toolIndex];
              if (disclosure != null) {
                disclosuresByIndex[toolIndex] = SkillDisclosureMessage(
                  t.id,
                  results[t.id]!,
                  fullRead: disclosure.fullRead,
                  fullSkills: disclosure.fullSkills,
                  requiredSkills: disclosure.requiredSkills,
                );
              }
            }
          }
        } on FormatException {
          // Plain skill results retain their exact disclosure text.
        }
        batch.mark(toolIndex + 1, t.id, failure: toolFailure);
        orderedResults.add(results[t.id]!);
        if (terminalOutput != null) {
          for (
            var later = toolIndex + 1;
            later < res.toolCalls.length;
            later++
          ) {
            batch.skippedAfterCompletion(
              res.toolCalls[later].id,
              toolIndex + 1,
            );
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

      final earlierTurnMessages = List<LlmMessage>.of(turnMsgs);
      turnMsgs
        ..add(assistant(executedResponse))
        ..addAll([
          for (var i = 0; i < orderedResults.length; i++)
            resultMessage(i, orderedResults[i]),
        ]);
      if (terminalQuestion != null) {
        submissions++;
        final question = terminalQuestion;
        calls.add(
          _Call.ok(
            step,
            res,
            rejected == 0 ? CallOutcome.passed : CallOutcome.rewritten,
            retry: tag,
          ),
        );
        return done(
          TurnStatus.ok,
          rejected == 0 ? TurnOutcome.model : TurnOutcome.rewritten,
          step,
          text: question.question,
          question: question,
          commit: () => _commitAsk(
            question: question,
            questionsAsked: _questionsAsked,
            userMessage: userMsg,
            turnMessages: earlierTurnMessages,
            assistantMessage: assistant(
              executedResponse,
              content: question.question,
              history: true,
            ),
            calls: executedResponse.toolCalls,
            results: orderedResults,
            resultMessages: [
              for (var i = 0; i < orderedResults.length; i++)
                resultMessage(i, orderedResults[i]),
            ],
            memoryResultIds: memResultIds,
            privateReasoning: memoryReasoning,
          ),
        );
      }

      if (terminalOutput == null) {
        if (terminalRejected) {
          submissions++;
          final detail =
              jsonDecode(orderedResults[batch.firstFailure! - 1]) as Map;
          lastErrors = [PlanIssue('${detail['code']}', '${detail['fix']}')];
          calls.add(
            _Call.ok(
              step,
              res,
              retry: tag,
              CallOutcome.rejected,
              codes: [for (final issue in lastErrors) issue.code],
            ),
          );
          if (++rejected > maxResubmits) {
            break;
          }
        } else {
          final failed = batch.firstFailure;
          final detail = failed == null
              ? null
              : jsonDecode(orderedResults[failed - 1]);
          calls.add(
            _Call.ok(
              step,
              res,
              retry: tag,
              CallOutcome.toolStep,
              codes: detail is Map && detail['code'] is String
                  ? [detail['code'] as String]
                  : const [],
            ),
          );
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
      if (output.unavailable) {
        final message =
            output.unavailableMessage ??
            (context.language.toLowerCase().startsWith('en')
                ? 'No actions match the current conditions. Would you like to adjust them?'
                : '当前条件没有符合要求的动作。是否愿意调整条件？');
        calls.add(_Call.ok(step, res, CallOutcome.passed, retry: tag));
        return done(
          TurnStatus.ok,
          TurnOutcome.model,
          step,
          text: message,
          commit: () {
            _turns++;
            _history
              ..add(userMsg)
              ..add(
                assistant(
                  executedResponse,
                  content: message,
                  toolCalls: const [],
                  history: true,
                ),
              );
          },
        );
      }
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
            visibleAssistant: () => assistant(
              response,
              content: g.text,
              toolCalls: const [],
              history: true,
            ),
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
    final task = _sessionState.task;
    final unfinishedTask = task != null && task.nodes.last.status != 'done';
    if (unfinishedTask || attemptedPlanning || attemptedOutput) {
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
      if (r.plan != null) {
        error = StateError('Fallback plans require explicit host selection');
        return await done(TurnStatus.error, TurnOutcome.error, step);
      }
      return await done(
        TurnStatus.fallback,
        TurnOutcome.fallback,
        step,
        text: r.text,
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

  /// All model feedback has the same actionable error fields.
  static String _feedback(List<PlanIssue> errors, {required int remaining}) {
    final first = errors.firstOrNull;
    final detail = first == null
        ? nodeError(
            'invalid_output',
            'output',
            '有效正文或当前任务的输出工具',
            '无可交付内容',
            '提交非空正文；计划通过 show_plan 交付。',
          )
        : _issueJson(first);
    return jsonEncode({
      'ok': false,
      'code': detail['code'],
      'field': detail['field'] ?? detail['path'] ?? 'output',
      'expected': detail['expected'],
      'actual': detail['actual'],
      'fix': detail['fix'],
      'remainingAttempts': remaining,
      'errors': [for (final e in errors) _issueJson(e)],
    });
  }

  static Map<String, Object?> _issueJson(PlanIssue e) {
    final j = ToolGate.issueJson(e);
    final fix = switch (e.code) {
      IssueCodes.unknownExercise ||
      IssueCodes.outOfProfile => '先用 search_actions 搜索，并选择返回的合规动作 id。',
      IssueCodes.modeMismatch =>
        '参考 search_actions 的剂量模式，用 reps 或 seconds 重新提交 draft_plan。',
      IssueCodes.avoid => '搜索并选择符合当前伤痛限制的动作，替换冲突动作。',
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

class AgentContextBudgetExceeded implements Exception {
  const AgentContextBudgetExceeded(
    this.bytes,
    this.hardLimitBytes, {
    this.reason = 'hard byte limit',
  });
  final int bytes;
  final int hardLimitBytes;
  final String reason;
  @override
  String toString() =>
      'AgentContextBudgetExceeded(bytes=$bytes, limit=$hardLimitBytes, $reason)';
}
