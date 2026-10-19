/// TrainingPlan v1 校验器：模板计划、AI 计划、已存计划（目录更新后复核）共用。
///
/// 规则（错误 = 不能用；警告 = 可用但值得注意）：
/// - schemaVersion=1；至少一个块；块非空；动作总数 ≤ limits.maxItems
/// - 块顺序：热身 → 主训练/循环 → 放松
/// - exerciseId 在目录中，且在 profile 范围内
/// - mode 与动作默认剂量的 mode 一致；reps / workSeconds 按 mode 必填
/// - 组数 / 次数 / 时长 / 休息 / 轮数 / 轮间休息：先过全局硬限，再过动作自己的 doseRange
/// - perSide == 动作 unilateral
/// - 器械 ⊆ 可用器械；动作 scenes 接受当前场所；场所禁止的体位（办公室不趴不躺）
/// - 动作 cautions 不含用户要保护的部位（计划 avoid ∪ 本轮 avoid）
/// - goal 在 profile.goals 中
/// - 警告：动作难度高于用户等级 1 级以上；估算时长偏离 targetMinutes；同一块内重复动作
library;

import '../catalog/catalog.dart';
import '../profile/coach_profile.dart';
import 'coach_context.dart';
import 'plan_issue.dart';
import 'training_plan.dart';

class ValidationReport {
  const ValidationReport(this.issues);
  final List<PlanIssue> issues;
  List<PlanIssue> get errors => [for (final i in issues) if (i.isError) i];
  List<PlanIssue> get warnings => [for (final i in issues) if (!i.isError) i];
  bool get ok => errors.isEmpty;
}

/// App 可追加自己的规则。
typedef PlanRule = Iterable<PlanIssue> Function(TrainingPlan plan, Catalog catalog, CoachContext context);

class PlanValidator {
  const PlanValidator({
    required this.catalog,
    required this.profile,
    this.enforceDrillDoseRange = true,
    this.duration = const PlanDuration(),
    this.extraRules = const [],
  });

  final Catalog catalog;
  final CoachProfile profile;

  /// 是否把动作自己的 doseRange 当硬性规则（默认是）。
  final bool enforceDrillDoseRange;
  final PlanDuration duration;
  final List<PlanRule> extraRules;

