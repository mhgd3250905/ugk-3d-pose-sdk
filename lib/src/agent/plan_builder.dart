/// Build a versioned draft from structured model choices and catalogue doses.
library;

import 'dart:math' as math;

import '../catalog/catalog.dart';
import '../plan/plan_codec.dart';
import '../plan/training_plan.dart';
import '../profile/coach_profile.dart';
import 'agent_task.dart';
import 'legacy_goal.dart';
import 'node_gates.dart';
import 'session_state.dart';

part 'plan_timing.dart';
part 'plan_focus_edit.dart';
part 'plan_duration_recovery.dart';

class DraftResult {
  const DraftResult(
    this.state, {
    this.planId,
    this.version,
    this.estimateMinutes,
    this.structure = const [],
    this.fitLog = const [],
    this.legacyGoal,
    this.changes = const [],
    this.note,
    this.notes = const [],
    this.feasibility,
    this.durationErrorPercent,
    this.error,
  });
  final CoachSessionState state;
  final String? planId;
  final int? version;
  final double? estimateMinutes;
  final List<Map<String, Object?>> structure;
  final List<Map<String, Object?>> fitLog;
  final String? legacyGoal;
  final List<CoachNodeState> changes;
  final String? note;
  final List<String> notes;
  final Map<String, Object?>? feasibility;
  final double? durationErrorPercent;
  final Map<String, Object?>? error;
  bool get ok => error == null;
  Map<String, Object?> toJson() => {
    if (error != null) ...error! else 'ok': true,
    if (planId != null) 'plan_id': planId,
    if (version != null) 'version': version,
    if (estimateMinutes != null) 'estimateMinutes': estimateMinutes,
    if (legacyGoal != null) 'legacyGoal': legacyGoal,
    if (structure.isNotEmpty) 'structure': structure,
    if (fitLog.isNotEmpty) 'fitLog': fitLog,
    if (note != null) 'note': note,
    if (notes.isNotEmpty) 'notes': notes,
    if (feasibility != null) ...{
      'status': 'infeasible',
      'needsUserChoice': true,
      'feasibility': feasibility,
    },
    if (durationErrorPercent != null) ...{
      'durationErrorPercent': durationErrorPercent,
      'withinTolerance': durationErrorPercent! <= 10,
    },
  };
}

class PlanBuilder {
  PlanBuilder(this.profile, this.catalog, {required int minPicks})
    : gate = NodeGates(profile, catalog, minPicks: minPicks);
  final CoachProfile profile;
  final Catalog catalog;
  final NodeGates gate;
  static const _duration = PlanDuration();

