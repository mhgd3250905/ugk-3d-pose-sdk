import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_tags.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$pack/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$pack/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();
  final profile = loadProfile('smartfit');

  test(
    'structured catalogue fields generate the shared goal and search codes',
    () {
      final tags = ActionTags(profile, catalog);
      expect(
        tags.goalCodes,
        containsAll(['body.core', 'body.inner_thigh', 'purpose.stretch']),
      );
      expect(tags.tags, isNot(contains('purpose.warmup')));
      expect(
        tags.forActionId('erectors-A'),
        containsAll(['body.core', 'body.erectors', 'purpose.core']),
      );
      expect(tags.forActionId('rotator-cuff-A'), contains('body.abs'));
      expect(tags.forActionId('rotator-cuff-A'), isNot(contains('body.core')));
      expect(tags.forActionId('adductors-B'), contains('body.inner_thigh'));
      expect(tags.forActionId('not-in-catalog'), isEmpty);
      for (final code in tags.goalCodes) {
        expect(tags.tags, contains(code));
        expect(code.startsWith('body.') || code.startsWith('purpose.'), isTrue);
      }
    },
  );

  test('equipment codes round trip to catalogue IDs, including hyphens', () {
    final tags = ActionTags(profile, catalog);
    expect(tags.equipmentCode('pullup-bar'), 'equip.pullup_bar');
    expect(tags.equipmentId('equip.pullup_bar'), 'pullup-bar');
    expect(tags.equipmentCode('mat'), 'equip.mat');
    expect(tags.equipmentId('equip.mat'), 'mat');
    expect(tags.equipmentCode('none'), isNull);
    expect(tags.equipmentId('equip.not_in_catalog'), isNull);
    final unknown = tags.equipmentCode('外部器材🙂')!;
    expect(unknown, startsWith('equip.host.'));
    expect(tags.equipmentId(unknown), '外部器材🙂');
    expect(tags.equipmentCodes, isNot(contains(unknown)));
    expect(tags.equipmentId('equip.host.-1'), isNull);
    for (final code in tags.equipmentCodes) {
      expect(tags.equipmentCode(tags.equipmentId(code)!), code);
    }
    final bodyweight = tags.forActionId('erectors-A');
    expect(bodyweight.where((code) => code.startsWith('equip.')), isEmpty);
  });

  test(
    'source safety limits and unknown host values round trip without loss',
    () {
      final tags = ActionTags(profile, catalog);
      const known = {
        '膝': 'limit.knee',
        '腰': 'limit.waist',
        '肩': 'limit.shoulder',
        '手腕': 'limit.wrist',
        '颈': 'limit.neck',
        '髋': 'limit.hip',
        '大腿内侧': 'limit.inner_thigh',
      };
      for (final entry in known.entries) {
        expect(tags.limitCode(entry.key), entry.value);
        expect(tags.limitValue(entry.value), entry.key);
        expect(tags.limitCodes, contains(entry.value));
      }
      for (final raw in ['旧宿主限制', 'knee', '受限🙂/左侧']) {
        final code = tags.limitCode(raw)!;
        expect(tags.limitValue(code), raw);
        expect(code.startsWith('limit.u_'), isTrue);
      }
      final hostWrist = tags.limitCode('wrist')!;
      expect(tags.limitValue(hostWrist), 'wrist');
      expect(tags.canonicalLimitCode(hostWrist), 'limit.wrist');
      expect(tags.canonicalLimitCode('手腕'), 'limit.wrist');
      expect(tags.canonicalLimitCode('knee'), 'limit.knee');
      expect(tags.canonicalLimitCode('back'), 'limit.waist');
      expect(tags.canonicalLimitCode('limit.knee'), 'limit.knee');
      expect(tags.canonicalLimitCode('旧宿主限制'), tags.limitCode('旧宿主限制'));
      expect(tags.limitValue('limit.u_-1'), isNull);
      expect(tags.limitValue('limit.u_d800'), isNull);
      expect(tags.limitValue('limit.u_110000'), isNull);
      expect(tags.limitCode(''), isNull);
    },
  );

  test(
    'scope excludes other action tags but retains user equipment vocabulary',
    () {
      const narrowed = CoachProfile(
        id: 'single',
        appName: 'single',
        select: DrillSelector(ids: {'erectors-A'}),
      );
      final tags = ActionTags(narrowed, catalog);
      expect(tags.forActionId('erectors-A'), contains('body.core'));
      expect(tags.forActionId('rotator-cuff-A'), isEmpty);
      expect(tags.equipmentCode('dumbbell'), 'equip.dumbbell');
      expect(() => tags.tags.add('invented'), throwsUnsupportedError);
      expect(
        () => tags.forActionId('erectors-A').add('invented'),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'ambiguous normalized equipment IDs fail instead of losing provenance',
    () {
      final ambiguous = Catalog(
        version: 'test',
        drills: const [],
        taxonomy: const Taxonomy(
          equipment: {'pullup-bar': 'a', 'pullup_bar': 'b'},
        ),
      );
      expect(() => ActionTags(profile, ambiguous), throwsFormatException);
    },
  );
}
