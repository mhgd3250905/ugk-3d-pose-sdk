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
    if (confirmedOperation?.turn == currentTurn &&
        {'edit', 'replace_all'}.contains(confirmedOperation?.value)) {
      suppliedOperation = confirmedOperation!.value;
    }
    final deliveredId = state.lastDeliveredPlanId;
    final deliveredVersion = state.lastDeliveredVersion;
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
                (state.activePlanId == deliveredId ||
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
      final confirmed = confirmedOperation?.turn == currentTurn;
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
      final rounds = kind == 'main'
          ? 1.clamp(profile.limits.rounds.min, profile.limits.rounds.max)
          : 1;
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
          _DraftItem(drill, sets, work, rest, setsRange, workRange, restRange),
        );
      }
      final grouped = <_DraftItem>[];
      for (final item in items) {
        final existing = grouped
            .where((v) => v.drill.id == item.drill.id)
            .firstOrNull;
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
      _stableMainOrder(block);
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
    if (blocks.isEmpty) {
      return DraftResult(
        state,
        notes: notes,
        feasibility: {
          'status': 'infeasible',
          'reason': 'no_selected_actions',
          'fix': language.toLowerCase().startsWith('en')
              ? 'No actions were selected. Explain that the current conditions have no plan or ask whether to adjust them.'
              : '当前没有已选动作，请说明无法生成计划或询问是否调整条件，不要反复提交空计划。',
        },
      );
    }
    final target = minutes * 60.0;
    final legacyGoal = resolveLegacyGoal(
      profile,
      goals.cast<String>(),
      blocks.map((b) => b.kind),
    );
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
    if (conflicts.isNotEmpty || bounds['status'] == 'infeasible') {
      return DraftResult(
        state,
        notes: notes,
        feasibility: {
          ...bounds,
          if (conflicts.isNotEmpty) ...{
            'status': 'infeasible',
            'reason': 'explicit_dose_conflict',
            'conflicts': conflicts,
          },
          'fix': language.toLowerCase().startsWith('en')
              ? 'Explain the conflict and ask which confirmed condition the user wants to adjust.'
              : '请说明已确认条件的冲突，询问用户愿意调整时长还是剂量；不要反复提交同一条件。',
        },
      );
    }
    _fit(blocks, target, estimate, log);
    final plan = asPlan(blocks);
    final seconds = _duration.estimateSeconds(plan, catalog);
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

  void _fit(
    List<_DraftBlock> blocks,
    double target,
    double Function(List<_DraftBlock>) estimate,
    List<Map<String, Object?>> log,
  ) {
    final initialSeconds = estimate(blocks);
    if ((initialSeconds - target).abs() <= target * .1) return;
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
      List<Map<String, Object?>> changes,
    ) {
      var current = estimate(candidate);
      void saveIfBetter() {
        if ((current - target).abs() < (chosenSeconds - target).abs()) {
          chosen = copy(candidate);
          chosenSeconds = current;
          chosenLog = List.of(changes);
        }
      }

      saveIfBetter();
      for (var stage = startStage; stage < 4; stage++) {
        if ((current - target).abs() <= target * .05) break;
        final direction = current < target ? 1 : -1;
        while ((current - target).abs() > target * .05) {
          final edits = <_Edit>[];
          for (final block in candidate) {
            if (stage == 0 && block.kind == 'main') {
              if (block.rounds + direction >= 1 &&
                  block.rounds + direction <= 4 &&
                  block.roundsRange.contains(block.rounds + direction)) {
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
              if (stage == 1 &&
                  block.kind == 'main' &&
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
                      (stage == 3 &&
                          block.kind != 'main' &&
                          item.drill.defaultDose.mode == DoseMode.time)) &&
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
            }
          }
          _Edit? best;
          var bestSeconds = double.infinity;
          for (final edit in edits) {
            final old = edit.get();
            edit.set(old + direction);
            final value = estimate(candidate);
            edit.set(old);
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

    attempt(copy(initial), 0, []);
    // Explore alternatives for each main block independently, followed by the
    // same ordered later stages. This is bounded by four times the block count.
    // It does not claim a global optimum across multiple blocks.
    for (
      var i = 0;
      i < initial.length && (chosenSeconds - target).abs() > target * .05;
      i++
    ) {
      if (initial[i].kind != 'main') continue;
      for (
        var rounds = 1;
        rounds <= 4 && (chosenSeconds - target).abs() > target * .05;
        rounds++
      ) {
        if (rounds == initial[i].rounds ||
            !initial[i].roundsRange.contains(rounds)) {
          continue;
        }
        final candidate = copy(initial);
        candidate[i].rounds = rounds;
        attempt(candidate, 1, [
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
    this.restRange,
  );
  final Drill drill;
  int sets, work, rest;
  IntRange setRange, workRange;
  final IntRange restRange;
  _DraftItem copy() =>
      _DraftItem(drill, sets, work, rest, setRange, workRange, restRange);
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