  DraftResult draft(
    CoachSessionState state,
    Map<String, Object?> arguments, {
    required String newPlanId,
    String language = 'zh',
  }) {
    DraftResult fail(
      String code,
      String field,
      Object? expected,
      Object? actual,
      String fix,
    ) => DraftResult(
      state,
      error: nodeError(code, field, expected, actual, fix),
    );
    final scene = state.params['scene']?.value;
    final minutes = state.params['minutes']?.value;
    final goals = state.params['goal']?.value;
    final missing = [
      if (scene == null) 'scene',
      if (goals == null || goals is List && goals.isEmpty) 'goal',
      if (minutes == null) 'minutes',
    ];
    if (missing.isNotEmpty) {
      return fail(
        'missing_parameters',
        'params',
        ['scene', 'goal', 'minutes'],
        missing,
        '先完成参数节点并补齐计划条件。',
      );
    }
    if (scene is! String ||
        minutes is! int ||
        minutes <= 0 ||
        goals is! List ||
        goals.isEmpty ||
        goals.any((x) => x is! String)) {
      return fail(
        'invalid_parameters',
        'params',
        ['scene', 'goal', 'minutes'],
        {'scene': scene, 'goal': goals, 'minutes': minutes},
        'scene 须为字符串，goal 须为非空编码列表，minutes 须为正整数。',
      );
    }
    final task = state.task;
    final replacementThreshold = profile.planRules.replaceAllMinDiff;
    if (!replacementThreshold.isFinite ||
        replacementThreshold < 0 ||
        replacementThreshold > 1) {
      return fail(
        'invalid_profile',
        'planRules.replaceAllMinDiff',
        '0 到 1 的有限数',
        replacementThreshold,
        '修正 profile 的换一套阈值。',
      );
    }
    // Old model operation markers remain a compatibility alias only. New
    // callers put the understood intent in source-validated set_params.
    final legacyOperation = arguments['operation'];
    final validLegacyOperation = {
      'edit',
      'replace_all',
    }.contains(legacyOperation);
    var suppliedOperation = validLegacyOperation ? legacyOperation : null;
    final currentTurn = state.userTurns.isEmpty ? 0 : state.userTurns.last.turn;
    final confirmedOperation = state.params['operation'];
    final operationRequestTurn =
        state.lastOperationRequestTurn ?? confirmedOperation?.turn;
    if (operationRequestTurn == currentTurn &&
        {'edit', 'replace_all'}.contains(confirmedOperation?.value)) {
      suppliedOperation = confirmedOperation!.value;
    }
    final focused = state.plans[state.focusPlanId]?.lastOrNull;
    final focusPlan = focused == null
        ? null
        : const PlanCodec().decode(focused.plan);
    final usedSourceIndices = <int>{};
    final deliveredId = focused == null
        ? state.lastDeliveredPlanId
        : state.focusPlanId;
    final deliveredVersion = focused?.version ?? state.lastDeliveredVersion;
    final deliveredVersions = deliveredId == null
        ? const <CoachPlanVersion>[]
        : state.plans[deliveredId] ?? const <CoachPlanVersion>[];
    final delivered = deliveredVersions
        .where((v) => v.version == deliveredVersion)
        .firstOrNull;
    final ignoredOperation =
        suppliedOperation != null && (deliveredId == null || delivered == null);
    if (ignoredOperation) suppliedOperation = null;
    final activeVersions = state.activePlanId == null
        ? const <CoachPlanVersion>[]
        : state.plans[state.activePlanId] ?? const <CoachPlanVersion>[];
    final latest = activeVersions.isEmpty ? null : activeVersions.last;
    final sameTurnDraft =
        latest != null &&
        latest.createdAtTurn == currentTurn &&
        state.activePlanId == deliveredId &&
        latest.version != deliveredVersion;
    final sameTurnRepair = sameTurnDraft && latest.check?['ok'] == false;
    final operation =
        (sameTurnDraft ? latest.operation : null) ??
        suppliedOperation as String? ??
        (sameTurnRepair ? latest.operation : null) ??
        (delivered != null &&
                (focused != null ||
                    state.activePlanId == deliveredId ||
                    arguments['plan_id'] == deliveredId)
            ? 'edit'
            : null);
    var suppliedId = arguments['plan_id'];
    final completed =
        task?.type == 'plan' &&
        task!.nodes.isNotEmpty &&
        task.nodes.every((n) => n.status == 'done' || n.status == 'updated');
    if (operation != null && suppliedId != null && suppliedId != deliveredId) {
      suppliedId = deliveredId;
    }
    CoachSessionState working = state;
    final changes = <CoachNodeState>[];
    if (completed && operation != null) {
      final nodes = <CoachNodeState>[];
      for (final node in task.nodes) {
        final status = node.id == 'planning'
            ? 'current'
            : (node.id == 'review' || node.id == 'output')
            ? 'pending'
            : node.status;
        final next = status == node.status
            ? node
            : node.copyWith(
                status: status,
                clearStamp: true,
                clearDoneAtTurn: true,
              );
        nodes.add(next);
        if (!identical(next, node)) changes.add(next);
      }
      working = state.copyWith(task: task.copyWith(nodes: nodes));
    }
    final current = working.task?.nodes
        .where((node) => node.status == 'current')
        .firstOrNull;
    if (working.task?.type != 'plan' || current?.id != 'planning') {
      return fail(
        'wrong_node',
        'node',
        'planning',
        current?.id,
        '先完成当前计划节点，然后在 planning 节点创建草稿。',
      );
    }
    final rawTitle = arguments['title'];
    final title = rawTitle is String && rawTitle.trim().isNotEmpty
        ? rawTitle.trim()
        : (language.toLowerCase().startsWith('en') ? 'Training plan' : '训练计划');
    final rawBlocks = arguments['blocks'];
    if (rawBlocks is! List ||
        (suppliedId != null && (suppliedId is! String || suppliedId.isEmpty))) {
      return fail(
        'invalid_draft',
        'draft_plan',
        'title、非空 blocks、可选已有 plan_id',
        arguments,
        '提供计划标题、结构和可选的已有计划 ID。',
      );
    }
    var id = operation != null
        ? deliveredId!
        : suppliedId as String? ?? newPlanId;
    if (operation == null && suppliedId != null && id != state.activePlanId) {
      id =
          state.activePlanId ??
          (state.legacyPlanFallback && state.plans.length == 1
              ? state.plans.keys.single
              : newPlanId);
    }
    if ((suppliedId != null && !state.plans.containsKey(id)) ||
        (suppliedId != null &&
            state.plans[id]?.isEmpty == true &&
            id != state.activePlanId) ||
        (operation == null &&
            suppliedId == null &&
            (id.isEmpty || state.plans.containsKey(id)))) {
      id = state.activePlanId ?? newPlanId;
      if (state.plans[id]?.isNotEmpty == true && operation == null) {
        id = '$newPlanId-${state.plans.length + 1}';
      }
    }
    final log = <Map<String, Object?>>[];
    final notes = <String>[];
    if (legacyOperation != null) {
      final confirmed = operationRequestTurn == currentTurn;
      notes.add(
        language.toLowerCase().startsWith('en')
            ? confirmed
                  ? 'Used the confirmed operation parameter instead of the legacy draft marker.'
                  : validLegacyOperation
                  ? 'Accepted the legacy operation marker for compatibility; new callers use set_params.'
                  : 'Ignored an invalid legacy operation marker; continued with the current/default operation.'
            : confirmed
            ? '已使用带来源的操作参数，未采用旧草稿操作标记。'
            : validLegacyOperation
            ? '已兼容旧操作标记；新调用应使用 set_params。'
            : '已忽略无效旧操作标记，沿用当前或默认操作。',
      );
    }
    if (arguments['plan_id'] != null && arguments['plan_id'] != id) {
      notes.add(
        language.toLowerCase().startsWith('en')
            ? 'Used the current plan reference managed by the SDK.'
            : '已使用 SDK 管理的当前计划引用。',
      );
    }
    if (arguments['operation'] == null && operation == 'edit') {
      notes.add(
        language.toLowerCase().startsWith('en')
            ? 'Continued the delivered plan with the default edit operation.'
            : '已按默认 edit 继续修改已交付计划。',
      );
    }
    if (arguments.containsKey('legacy_goal')) {
      notes.add(
        language.toLowerCase().startsWith('en')
            ? 'Ignored legacy_goal; the SDK derives it from confirmed goals.'
            : '已忽略 legacy_goal，由 SDK 从已确认目标推导。',
      );
    }
    final ignoredDoseFields = <String>[];
    for (final field in ['sets', 'reps', 'seconds', 'rounds']) {
      if (arguments.containsKey(field)) ignoredDoseFields.add(field);
    }
    if (title != rawTitle) {
      notes.add(
        language.toLowerCase().startsWith('en')
            ? 'Used a default plan title.'
            : '已使用默认计划标题。',
      );
    }
    final blocks = <_DraftBlock>[];
    final extras = <String>{};
    for (var bi = 0; bi < rawBlocks.length; bi++) {
      final raw = rawBlocks[bi];
      if (raw is! Map || raw['items'] is! List) {
        return fail(
          'invalid_block',
          'blocks[$bi]',
          'kind、非空 items、可选整数 rounds',
          raw,
          '提供 warmup、main 或 cooldown 块和动作。',
        );
      }
      if ((raw['items'] as List).isEmpty) {
        notes.add(
          language.toLowerCase().startsWith('en')
              ? 'Removed empty block b${bi + 1}.'
              : '已移除空块 b${bi + 1}。',
        );
        continue;
      }
      final kind = {'warmup', 'main', 'cooldown'}.contains(raw['kind'])
          ? raw['kind'] as String
          : 'main';
      if (kind != raw['kind']) {
        notes.add(
          language.toLowerCase().startsWith('en')
              ? 'Normalized block b${bi + 1} to main.'
              : '已将 b${bi + 1} 规范化为主体块。',
        );
      }
      if (raw.containsKey('rounds')) {
        ignoredDoseFields.add('blocks[$bi].rounds');
      }
      final rounds = 1.clamp(
        profile.limits.rounds.min,
        profile.limits.rounds.max,
      );
      final items = <_DraftItem>[];
      for (var ii = 0; ii < (raw['items'] as List).length; ii++) {
        final item = (raw['items'] as List)[ii];
        if (item is! Map || item['id'] is! String) {
          return fail(
            'invalid_item',
            'blocks[$bi].items[$ii]',
            'id 和可选整数剂量',
            item,
            '提供动作 ID 和整数剂量。',
          );
        }
        for (final key in ['sets', 'reps', 'seconds', 'rounds']) {
          if (item.containsKey(key)) {
            ignoredDoseFields.add('blocks[$bi].items[$ii].$key');
          }
        }
        final actionId = item['id'] as String;
        int? sourceIndex;
        if (focusPlan != null &&
            operation == 'edit' &&
            item.containsKey('sourceIndex')) {
          final rawIndex = item['sourceIndex'];
          final originals = focusPlan.items.toList();
          if (rawIndex is! int ||
              rawIndex < 1 ||
              rawIndex > originals.length ||
              originals[rawIndex - 1].exerciseId != actionId ||
              !usedSourceIndices.add(rawIndex)) {
            return fail(
              'invalid_source_index',
              'blocks[$bi].items[$ii].sourceIndex',
              '当前 focus_plan 中与动作ID相符且未复用的1-based index',
              rawIndex,
              '保留旧项时引用其真实 index；新增动作不传 sourceIndex。',
            );
          }
          sourceIndex = rawIndex;
        }
        final drill = catalog[actionId];
        if (drill == null ||
            !state.seenActionIds.contains(actionId) ||
            gate.actionProblem(state, actionId) != null) {
          return fail(
            'incompatible_action',
            'blocks[$bi].items[$ii].id',
            '已搜索且符合条件的动作',
            actionId,
            '先用 search_actions 搜索，再选择符合当前条件的动作。',
          );
        }
        if (!state.picks.contains(actionId)) extras.add(actionId);
        final setsRange = _range(drill.doseRange.sets, profile.limits.sets);
        final workRange = _range(
          drill.defaultDose.mode == DoseMode.reps
              ? drill.doseRange.reps
              : drill.doseRange.seconds,
          drill.defaultDose.mode == DoseMode.reps
              ? profile.limits.reps
              : profile.limits.workSeconds,
        );
        if (setsRange == null || workRange == null) {
          return fail(
            'invalid_dose_range',
            'blocks[$bi].items[$ii]',
            '目录与 profile 范围有交集',
            actionId,
            '修正目录或 profile 的剂量范围。',
          );
        }
        final requestedSets = drill.defaultDose.sets;
        final requestedWork =
            (drill.defaultDose.mode == DoseMode.reps
                ? drill.defaultDose.reps
                : drill.defaultDose.seconds) ??
            workRange.min;
        final sets = requestedSets.clamp(setsRange.min, setsRange.max);
        final work = requestedWork.clamp(workRange.min, workRange.max);
        final restRange = _range(
          drill.doseRange.restSeconds,
          profile.limits.restSeconds,
        );
        if (restRange == null) {
          return fail(
            'invalid_dose_range',
            'blocks[$bi].items[$ii]',
            '目录与 profile 的休息范围有交集',
            actionId,
            '修正目录或 profile 的休息范围。',
          );
        }
        final rest = drill.defaultDose.restSeconds.clamp(
          restRange.min,
          restRange.max,
        );
        items.add(
          _DraftItem(
            drill,
            sets,
            work,
            rest,
            setsRange,
            workRange,
            restRange,
            sourceIndex: sourceIndex,
          ),
        );
      }
      final grouped = <_DraftItem>[];
      for (final item in items) {
        final existing = focused == null
            ? grouped.where((v) => v.drill.id == item.drill.id).firstOrNull
            : null;
        if (existing == null) {
          grouped.add(item);
        } else {
          existing.sets = (existing.sets + item.sets).clamp(
            existing.setRange.min,
            existing.setRange.max,
          );
          notes.add(
            language.toLowerCase().startsWith('en')
                ? 'Merged repeated ${item.drill.id} in block b${bi + 1}; the timer determines its dose.'
                : '已合并 b${bi + 1} 中重复的 ${item.drill.id}，剂量由配时器统一计算。',
          );
        }
      }
      final block = _DraftBlock(
        'b${bi + 1}',
        kind,
        rounds,
        grouped,
        roundsRange: profile.limits.rounds,
        roundRestRange: profile.limits.restBetweenRoundsSeconds,
        roundRest: profile.limits.restBetweenRoundsSeconds.min,
      );
      final originalOrder = grouped.map((item) => item.drill.id).join(',');
      // In focused editing, item positions are user-visible references. Keep
      // the supplied ordered replacement/insert/delete instead of re-sorting
      // unrelated actions around the requested position.
      if (focused == null) _stableMainOrder(block);
      if (originalOrder != block.items.map((item) => item.drill.id).join(',')) {
        notes.add(
          language.toLowerCase().startsWith('en')
              ? 'Stably ordered main block ${block.id} without adding or removing actions.'
              : '已稳定排序主体块 ${block.id}，未增删动作。',
        );
      }
      blocks.add(block);
    }
    final originalPhases = blocks.map((block) => block.id).join(',');
    blocks.sort((a, b) {
      const phase = {'warmup': 0, 'main': 1, 'cooldown': 2};
      final byPhase = phase[a.kind]!.compareTo(phase[b.kind]!);
      return byPhase != 0
          ? byPhase
          : int.parse(
              a.id.substring(1),
            ).compareTo(int.parse(b.id.substring(1)));
    });
    if (originalPhases != blocks.map((block) => block.id).join(',')) {
      notes.add(
        language.toLowerCase().startsWith('en')
            ? 'Ordered blocks as warmup, main, cooldown.'
            : '已按热身、主体、收尾排列分块。',
      );
    }
    if (ignoredDoseFields.isNotEmpty) {
      notes.add(
        language.toLowerCase().startsWith('en')
            ? 'Ignored ${ignoredDoseFields.length} legacy dose fields; doses and rounds are calculated from the catalogue and confirmed parameters.'
            : '已忽略 ${ignoredDoseFields.length} 个旧模型剂量字段；剂量和轮数由目录及已确认参数计算。',
      );
    }
    final target = minutes * 60.0;
    final legacyGoal = resolveLegacyGoal(
      profile,
      goals.cast<String>(),
      blocks.map((b) => b.kind),
    );
    if (focused != null && operation == 'edit') {
      return _draftFocused(
        state,
        working,
        focusPlan!,
        blocks,
        title: title,
        minutes: minutes,
        legacyGoal: legacyGoal,
        changes: changes,
        extras: extras,
        notes: notes,
        language: language,
      );
    }
    TrainingPlan asPlan(List<_DraftBlock> source) {
      final equipment = <String>{
        for (final b in source)
          for (final i in b.items) ...i.drill.equipment,
      }..remove('none');
      final limits =
          (state.params['limits']?.value as List<Object?>? ?? const [])
              .cast<String>();
      return TrainingPlan(
        id: id,
        source: 'ai',
        title: title,
        summary: title,
        goal: legacyGoal,
        scene: scene,
        equipment: equipment.toList(),
        level: state.params['level']?.value as int? ?? 1,
        targetMinutes: minutes,
        avoid: {for (final code in limits) gate.tags.limitValue(code) ?? code},
        blocks: [for (final block in source) block.toBlock()],
      );
    }

    double estimate(List<_DraftBlock> source) =>
        _duration.estimateSeconds(asPlan(source), catalog);
    final conflicts = _applyDoseConstraints(
      blocks,
      state.params['dose']?.value,
      profile.limits.rounds,
    );
    final bounds = _timingBounds(blocks, target, estimate);
    Map<String, Object?> recovery() => _durationRecovery(
      state,
      asPlan(_timingExtreme(blocks, false)),
      asPlan(_timingExtreme(blocks, true)),
      bounds,
      language: language,
    );
    if (conflicts.isNotEmpty || bounds['status'] == 'infeasible') {
      return _durationRejected(
        state,
        seconds: estimate(blocks),
        target: target,
        recovery: recovery(),
        conflicts: conflicts,
        notes: notes,
        language: language,
      );
    }
    _fit(blocks, target, estimate, log);
    final plan = asPlan(blocks);
    final seconds = _duration.estimateSeconds(plan, catalog);
    final durationFailure = _durationFailure(
      state,
      seconds,
      target,
      log,
      notes: notes,
      language: language,
      recovery: recovery,
    );
    if (durationFailure != null) return durationFailure;
    final previous = state.plans[id] ?? const <CoachPlanVersion>[];
    final version = previous.isEmpty
        ? 1
        : previous.map((v) => v.version).reduce(math.max) + 1;
    final saved = CoachPlanVersion(
      version: version,
      plan: plan.toJson(),
      estimateSec: seconds,
      fitLog: log,
      createdAtTurn: currentTurn,
      operation: operation,
    );
    if (extras.isNotEmpty) {
      final updated = gate.addDraftPicks(working, extras, language: language);
      if (!updated.ok) return DraftResult(state, error: updated.error);
      working = updated.state;
      changes.addAll(updated.changes);
    }
    final next = working.copyWith(
      plans: {
        for (final entry in state.plans.entries)
          if (!(suppliedId == null &&
              operation == null &&
              entry.key == state.activePlanId &&
              entry.value.isEmpty))
            entry.key: entry.value,
        id: [...previous, saved],
      },
      activePlanId: id,
    );
    final structure = [
      for (final b in blocks)
        {
          'blockId': b.id,
          'kind': b.kind,
          'rounds': b.rounds,
          'items': b.items.length,
        },
    ];
    Map<String, Object?>? error;
    if (operation == 'replace_all') {
      final oldPlan = const PlanCodec().decode(delivered!.plan);
      final oldMain = <String>{
        for (final block in oldPlan.blocks)
          if (block.type == BlockType.main || block.type == BlockType.circuit)
            for (final item in block.items)
              if (item.segments.isEmpty)
                item.exerciseId
              else
                for (final segment in item.segments) segment.exerciseId,
      };
      final newMain = <String>{
        for (final block in blocks)
          if (block.kind == 'main')
            for (final item in block.items) item.drill.id,
      };
      final different = newMain.difference(oldMain);
      final ratio = newMain.isEmpty ? 0.0 : different.length / newMain.length;
      if (newMain.isEmpty || ratio < replacementThreshold) {
        final percentage = (replacementThreshold * 100).toStringAsFixed(2);
        final formattedPercentage = percentage.endsWith('.00')
            ? percentage.substring(0, percentage.length - 3)
            : percentage;
        final candidates = [
          for (final candidate in state.seenActionIds)
            if (!oldMain.contains(candidate) &&
                !newMain.contains(candidate) &&
                gate.actionProblem(state, candidate) == null)
              candidate,
        ];
        final needed = math.max(
          1,
          (replacementThreshold * newMain.length - different.length).ceil(),
        );
        error = {
          ...nodeError(
            'replace_too_similar',
            'blocks.main',
            '≥ $formattedPercentage% 不同',
            '${different.length}/${newMain.length} 不同',
            candidates.length < needed
                ? '替换至少 $needed 个主体动作；候选不足，先搜索更多合规动作。'
                : '替换至少 $needed 个主体动作。',
          ),
          'candidates': candidates,
        };
      }
    }
    return DraftResult(
      next,
      planId: id,
      version: version,
      estimateMinutes: (seconds / 6).round() / 10,
      structure: List.unmodifiable(structure),
      fitLog: List.unmodifiable(log),
      legacyGoal: legacyGoal,
      note: !ignoredOperation && ignoredDoseFields.isEmpty
          ? null
          : [
              if (ignoredOperation) '首份计划，已忽略 operation',
              if (ignoredDoseFields.isNotEmpty)
                language.toLowerCase().startsWith('en')
                    ? 'Ignored legacy model doses; the timer computed them.'
                    : '已忽略旧模型剂量，由配时器计算。',
            ].join(' '),
      notes: List.unmodifiable(notes),
      durationErrorPercent: (seconds - target).abs() / target * 100,
      error: error,
      changes: List.unmodifiable(changes),
    );
  }

