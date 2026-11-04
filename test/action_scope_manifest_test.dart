import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:ugk_coach/src/catalog/catalog.dart';
import 'package:ugk_coach/src/catalog/pose_hub_app_test_pack.dart';
import 'package:ugk_coach/src/plan/training_plan.dart';
import 'package:ugk_coach/src/profile/coach_profile.dart';
import 'package:ugk_coach/src/scope/action_scope.dart';

Map<String, Object?> actionScopeDrill(
  String id, {
  String? name,
  String body = 'adductors',
  String category = 'stretch',
  List<String> equipment = const ['mat'],
  List<String> scenes = const ['home'],
  List<String> cautions = const [],
  bool complete = true,
}) => {
  'id': id,
  'name': {'zh': name ?? id},
  'purpose': '同部位训练',
  'category': category,
  'muscles': [body],
  'muscleGroups': [body],
  'equipment': equipment,
  'position': 'seated',
  'unilateral': false,
  'level': 1,
  'scenes': scenes,
  'defaultDose': {'mode': 'time', 'sets': 1, 'seconds': 30, 'restSeconds': 5},
  'doseRange': {
    'sets': [1, 3],
    'seconds': [15, 60],
    'restSeconds': [0, 20],
  },
  'cues': {
    'zh': ['缓慢完成'],
  },
  'cautions': cautions,
  'contraindications': <String>[],
  'trainingDefinitionComplete': complete,
  'apps': ['hiplab', 'smartfit'],
  'assets': {
    'video': {
      'sources': [
        {'app': 'hiplab', 'path': 'assets/$id.mp4', 'repSeconds': 3.5},
      ],
    },
  },
};

Catalog actionScopeCatalog({List<Map<String, Object?>>? rows}) =>
    Catalog.fromJson({
      'format': 'pose-hub-catalog',
      'formatVersion': 1,
      'version': 'scope-test-1',
      'apps': {
        'hiplab': {
          'drills': ['outside-a', 'outside-back'],
        },
      },
      'taxonomy': {
        'muscleGroups': {
          'adductors': {'zh': '大腿内侧'},
          'hip-flexors': {'zh': '髋屈肌'},
          'lats': {'zh': '背部'},
        },
        'equipment': {
          'mat': {'zh': '垫子'},
        },
      },
      'drills':
          rows ??
          [
            actionScopeDrill('hip-a', name: '温和内侧伸展'),
            actionScopeDrill('hip-b', name: '髋屈肌伸展', body: 'hip-flexors'),
            actionScopeDrill('unsafe-hip', name: '需要护髋的内侧伸展', cautions: ['髋']),
            actionScopeDrill('incomplete', complete: false),
            actionScopeDrill('outside-a', name: '名单外内侧伸展'),
            actionScopeDrill('outside-back', name: '名单外背部训练', body: 'lats'),
          ],
    });

CoachProfile actionScopeProfile({
  DrillSelector select = const DrillSelector(),
}) => CoachProfile(
  id: 'hiplab',
  appName: '测试髋部训练',
  focus: '本 App 专注髋部、臀部和温和拉伸。',
  select: select,
);

CoachActionScopeManifest actionScopeManifest(
  Catalog catalog, {
  Iterable<String> ids = const ['hip-a', 'hip-b', 'unsafe-hip', 'incomplete'],
  String? masterHash,
  String? allowlistHash,
}) => CoachActionScopeManifest.fromCatalogBytes(
  appId: 'hiplab',
  catalogBytes: utf8.encode(jsonEncode(catalog.toJson())),
  allowedActionIds: ids,
  catalogSha256: masterHash,
  allowlistSha256: allowlistHash,
);

TrainingPlan actionScopePlan(
  String id, {
  String? replacedFrom,
  String? segment,
}) => TrainingPlan(
  id: 'plan-one',
  source: 'ai',
  title: '范围内训练',
  summary: '髋部训练',
  goal: 'relax',
  scene: 'home',
  equipment: const ['mat'],
  level: 1,
  targetMinutes: 5,
  blocks: [
    PlanBlock(
      id: 'main',
      name: '主训练',
      type: BlockType.main,
      items: [
        PlanItem(
          exerciseId: id,
          mode: DoseMode.time,
          sets: 1,
          workSeconds: 30,
          perSide: false,
          restSeconds: 5,
          replacedFrom: replacedFrom,
          segments: [
            if (segment != null)
              PlanSegment(
                id: 'part-1',
                exerciseId: segment,
                mode: DoseMode.time,
                workSeconds: 20,
              ),
          ],
        ),
      ],
    ),
  ],
);

Matcher configuration(String code) =>
    isA<CoachActionScopeConfigurationException>().having(
      (error) => error.code,
      'code',
      code,
    );

