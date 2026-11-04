import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_coach/ugk_coach_qa_v2.dart';

Catalog _publicCatalog() {
  final meta = File(
    'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog.json',
  );
  final descriptor = PoseHubAppTestCatalog.fromBytes(meta.readAsBytesSync());
  final semantics = File(
    '${meta.parent.path}/${descriptor.semanticCatalogFile.path}',
  ).readAsBytesSync();
  return PoseHubAppTestCatalog.fromBytes(
    meta.readAsBytesSync(),
    semanticCatalogBytes: semantics,
  ).toAiCatalog();
}

CoachProfile _profile() => CoachProfile.fromJson(
  jsonDecode(File('profiles/smartfit.json').readAsStringSync()),
);

Map<String, Object?> _tags(List<String> equipment) => {
  'format': 'pose-hub-ai-tags@1',
  'requiredEquipment': equipment,
  'scenes': ['home', 'gym'],
  'trainingType': ['strength'],
  'primaryMuscles': ['lats'],
  'sessionRole': ['main'],
  'difficulty': 1,
};

Catalog _swapCatalog() => Catalog.fromJson({
  'format': 'pose-hub-catalog',
  'formatVersion': 1,
  'version': 'equipment-regression',
  'taxonomy': {
    'equipment': {
      'band': {'en': 'Band'},
      'dumbbell': {'en': 'Dumbbell'},
      'wall': {'en': 'Wall'},
    },
  },
  'drills': [
    for (final id in ['before', 'after', 'keep'])
      {
        'id': id,
        'name': {'en': id},
        'purpose': 'Training',
        'category': 'strength',
        'muscleGroups': ['lats'],
        'equipment': [if (id == 'before') 'band', if (id == 'after') 'dumbbell'],
        'position': 'standing',
        'unilateral': false,
        'level': 1,
        'scenes': ['home', 'gym'],
        'defaultDose': {
          'mode': 'time',
          'sets': 1,
          'seconds': 90,
          'restSeconds': 0,
        },
        'doseRange': {
          'sets': [1, 4],
          'seconds': [10, 120],
          'restSeconds': [0, 60],
        },
        'cues': {'en': <String>[]},
        'cautions': <String>[],
        'contraindications': <String>[],
      },
  ],
});

class _SwapModel implements LlmClient {
  @override
  String get model => 'equipment-test';
  @override
  Pricing? get pricing => null;
  @override
  Future<LlmResponse> complete(LlmRequest request, {CancelToken? cancel}) async {
    final tool = request.tools.first.name;
    return LlmResponse(
      content: '',
      toolCalls: [
        LlmToolCall(
          id: tool,
          name: tool,
          arguments: jsonEncode(
            tool == 'fill_form'
                ? {
                    'language': 'en',
                    'intent': 'swap',
                    'answer_status': 'none',
                    'place': 'gym',
                    'equipment_known': false,
                    'positions': [1],
                    'next': 'answer',
                  }
                : {
                    'text': 'Updated.',
                    'changes': [
                      {'position': 1, 'new_id': 'after', 'why': 'Same target'},
                    ],
                    'chips': <String>[],
                  },
          ),
        ),
      ],
    );
  }
}

