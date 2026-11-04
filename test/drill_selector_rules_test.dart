import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/catalog/catalog.dart';
import 'package:ugk_coach/src/profile/coach_profile.dart';

/// 规格第 7 节：没标 apps/tags 的动作由 App profile 规则（部位、类型、器械）放行。
Catalog _bundled() => Catalog.fromJson(
  jsonDecode(
    File('packages/ugk_trainer/assets/pose_hub/app-pack-r2-v1/catalog/catalog.json').readAsStringSync(),
  ),
);

Map<String, Object?> _profile(String id) =>
    jsonDecode(File('profiles/$id.json').readAsStringSync()) as Map<String, Object?>;

void main() {
  final catalog = _bundled();
  Drill drill(String id) => catalog.drills.firstWhere((d) => d.id == id);

  test('rules admit untagged drills only when every dimension matches', () {
    const rule = DrillRule(
      muscleGroups: {'glute-max', 'hamstrings', 'quadriceps'},
      categories: {'strength'},
      equipment: {'chair', 'mat'},
    );
    const selector = DrillSelector(apps: {'hiplab'}, rules: rule);
    // 未标 apps/tags、髋腿力量、只用椅子 → 放行
    final untagged = drill('o-supported-mini-squat');
    expect(untagged.apps, isEmpty);
    expect(untagged.tags, isEmpty);
    expect(selector.matches(untagged), isTrue);
    // 未标但含上肢肌群 → 不放行
    expect(selector.matches(drill('h-db-reverse-curl')), isFalse);
    // 未标但器械不在规则里（哑铃）→ 不放行
    expect(selector.matches(drill('h-kb-swing')), isFalse);
    // 已标 apps 的动作不走规则：只看 apps
    final tagged = catalog.drills.firstWhere((d) => d.apps.isNotEmpty && !d.apps.contains('hiplab'));
    expect(const DrillSelector(apps: {'hiplab'}, rules: DrillRule(categories: {'strength', 'stretch', 'mobility', 'core', 'cardio'})).matches(tagged), isFalse);
  });

  test('rules-only selector is not select-all; empty rule admits nothing', () {
    const onlyRules = DrillSelector(rules: DrillRule(categories: {'stretch'}));
    expect(onlyRules.selectsAll, isFalse);
    expect(const DrillRule().matches(drill('o-supported-mini-squat')), isFalse);
    expect(const DrillSelector(apps: {'hiplab'}).matches(drill('o-supported-mini-squat')), isFalse);
  });

  test('rules round-trip through json', () {
    final s = DrillSelector.fromJson({
      'apps': ['hiplab'],
      'rules': {
        'muscleGroups': ['adductors'],
        'categories': ['stretch'],
        'equipment': ['mat'],
      },
    });
    expect(DrillSelector.fromJson(s.toJson()).rules.toJson(), s.rules.toJson());
  });

  test('bundled r2-v1: HipLab profile rules pick up untagged hip actions, keep upper-body out', () {
    final hiplab = CoachProfile.fromJson(_profile('hiplab'));
    final scope = {for (final d in hiplab.scope(catalog)) d.id};
    final untaggedIn = [
      for (final d in catalog.drills)
        if (d.apps.isEmpty && d.tags.isEmpty && scope.contains(d.id)) d,
    ];
    expect(untaggedIn, isNotEmpty);
    expect(scope, contains('o-supported-mini-squat'));
    expect(scope, contains('h-inner-thigh'));
    expect(scope, isNot(contains('h-db-reverse-curl')));
    for (final d in untaggedIn) {
      expect(d.muscleGroups.every(hiplab.select.rules.muscleGroups.contains), isTrue, reason: d.id);
    }
    // 所有原来标了 hiplab 的动作仍在
    for (final d in catalog.drills) {
      if (d.apps.contains('hiplab')) expect(scope, contains(d.id));
    }
    // smartfit 选全库：未标动作全部进入
    final smartfit = CoachProfile.fromJson(_profile('smartfit'));
    expect(smartfit.scope(catalog).length, catalog.drills.length);
  });
}