  IntRange? _range(IntRange? catalogRange, IntRange limit) {
    final min = math.max(catalogRange?.min ?? limit.min, limit.min);
    final max = math.min(catalogRange?.max ?? limit.max, limit.max);
    return min > max ? null : IntRange(min, max);
  }

  // Failure to find a fitting integer dose is recoverable, not a proof that
  // the user's conditions are impossible. Never commit an approximate card.
  DraftResult? _durationFailure(
    CoachSessionState state,
    double seconds,
    double target,
    List<Map<String, Object?>> log, {
    List<String> notes = const [],
    String language = 'zh',
    required Map<String, Object?> Function() recovery,
  }) {
    final tolerance = math.min(.1, profile.limits.durationTolerance);
    if ((seconds - target).abs() <= target * tolerance + 1e-9) return null;
    return _durationRejected(
      state,
      seconds: seconds,
      target: target,
      recovery: recovery(),
      log: log,
      notes: notes,
      language: language,
    );
  }

  DraftResult _durationRejected(
    CoachSessionState state, {
    required double seconds,
    required double target,
    required Map<String, Object?> recovery,
    List<Map<String, Object?>> log = const [],
    List<Map<String, Object?>> conflicts = const [],
    List<String> notes = const [],
    String language = 'zh',
  }) {
    final verifiedDose = recovery['userConfirmedDose'] == true;
    // These conflicts cannot be repaired by selecting a different free action:
    // a pinned action has a wrong mode/range, two explicit values disagree, or
    // a required value lies outside the profile for every possible action.
    final doseConflict =
        verifiedDose &&
        conflicts.any((conflict) {
          if (conflict['reason'] == 'conflicting_explicit_values') return true;
          if (conflict['reason'] == 'no_selected_action_matches_constraint') {
            return false;
          }
          if (conflict['actionId'] is String) return true;
          final value = conflict['actual'];
          final range = switch (conflict['field']) {
            'rounds' => profile.limits.rounds,
            'sets' => profile.limits.sets,
            'reps' => profile.limits.reps,
            'seconds' => profile.limits.workSeconds,
            _ => null,
          };
          return value is int && range != null && !range.contains(value);
        });
    final diagnostics = <String, Object?>{
      ...recovery,
      if (conflicts.isNotEmpty) ...{
        'reason': 'explicit_dose_conflict',
        'conflicts': conflicts,
      },
      if (doseConflict) ...{
        'status': 'infeasible',
        'clarificationAllowed': true,
        'needsDraftRebuild': false,
        'clarificationProof': 'confirmed_dose_cannot_be_repaired_by_selection',
        'fix': language.toLowerCase().startsWith('en')
            ? 'The confirmed dose itself conflicts with its permitted range or mode. Ask which confirmed requirement the user wants to change.'
            : '用户明确剂量本身与允许范围或模式冲突，增删未确认动作也无法解决；请询问用户愿意调整哪项已确认条件。',
      },
    };
    if (diagnostics['clarificationAllowed'] == true) {
      return DraftResult(
        state,
        notes: List.unmodifiable(notes),
        fitLog: List.unmodifiable(log),
        feasibility: diagnostics,
      );
    }
    return DraftResult(
      state,
      fitLog: List.unmodifiable(log),
      notes: List.unmodifiable(notes),
      durationErrorPercent: (seconds - target).abs() / target * 100,
      error: {
        ...nodeError(
          'duration_fit_failed',
          'plan.duration',
          {'targetSec': target, 'toleranceRatio': recovery['toleranceRatio']},
          {'estimatedSec': seconds},
          diagnostics['fix'] as String,
        ),
        ...diagnostics,
        'ok': false,
      },
    );
  }