void main() {
  final catalog = _publicCatalog();

  test('home plan declares the wall actually used, not owned unused gear', () {
    final index = QaActionIndex(catalog);
    final builder = QaPlanBuilder(QaFinder(index));
    final result = builder.build(
      mainIds: ['h-wall-angel', 'h-good-morning'],
      minutes: 5,
      base: QaQuery(
        scene: 'home',
        equipment: const {'dumbbell'},
        strict: true,
      ),
    );
    expect(result.orderedIds, contains('h-wall-angel'));
    expect(result.plan.equipment, contains('wall'));
    expect(result.plan.equipment, isNot(contains('dumbbell')));
    expect(result.plan.equipment, unorderedEquals({
      for (final id in result.orderedIds) ...index[id]!.requiredEquipment,
    }));
  });

  test('gym and retimed plans aggregate final main, warmup and cooldown tags', () {
    final tags = <String, Map<String, Object?>>{
      // App-supplied tag samples. No external label dataset is bundled.
      'h-band-standing-adduction': _tags(['band']),
    };
    final index = QaActionIndex(catalog, aiTags: tags);
    final builder = QaPlanBuilder(QaFinder(index));
    final base = QaQuery(scene: 'gym', equipment: const {}, strict: true);
    final original = builder.build(
      mainIds: ['adductors-B', 'h-band-standing-adduction', 'h-lateral-step-lunge'],
      minutes: 15,
      base: base,
    );
    for (final result in [
      original,
      builder.build(
        mainIds: original.mainIds,
        minutes: 10,
        base: base,
        warmIds: [
          for (final block in original.plan.blocks)
            if (block.type == BlockType.warmup)
              for (final item in block.items) item.exerciseId,
        ],
        coolIds: [
          for (final block in original.plan.blocks)
            if (block.type == BlockType.cooldown)
              for (final item in block.items) item.exerciseId,
        ],
      ),
    ]) {
      expect(result.plan.equipment, unorderedEquals({
        for (final id in result.orderedIds) ...index[id]!.requiredEquipment,
      }));
      expect(result.plan.equipment, contains('band'));
      expect(result.plan.equipment, contains('mat'));
      expect(result.plan.equipment, contains('chair'));
    }
  });

  test('QA admission uses injected equipment facts without altering the App catalogue', () {
    final tags = {
      // The real tag vocabulary uses bench while the old catalogue uses chair.
      'adductors-B': _tags(['bench', 'mat']),
      'h-band-standing-adduction': _tags(['band']),
    };
    final index = QaActionIndex(catalog, aiTags: tags);
    final projected = index.equipmentCatalog();
    final plan = TrainingPlan(
      id: 'tag-equipment-admission',
      source: 'ai',
      title: 'Workout',
      summary: 'Workout',
      goal: 'strength',
      scene: 'gym',
      equipment: const ['band', 'bench', 'mat'],
      level: 1,
      targetMinutes: 5,
      blocks: [
        PlanBlock(
          id: 'main',
          name: 'Main',
          type: BlockType.main,
          items: [
            for (final id in tags.keys)
              PlanItem(
                exerciseId: id,
                mode: catalog[id]!.defaultDose.mode,
                sets: 1,
                reps: catalog[id]!.defaultDose.reps,
                workSeconds: catalog[id]!.defaultDose.seconds,
                perSide: catalog[id]!.unilateral,
                restSeconds: catalog[id]!.defaultDose.restSeconds,
              ),
          ],
        ),
      ],
    );
    final context = CoachContext(scene: 'gym', equipment: plan.equipment.toSet());
    expect(
      PlanValidator(catalog: catalog, profile: _profile()).validate(plan, context).ok,
      isFalse,
    );
    final admitted = PlanValidator(
      catalog: projected,
      profile: _profile(),
    ).validate(plan, context);
    expect(admitted.errors, isEmpty);
    expect(projected['adductors-B']!.equipment, ['bench', 'mat']);
    expect(projected['h-band-standing-adduction']!.equipment, ['band']);
    expect(projected.taxonomy.equipment['bench'], 'bench');
    expect(catalog['adductors-B']!.equipment, ['chair', 'mat']);
    expect(catalog.taxonomy.equipment.containsKey('bench'), isFalse);
    expect(identical(projected['h-wall-angel'], catalog['h-wall-angel']), isTrue);
    final roundtrip = Catalog.fromJson(projected.toJson());
    expect(roundtrip['adductors-B']!.equipment, ['bench', 'mat']);
    expect(roundtrip.taxonomy.equipment.containsKey('bench'), isTrue);
  });

  test('swapping a plan item removes old equipment and declares the replacement', () async {
    final agent = CoachQaAgent(
      client: _SwapModel(),
      catalog: _swapCatalog(),
      profile: _profile(),
      aiTags: {
        'before': _tags(['band']),
        'after': _tags(['dumbbell']),
        'keep': _tags([]),
      },
    );
    final plan = TrainingPlan(
      id: 'swap-equipment',
      source: 'ai',
      title: 'Workout',
      summary: 'Workout',
      goal: 'strength',
      scene: 'gym',
      equipment: const ['band'],
      level: 1,
      targetMinutes: 3,
      blocks: [
        PlanBlock(
          id: 'main',
          name: 'Main',
          type: BlockType.main,
          items: [
            for (final id in ['before', 'keep'])
              PlanItem(
                exerciseId: id,
                mode: DoseMode.time,
                sets: 1,
                workSeconds: 90,
                perSide: false,
                restSeconds: 0,
              ),
          ],
        ),
      ],
    );
    agent.state
      ..place = 'gym'
      ..lastPlan = QaPlanResult(plan, 180, const []);
    final reply = await agent.send('Swap the first item.');
    expect(reply.kind, 'replace');
    expect(reply.planOrderedIds, ['after', 'keep']);
    expect(reply.plan!.equipment, ['dumbbell']);
    expect(agent.state.lastPlan!.plan.equipment, ['dumbbell']);
  });
}
