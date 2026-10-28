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
    this.warningDetails = const [],
    this.notes = const [],
    this.changes = const [],
  });
  final CoachSessionState state;
  final Map<String, Object?>? error;
  final List<Map<String, Object?>> errors;
  final Map<String, Object?> rules;
  final List<String> warnings;
  final List<Map<String, Object?>> warningDetails;
  final List<String> notes;
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
        if (warningDetails.isNotEmpty) 'warningDetails': warningDetails,
        if (notes.isNotEmpty) 'notes': notes,
      };
    }
    return {
      'ok': true,
      'summary': warnings.isEmpty ? '计划检查通过。' : '计划检查通过，建议见 warning。',
      if (warnings.isNotEmpty) 'warnings': warnings,
      if (warningDetails.isNotEmpty) 'warningDetails': warningDetails,
      if (notes.isNotEmpty) 'notes': notes,
    };
  }
}

class PlanChecker {
  PlanChecker(
    this.profile,
    this.catalog, {
    required int minPicks,
    this.extraRules = const [],
    this.enforceDrillDoseRange = false,
  }) : gate = NodeGates(profile, catalog, minPicks: minPicks);
  final CoachProfile profile;
  final Catalog catalog;
  final NodeGates gate;
  final List<PlanRule> extraRules;
  final bool enforceDrillDoseRange;

  PlanCheckResult check(CoachSessionState state, String planId) =>
      _check(state, planId, enforceNodeOrder: true);

  /// Checks a host-selected template with the same data rules. This does not
  /// complete, synthesize or reorder the model's task nodes.
  PlanCheckResult validateTemplate(CoachSessionState state, TrainingPlan plan) {
    final candidate = CoachPlanVersion(
      version: 1,
      plan: plan.toJson(),
      estimateSec: const PlanDuration().estimateSeconds(plan, catalog),
      fitLog: const [],
    );
    return _check(
      state.copyWith(
        activePlanId: plan.id,
        plans: {
          ...state.plans,
          plan.id: [candidate],
        },
      ),
      plan.id,
      enforceNodeOrder: false,
    );
  }

