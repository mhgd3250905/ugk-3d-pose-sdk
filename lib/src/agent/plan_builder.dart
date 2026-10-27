/// Build a versioned draft from structured model choices and catalogue doses.
library;

import 'dart:math' as math;

import '../catalog/catalog.dart';
import '../plan/training_plan.dart';
import '../profile/coach_profile.dart';
import 'agent_task.dart';
import 'legacy_goal.dart';
import 'node_gates.dart';
import 'session_state.dart';

class DraftResult {
  const DraftResult(
    this.state, {
    this.planId,
    this.version,
    this.estimateMinutes,
    this.structure = const [],
    this.fitLog = const [],
    this.legacyGoal,
    this.error,
  });
  final CoachSessionState state;
  final String? planId;
  final int? version;
  final double? estimateMinutes;
  final List<Map<String, Object?>> structure;
  final List<String> fitLog;
  final String? legacyGoal;
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
    if (scene is! String ||
        minutes is! int ||
        minutes <= 0 ||
        goals is! List ||
        goals.isEmpty ||
        goals.any((x) => x is! String)) {
      return fail(
        'missing_parameters',
        'params',
        'scene、非空 goal、正整数 minutes',
        state.params.keys.toList(),
        '先完成参数节点并补齐计划条件。',
      );
    }
    final task = state.task;
    final current = task?.nodes
        .where((node) => node.status == 'current')
        .firstOrNull;
    if (task?.type != 'plan' || current?.id != 'planning') {
      return fail(
        'wrong_node',
        'node',
        'planning',
        current?.id,
        '先完成当前计划节点，然后在 planning 节点创建草稿。',
      );
    }
    final title = arguments['title'];
    final rawBlocks = arguments['blocks'];
    final suppliedId = arguments['plan_id'];
    if (arguments.keys.any(
          (k) => !{'plan_id', 'title', 'blocks'}.contains(k),
        ) ||
        title is! String ||
        title.trim().isEmpty ||
        rawBlocks is! List ||
        rawBlocks.isEmpty ||
        (suppliedId != null && (suppliedId is! String || suppliedId.isEmpty))) {
      return fail(
        'invalid_draft',
        'draft_plan',
        'title、非空 blocks、可选已有 plan_id',
        arguments,
        '提供计划标题、结构和可选的已有计划 ID。',
      );
    }
    final id = suppliedId as String? ?? newPlanId;
    if ((suppliedId != null && !state.plans.containsKey(id)) ||
        (suppliedId == null && (id.isEmpty || state.plans.containsKey(id)))) {
      return fail(
        'invalid_plan_id',
        'plan_id',
        suppliedId == null ? '未使用的新计划 ID' : '已有计划 ID',
        id,
        '传入已有计划 ID，或生成未使用的新计划 ID。',
      );
    }
    final log = <String>[];
    final blocks = <_DraftBlock>[];
    final extras = <String>{};
    for (var bi = 0; bi < rawBlocks.length; bi++) {
      final raw = rawBlocks[bi];
      if (raw is! Map ||
          raw.keys.any((k) => !{'kind', 'rounds', 'items'}.contains(k)) ||
          !{'warmup', 'main', 'cooldown'}.contains(raw['kind']) ||
          raw['items'] is! List ||
          (raw['items'] as List).isEmpty ||
          (raw['rounds'] != null && raw['rounds'] is! int)) {
        return fail(
          'invalid_block',
          'blocks[$bi]',
          'kind、非空 items、可选整数 rounds',
          raw,
          '提供 warmup、main 或 cooldown 块和动作。',
        );
      }
      final kind = raw['kind'] as String;
      final inputRounds = (raw['rounds'] as int?) ?? 1;
      final rounds = inputRounds.clamp(1, 4);
      if (rounds != inputRounds) log.add('$kind 轮数从 $inputRounds 夹到 $rounds');
      final items = <_DraftItem>[];
      for (var ii = 0; ii < (raw['items'] as List).length; ii++) {
        final item = (raw['items'] as List)[ii];
        if (item is! Map ||
            item.keys.any(
              (k) => !{'id', 'sets', 'reps', 'seconds'}.contains(k),
            ) ||
            item['id'] is! String ||
            [
              'sets',
              'reps',
              'seconds',
            ].any((k) => item[k] != null && item[k] is! int)) {
          return fail(
            'invalid_item',
            'blocks[$bi].items[$ii]',
            'id 和可选整数剂量',
            item,
            '提供动作 ID 和整数剂量。',
          );
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
            '选择已搜索并符合当前条件的动作。',
          );
        }
        if (!state.picks.contains(actionId)) extras.add(actionId);
        if ((drill.defaultDose.mode == DoseMode.reps &&
                item.containsKey('seconds')) ||
            (drill.defaultDose.mode == DoseMode.time &&
                item.containsKey('reps'))) {
          return fail(
            'invalid_dose_mode',
            'blocks[$bi].items[$ii]',
            drill.defaultDose.mode.name,
            item,
            '按目录的计次或计时模式提供剂量。',
          );
        }
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
        final requestedSets = (item['sets'] as int?) ?? drill.defaultDose.sets;
        final requestedWork =
            (drill.defaultDose.mode == DoseMode.reps
                ? item['reps'] as int?
                : item['seconds'] as int?) ??
            (drill.defaultDose.mode == DoseMode.reps
                ? drill.defaultDose.reps
                : drill.defaultDose.seconds) ??
            workRange.min;
        final sets = requestedSets.clamp(setsRange.min, setsRange.max);
        final work = requestedWork.clamp(workRange.min, workRange.max);
        if (sets != requestedSets) {
          log.add('$actionId 组数从 $requestedSets 夹到 $sets');
        }
        if (work != requestedWork) {
          log.add('$actionId 剂量从 $requestedWork 夹到 $work');
        }
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
        if (rest != drill.defaultDose.restSeconds) {
          log.add('$actionId 休息从 ${drill.defaultDose.restSeconds} 秒夹到 $rest 秒');
        }
        items.add(_DraftItem(drill, sets, work, rest, setsRange, workRange));
      }
      blocks.add(_DraftBlock(kind, rounds, items));
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
        blocks: [
          for (var bi = 0; bi < source.length; bi++) source[bi].toBlock(bi),
        ],
      );
    }

    double estimate(List<_DraftBlock> source) =>
        _duration.estimateSeconds(asPlan(source), catalog);
    if (extras.isNotEmpty) {
      final baseline = [
        for (final b in blocks)
          if (b.items.any((i) => !extras.contains(i.drill.id)))
            b.cloneWithout(extras),
      ];
      _fit(baseline, target, estimate, <String>[]);
      if (estimate(baseline) >= target * .9) {
        return fail(
          'extra_actions_not_needed',
          'blocks.items.id',
          '仅时长不足时可加入已搜索的其他动作',
          extras.toList(),
          '只使用 picks；或在配时仍不足时加入已搜索动作。',
        );
      }
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
    );
    final next = state.copyWith(
      plans: {
        ...state.plans,
        id: [...previous, saved],
      },
      activePlanId: id,
    );
    final structure = [
      for (final b in blocks)
        {'kind': b.kind, 'rounds': b.rounds, 'items': b.items.length},
    ];
    Map<String, Object?>? error;
    if ((seconds - target).abs() > target * .1) {
      final count = blocks.fold<int>(0, (sum, b) => sum + b.items.length);
      final mean = count == 0 ? target : seconds / count;
      final change = ((target - seconds).abs() / mean).ceil();
      final chosen = plan.exerciseIds;
      final candidates = [
        for (final candidate in state.seenActionIds)
          if (!chosen.contains(candidate) &&
              gate.actionProblem(state, candidate) == null)
            candidate,
      ];
      error = {
        ...nodeError(
          'duration_unfit',
          'duration',
          '目标 $minutes 分钟 ±10%',
          '${(seconds - target).round()} 秒',
          seconds < target ? '建议增加约 $change 个动作。' : '建议减少约 $change 个动作。',
        ),
        'candidates': candidates,
      };
    }
    return DraftResult(
      next,
      planId: id,
      version: version,
      estimateMinutes: (seconds / 6).round() / 10,
      structure: List.unmodifiable(structure),
      fitLog: List.unmodifiable(log),
      legacyGoal: legacyGoal,
      error: error,
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
    List<String> log,
  ) {
    final initialSeconds = estimate(blocks);
    if ((initialSeconds - target).abs() <= target * .1) return;
    List<_DraftBlock> copy(List<_DraftBlock> source) => [
      for (final block in source) block.cloneWithout(const {}),
    ];
    final initial = copy(blocks);
    var chosen = copy(blocks);
    var chosenSeconds = initialSeconds;
    var chosenLog = <String>[];

    void attempt(
      List<_DraftBlock> candidate,
      int startStage,
      List<String> changes,
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
                  block.rounds + direction <= 4) {
                edits.add(
                  _Edit('主体轮数', () => block.rounds, (v) => block.rounds = v),
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
                    '${item.drill.id} 组数',
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
                    '${item.drill.id} 剂量',
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
          best.set(before + direction);
          changes.add('${best.label}由 $before 调至 ${best.get()}');
          current = bestSeconds;
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
        if (rounds == initial[i].rounds) continue;
        final candidate = copy(initial);
        candidate[i].rounds = rounds;
        attempt(candidate, 1, ['主体轮数由 ${initial[i].rounds} 调至 $rounds']);
      }
    }
    blocks
      ..clear()
      ..addAll(chosen);
    log.addAll(chosenLog);
  }
}

class _Edit {
  _Edit(this.label, this.get, this.set);
  final String label;
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
  );
  final Drill drill;
  int sets, work;
  final int rest;
  final IntRange setRange, workRange;
  _DraftItem copy() => _DraftItem(drill, sets, work, rest, setRange, workRange);
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
  _DraftBlock(this.kind, this.rounds, this.items);
  final String kind;
  int rounds;
  final List<_DraftItem> items;
  _DraftBlock cloneWithout(Set<String> excluded) => _DraftBlock(kind, rounds, [
    for (final item in items)
      if (!excluded.contains(item.drill.id)) item.copy(),
  ]);
  PlanBlock toBlock(int index) => PlanBlock(
    id: 'b${index + 1}',
    name: kind,
    type: BlockType.values.firstWhere((t) => t.name == kind),
    rounds: rounds,
    items: [for (final item in items) item.toPlanItem()],
  );
}
