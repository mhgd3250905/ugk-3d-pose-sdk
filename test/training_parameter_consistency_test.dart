import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/training_parameters.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('hiplab');
  final parameters = TrainingParameters.infer(
    const [],
    const CoachContext(),
    catalog,
    profile,
  );
  final gate = ToolGate(
    catalog: catalog,
    profile: profile,
    extraRules: [parameters.validate],
  );
  const confirmed = CoachContext(
    scene: 'home',
    equipment: {'mat', 'chair'},
    minutes: 10,
  );

  test('equipment edits preserve, replace or remove the previous gear', () {
    const previous = CoachContext(
      scene: 'home',
      equipment: {'mat'},
      minutes: 10,
    );
    CoachContext infer(String message, [CoachContext context = previous]) =>
        TrainingParameters.infer([message], context, catalog, profile).context;

    for (final message in ['增加椅子', '再加椅子', '把这套计划加上椅子']) {
      final updated = infer(message);
      expect(updated.equipment, {'mat', 'chair'}, reason: message);
      expect(updated.scene, 'home');
      expect(updated.minutes, 10);
    }
    for (final message in ['改成椅子', '只用椅子']) {
      expect(infer(message).equipment, {'chair'}, reason: message);
    }
    expect(infer('不用椅子', confirmed).equipment, {'mat'});
    expect(infer('没有瑜伽垫', confirmed).equipment, {'chair'});
    expect(infer('瑜伽垫不用了，再加椅子').equipment, {'chair'});
    expect(infer('不用椅子', const CoachContext()).equipment, isNull);
  });

  TrainingPlan makePlan({int minutes = 10, List<String>? equipment}) {
    final json = planOf(okEnvelope())
      ..['targetMinutes'] = minutes
      ..['equipment'] = equipment ?? ['mat'];
    return const PlanCodec().decode(json);
  }

  test('fallback template target must match the confirmed minutes', () {
    expect(gate.admitTemplate(makePlan(), confirmed), isNotNull);
    final mismatch = makePlan(minutes: 15);
    final issues = parameters.validate(mismatch, catalog, confirmed).toList();
    expect(
      issues,
      contains(
        isA<PlanIssue>()
            .having((issue) => issue.code, 'code', IssueCodes.contextConflict)
            .having((issue) => issue.path, 'path', 'targetMinutes'),
      ),
    );
    // The exercise dose remains the same, and thus its estimated duration
    // still matches the user's 10-minute selection. Only the label differs.
    expect(gate.admitTemplate(mismatch, confirmed), isNull);
  });

  test('plan gear may be a subset, but cannot declare unconfirmed gear', () {
    // The user owns a mat and a chair; a plan that only needs the mat is OK.
    expect(
      gate.admitTemplate(makePlan(equipment: ['mat']), confirmed),
      isNotNull,
    );
    final mismatch = makePlan(equipment: ['mat', 'dumbbell']);
    final issues = parameters.validate(mismatch, catalog, confirmed).toList();
    expect(
      issues,
      contains(
        isA<PlanIssue>()
            .having((issue) => issue.code, 'code', IssueCodes.equipment)
            .having((issue) => issue.path, 'path', 'equipment')
            .having((issue) => issue.actual, 'actual', 'dumbbell'),
      ),
    );
    expect(gate.admitTemplate(mismatch, confirmed), isNull);
  });

  test('unknown constraints do not invent restrictions', () {
    const unknown = CoachContext();
    final candidate = makePlan(minutes: 15, equipment: ['mat', 'dumbbell']);
    expect(parameters.validate(candidate, catalog, unknown), isEmpty);
  });

  test('equipment metadata matches actual catalog needs', () {
    final missing = parameters
        .validate(makePlan(equipment: []), catalog, confirmed)
        .where((issue) => issue.path == 'equipment')
        .toList();
    expect(missing, isNotEmpty);
    expect(missing.single.expected, 'mat');
    final extra = parameters
        .validate(makePlan(equipment: ['mat', 'chair']), catalog, confirmed)
        .where((issue) => issue.path == 'equipment')
        .toList();
    expect(extra, isNotEmpty);
    expect(extra.single.expected, 'mat');
  });

  test('segments rather than the parent represent performed equipment', () {
    final original = makePlan();
    final candidate = TrainingPlan(
      id: original.id,
      source: original.source,
      title: original.title,
      summary: original.summary,
      goal: original.goal,
      scene: original.scene,
      level: original.level,
      targetMinutes: original.targetMinutes,
      equipment: const [],
      blocks: [
        PlanBlock(
          id: 'b',
          name: 'main',
          type: BlockType.main,
          items: [
            PlanItem(
              // This parent needs a mat but is not the performed segment.
              exerciseId: 'n-windshield',
              mode: DoseMode.reps,
              sets: 1,
              reps: 8,
              perSide: false,
              restSeconds: 0,
              segments: const [
                PlanSegment(
                  id: 's',
                  exerciseId: 'h-squat',
                  mode: DoseMode.reps,
                  reps: 8,
                ),
              ],
            ),
          ],
        ),
      ],
    );
    expect(
      parameters
          .validate(candidate, catalog, confirmed)
          .where((issue) => issue.path == 'equipment'),
      isEmpty,
    );
  });

  test('office chair and wall are both reflected in the actual equipment', () {
    final smartfit = loadProfile('smartfit');
    final officeParameters = TrainingParameters.infer(
      const [],
      const CoachContext(),
      catalog,
      smartfit,
    );
    final officeGate = ToolGate(
      catalog: catalog,
      profile: smartfit,
      extraRules: [officeParameters.validate],
    );
    const office = CoachContext(
      scene: 'office',
      equipment: {'chair', 'wall'},
      minutes: 10,
    );
    TrainingPlan officePlan(List<String> equipment) => TrainingPlan(
      id: 'office-stretch',
      source: 'template',
      title: '办公室拉伸',
      summary: '舒展身体',
      goal: 'relax',
      scene: 'office',
      equipment: equipment,
      level: 1,
      targetMinutes: 10,
      blocks: const [
        PlanBlock(
          id: 'b',
          name: '拉伸',
          type: BlockType.main,
          items: [
            PlanItem(
              exerciseId: 'h-chair-lat',
              mode: DoseMode.time,
              sets: 2,
              workSeconds: 120,
              perSide: false,
              restSeconds: 30,
            ),
            PlanItem(
              exerciseId: 'h-wall-calf',
              mode: DoseMode.time,
              sets: 1,
              workSeconds: 120,
              perSide: true,
              restSeconds: 0,
            ),
          ],
        ),
      ],
    );
    expect(
      officeGate.admitTemplate(officePlan(['chair', 'wall']), office),
      isNotNull,
    );
    expect(officeGate.admitTemplate(officePlan(['chair']), office), isNull);
  });

  test(
    'selected equipment is preferred, not forced into an unsuitable plan',
    () {
      final original = makePlan();
      final candidate = TrainingPlan(
        id: original.id,
        source: original.source,
        title: original.title,
        summary: original.summary,
        goal: original.goal,
        scene: original.scene,
        level: original.level,
        targetMinutes: original.targetMinutes,
        equipment: const [],
        blocks: const [
          PlanBlock(
            id: 'b',
            name: 'main',
            type: BlockType.main,
            items: [
              PlanItem(
                exerciseId: 'h-squat',
                mode: DoseMode.reps,
                sets: 1,
                reps: 8,
                perSide: false,
                restSeconds: 0,
              ),
            ],
          ),
        ],
      );
      expect(
        parameters
            .validate(candidate, catalog, confirmed)
            .where((issue) => issue.path == 'equipment'),
        isEmpty,
      );
    },
  );

  test('the requested default shortcut is recognized', () {
    final p = TrainingParameters.infer(
      ['按默认来'],
      const CoachContext(),
      catalog,
      profile,
    );
    expect(p.skipped, isTrue);
  });
}