  PlanCheckResult _check(
    CoachSessionState state,
    String planId, {
    required bool enforceNodeOrder,
  }) {
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
        createdAtTurn: version.createdAtTurn,
        operation: version.operation,
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
    var plan = decoded.plan!;
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
        ['minutes', 'goal'],
        [
          if (minutes is! int || minutes <= 0) 'minutes',
          if (goalValue is! List ||
              goalValue.isEmpty ||
              goalValue.any((g) => g is! String))
            'goal',
        ],
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
    final equipment = gate.effectiveEquipment(state);
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
    final allWarningDetails = <Map<String, Object?>>[];
    final newWarningDetails = <Map<String, Object?>>[];
    final emitted = {...state.emittedWarningCodes};
    void advisory(
      String code,
      String message,
      Object? expected,
      Object? actual, {
      bool applicable = true,
    }) {
      rules[code.startsWith('plan_') ? code.substring(5) : code] = {
        'ok': true,
        'severity': 'warning',
        'applicable': applicable,
        'expected': expected,
        'actual': actual,
      };
      if (!applicable) return;
      final detail = <String, Object?>{
        'code': code,
        'message': message,
        'expected': expected,
        'actual': actual,
      };
      allWarningDetails.add(detail);
      warnings.add(message);
      if (emitted.add(code)) newWarningDetails.add(detail);
    }

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
    final correctedConditions =
        declared.length != usedEquipment.length ||
        !declared.containsAll(usedEquipment);
    if (correctedConditions) {
      plan = const PlanCodec().decode({
        ...plan.toJson(),
        'equipment': usedEquipment.toList()..sort(),
      });
    }
    rules['card_conditions'] = {
      'ok': true,
      'normalized': correctedConditions,
      'expected': {
        'targetMinutes': minutes,
        'equipment': usedEquipment.toList()..sort(),
      },
      'actual': {
        'targetMinutes': plan.targetMinutes,
        'equipment': plan.equipment,
      },
    };
    final seconds = const PlanDuration().estimateSeconds(plan, catalog);
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
    advisory(
      'plan_structure',
      '可结合本次目标考虑热身和收尾；当前分组不作为交付门槛。',
      {'warmup': needWarmup, 'cooldown': needCooldown},
      {'warmup': hasWarmup, 'cooldown': hasCooldown},
      applicable: (needWarmup && !hasWarmup) || (needCooldown && !hasCooldown),
    );

    const preparationPurposes = {
      'purpose.stretch',
      'purpose.mobility',
      'purpose.breath',
      'purpose.activation',
    };
    final invalidPreparation = <Map<String, Object?>>[
      for (final entry in entries)
        if ({
              BlockType.warmup,
              BlockType.cooldown,
            }.contains(plan.blocks[entry.block].type) &&
            gate.tags
                .forActionId(entry.id)
                .intersection(preparationPurposes)
                .isEmpty)
          {
            'block': entry.block,
            'kind': plan.blocks[entry.block].type.name,
            'id': entry.id,
            'purposes': gate.tags
                .forActionId(entry.id)
                .where((code) => code.startsWith('purpose.'))
                .toList(),
          },
    ];
    advisory(
      'plan_block_purpose',
      '部分热身或收尾动作的目录用途不典型，可结合目标与低剂量使用；这不代表存在已知安全冲突。',
      {'warmup/cooldown': preparationPurposes.toList()},
      invalidPreparation,
      applicable: invalidPreparation.isNotEmpty,
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
      final expanded = gate.tags.expandCodes(group);
      final matched = main
          .where(
            (item) => gate.tags
                .forActionId(item.id)
                .intersection(expanded)
                .isNotEmpty,
          )
          .length;
      final ratio = main.isEmpty ? 0.0 : matched / main.length;
      final threshold = name == 'body' && settings.focusRatio < .5
          ? .5
          : settings.focusRatio;
      result(
        'focus_$name',
        main.isNotEmpty && ratio >= threshold,
        'main ≥ ${(threshold * 100).toStringAsFixed(0)}% 含 ${group.join('、')}',
        '$matched/${main.length}',
        '替换主体动作为目标组的合规候选动作。',
        alternatives: candidates(match: expanded),
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

    // Alternation is an advisory for multi-region work, never a reason to
    // change a focused action selection or count preparation as main work.
    final singleBodyGoal =
        body.length == 1 ||
        profile.bodyGroups.values.any(
          (children) => children.toSet().containsAll(body),
        );
    final balanceApplicable = body.isNotEmpty
        ? !singleBodyGoal
        : plan.goal == 'fullbody' && purpose.contains('purpose.strength');
    String? previousBody;
    var streak = 0, longest = 0;
    for (final entry in main) {
      final primary = catalog[entry.id]?.muscleGroups.firstOrNull;
      if (primary == null) {
        previousBody = null;
        streak = 0;
        continue;
      }
      streak = previousBody == primary ? streak + 1 : 1;
      previousBody = primary;
      if (streak > longest) longest = streak;
    }
    advisory(
      'plan_balance_sequence',
      '多部位训练可考虑交替主体动作；本次保留已选动作与代码排序。',
      settings.maxSameMuscleInRow,
      longest,
      applicable: balanceApplicable && longest > settings.maxSameMuscleInRow,
    );
    final tags = <String>{
      for (final entry in main) ...gate.tags.forActionId(entry.id),
    };
    final missingPairs = [
      for (final pair in settings.antagonisticPairs)
        if (!pair.first.any(tags.contains) || !pair.second.any(tags.contains))
          {'first': pair.first, 'second': pair.second},
    ];
    advisory(
      'plan_balance_antagonists',
      '多部位训练可考虑相关拮抗部位覆盖；不改变本次确认目标。',
      settings.antagonisticPairs.length,
      missingPairs,
      applicable: balanceApplicable && missingPairs.isNotEmpty,
    );

    rules['balance'] = {
      'ok': true,
      'severity': 'warning',
      'applicable': balanceApplicable,
      'actual': {'longest': longest, 'missingPairs': missingPairs},
      'expected': {'maxSameMuscleInRow': settings.maxSameMuscleInRow},
    };

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
      extraRules: extraRules,
      enforceDrillDoseRange: enforceDrillDoseRange,
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
      if (allWarningDetails.isNotEmpty) 'warningDetails': allWarningDetails,
    };
    final saved = CoachPlanVersion(
      version: version.version,
      plan: plan.toJson(),
      estimateSec: seconds,
      fitLog: version.fitLog,
      createdAtTurn: version.createdAtTurn,
      operation: version.operation,
      check: check,
    );
    var next = state.copyWith(
      emittedWarningCodes: emitted,
      plans: {
        ...state.plans,
        planId: [...versions.take(versions.length - 1), saved],
      },
    );
    final changes = <CoachNodeState>[];
    if (errors.isNotEmpty && enforceNodeOrder && next.task?.type == 'plan') {
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
      warnings: List.unmodifiable([
        ...warnings.where(
          (text) =>
              !allWarningDetails.any((detail) => detail['message'] == text),
        ),
        for (final detail in newWarningDetails) detail['message'] as String,
      ]),
      warningDetails: List.unmodifiable(newWarningDetails),
      notes: correctedConditions ? ['已从实际动作同步卡片器械字段。'] : const [],
      changes: List.unmodifiable(changes),
    );
  }
}