  void _fit(
    List<_DraftBlock> blocks,
    double target,
    double Function(List<_DraftBlock>) estimate,
    List<Map<String, Object?>> log,
  ) {
    final initialSeconds = estimate(blocks);
    final tolerance = math.min(.1, profile.limits.durationTolerance);
    final fitTolerance = math.min(.05, tolerance);
    if ((initialSeconds - target).abs() <= target * tolerance) return;
    List<_DraftBlock> copy(List<_DraftBlock> source) => [
      for (final block in source) block.cloneWithout(const {}),
    ];
    final initial = copy(blocks);
    var chosen = copy(blocks);
    var chosenSeconds = initialSeconds;
    var chosenLog = <Map<String, Object?>>[];

    void attempt(
      List<_DraftBlock> candidate,
      int startStage,
      List<Map<String, Object?>> changes, {
      bool segmentWork = false,
    }) {
      var current = estimate(candidate);
      void saveIfBetter() {
        if ((current - target).abs() < (chosenSeconds - target).abs()) {
          chosen = copy(candidate);
          chosenSeconds = current;
          chosenLog = List.of(changes);
        }
      }

      saveIfBetter();
      // Revisit stages after crossing the target: reducing one action's sets
      // and increasing another can fit even when either change alone cannot.
      final visited = <String>{};
      while ((current - target).abs() > target * fitTolerance) {
        final signature = [
          for (final block in candidate)
            '${block.rounds}:${block.roundRest}:'
                '${block.items.map((item) => '${item.sets},${item.work},${item.rest},${item.parts.map((part) => part.work).join(',')}').join(';')}',
        ].join('|');
        if (!visited.add(signature)) break;
        for (var stage = startStage; stage < (segmentWork ? 9 : 8); stage++) {
          if ((current - target).abs() <= target * fitTolerance) break;
          final direction = current < target ? 1 : -1;
          while ((current - target).abs() > target * fitTolerance) {
            final edits = <_Edit>[];
            for (final block in candidate) {
              if ((stage == 0 && block.kind == 'main') ||
                  (stage == 5 && block.kind != 'main')) {
                if (block.roundsRange.contains(block.rounds + direction)) {
                  edits.add(
                    _Edit(
                      block.id,
                      null,
                      'rounds',
                      () => block.rounds,
                      (v) => block.rounds = v,
                    ),
                  );
                }
              }
              for (final item in block.items) {
                if (((stage == 1 && block.kind == 'main') ||
                        (stage == 4 && block.kind != 'main')) &&
                    item.sets + direction >= item.setRange.min &&
                    item.sets + direction <= item.setRange.max) {
                  edits.add(
                    _Edit(
                      block.id,
                      item.drill.id,
                      'sets',
                      () => item.sets,
                      (v) => item.sets = v,
                    ),
                  );
                }
                if (((stage == 2 && block.kind == 'main') ||
                        (stage == 3 && block.kind != 'main')) &&
                    item.parts.isEmpty &&
                    item.work + direction >= item.workRange.min &&
                    item.work + direction <= item.workRange.max) {
                  edits.add(
                    _Edit(
                      block.id,
                      item.drill.id,
                      item.drill.defaultDose.mode == DoseMode.reps
                          ? 'reps'
                          : 'seconds',
                      () => item.work,
                      (v) => item.work = v,
                    ),
                  );
                }
                if (stage == 6 &&
                    item.rest + direction >= item.restRange.min &&
                    item.rest + direction <= item.restRange.max) {
                  edits.add(
                    _Edit(
                      block.id,
                      item.drill.id,
                      'restSeconds',
                      () => item.rest,
                      (value) => item.rest = value,
                    ),
                  );
                }
                // Preserve existing group work whenever earlier stages fit.
                // Otherwise search performed segments without flattening them.
                if (stage == 8) {
                  for (final part in item.parts) {
                    if (!part.workRange.contains(part.work + direction)) {
                      continue;
                    }
                    edits.add(
                      _Edit(
                        block.id,
                        part.drill.id,
                        part.drill.defaultDose.mode == DoseMode.reps
                            ? 'reps'
                            : 'seconds',
                        () => part.work,
                        (value) => part.work = value,
                      ),
                    );
                  }
                }
              }
              if (stage == 7 &&
                  block.roundRestRange.contains(block.roundRest + direction)) {
                edits.add(
                  _Edit(
                    block.id,
                    null,
                    'restBetweenRoundsSeconds',
                    () => block.roundRest,
                    (value) => block.roundRest = value,
                  ),
                );
              }
            }
            _Edit? best;
            var bestSeconds = double.infinity;
            for (final edit in edits) {
              final old = edit.get();
              edit.set(old + direction);
              final value = estimate(candidate);
              edit.set(old);
              if ((value - current).abs() < 1e-9) continue;
              if (best == null ||
                  (value - target).abs() < (bestSeconds - target).abs()) {
                best = edit;
                bestSeconds = value;
              }
            }
            if (best == null) break;
            final before = best.get();
            final beforeSeconds = current;
            best.set(before + direction);
            current = bestSeconds;
            changes.add({
              'blockId': best.blockId,
              'actionId': best.actionId,
              'field': best.field,
              'before': before,
              'after': best.get(),
              'beforeEstimatedSec': beforeSeconds,
              'afterEstimatedSec': current,
            });
            saveIfBetter();
            if ((direction > 0 && current >= target) ||
                (direction < 0 && current <= target)) {
              break;
            }
          }
        }
      }
    }

    attempt(copy(initial), 0, []);
    // Explore each block's legal rounds, not a hard-coded main-only 1..4.
    // Later passes revisit all dose stages so compensating edits remain legal.
    for (
      var i = 0;
      i < initial.length &&
          (chosenSeconds - target).abs() > target * fitTolerance;
      i++
    ) {
      for (
        var rounds = initial[i].roundsRange.min;
        rounds <= initial[i].roundsRange.max &&
            (chosenSeconds - target).abs() > target * fitTolerance;
        rounds++
      ) {
        if (rounds == initial[i].rounds ||
            !initial[i].roundsRange.contains(rounds)) {
          continue;
        }
        final candidate = copy(initial);
        candidate[i].rounds = rounds;
        attempt(candidate, initial[i].kind == 'main' ? 1 : 0, [
          {
            'blockId': initial[i].id,
            'actionId': null,
            'field': 'rounds',
            'before': initial[i].rounds,
            'after': rounds,
            'beforeEstimatedSec': initialSeconds,
            'afterEstimatedSec': estimate(candidate),
          },
        ]);
      }
    }
    // Legal endpoint seeds also expose compensating edits that a pass from
    // catalogue defaults can miss. The result is still checked at delivery;
    // a search miss is never represented as a proof of infeasibility.
    for (final maximum in [false, true]) {
      if ((chosenSeconds - target).abs() <= target * tolerance) break;
      final candidate = copy(initial);
      final changes = <Map<String, Object?>>[];
      void seed(_Edit edit, int value) {
        final before = edit.get();
        if (before == value) return;
        final beforeSeconds = estimate(candidate);
        edit.set(value);
        changes.add({
          'blockId': edit.blockId,
          'actionId': edit.actionId,
          'field': edit.field,
          'before': before,
          'after': value,
          'beforeEstimatedSec': beforeSeconds,
          'afterEstimatedSec': estimate(candidate),
        });
      }

      for (final block in candidate) {
        seed(
          _Edit(
            block.id,
            null,
            'rounds',
            () => block.rounds,
            (value) => block.rounds = value,
          ),
          maximum ? block.roundsRange.max : block.roundsRange.min,
        );
        seed(
          _Edit(
            block.id,
            null,
            'restBetweenRoundsSeconds',
            () => block.roundRest,
            (value) => block.roundRest = value,
          ),
          maximum ? block.roundRestRange.max : block.roundRestRange.min,
        );
        for (final item in block.items) {
          seed(
            _Edit(
              block.id,
              item.drill.id,
              'sets',
              () => item.sets,
              (value) => item.sets = value,
            ),
            maximum ? item.setRange.max : item.setRange.min,
          );
          seed(
            _Edit(
              block.id,
              item.drill.id,
              item.drill.defaultDose.mode == DoseMode.reps ? 'reps' : 'seconds',
              () => item.work,
              (value) => item.work = value,
            ),
            maximum ? item.workRange.max : item.workRange.min,
          );
          seed(
            _Edit(
              block.id,
              item.drill.id,
              'restSeconds',
              () => item.rest,
              (value) => item.rest = value,
            ),
            maximum ? item.restRange.max : item.restRange.min,
          );
          for (final part in item.parts) {
            seed(
              _Edit(
                block.id,
                part.drill.id,
                part.drill.defaultDose.mode == DoseMode.reps
                    ? 'reps'
                    : 'seconds',
                () => part.work,
                (value) => part.work = value,
              ),
              maximum ? part.workRange.max : part.workRange.min,
            );
          }
        }
      }
      attempt(candidate, 0, changes);
    }
    if ((chosenSeconds - target).abs() > target * tolerance &&
        chosen.any(
          (block) => block.items.any((item) => item.parts.isNotEmpty),
        )) {
      attempt(copy(chosen), 0, List.of(chosenLog), segmentWork: true);
    }
    blocks
      ..clear()
      ..addAll(chosen);
    log.addAll(chosenLog);
  }
}