  ValidationReport validate(TrainingPlan plan, [CoachContext context = const CoachContext()]) {
    final out = <PlanIssue>[];
    void err(String code, String msg, String path, [String? id]) =>
        out.add(PlanIssue(code, msg, path: path, exerciseId: id));
    void warn(String code, String msg, String path, [String? id]) =>
        out.add(PlanIssue.warning(code, msg, path: path, exerciseId: id));

    final lim = profile.limits;
    final scene = context.scene ?? plan.scene;
    final rule = profile.sceneRule(scene);
    final have = context.availableEquipment(profile);
    final avoid = {...plan.avoid, ...context.avoid};
    final level = context.level ?? plan.level;
    final scope = {for (final d in profile.scope(catalog)) d.id};

    if (plan.schemaVersion != planSchemaVersion) {
      err(IssueCodes.schemaVersion, 'schemaVersion 必须为 $planSchemaVersion', 'plan.schemaVersion');
    }
    if (!profile.goals.contains(plan.goal)) {
      err(IssueCodes.goal, 'goal「${plan.goal}」不在可选值 ${profile.goals.join('/')} 中', 'plan.goal');
    }
    if (plan.blocks.isEmpty) err(IssueCodes.emptyPlan, '计划没有任何训练块', 'plan.blocks');
    final count = plan.items.length;
    if (count > lim.maxItems) {
      err(IssueCodes.tooManyItems, '动作项 $count 个，超过上限 ${lim.maxItems}', 'plan.blocks');
    }

    var maxOrder = 0;
    for (var bi = 0; bi < plan.blocks.length; bi++) {
      final b = plan.blocks[bi];
      final bp = 'plan.blocks[$bi]';
      if (b.type.order < maxOrder) {
        err(IssueCodes.blockOrder, '「${b.name}」(${b.type.name}) 排错了位置：应为 热身 → 主训练/循环 → 放松', '$bp.type');
      }
      if (b.type.order > maxOrder) maxOrder = b.type.order;
      if (b.items.isEmpty) err(IssueCodes.emptyBlock, '训练块「${b.name}」为空', '$bp.items');
      if (!lim.rounds.contains(b.rounds)) {
        err(IssueCodes.roundsRange, '「${b.name}」轮数 ${b.rounds} 超出 ${lim.rounds}', '$bp.rounds');
      }
      if (!lim.restBetweenRoundsSeconds.contains(b.restBetweenRoundsSeconds)) {
        err(IssueCodes.restBetweenRoundsRange,
            '「${b.name}」轮间休息 ${b.restBetweenRoundsSeconds} 秒超出 ${lim.restBetweenRoundsSeconds}', '$bp.restBetweenRoundsSeconds');
      }
      final seen = <String>{};
      for (var ii = 0; ii < b.items.length; ii++) {
        final i = b.items[ii];
        final ip = '$bp.items[$ii]';
        final d = catalog[i.exerciseId];
        if (d == null) {
          err(IssueCodes.unknownExercise, '未知动作 ID：${i.exerciseId}（只能用目录表里的 id）', '$ip.exerciseId', i.exerciseId);
          continue;
        }
        final n = '${d.name.of(context.language)}(${d.id})';
        if (!scope.contains(d.id)) {
          err(IssueCodes.outOfProfile, '$n 不在${profile.appName}的动作范围内', '$ip.exerciseId', d.id);
        }
        if (!seen.add(d.id)) warn(IssueCodes.duplicateExercise, '$n 在「${b.name}」里重复出现', ip, d.id);

        if (i.mode != d.defaultDose.mode) {
          final want = d.defaultDose.mode == DoseMode.reps ? 'reps（计次）' : 'time（计时）';
          err(IssueCodes.modeMismatch, '$n 的 mode 应为 $want', '$ip.mode', d.id);
        }
        _range(out, IssueCodes.setsRange, '$n 组数', i.sets, lim.sets, enforceDrillDoseRange ? d.doseRange.sets : null, '$ip.sets', d.id, '');
        if (i.mode == DoseMode.reps) {
          if (i.reps == null) {
            err(IssueCodes.repsRange, '$n 计次动作必须写 reps', '$ip.reps', d.id);
          } else {
            _range(out, IssueCodes.repsRange, '$n 次数', i.reps!, lim.reps, enforceDrillDoseRange ? d.doseRange.reps : null, '$ip.reps', d.id, '');
          }
        } else {
          if (i.workSeconds == null) {
            err(IssueCodes.workSecondsRange, '$n 计时动作必须写 workSeconds', '$ip.workSeconds', d.id);
          } else {
            _range(out, IssueCodes.workSecondsRange, '$n 时长', i.workSeconds!, lim.workSeconds,
                enforceDrillDoseRange ? d.doseRange.seconds : null, '$ip.workSeconds', d.id, ' 秒');
          }
        }
        _range(out, IssueCodes.restRange, '$n 休息', i.restSeconds, lim.restSeconds,
            enforceDrillDoseRange ? d.doseRange.restSeconds : null, '$ip.restSeconds', d.id, ' 秒');

        if (i.perSide != d.unilateral) {
          err(IssueCodes.perSide, '$n 的 perSide 应为 ${d.unilateral}（${d.unilateral ? '单侧动作，左右各做' : '双侧动作'}）', '$ip.perSide', d.id);
        }
        if (have != null) {
          final lack = d.equipment.where((q) => !have.contains(q)).toList();
          if (lack.isNotEmpty) {
            err(IssueCodes.equipment, '$n 需要${lack.map(catalog.taxonomy.equipmentLabel).join('、')}，用户没有', '$ip.exerciseId', d.id);
          }
        }
        final accept = rule.acceptDrillScenes.isEmpty ? {scene} : rule.acceptDrillScenes;
        if (d.scenes.isNotEmpty && !d.scenes.any(accept.contains)) {
          err(IssueCodes.scene, '$n 不适合在${rule.label ?? scene}做（适用：${d.scenes.join('/')}）', '$ip.exerciseId', d.id);
        }
        if ((rule.forbidFloor && catalog.taxonomy.floorPositions.contains(d.position)) ||
            rule.forbidPositions.contains(d.position)) {
          err(IssueCodes.position, '$n 是${catalog.taxonomy.positionLabel(d.position)}动作，${rule.label ?? scene}不方便', '$ip.exerciseId', d.id);
        }
        final hit = d.cautions.where(avoid.contains).toList();
        if (hit.isNotEmpty) {
          err(IssueCodes.avoid, '$n 会加重${hit.join('、')}的负担，用户要保护这些部位', '$ip.exerciseId', d.id);
        }
        if (d.level > level + 1) {
          warn(IssueCodes.levelHigh, '$n 难度 L${d.level}，用户是 L$level', '$ip.exerciseId', d.id);
        }
      }
    }

    if (out.every((i) => i.code != IssueCodes.unknownExercise) && plan.targetMinutes > 0) {
      final est = duration.estimateSeconds(plan, catalog) / 60;
      final t = plan.targetMinutes;
      if ((est - t).abs() > t * lim.durationTolerance) {
        warn(IssueCodes.duration, '估算约 ${est.round()} 分钟，目标 $t 分钟', 'plan.targetMinutes');
      }
    }
    for (final r in extraRules) {
      out.addAll(r(plan, catalog, context));
    }
    return ValidationReport(out);
  }

  void _range(List<PlanIssue> out, String code, String what, int v, IntRange hard, IntRange? drill, String path,
      String id, String unit) {
    if (!hard.contains(v)) {
      out.add(PlanIssue(code, '$what $v$unit 超出 $hard$unit', path: path, exerciseId: id));
    } else if (drill != null && !drill.contains(v)) {
      out.add(PlanIssue(code, '$what $v$unit 超出该动作的推荐范围 $drill$unit', path: path, exerciseId: id));
    }
  }
}
