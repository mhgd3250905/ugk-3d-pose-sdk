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
  String? planningHash,
  String? allowlistHash,
}) => CoachActionScopeManifest.fromCatalogBytes(
  appId: 'hiplab',
  catalogBytes: utf8.encode(jsonEncode(catalog.toJson())),
  planningCatalog: catalog,
  allowedActionIds: ids,
  catalogSha256: masterHash,
  planningCatalogSha256: planningHash,
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

Matcher _configuration(String code) =>
    isA<CoachActionScopeConfigurationException>().having(
      (error) => error.code,
      'code',
      code,
    );

void main() {
  test('manifest rejects empty and duplicate IDs instead of granting all', () {
    final catalog = actionScopeCatalog();
    expect(
      () => actionScopeManifest(catalog, ids: []),
      throwsA(_configuration('empty_allowlist')),
    );
    expect(
      () => actionScopeManifest(catalog, ids: ['hip-a', 'hip-a']),
      throwsA(_configuration('duplicate_action_id')),
    );
  });

  for (final id in [
    '*',
    'hip-*',
    'tag:stretch',
    'hip-',
    'not-real',
    ' hip-a',
    '',
  ]) {
    test('only an exact known action ID can be authorized: $id', () {
      expect(
        () => actionScopeManifest(actionScopeCatalog(), ids: [id]),
        throwsA(isA<CoachActionScopeConfigurationException>()),
      );
    });
  }

  test(
    'master, planning and allowlist identities are separate and verified',
    () {
      final catalog = actionScopeCatalog();
      final manifest = actionScopeManifest(catalog);
      expect(
        manifest.catalogSha256,
        sha256.convert(utf8.encode(jsonEncode(catalog.toJson()))).toString(),
      );
      expect(
        manifest.planningCatalogSha256,
        computePlanningCatalogSha256(catalog),
      );
      expect(
        manifest.allowlistSha256,
        computeAllowlistSha256(['unsafe-hip', 'hip-a', 'incomplete', 'hip-b']),
      );
      expect(manifest.catalogSha256, isNot(manifest.planningCatalogSha256));
      expect(
        () => actionScopeManifest(catalog, masterHash: '0' * 64),
        throwsA(_configuration('catalog_sha256_mismatch')),
      );
      expect(
        () => actionScopeManifest(catalog, planningHash: '0' * 64),
        throwsA(_configuration('planning_catalog_sha256_mismatch')),
      );
      expect(
        () => actionScopeManifest(catalog, allowlistHash: '0' * 64),
        throwsA(_configuration('allowlist_sha256_mismatch')),
      );
    },
  );

  test('allowlist digest matches the asset closure LF format', () {
    expect(
      computeAllowlistSha256(['hip-b', 'hip-a']),
      sha256.convert(utf8.encode('hip-a\nhip-b\n')).toString(),
    );
  });

  test(
    'manifest JSON round trip revalidates source and planning identities',
    () {
      final catalog = actionScopeCatalog();
      final manifest = actionScopeManifest(catalog);
      final restored = CoachActionScopeManifest.fromJson(
        jsonDecode(jsonEncode(manifest.toJson())),
        catalogBytes: utf8.encode(jsonEncode(catalog.toJson())),
        planningCatalog: catalog,
      );
      expect(restored.toJson(), manifest.toJson());
      final forged = {
        ...manifest.toJson(),
        'allowedActionIds': ['outside-a'],
      };
      expect(
        () => CoachActionScopeManifest.fromJson(
          forged,
          catalogBytes: utf8.encode(jsonEncode(catalog.toJson())),
          planningCatalog: catalog,
        ),
        throwsA(_configuration('allowlist_sha256_mismatch')),
      );
    },
  );

  test(
    'restricted catalogue is exactly hard list intersect complete intersect profile',
    () {
      final catalog = actionScopeCatalog();
      final scope = actionScopeManifest(catalog).restrict(
        catalog: catalog,
        profile: actionScopeProfile(
          select: const DrillSelector(exclude: {'hip-b'}),
        ),
      );
      expect(scope.allowedActionIds, contains('incomplete'));
      expect(scope.plannableIds, {'hip-a', 'unsafe-hip'});
      expect(scope.catalog['outside-a'], isNull);
      expect(scope.catalog['incomplete'], isNull);
      expect(scope.profile.select.ids, scope.plannableIds);
      expect(scope.profile.select.idPrefixes, isEmpty);
      expect(scope.profile.select.tags, isEmpty);
    },
  );

  test(
    'same IDs with changed dose, raw rhythm, hold override or taxonomy cannot replace the bound provider',
    () {
      final catalog = actionScopeCatalog();
      final manifest = actionScopeManifest(catalog);
      for (final mutate in <void Function(Map<String, Object?>)>[
        (json) => ((json['drills']! as List).first as Map)['defaultDose'] = {
          'mode': 'time',
          'sets': 1,
          'seconds': 40,
          'restSeconds': 5,
        },
        (json) => ((json['drills']! as List).first as Map)['rhythm'] = {
          'kind': 'rep_hold',
          'holdSeconds': 20,
        },
        (json) => ((json['drills']! as List).first as Map)['holdSeconds'] = 25,
        (json) => (json['taxonomy']! as Map)['positions'] = {
          'seated': {'floor': true},
        },
      ]) {
        final raw = (jsonDecode(jsonEncode(catalog.toJson())) as Map)
            .cast<String, Object?>();
        mutate(raw);
        final forged = Catalog.fromJson(raw);
        expect(forged.ids, catalog.ids);
        expect(
          () =>
              manifest.restrict(catalog: forged, profile: actionScopeProfile()),
          throwsA(_configuration('planning_catalog_changed')),
        );
      }
    },
  );

  test(
    'raw catalog indexes, alternatives, source metadata and foreign asset paths cannot leak',
    () {
      final rows = [
        {
          ...actionScopeDrill('hip-a'),
          'alternative': 'outside-a',
          'secretIndex': {
            'drills': [actionScopeDrill('outside-a', name: '外部秘密全量条目')],
          },
        },
        actionScopeDrill('outside-a', name: '外部秘密全量条目'),
      ];
      final catalog = actionScopeCatalog(rows: rows);
      final scope = actionScopeManifest(
        catalog,
        ids: ['hip-a'],
      ).restrict(catalog: catalog, profile: actionScopeProfile());
      final serialized = jsonEncode({
        'catalog': scope.catalog.toJson(),
        'drillRaw': scope.catalog.drills.single.raw,
        'profile': scope.profile.toJson(),
      });
      expect(serialized, isNot(contains('outside-a')));
      expect(serialized, isNot(contains('外部秘密全量条目')));
      expect(scope.catalog.drills.single.alternative, isNull);
      expect(scope.catalog.raw.containsKey('apps'), isFalse);
    },
  );

  test(
    'authored dose/rhythm and effective video rep timing survive projection',
    () {
      final catalog = actionScopeCatalog(
        rows: [
          {
            ...actionScopeDrill('hip-a'),
            'rhythm': {'kind': 'rep_hold', 'holdSeconds': 15},
            'holdSeconds': 25,
          },
        ],
      );
      final original = catalog.drills.single;
      final scope = actionScopeManifest(
        catalog,
        ids: ['hip-a'],
      ).restrict(catalog: catalog, profile: actionScopeProfile());
      final after = scope.catalog.drills.single;
      expect(after.defaultDose.toJson(), original.defaultDose.toJson());
      expect(after.doseRange.toJson(), original.doseRange.toJson());
      expect(after.raw['rhythm'], original.raw['rhythm']);
      expect(after.raw['holdSeconds'], 25);
      expect(
        after.assets.videos.first.repSeconds,
        original.assets.videos.first.repSeconds,
      );
    },
  );

  test(
    'scope projection and ID-only profile cannot be widened by mutation',
    () {
      final catalog = actionScopeCatalog();
      final scope = actionScopeManifest(
        catalog,
      ).restrict(catalog: catalog, profile: actionScopeProfile());
      expect(() => scope.catalog.drills.clear(), throwsUnsupportedError);
      expect(
        () => scope.catalog.drills.first.raw['extra'] = 'outside-a',
        throwsUnsupportedError,
      );
      expect(
        () => scope.profile.select.ids.add('outside-a'),
        throwsUnsupportedError,
      );
      expect(() => scope.plannableIds.add('outside-a'), throwsUnsupportedError);
    },
  );

  test(
    'scope plan validation rejects parent, segment and replacedFrom bypasses',
    () {
      final catalog = actionScopeCatalog();
      final scope = actionScopeManifest(
        catalog,
      ).restrict(catalog: catalog, profile: actionScopeProfile());
      final valid = actionScopePlan('hip-a');
      expect(valid.blocks.expand((block) => block.items), isNotEmpty);
      expect(scope.validatePlan(valid), isEmpty);
      expect(
        scope.validatePlan(actionScopePlan('outside-a')).single.path,
        endsWith('.exerciseId'),
      );
      expect(
        scope
            .validatePlan(actionScopePlan('hip-a', segment: 'outside-a'))
            .single
            .path,
        contains('segments[0]'),
      );
      expect(
        scope
            .validatePlan(actionScopePlan('hip-a', replacedFrom: 'outside-a'))
            .single
            .path,
        endsWith('.replacedFrom'),
      );
    },
  );

  test(
    'snapshot pick, seen, pending search, recommendation and forged refs cannot bypass',
    () {
      final catalog = actionScopeCatalog();
      final scope = actionScopeManifest(
        catalog,
      ).restrict(catalog: catalog, profile: actionScopeProfile());
      for (final value in [
        {
          'picks': ['outside-a'],
        },
        {
          'seenActionIds': ['outside-a'],
        },
        {
          'pendingSearchIds': ['outside-a'],
        },
        {
          'recommendations': [
            {'id': 'outside-a'},
          ],
        },
        {
          'arbitrary': {'sourceActionId': 'forged-id'},
        },
        {
          'segments': [
            {'exerciseId': 'forged-id'},
          ],
        },
      ]) {
        expect(scope.validateReferences(value), isNotEmpty);
      }
      expect(
        scope.validateReferences({
          'userTurns': [
            {'text': '我想做outside-a'},
          ],
        }),
        isEmpty,
        reason: '用户原话不授予执行权限，也不应被误认为执行引用',
      );
    },
  );

  test(
    'SF approved fixture authorizes 219 but admits only 211 complete actions',
    () {
      const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
      final bytes = File('$pack/catalog.json').readAsBytesSync();
      final delivery = PoseHubAppTestCatalog.fromBytes(
        bytes,
        semanticCatalogBytes: File(
          '$pack/catalog/catalog.json',
        ).readAsBytesSync(),
      );
      final planning = delivery.toAiCatalog();
      final fixture =
          jsonDecode(
                File(
                  'test/fixtures/action-scope/smartfit-219.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final manifest = CoachActionScopeManifest.fromCatalogBytes(
        appId: 'smartfit',
        catalogBytes: bytes,
        planningCatalog: planning,
        allowedActionIds: (fixture['allowedActionIds'] as List).cast<String>(),
        catalogSha256: fixture['catalogSha256'] as String,
        allowlistSha256: fixture['allowlistSha256'] as String,
      );
      final scope = manifest.restrict(
        catalog: planning,
        profile: const CoachProfile(id: 'smartfit', appName: 'SmartFit'),
      );
      expect(manifest.allowedActionIds, hasLength(219));
      expect(scope.catalog.drills, hasLength(211));
      expect(scope.catalog.drills, isNotEmpty);
      expect(
        scope.catalog.ids.toSet().difference(manifest.allowedActionIds),
        isEmpty,
      );
      expect(scope.catalog['h-db-shrug'], isNull);
    },
  );

  test(
    'HipLab fixture remains a 45-ID candidate and intersects the host catalogue',
    () {
      const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
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
              as Map<String, dynamic>;
      expect(fixture['approvalStatus'], 'candidate-not-user-approved');
      final manifest = CoachActionScopeManifest.fromCatalogBytes(
        appId: 'hiplab',
        catalogBytes: bytes,
        planningCatalog: planning,
        allowedActionIds: (fixture['allowedActionIds'] as List).cast<String>(),
      );
      final scope = manifest.restrict(
        catalog: planning,
        profile: actionScopeProfile(),
      );
      expect(scope.allowedActionIds, hasLength(45));
      expect(scope.plannableIds, hasLength(45));
      expect(scope.catalog.drills, isNotEmpty);
      expect(scope.plannableIds.difference(scope.allowedActionIds), isEmpty);
      expect(scope.catalog['n-thomas-test'], isNull);
    },
  );
  test(
    'archived candidate rows and named action cues cannot bypass ID admission',
    () {
      final catalog = actionScopeCatalog();
      final scope = actionScopeManifest(
        catalog,
      ).restrict(catalog: catalog, profile: actionScopeProfile());
      for (final value in [
        {
          'candidateIds': ['outside-a'],
        },
        {
          'completedContextLedger': {
            'candidates': [
              ['outside-a', '不可用动作', 'body.inner_thigh', 'time', 1],
            ],
          },
        },
        {
          'candidateRows': [
            ['forged-id', '伪造动作'],
          ],
        },
        {
          'completedContextLedger': {
            'picks': [
              ['outside-a', '不可用动作'],
            ],
          },
        },
        {
          'segments': [
            {
              'exerciseId': 'hip-a',
              'rhythm': {
                'phases': [
                  {'cue': 'drill.outside-a'},
                ],
              },
            },
          ],
        },
        {
          'segments': [
            {
              'exerciseId': 'hip-a',
              'rhythm': {
                'phases': [
                  {
                    'cue': ['point.forged-id'],
                  },
                ],
              },
            },
          ],
        },
      ]) {
        expect(scope.validateReferences(value), isNotEmpty);
      }
      expect(
        scope.validateReferences({
          'candidateRows': [
            ['hip-a', '有效动作'],
          ],
        }),
        isEmpty,
      );
    },
  );
}
