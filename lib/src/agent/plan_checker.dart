/// Structured checks for the current version of a drafted plan.
library;

import '../catalog/catalog.dart';
import '../plan/coach_context.dart';
import '../plan/plan_codec.dart';
import '../plan/plan_validator.dart';
import '../plan/training_plan.dart';
import '../profile/coach_profile.dart';
import 'agent_task.dart';
import 'node_gates.dart';
import 'session_state.dart';

class PlanCheckResult {
  const PlanCheckResult(
    this.state, {
    this.error,
    this.errors = const [],
    this.rules = const {},
    this.warnings = const [],
    this.changes = const [],
  });
  final CoachSessionState state;
  final Map<String, Object?>? error;
  final List<Map<String, Object?>> errors;
  final Map<String, Object?> rules;
  final List<String> warnings;
  final List<CoachNodeState> changes;
  bool get ok => error == null && errors.isEmpty;
  Map<String, Object?> toJson() {
    if (error != null) return error!;
    if (errors.isNotEmpty) {
      return {
        ...nodeError(
          'plan_check_failed',
          'plan_id',
          '计划各项检查通过',
          '${errors.length} 项未通过',
          '按各项 fix 修改计划，再重新核对。',
        ),
        'errors': errors,
        if (warnings.isNotEmpty) 'warnings': warnings,
      };
    }
    return {
      'ok': true,
      'summary': warnings.isEmpty ? '计划检查通过。' : '计划检查通过；部分限制缺少目录依据。',
      if (warnings.isNotEmpty) 'warnings': warnings,
    };
  }
}

class PlanChecker {
  PlanChecker(this.profile, this.catalog, {required int minPicks})
    : gate = NodeGates(profile, catalog, minPicks: minPicks);
  final CoachProfile profile;
  final Catalog catalog;
  final NodeGates gate;

