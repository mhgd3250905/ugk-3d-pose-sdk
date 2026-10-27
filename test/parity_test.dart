// 与评测 Python 校验器逐例对照：`eval/tools/validate.py --selftest` 的 25 例 + 补充规则样例
// （mode 与目录一致、动作 scenes 匹配计划场所），由 `eval/tools/export_parity.py` 导出到
// test/fixtures/parity.json（含 Python 实际判定）。同一份输出，SDK 给出相同的错误分类（E_*）
// 且每类条数相同，保证评测通过率 = 线上通过率。改了 validate.py 或目录后重导。
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();
  final profiles = {for (final p in ['flarelab', 'hiplab', 'smartfit']) p: loadProfile(p)};
  final doc = (jsonDecode(File('test/fixtures/parity.json').readAsStringSync()) as Map).cast<String, Object?>();
  final cases = [for (final c in doc['cases']! as List) (c as Map).cast<String, Object?>()];

  CoachContext contextOf(Map<String, Object?> r) => CoachContext(
    scene: r['scene'] as String?,
    equipment: r.containsKey('equipment') ? {for (final q in r['equipment']! as List) q as String} : null,
    avoid: {for (final a in (r['avoid'] as List?) ?? const []) a as String},
  );

  test('自测用例数与评测一致（25），并含补充规则样例', () {
    expect(doc['selftestCount'], 25);
    expect(cases.where((c) => c['group'] == 'selftest'), hasLength(25));
    expect(cases.where((c) => c['group'] == 'rules'), isNotEmpty);
    expect(doc['catalogVersion'], catalog.version);
  });

  for (final c in cases) {
    test('[${c['group']}] ${c['name']}', () {
      final reply = c['reply']!;
      final r = check(reply, profiles[c['profile']]!, catalog, contextOf((c['request']! as Map).cast<String, Object?>()));
      final py = (c['python']! as Map).cast<String, Object?>();
      final pyErrors = {for (final e in py['errors']! as List) e as String};
      final pyCounts = (py['counts']! as Map).map((k, v) => MapEntry(k as String, v as int));
      final dartCounts = <String, int>{};
      for (final i in r.issues.where((i) => i.isError)) {
        dartCounts.update(i.category, (n) => n + 1, ifAbsent: () => 1);
      }
      final why = 'Dart: ${r.issues.where((i) => i.isError).join('\n')}\nPython: ${py['messages']}';
      expect(r.errors, pyErrors, reason: why);
      expect(dartCounts, pyCounts, reason: why);
      // 期望本身（评测自测的判定口径）：期望的都出现，额外的只允许是场所/器械连带错误。
      final expected = {for (final e in c['expect']! as List) e as String};
      if (expected.isEmpty) {
        expect(r.errors, isEmpty);
      } else {
        expect(r.errors.containsAll(expected), isTrue);
        expect(r.errors.difference(expected).difference({'E_SCENE', 'E_EQUIP'}), isEmpty);
      }
    });
  }

  test('器械未知时计划自报垫子不成为可用器械', () {
    final c = cases.singleWhere((row) => row['name'] == '器械未知：计划声明垫子不能证明拥有');
    final req = (c['request']! as Map).cast<String, Object?>();
    expect(req, isEmpty);
    final plan = (c['reply']! as Map)['plan']! as Map;
    expect(plan['equipment'], ['mat']);
    final result = check(c['reply']!, profiles[c['profile']]!, catalog, contextOf(req));
    final equipmentErrors = result.issues.where((issue) => issue.isError && issue.category == 'E_EQUIP');
    expect(equipmentErrors, hasLength(6));
    final python = (c['python']! as Map)['counts']! as Map;
    expect(python['E_EQUIP'], 6);
  });

  test('合法计划估算时长与评测一致（validate.py 输出 10.7 分钟）', () {
    final plan = const EnvelopeParser().parse(jsonEncode(okEnvelope())).reply!.plan!;
    final est = const PlanDuration().estimateSeconds(plan, catalog) / 60;
    expect(est, closeTo(10.7, 0.05));
  });
}
