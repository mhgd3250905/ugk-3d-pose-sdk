import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  test(
    'omitted and explicitly empty avoid have distinct host update intent',
    () {
      const omitted = CoachContext();
      const explicitEmpty = CoachContext(avoid: {});
      const explicitKnee = CoachContext(avoid: {'膝'});

      expect(omitted.avoid, isEmpty);
      expect(explicitEmpty.avoid, isEmpty);
      expect(omitted.hasExplicitAvoid, isFalse);
      expect(explicitEmpty.hasExplicitAvoid, isTrue);
      expect(explicitKnee.hasExplicitAvoid, isTrue);
      // Legacy context JSON remains unchanged. Persistent host provenance is
      // stored in CoachSessionState.params, not in the transient input marker.
      expect(omitted.toJson(), {'language': 'zh'});
      expect(explicitEmpty.toJson(), {'language': 'zh'});
      expect(explicitKnee.toJson()['avoid'], ['膝']);
    },
  );

  test('copyWith keeps or explicitly replaces the avoid update intent', () {
    const omitted = CoachContext(scene: 'home');
    const explicitEmpty = CoachContext(avoid: {});
    const explicitKnee = CoachContext(avoid: {'膝'});

    expect(omitted.copyWith(minutes: 10).hasExplicitAvoid, isFalse);
    expect(explicitEmpty.copyWith(minutes: 10).hasExplicitAvoid, isTrue);
    expect(explicitKnee.copyWith(minutes: 10).avoid, {'膝'});
    final cleared = explicitKnee.copyWith(avoid: {});
    expect(cleared.hasExplicitAvoid, isTrue);
    expect(cleared.avoid, isEmpty);
    expect(omitted.copyWith(avoid: {}).hasExplicitAvoid, isTrue);
  });

  test('legacy plan state without avoid does not invent an explicit clear', () {
    final legacy = CoachPlanState.fromJson({
      'planId': 'legacy',
      'context': {'scene': 'home', 'language': 'zh'},
    });
    expect(legacy.context.avoid, isEmpty);
    expect(legacy.context.hasExplicitAvoid, isFalse);
    expect(legacy.toJson()['context'], {'scene': 'home', 'language': 'zh'});
  });

  test('bundled and fallback scenes never assume equipment ownership', () {
    for (final id in ['hiplab', 'flarelab', 'smartfit']) {
      final profile = loadProfile(id);
      for (final entry in profile.scenes.entries) {
        expect(
          entry.value.assumedEquipment,
          isEmpty,
          reason: '$id/${entry.key}',
        );
        expect(entry.value.allEquipment, isFalse, reason: '$id/${entry.key}');
        expect(
          const CoachContext().availableEquipment(profile, scene: entry.key),
          isEmpty,
          reason: '$id/${entry.key}',
        );
      }
    }
    for (final rule in SceneRule.defaults.values) {
      expect(rule.assumedEquipment, isEmpty);
      expect(rule.allEquipment, isFalse);
    }
  });

  test('plan-declared equipment cannot establish that the user owns it', () {
    final profile = loadProfile('hiplab');
    final catalog = loadCatalog();
    final plan = const PlanCodec().decode(planOf(okEnvelope()));
    final gate = ToolGate(catalog: catalog, profile: profile);

    expect(
      const CoachContext().availableEquipment(profile, declared: ['mat']),
      isEmpty,
    );
    expect(gate.admitTemplate(plan), isNull);
    const confirmedMat = CoachContext(equipment: {'mat'});
    expect(confirmedMat.availableEquipment(profile), {'mat'});
    expect(gate.admitTemplate(plan, confirmedMat), isNotNull);
  });
}
