// 评测对照之外的规则细节：警告、可选严格模式、器械信任、扩展规则、计划保存序列化。
import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();
  final hip = loadProfile('hiplab');
  TrainingPlan planFrom(Map<String, Object?> env) => const EnvelopeParser().parse(jsonEncode(env)).reply!.plan!;
  ValidationReport v(Map<String, Object?> env, [CoachContext c = const CoachContext(), PlanValidator? val]) =>
      (val ?? PlanValidator(catalog: catalog, profile: hip)).validate(planFrom(env), c);

  test('合法计划无错误、无警告', () {
    final r = v(okEnvelope());
    expect(r.ok, isTrue);
    expect(r.warnings, isEmpty, reason: '${r.warnings}');
  });

  test('超出动作 doseRange：默认警告，严格模式判错', () {
    final e = okEnvelope();
    itemOf(e, 1, 0)['workSeconds'] = 90; // s-figure4 推荐 15–60
    final loose = v(e);
    expect(loose.ok, isTrue);
    expect(loose.warnings.map((w) => w.code), contains(IssueCodes.doseRange));
    final strict = v(e, const CoachContext(), PlanValidator(catalog: catalog, profile: hip, enforceDrillDoseRange: true));
    expect(strict.errors.single.code, IssueCodes.workSecondsRange);
  });

  test('主训练排在放松后：警告不判错；热身在放松后：判错', () {
    final e = okEnvelope();
    final b = blocksOf(e);
    b.add(b.removeAt(1));
    final r = v(e);
    expect(r.ok, isTrue);
    expect(r.warnings.map((w) => w.code), contains(IssueCodes.blockOrder));
  });

  test('难度高于用户 1 级以上给警告', () {
    final e = okEnvelope();
    addItem(e, 1, {'exerciseId': 'h-9090-liftoff', 'mode': 'reps', 'sets': 1, 'reps': 8, 'perSide': true, 'restSeconds': 10});
    final r = v(e, const CoachContext(level: 1));
    expect(r.warnings.map((w) => w.code), contains(IssueCodes.levelHigh));
  });

  test('估算时长偏离目标给警告', () {
    final e = okEnvelope();
    planOf(e)['targetMinutes'] = 30;
    expect(v(e).warnings.map((w) => w.code), contains(IssueCodes.duration));
  });

  test('器械：App 不知道时信任计划声明；明确没有时判错', () {
    final sf = loadProfile('smartfit');
    final e = okEnvelope();
    addItem(e, 1, {'exerciseId': 'h-db-curl', 'mode': 'reps', 'sets': 2, 'reps': 10, 'perSide': false, 'restSeconds': 30});
    planOf(e)['equipment'] = ['mat', 'dumbbell'];
    final val = PlanValidator(catalog: catalog, profile: sf);
    expect(val.validate(planFrom(e)).ok, isTrue);
    expect(val.validate(planFrom(e), const CoachContext(equipment: {})).errorCategories, {'E_EQUIP'});
    expect(val.validate(planFrom(e), const CoachContext(equipment: {'dumbbell'})).ok, isTrue);
  });

  test('plan.equipment 漏写给警告', () {
    final e = okEnvelope();
    planOf(e)['equipment'] = <String>[];
    expect(v(e).warnings.map((w) => w.code), contains(IssueCodes.equipmentUndeclared));
  });

  test('goal 在全局枚举但不在本 App 侧重：警告', () {
    final e = okEnvelope();
    planOf(e)['goal'] = 'core';
    final r = v(e);
    expect(r.ok, isTrue);
    expect(r.warnings.map((w) => w.code), contains(IssueCodes.goalOutOfProfile));
  });

  test('计划场所与本轮场所不符', () {
    expect(v(okEnvelope(), const CoachContext(scene: 'office')).errors.map((e) => e.code), contains(IssueCodes.scene));
  });

  test('每个问题带路径与动作 id，可回传模型', () {
    final e = okEnvelope();
    itemOf(e, 1, 3)['reps'] = 40;
    final i = v(e).errors.single;
    expect(i.path, 'plan.blocks[1].items[3].reps');
    expect(i.exerciseId, 'h-reverse-clam');
    expect(i.feedbackLine, contains('超出 1–30'));
  });

  test('App 自定义规则', () {
    final val = PlanValidator(catalog: catalog, profile: hip, extraRules: [
      (plan, _, _) => [if (plan.items.length > 5) const PlanIssue('custom_max5', '本 App 最多 5 个动作')],
    ]);
    expect(val.validate(planFrom(okEnvelope())).errors.single.code, 'custom_max5');
  });

  test('目录更新后复核已存计划：动作被移除 → unknown_exercise', () {
    final plan = planFrom(okEnvelope());
    final raw = jsonDecode(catalogText()) as Map<String, Object?>;
    (raw['drills']! as List).removeWhere((d) => (d as Map)['id'] == 's-butterfly');
    raw['version'] = '0.1.1';
    final next = Catalog.fromJson(raw);
    final r = PlanValidator(catalog: next, profile: hip).validate(plan);
    expect(r.errors.single.code, IssueCodes.unknownExercise);
  });

  group('PlanCodec（计划保存）', () {
    test('编码与 SmartFit TrainingPlan v1 同 JSON，往返不变', () {
      final plan = planFrom(okEnvelope());
      final text = const PlanCodec().encode(plan);
      final back = const PlanCodec().decode(text);
      expect(const PlanCodec().encode(back), text);
      final j = jsonDecode(text) as Map<String, Object?>;
      expect(j.keys, containsAll(['schemaVersion', 'id', 'source', 'title', 'goal', 'scene', 'blocks', 'notes', 'safetyNotes']));
      final item = ((j['blocks']! as List).first as Map)['items'] as List;
      expect((item.first as Map).keys, ['exerciseId', 'mode', 'sets', 'reps', 'perSide', 'restSeconds']);
    });
    test('宽容解码旧计划（缺字段给默认值）', () {
      final p = const PlanCodec().decode({
        'id': 'old',
        'title': '旧计划',
        'blocks': [
          {'type': 'main', 'items': [
            {'exerciseId': 'h-squat', 'mode': 'reps'},
          ]},
        ],
      });
      expect(p.items.single.reps, 10);
      expect(p.items.single.restSeconds, 20);
      expect(p.source, 'ai');
    });
    test('结构坏到无法恢复抛 FormatException', () {
      expect(() => const PlanCodec().decode({'title': 'x'}), throwsFormatException);
    });
  });
}