class _Edit {
  _Edit(this.blockId, this.actionId, this.field, this.get, this.set);
  final String blockId, field;
  final String? actionId;
  final int Function() get;
  final void Function(int) set;
}

class _DraftItem {
  _DraftItem(
    this.drill,
    this.sets,
    this.work,
    this.rest,
    this.setRange,
    this.workRange,
    this.restRange, {
    this.sourceIndex,
    this.parts = const [],
  });
  final Drill drill;
  final int? sourceIndex;
  int sets, work, rest;
  IntRange setRange, workRange;
  final IntRange restRange;
  List<_DraftItem> parts;
  _DraftItem copy() => _DraftItem(
    drill,
    sets,
    work,
    rest,
    setRange,
    workRange,
    restRange,
    sourceIndex: sourceIndex,
    parts: [for (final part in parts) part.copy()],
  );
  PlanItem toPlanItem() => PlanItem(
    exerciseId: drill.id,
    mode: drill.defaultDose.mode,
    sets: sets,
    reps: drill.defaultDose.mode == DoseMode.reps ? work : null,
    workSeconds: drill.defaultDose.mode == DoseMode.time ? work : null,
    perSide: drill.unilateral,
    restSeconds: rest,
  );
}

class _DraftBlock {
  _DraftBlock(
    this.id,
    this.kind,
    this.rounds,
    this.items, {
    required this.roundsRange,
    required this.roundRestRange,
    this.roundRest = 0,
  });
  final String id, kind;
  int rounds;
  IntRange roundsRange;
  final IntRange roundRestRange;
  int roundRest;
  final List<_DraftItem> items;
  _DraftBlock cloneWithout(Set<String> excluded) => _DraftBlock(
    id,
    kind,
    rounds,
    [
      for (final item in items)
        if (!excluded.contains(item.drill.id)) item.copy(),
    ],
    roundsRange: roundsRange,
    roundRestRange: roundRestRange,
    roundRest: roundRest,
  );
  PlanBlock toBlock() => PlanBlock(
    id: id,
    name: kind,
    type: BlockType.values.firstWhere((t) => t.name == kind),
    rounds: rounds,
    restBetweenRoundsSeconds: roundRest,
    items: [for (final item in items) item.toPlanItem()],
  );
}