  PlanCheckResult check(CoachSessionState state, String planId) {
    PlanCheckResult fail(
      String code,
      String field,
      Object? expected,
      Object? actual,
      String fix,
    ) => PlanCheckResult(
      state,
      error: nodeError(code, field, expected, actual, fix),
    );
    final current = state.task?.nodes
        .where((n) => n.status == 'current')
        .firstOrNull;
    if (state.task?.type != 'plan' || current?.id != 'review') {
      return fail(
        'wrong_node',
        'node',
        'review',
        current?.id,
        '先完成 planning 节点，再核对计划。',
      );
    }
    final currentId =
        state.activePlanId ??
        (state.legacyPlanFallback && state.plans.length == 1
            ? state.plans.keys.single
            : null);
    if (currentId != planId || state.plans[planId]?.isNotEmpty != true) {
      return fail(
        'invalid_plan_id',
        'plan_id',
        currentId ?? '当前计划 ID',
        planId,
        '核对当前计划的最新版本。',
      );
    }
    final versions = state.plans[planId]!;
    final version = versions.last;
    PlanCheckResult invalidate(
      String code,
      String field,
      Object? expected,
      Object? actual,
      String fix,
    ) {
      final error = nodeError(code, field, expected, actual, fix);
      final invalid = CoachPlanVersion(
        version: version.version,
        plan: version.plan,
        estimateSec: version.estimateSec,
        fitLog: version.fitLog,
        check: {
          'ok': false,
          'errors': [error],
        },
      );
      return PlanCheckResult(
        state.copyWith(
          plans: {
            ...state.plans,
            planId: [...versions.take(versions.length - 1), invalid],
          },
        ),
        error: error,
      );
    }

    final decoded = const PlanCodec().decodeStrict(version.plan);
    if (!decoded.ok) {
      return invalidate(
        'invalid_plan',
        'plan',
        '可解析的计划卡',
        decoded.issues.map((i) => i.message).toList(),
        '修复计划结构后重新生成草稿。',
      );
    }
    final plan = decoded.plan!;
    final params = state.params;
    final minutes = params['minutes']?.value;
    final goalValue = params['goal']?.value;
    if (minutes is! int ||
        minutes <= 0 ||
        goalValue is! List ||
        goalValue.isEmpty ||
        goalValue.any((g) => g is! String)) {
      return invalidate(
        'missing_parameters',
        'params',
        '正整数 minutes 和非空 goal',
        params.keys.toList(),
        '补齐计划时长和目标后重新核对。',
      );
    }
    final settings = profile.planRules;
    if (!settings.focusRatio.isFinite ||
        settings.focusRatio < 0 ||
        settings.focusRatio > 1 ||
        settings.warmupFromMinutes < 0 ||
        settings.cooldownFromMinutes < 0 ||
        settings.maxSameMuscleInRow <= 0 ||
        settings.antagonisticPairs.any(
          (pair) =>
              pair.first.isEmpty ||
              pair.second.isEmpty ||
              [
                ...pair.first,
                ...pair.second,
              ].any((code) => !code.startsWith('body.') || code.length <= 5),
        )) {
      return invalidate(
        'invalid_plan_rules',
        'profile.planRules',
        'focusRatio 0..1、非负时长阈值、正数连续上限及非空 body.* 拮抗对',
        settings.toJson(),
        '修正 profile.planRules 后重新核对。',
      );
    }
    final goals = goalValue.cast<String>();
    final equipment = (params['equipment']?.value as List<Object?>? ?? const [])
        .cast<String>()
        .toSet();
    final limits = (params['limits']?.value as List<Object?>? ?? const [])
        .cast<String>()
        .toSet();
    final canonicalLimits = limits
        .map((v) => gate.tags.canonicalLimitCode(v) ?? v)
        .toSet();
    final rules = <String, Object?>{};
    final errors = <Map<String, Object?>>[];
    final warnings = <String>[
      for (final code
          in (state.hostValues['limitsOpaque'] as List<Object?>? ?? const [])
              .cast<String>())
        '目录缺少限制 ${gate.tags.limitValue(code) ?? code} 的可核对禁忌，不能确认其安全性。',
    ];
    final entries = <({String id, int block})>[
      for (var bi = 0; bi < plan.blocks.length; bi++)
        for (final item in plan.blocks[bi].items)
          if (item.segments.isEmpty)
            (id: item.exerciseId, block: bi)
          else
            for (final segment in item.segments)
              (id: segment.exerciseId, block: bi),
    ];
    final planIds = {for (final entry in entries) entry.id};
    List<String> candidates({Set<String>? match}) => [
      for (final id in state.seenActionIds)
        if (!planIds.contains(id) &&
            gate.actionProblem(state, id) == null &&
            (match == null ||
                gate.tags.forActionId(id).intersection(match).isNotEmpty))
          id,
    ];
    void result(
      String key,
      bool ok,
      Object? expected,
      Object? actual,
      String fix, {
      List<String>? alternatives,
    }) {
      rules[key] = {'ok': ok, 'expected': expected, 'actual': actual};
      if (!ok) {
        errors.add({
          ...nodeError('plan_$key', key, expected, actual, fix),
          'candidates': alternatives ?? candidates(),
        });
      }
    }

    final missing = <String>{};
    final usedEquipment = <String>{};
    final unsafe = <String, List<String>>{};
    final unavailable = <String>{};
    for (final entry in entries) {
      final drill = catalog[entry.id];
      if (drill == null || !profile.select.matches(drill)) {
        unavailable.add(entry.id);
        continue;
      }
      for (final raw in drill.equipment) {
        if (raw == 'none') continue;
        usedEquipment.add(raw);
        final code = gate.tags.equipmentCode(raw);
        if (code == null || !equipment.contains(code)) missing.add(code ?? raw);
      }
      final conflicts = [
        for (final raw in [...drill.cautions, ...drill.contraindications])
          if (canonicalLimits.contains(gate.tags.canonicalLimitCode(raw))) raw,
      ];
      if (conflicts.isNotEmpty) unsafe[drill.id] = conflicts;
      final semantics = drill.raw['trainingSemantics'];
      if (semantics is Map && semantics['unknownFields'] is List) {
        for (final item in semantics['unknownFields'] as List) {
          if (item is Map && item['field'] is String) {
            warnings.add('${drill.id} 的 ${item['field']} 尚未明确，不能视为已验证。');
          }
        }
      }
    }
    result('safety', unsafe.isEmpty && unavailable.isEmpty, '所有动作在范围内且不触发限制', {
      'conflicts': unsafe,
      'unavailable': unavailable.toList(),
    }, '替换不在范围或触及伤痛限制的动作。');
    result(
      'equipment',
      missing.isEmpty,
      equipment.toList(),
      missing.toList(),
      '替换需要未确认器材的动作。',
    );
    final declared = plan.equipment.toSet();
    result(
      'card_conditions',
      plan.targetMinutes == minutes &&
          declared.length == usedEquipment.length &&
          declared.containsAll(usedEquipment),
      {'targetMinutes': minutes, 'equipment': usedEquipment.toList()..sort()},
      {
        'targetMinutes': plan.targetMinutes,
        'equipment': declared.toList()..sort(),
      },
      '重新生成计划，使卡片时长与用户条件一致、器材与实际动作一致。',
    );
    final seconds = const PlanDuration().estimateSeconds(plan, catalog);
    final target = minutes * 60;
    result(
      'duration',
      (seconds - target).abs() <= target * .1,
      '$target 秒 ±10%',
      seconds,
      '调整动作、组数或轮数，使估时接近目标。',
    );

    final purpose = goals.where((v) => v.startsWith('purpose.')).toSet();
    final body = goals.where((v) => v.startsWith('body.')).toSet();
    final pureStretch =
        purpose.length == 1 && purpose.contains('purpose.stretch');
    final needWarmup =
        minutes >= settings.warmupFromMinutes &&
        !(settings.exemptWarmupForPureStretch && pureStretch);
    final needCooldown = minutes >= settings.cooldownFromMinutes;
    final hasWarmup = plan.blocks.any(
      (b) => b.type == BlockType.warmup && b.items.isNotEmpty,
    );
    final hasCooldown = plan.blocks.any(
      (b) => b.type == BlockType.cooldown && b.items.isNotEmpty,
    );
    result(
      'structure',
      (!needWarmup || hasWarmup) && (!needCooldown || hasCooldown),
      {'warmup': needWarmup, 'cooldown': needCooldown},
      {'warmup': hasWarmup, 'cooldown': hasCooldown},
      '根据时长添加缺少的热身或收尾块。',
    );

    final main = entries
        .where(
          (entry) =>
              plan.blocks[entry.block].type == BlockType.main ||
              plan.blocks[entry.block].type == BlockType.circuit,
        )
        .toList();
    void focus(String name, Set<String> group) {
      if (group.isEmpty) return;
      final matched = main
          .where(
            (item) =>
                gate.tags.forActionId(item.id).intersection(group).isNotEmpty,
          )
          .length;
      final ratio = main.isEmpty ? 0.0 : matched / main.length;
      result(
        'focus_$name',
        main.isNotEmpty && ratio >= settings.focusRatio,
        'main ≥ ${(settings.focusRatio * 100).toStringAsFixed(0)}% 含 ${group.join('、')}',
        '$matched/${main.length}',
        '替换主体动作为目标组的合规候选动作。',
        alternatives: candidates(match: group),
      );
    }

    focus('body', body);
    focus('purpose', purpose);
    if (body.isEmpty && purpose.isEmpty) {
      result(
        'focus',
        false,
        '非空 body.* 或 purpose.* 目标',
        goals,
        '先设置目录中的结构化目标。',
      );
    }

    final duplicate = <String>[];
    for (var i = 0; i < plan.blocks.length; i++) {
      final seen = <String>{};
      for (final e in entries.where((e) => e.block == i)) {
        if (!seen.add(e.id)) duplicate.add('${i + 1}:${e.id}');
      }
    }
    String? previousBody;
    var streak = 0, longest = 0;
    for (final entry in entries) {
      final drill = catalog[entry.id];
      final primary = drill?.muscleGroups.firstOrNull;
      if (primary == null) {
        previousBody = null;
        streak = 0;
        continue;
      }
      streak = previousBody == primary ? streak + 1 : 1;
      previousBody = primary;
      if (streak > longest) longest = streak;
    }
    final missingPairs = <Object>[];
    final tags = <String>{
      for (final entry in entries) ...gate.tags.forActionId(entry.id),
    };
    for (final pair in settings.antagonisticPairs) {
      if (!pair.first.any(tags.contains) || !pair.second.any(tags.contains)) {
        missingPairs.add({'first': pair.first, 'second': pair.second});
      }
    }
    result(
      'balance',
      duplicate.isEmpty &&
          longest <= settings.maxSameMuscleInRow &&
          missingPairs.isEmpty,
      {
        'maxSameMuscleInRow': settings.maxSameMuscleInRow,
        'duplicates': 0,
        'antagonisticPairs': '两侧均有',
      },
      {
        'longest': longest,
        'duplicates': duplicate,
        'missingPairs': missingPairs,
      },
      '调整顺序、去除同块重复动作，并补齐缺少的拮抗部位。',
    );

    // Existing card validation still enforces structural and dose safety.
    final context = CoachContext(
      scene: params['scene']?.value as String?,
      equipment: {for (final code in equipment) ?gate.tags.equipmentId(code)},
      avoid: {for (final code in limits) gate.tags.limitValue(code) ?? code},
      level: params['level']?.value as int?,
      minutes: minutes,
    );
    final legacy = PlanValidator(
      catalog: catalog,
      profile: profile,
    ).validate(plan, context);
    final hard = legacy.errors;
    for (final issue in hard) {
      final field = issue.path ?? 'plan';
      errors.add({
        ...nodeError(
          issue.code,
          field,
          issue.expected ?? issue.message,
          issue.actual ?? issue.exerciseId ?? issue.message,
          issue.fix ?? '调整 $field：${issue.message}。',
        ),
        'candidates': candidates(),
      });
    }
    rules['legacy'] = {
      'ok': hard.isEmpty,
      'expected': '旧计划结构和安全约束通过',
      'actual': hard.map((e) => e.code).toList(),
    };

    final check = {
      'ok': errors.isEmpty,
      'errors': errors,
      'rules': rules,
      if (warnings.isNotEmpty) 'warnings': warnings,
    };
    final saved = CoachPlanVersion(
      version: version.version,
      plan: version.plan,
      estimateSec: seconds,
      fitLog: version.fitLog,
      check: check,
    );
    var next = state.copyWith(
      plans: {
        ...state.plans,
        planId: [...versions.take(versions.length - 1), saved],
      },
    );
    final changes = <CoachNodeState>[];
    if (errors.isNotEmpty) {
      final task = next.task!;
      final nodes = List<CoachNodeState>.of(task.nodes);
      final planning = nodes.indexWhere((node) => node.id == 'planning');
      final review = nodes.indexWhere((node) => node.id == 'review');
      if (planning >= 0 && review >= 0) {
        for (final index in [planning, review]) {
          nodes[index] = nodes[index].copyWith(
            status: index == planning ? 'current' : 'pending',
            clearStamp: true,
            clearDoneAtTurn: true,
          );
          changes.add(nodes[index]);
        }
        next = next.copyWith(task: task.copyWith(nodes: nodes));
      }
    }
    return PlanCheckResult(
      next,
      errors: List.unmodifiable(errors),
      rules: Map.unmodifiable(rules),
      warnings: List.unmodifiable(warnings),
      changes: List.unmodifiable(changes),
    );
  }
}
