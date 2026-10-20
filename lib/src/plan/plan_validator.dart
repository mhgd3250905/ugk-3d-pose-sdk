/// TrainingPlan v1 校验器：模板计划、AI 计划、已存计划（目录更新后复核）共用。
/// 规则与 ai-coach-eval `tools/validate.py` 对齐（`test/parity_test.dart` 逐条核对），
/// 评测通过率即线上通过率。
///
/// 错误（不能用，触发重写 / 回落）：
/// - 结构：schemaVersion=1；title、summary 非空；goal 在全局枚举；scene ∈ home/office/gym；level 1–3；
///   equipment 为目录器械 id；至少一个块；块非空
/// - 动作：id 在目录（E_UNKNOWN）；在 profile 范围（E_SCOPE）
/// - 剂量（E_DOSE）：mode 与目录默认剂量一致；sets 1–6、reps 1–30、workSeconds 10–120、restSeconds 0–180、
///   rounds 1–6、轮间休息 0–300；targetMinutes 在 profile.limits.minutes；动作总数 ≤ maxItems
/// - perSide == unilateral（E_SIDE）；保护部位（E_AVOID）；器械（E_EQUIP）
/// - 场所（E_SCENE）：profile 支持该场所；计划场所 = 本轮场所；动作 scenes 被接受；办公室不着地
/// - 块顺序（E_ORDER）：热身不能排在放松之后
///
/// 警告：goal 不在本 App 侧重；超出动作 doseRange；其他块顺序不理想；难度高于用户 1 级以上；
/// 估算时长偏离 ±40%；块内重复；plan.equipment 漏写；avoid 用了词表外的部位。
library;

import '../catalog/catalog.dart';
import '../profile/coach_profile.dart';
import 'coach_context.dart';
import 'plan_issue.dart';
import 'training_plan.dart';

/// 全局 goal 枚举（TrainingPlan v1）。
const planGoals = {'relax', 'mobility', 'strength', 'core', 'fullbody', 'warmup', 'cooldown'};
const planScenes = {'home', 'office', 'gym'};

class ValidationReport {
  const ValidationReport(this.issues);
  final List<PlanIssue> issues;
  List<PlanIssue> get errors => [for (final i in issues) if (i.isError) i];
  List<PlanIssue> get warnings => [for (final i in issues) if (!i.isError) i];
  bool get ok => errors.isEmpty;

  /// E_* 分类集合（评测对照用）。
  Set<String> get errorCategories => {for (final e in errors) e.category};
}

/// App 可追加自己的规则。
typedef PlanRule = Iterable<PlanIssue> Function(TrainingPlan plan, Catalog catalog, CoachContext context);

class PlanValidator {
  const PlanValidator({
    required this.catalog,
    required this.profile,
    this.enforceDrillDoseRange = false,
    this.duration = const PlanDuration(),
    this.extraRules = const [],
  });

  final Catalog catalog;
  final CoachProfile profile;

  /// 超出动作 doseRange 是否判错（默认只警告，与评测口径一致）。
  final bool enforceDrillDoseRange;
  final PlanDuration duration;
  final List<PlanRule> extraRules;