void main() {
  test(
    'an empty allowlist is a configuration error rather than full catalogue',
    () {
      expect(
        () => actionScopeManifest(actionScopeCatalog(), ids: []),
        throwsA(configuration('empty_allowlist')),
      );
    },
  );

  test('duplicate allowed IDs are rejected during configuration', () {
    expect(
      () => actionScopeManifest(actionScopeCatalog(), ids: ['hip-a', 'hip-a']),
      throwsA(configuration('duplicate_action_id')),
    );
  });

  test('unknown allowed IDs are rejected during configuration', () {
    expect(
      () => actionScopeManifest(actionScopeCatalog(), ids: ['not-in-catalog']),
      throwsA(configuration('unknown_action_id')),
    );
  });

  test('an empty action ID is rejected during configuration', () {
    expect(
      () => actionScopeManifest(actionScopeCatalog(), ids: ['']),
      throwsA(configuration('invalid_text')),
    );
  });

  test('allowlist entries must be exact IDs rather than prefix patterns', () {
    expect(
      () => actionScopeManifest(actionScopeCatalog(), ids: ['hip-*']),
      throwsA(configuration('invalid_exact_action_id')),
    );
  });

  test(
    'catalogue and sorted allowlist SHAs are build metadata that serialize',
    () {
      final catalog = actionScopeCatalog();
      final bytes = utf8.encode(jsonEncode(catalog.toJson()));
      final manifest = actionScopeManifest(catalog);
      expect(manifest.catalogSha256, sha256.convert(bytes).toString());
      expect(
        manifest.allowlistSha256,
        computeAllowlistSha256(['incomplete', 'unsafe-hip', 'hip-b', 'hip-a']),
      );
      final restored = CoachActionScopeManifest.fromJson(
        manifest.toJson(),
        catalogBytes: bytes,
      );
      expect(restored.toJson(), manifest.toJson());
    },
  );

  test('declared metadata is checked once when loading configuration', () {
    expect(
      () => actionScopeManifest(actionScopeCatalog(), masterHash: '0' * 64),
      throwsA(configuration('catalog_sha256_mismatch')),
    );
  });

  test(
    'projection intersects allowed IDs, complete definitions and App profile',
    () {
      final catalog = actionScopeCatalog();
      final scope = actionScopeManifest(catalog).restrict(
        catalog: catalog,
        profile: actionScopeProfile(
          select: const DrillSelector(
            ids: {'hip-a', 'incomplete', 'outside-a'},
          ),
        ),
      );
      expect(scope.catalog.drills, isNotEmpty);
      expect(scope.plannableIds, {'hip-a'});
      expect(scope.profile.scope(scope.catalog).map((drill) => drill.id), [
        'hip-a',
      ]);
      expect(scope.catalog.raw.containsKey('apps'), isFalse);
    },
  );

  test(
    'projection preserves host-authored dose and rhythm overlays',
    () {
      final master = actionScopeCatalog();
      final row = actionScopeDrill('hip-a');
      row['defaultDose'] = {
        'mode': 'time',
        'sets': 1,
        'seconds': 42,
        'holdSeconds': 21,
        'restSeconds': 5,
      };
      row['rhythm'] = {'cycleSeconds': 4.2};
      final planning = actionScopeCatalog(rows: [row]);
      final scope = actionScopeManifest(
        master,
        ids: ['hip-a'],
      ).restrict(catalog: planning, profile: actionScopeProfile());
      expect(scope.catalog.drills, isNotEmpty);
      expect(scope.catalog['hip-a']!.defaultDose.seconds, 42);
      expect(
        (scope.catalog['hip-a']!.raw['defaultDose'] as Map)['holdSeconds'],
        21,
      );
      expect(scope.catalog['hip-a']!.raw['rhythm'], {'cycleSeconds': 4.2});
    },
  );

  test('an alternative outside the projection is not exposed as an action', () {
    final catalog = actionScopeCatalog(
      rows: [
        {...actionScopeDrill('hip-a'), 'alternative': 'outside-a'},
        actionScopeDrill('outside-a'),
      ],
    );
    final scope = actionScopeManifest(
      catalog,
      ids: ['hip-a'],
    ).restrict(catalog: catalog, profile: actionScopeProfile());
    expect(scope.catalog.drills, isNotEmpty);
    expect(scope.catalog['outside-a'], isNull);
    expect(scope.catalog['hip-a']!.alternative, isNull);
    expect(scope.catalog['hip-a']!.raw['alternative'], isNull);
  });

  test('a profile for another App is a configuration error', () {
    final catalog = actionScopeCatalog();
    expect(
      () => actionScopeManifest(catalog).restrict(
        catalog: catalog,
        profile: const CoachProfile(id: 'other', appName: 'Other'),
      ),
      throwsA(configuration('profile_app_mismatch')),
    );
  });

  test(
    'plan admission accepts nonempty plans containing only scoped actions',
    () {
      final catalog = actionScopeCatalog();
      final scope = actionScopeManifest(
        catalog,
      ).restrict(catalog: catalog, profile: actionScopeProfile());
      final plan = actionScopePlan(
        'hip-a',
        segment: 'hip-b',
        replacedFrom: 'hip-b',
      );
      expect(plan.items, isNotEmpty);
      expect(plan.exerciseIds, isNotEmpty);
      expect(scope.validatePlan(plan), isEmpty);
    },
  );

  test('plan admission rejects an outside parent action', () {
    final catalog = actionScopeCatalog();
    final scope = actionScopeManifest(
      catalog,
    ).restrict(catalog: catalog, profile: actionScopeProfile());
    expect(
      scope.validatePlan(actionScopePlan('outside-a')).single.exerciseId,
      'outside-a',
    );
  });

  test('plan admission rejects an outside segment action', () {
    final catalog = actionScopeCatalog();
    final scope = actionScopeManifest(
      catalog,
    ).restrict(catalog: catalog, profile: actionScopeProfile());
    expect(
      scope
          .validatePlan(actionScopePlan('hip-a', segment: 'outside-a'))
          .single
          .path,
      'plan.blocks[0].items[0].segments[0].exerciseId',
    );
  });

  test('plan admission checks the replacement action reference', () {
    final catalog = actionScopeCatalog();
    final scope = actionScopeManifest(
      catalog,
    ).restrict(catalog: catalog, profile: actionScopeProfile());
    expect(
      scope
          .validatePlan(actionScopePlan('hip-a', replacedFrom: 'outside-a'))
          .single
          .path,
      'plan.blocks[0].items[0].replacedFrom',
    );
  });

  test(
    'SF configuration has 219 allowed and 211 complete planning actions',
    () {
      const pack = 'test/fixtures/pose_hub/r1-v3';
      final bytes = File('$pack/catalog.json').readAsBytesSync();
      final planning = PoseHubAppTestCatalog.fromBytes(
        bytes,
        semanticCatalogBytes: File(
          '$pack/catalog/catalog.json',
        ).readAsBytesSync(),
      ).toAiCatalog();
      final fixture =
          jsonDecode(
                File(
                  'test/fixtures/action-scope/smartfit-219.json',
                ).readAsStringSync(),
              )
              as Map;
      final manifest = CoachActionScopeManifest.fromCatalogBytes(
        appId: 'smartfit',
        catalogBytes: bytes,
        allowedActionIds: (fixture['allowedActionIds'] as List).cast<String>(),
        catalogSha256: fixture['catalogSha256'] as String,
        allowlistSha256: fixture['allowlistSha256'] as String,
      );
      final scope = manifest.restrict(
        catalog: planning,
        profile: const CoachProfile(id: 'smartfit', appName: 'SmartFit'),
      );
      expect(manifest.allowedActionIds, hasLength(219));
      expect(scope.catalog.drills, isNotEmpty);
      expect(scope.plannableIds, hasLength(211));
      expect(scope.plannableIds.difference(manifest.allowedActionIds), isEmpty);
    },
  );

  test(
    'HipLab 45-ID fixture remains a candidate rather than a signed manifest',
    () {
      const pack = 'test/fixtures/pose_hub/r1-v3';
      final bytes = File('$pack/catalog.json').readAsBytesSync();
      final planning = PoseHubAppTestCatalog.fromBytes(
        bytes,
        semanticCatalogBytes: File(
          '$pack/catalog/catalog.json',
        ).readAsBytesSync(),
      ).toAiCatalog();
      final fixture =
          jsonDecode(
                File(
                  'test/fixtures/action-scope/hiplab-candidate-45.json',
                ).readAsStringSync(),
              )
              as Map;
      expect(fixture['approvalStatus'], 'candidate-not-user-approved');
      final manifest = CoachActionScopeManifest.fromCatalogBytes(
        appId: 'hiplab',
        catalogBytes: bytes,
        allowedActionIds: (fixture['allowedActionIds'] as List).cast<String>(),
      );
      final scope = manifest.restrict(
        catalog: planning,
        profile: actionScopeProfile(),
      );
      expect(scope.catalog.drills, isNotEmpty);
      expect(scope.plannableIds, hasLength(45));
      expect(scope.plannableIds.difference(manifest.allowedActionIds), isEmpty);
    },
  );
}
