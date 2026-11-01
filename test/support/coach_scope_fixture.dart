import 'dart:convert';

import 'package:ugk_coach/ugk_coach.dart';

/// Synthetic complete catalogue for public-boundary tests, not an App manifest.
Catalog coachScopeFixtureCatalog({
  int insideSeconds = 90,
  List<String> equipment = const [],
  List<String> cautions = const [],
}) => Catalog.fromJson({
  'format': 'pose-hub-catalog',
  'formatVersion': 1,
  'version': 'scope-security-1',
  'taxonomy': {
    'muscleGroups': {
      'adductors': {'zh': '大腿内侧'},
      'hip-flexors': {'zh': '髋屈肌'},
      'glutes': {'zh': '臀部'},
      'lats': {'zh': '背部'},
    },
    'equipment': {
      'mat': {'zh': '垫子'},
    },
    'cautions': cautions,
  },
  'drills': [
    _drill('inside-a', '内侧放松', 'adductors', insideSeconds, equipment),
    _drill('inside-b', '髋前放松', 'hip-flexors', 90, equipment),
    _drill('inside-c', '臀部放松', 'glutes', 90, equipment),
    _drill('outside-a', '外部内侧伸展', 'adductors', 90, equipment),
    _drill('outside-back', '外部背部训练', 'lats', 90, equipment),
  ],
});

Map<String, Object?> _drill(
  String id,
  String name,
  String body,
  int seconds,
  List<String> equipment,
) => {
  'id': id,
  'name': {'zh': name},
  'purpose': '温和放松',
  'category': 'stretch',
  'muscles': [body],
  'muscleGroups': [body],
  'equipment': equipment,
  'position': 'seated',
  'unilateral': false,
  'level': 1,
  'scenes': ['home'],
  'defaultDose': {
    'mode': 'time',
    'sets': 1,
    'seconds': seconds,
    'restSeconds': 0,
  },
  'doseRange': {
    'sets': [1, 3],
    'seconds': [10, 120],
    'restSeconds': [0, 30],
  },
  'cues': {
    'zh': ['缓慢完成，保持自然呼吸'],
  },
  'cautions': <String>[],
  'contraindications': <String>[],
  'trainingDefinitionComplete': true,
};

const coachScopeFixtureIds = {'inside-a', 'inside-b', 'inside-c'};

const coachScopeFixtureProfile = CoachProfile(
  id: 'scope-test',
  appName: '范围测试',
  focus: '本 App 专注髋部、臀部与温和拉伸。',
);

final coachScopeFixturePolicy = CoachScopeConversationPolicy(
  specialty: '本 App 专注髋部、臀部与温和拉伸。',
  suggestions: ['来一组髋部放松'],
);

CoachActionScopeManifest coachScopeFixtureManifest(
  Catalog catalog, {
  Iterable<String> ids = coachScopeFixtureIds,
}) => CoachActionScopeManifest.fromCatalogBytes(
  appId: coachScopeFixtureProfile.id,
  catalogBytes: utf8.encode(jsonEncode(catalog.toJson())),
  allowedActionIds: ids,
);

PlanItem coachScopeFixtureItem(
  String id, {
  int seconds = 90,
  String? replacedFrom,
  String? segment,
}) => PlanItem(
  exerciseId: id,
  mode: DoseMode.time,
  sets: 1,
  workSeconds: seconds,
  perSide: false,
  restSeconds: 0,
  replacedFrom: replacedFrom,
  segments: [
    if (segment != null)
      PlanSegment(
        id: 'segment-1',
        exerciseId: segment,
        mode: DoseMode.time,
        workSeconds: seconds,
      ),
  ],
);

TrainingPlan coachScopeFixturePlan({
  String id = 'host-plan',
  PlanItem? first,
  List<String> equipment = const [],
}) => TrainingPlan(
  id: id,
  source: 'template',
  title: '五分钟髋臀放松',
  summary: '按保存顺序完成',
  goal: 'relax',
  scene: 'home',
  equipment: equipment,
  level: 1,
  targetMinutes: 5,
  blocks: [
    PlanBlock(
      id: 'main',
      name: '放松',
      type: BlockType.main,
      items: [
        first ?? coachScopeFixtureItem('inside-a', seconds: 80),
        coachScopeFixtureItem('inside-b'),
        coachScopeFixtureItem('inside-c'),
      ],
    ),
  ],
);

PlanExecutionTiming coachScopeFixtureTiming(
  TrainingPlan plan, {
  double seconds = 300,
  bool manual = false,
}) => PlanExecutionTiming(
  totalSeconds: seconds,
  blocks: [
    for (final block in plan.blocks)
      PlanBlockExecutionTiming(blockId: block.id, seconds: seconds),
  ],
  containsManualCounting: manual,
);