  ValidationReport validate(TrainingPlan plan, [CoachContext context = const CoachContext()]) {
    final out = <PlanIssue>[];
    void err(String code, String msg, String path, [String? id, String? expected, String? actual]) =>
        out.add(PlanIssue(code, msg, path: path, exerciseId: id, expected: expected, actual: actual));
    void warn(String code, String msg, String path, [String? id]) =>
        out.add(PlanIssue.warning(code, msg, path: path, exerciseId: id));
    final tax = catalog.taxonomy;
    final lim = profile.limits;
    final lang = context.language;

    // ---- 计划整体 ----
    if (plan.schemaVersion != planSchemaVersion) {
      err(IssueCodes.schemaVersion, 'schemaVersion 必须为 $planSchemaVersion', 'plan.schemaVersion');
    }
    if (plan.title.trim().isEmpty) err(IssueCodes.schema, '缺少 title', 'plan.title');
    if (plan.summary.trim().isEmpty) err(IssueCodes.schema, '缺少 summary', 'plan.summary');
    if (!planGoals.contains(plan.goal)) {
      err(IssueCodes.goal, 'goal「${plan.goal}」不在 ${planGoals.join('/')}', 'plan.goal');
    } else if (!profile.goals.contains(plan.goal)) {
      warn(IssueCodes.goalOutOfProfile, 'goal ${plan.goal} 不在本 App 侧重 ${profile.goals.join('/')}', 'plan.goal');
    }
    final scene = context.scene ?? plan.scene;
    if (!planScenes.contains(plan.scene)) {
      err(IssueCodes.schema, 'scene「${plan.scene}」不在 home/office/gym', 'plan.scene');
    } else if (!profile.scenes.containsKey(plan.scene)) {
      err(IssueCodes.sceneUnsupported, '${profile.appName}不支持场所 ${plan.scene}', 'plan.scene');
    }
    if (context.scene != null && plan.scene != context.scene) {
      err(IssueCodes.scene, '计划场所 ${plan.scene} 与用户场所 ${context.scene} 不符', 'plan.scene');
    }
    if (plan.level < 1 || plan.level > 3) err(IssueCodes.schema, 'level 必须是 1/2/3', 'plan.level');
    if (!lim.minutes.contains(plan.targetMinutes)) {
      err(IssueCodes.minutesRange, 'targetMinutes ${plan.targetMinutes} 超出 ${lim.minutes}', 'plan.targetMinutes');
    }
    if (tax.equipment.isNotEmpty) {
      for (final q in plan.equipment) {
        if (!tax.equipment.containsKey(q)) err(IssueCodes.schema, 'equipment「$q」不是器械 id', 'plan.equipment');
      }
    }
    final avoid = {...plan.avoid, ...context.avoid};
    if (tax.cautions.isNotEmpty) {
      for (final a in avoid) {
        if (!tax.cautions.contains(a)) warn(IssueCodes.avoidVocabulary, 'avoid 部位「$a」不在词表 ${tax.cautions.join('/')}', 'plan.avoid');
      }
    }
    final rule = profile.scenes[scene] ?? SceneRule.defaults[scene] ?? const SceneRule();
    final have = context.availableEquipment(profile, scene: scene, declared: plan.equipment);
    final accept = rule.acceptDrillScenes.isEmpty ? {scene} : rule.acceptDrillScenes;
    final level = context.level ?? plan.level;
    final scope = {for (final d in profile.scope(catalog)) d.id};
    if (plan.blocks.isEmpty) err(IssueCodes.emptyPlan, '计划没有任何训练块', 'plan.blocks');

    // ---- 块与动作 ----
    final used = <String>{};
    var sawCooldown = false;
    var maxOrder = 0;
    var count = 0;
    for (var bi = 0; bi < plan.blocks.length; bi++) {
      final b = plan.blocks[bi];
      final bp = 'plan.blocks[$bi]';
      if (!lim.rounds.contains(b.rounds)) err(IssueCodes.roundsRange, '「${b.name}」轮数 ${b.rounds} 超出 ${lim.rounds}', '$bp.rounds');
      if (!lim.restBetweenRoundsSeconds.contains(b.restBetweenRoundsSeconds)) {
        err(IssueCodes.restBetweenRoundsRange,
            '「${b.name}」轮间休息 ${b.restBetweenRoundsSeconds} 秒超出 ${lim.restBetweenRoundsSeconds}', '$bp.restBetweenRoundsSeconds');
      }
      if (b.type == BlockType.cooldown) sawCooldown = true;
      if (b.type == BlockType.warmup && sawCooldown) {
        err(IssueCodes.blockOrder, '热身块「${b.name}」不能排在放松块之后', '$bp.type');
      } else if (b.type.order < maxOrder) {
        warn(IssueCodes.blockOrder, '「${b.name}」(${b.type.name}) 位置不理想：建议 热身 → 主训练/循环 → 放松', '$bp.type');
      }
      if (b.type.order > maxOrder) maxOrder = b.type.order;
      if (b.items.isEmpty) err(IssueCodes.emptyBlock, '训练块「${b.name}」为空', '$bp.items');

      final seen = <String>{};
      for (var ii = 0; ii < b.items.length; ii++) {
        count++;
        final i = b.items[ii];
        final ip = '$bp.items[$ii]';
        final d = catalog[i.exerciseId];
        if (d == null) {
          err(IssueCodes.unknownExercise, '未知动作 ID：${i.exerciseId}（只能用目录里的 id）', '$ip.exerciseId', i.exerciseId,
              '本 App 动作目录里的 id', i.exerciseId);
          continue;
        }
        final n = '${d.name.of(lang)}（${d.id}）';
        if (!scope.contains(d.id)) err(IssueCodes.outOfProfile, '$n 不在本 App 的动作范围', '$ip.exerciseId', d.id, '本 App 动作目录里的 id', d.id);
        if (!seen.add(d.id)) warn(IssueCodes.duplicateExercise, '「${b.name}」里重复了 $n', ip, d.id);

        if (i.mode != d.defaultDose.mode) {
          err(IssueCodes.modeMismatch, '$n：mode 应为 ${d.defaultDose.mode.name}（目录剂量单位）', '$ip.mode', d.id,
              d.defaultDose.mode.name, i.mode.name);
        }
        final r = d.doseRange;
        _dose(out, IssueCodes.setsRange, '$n：组数', i.sets, lim.sets, b.type == BlockType.circuit ? null : r.sets, '$ip.sets', d.id, '');
        if (i.mode == DoseMode.reps) {
          if (i.reps == null) {
            err(IssueCodes.repsRange, '$n：计次动作必须写 reps', '$ip.reps', d.id);
          } else {
            _dose(out, IssueCodes.repsRange, '$n：次数', i.reps!, lim.reps, r.reps, '$ip.reps', d.id, '');
          }
        } else if (i.workSeconds == null) {
          err(IssueCodes.workSecondsRange, '$n：计时动作必须写 workSeconds', '$ip.workSeconds', d.id);
        } else {
          _dose(out, IssueCodes.workSecondsRange, '$n：时长', i.workSeconds!, lim.workSeconds, r.seconds, '$ip.workSeconds', d.id, ' 秒');
        }
        _dose(out, IssueCodes.restRange, '$n：休息', i.restSeconds, lim.restSeconds, r.restSeconds, '$ip.restSeconds', d.id, ' 秒');

        if (i.perSide != d.unilateral) {
          err(IssueCodes.perSide, '$n：perSide 应为 ${d.unilateral}${d.unilateral ? '（单侧动作，reps/workSeconds 指每侧）' : ''}', '$ip.perSide', d.id,
              '${d.unilateral}', '${i.perSide}');
        }
        for (final c in d.cautions) {
          if (avoid.contains(c)) err(IssueCodes.avoid, '$n 会加重$c部负担（用户要保护）', '$ip.exerciseId', d.id, '注意列不含「$c」的动作', d.id);
        }
        used.addAll(d.equipment);
        if (have != null) {
          for (final q in d.equipment) {
            if (!have.contains(q)) err(IssueCodes.equipment, '$n 需要${tax.equipmentLabel(q)}', '$ip.exerciseId', d.id);
          }
        }
        if (planScenes.contains(scene)) {
          if ((rule.forbidFloor && tax.floorPositions.contains(d.position)) || rule.forbidPositions.contains(d.position)) {
            err(IssueCodes.position, '$n 需要趴/躺/跪在地上，不适合${rule.label ?? scene}', '$ip.exerciseId', d.id);
          }
          if (!d.scenes.any(accept.contains)) {
            err(IssueCodes.scene, '$n 不适合场所 $scene（动作场所 ${d.scenes.join('/')}）', '$ip.exerciseId', d.id);
          }
        }
        if (d.level > level + 1) warn(IssueCodes.levelHigh, '$n 难度 ${d.level}，用户水平 $level', '$ip.exerciseId', d.id);
      }
    }
    if (count > lim.maxItems) err(IssueCodes.tooManyItems, '动作条目 $count 过多（上限 ${lim.maxItems}）', 'plan.blocks');
    final undeclared = used.difference(plan.equipment.toSet());
    if (undeclared.isNotEmpty) {
      warn(IssueCodes.equipmentUndeclared, 'plan.equipment 漏写 ${(undeclared.toList()..sort()).join(', ')}', 'plan.equipment');
    }
    if (plan.targetMinutes > 0) {
      final est = duration.estimateSeconds(plan, catalog) / 60;
      if ((est - plan.targetMinutes).abs() / plan.targetMinutes > lim.durationTolerance) {
        warn(IssueCodes.duration, '估算时长约 ${est.toStringAsFixed(1)} 分钟，偏离目标 ${plan.targetMinutes} 分钟', 'plan.targetMinutes');
      }
    }
    for (final r in extraRules) {
      out.addAll(r(plan, catalog, context));
    }
    return ValidationReport(out);
  }

  /// 硬限 → 错误；动作 doseRange → 警告（或 [enforceDrillDoseRange] 时错误）。
  void _dose(List<PlanIssue> out, String code, String what, int v, IntRange hard, IntRange? drill, String path,
      String id, String unit) {
    if (!hard.contains(v)) {
      out.add(PlanIssue(code, '$what $v$unit 超出 $hard$unit', path: path, exerciseId: id, expected: '$hard', actual: '$v'));
    } else if (drill != null && !drill.contains(v)) {
      out.add(PlanIssue(enforceDrillDoseRange ? code : IssueCodes.doseRange, '$what $v$unit 超出推荐 $drill$unit',
          path: path, exerciseId: id, expected: '$drill', actual: '$v', severity: enforceDrillDoseRange ? IssueSeverity.error : IssueSeverity.warning));
    }
  }
}
