import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

import 'support.dart';

// The adapter consumes the real, checked-in SmartFit pack metadata. In
// particular h-squat has repSeconds=4; the contract must not conceal cadence
// differences by assigning a made-up fallback rhythm to both implementations.
Catalog _catalog() => Catalog.fromJson({
  'format': catalogFormat,
  'formatVersion': supportedCatalogFormatVersion,
  'version': '1.0.0',
  'drills': [
    for (final pack in smartPacks)
      const DrillPackAdapter().toDrillJson(
        loadJson('smartfit/packs/$pack/pack.json'),
      ),
  ],
});

void _expectCardAndExecutionAgree(TrainingPlan plan, Catalog catalog) {
  final originalPlan = plan.toJson();
  final cardSeconds = const PlanDuration().estimateSeconds(plan, catalog);
  final builder = SessionBuilder(rhythms: rhythmsFromCatalog(catalog));
  final phases = builder.phases(plan);
  final scheduledSeconds = phases.fold(
    0.0,
    (sum, phase) => sum + phase.seconds,
  );
  expect(
    scheduledSeconds,
    closeTo(cardSeconds, 1),
    reason:
        '${plan.blocks.map((block) => '${block.type.name} x${block.rounds}').join(', ')}: '
        'Coach card=$cardSeconds, actual phase schedule=$scheduledSeconds',
  );
  expect(builder.planSeconds(plan) + phases.first.seconds, scheduledSeconds);

  // Verify the real engine, not only a second arithmetic estimator. Advance
  // across every phase boundary, including each side, set and repeated block.
  final engine = SessionEngine(phases);
  var elapsed = 0.0;
  for (final phase in phases.where((phase) => phase.kind != PhaseKind.done)) {
    expect(phase.selfPaced, isFalse);
    elapsed += phase.seconds;
    engine.update(elapsed);
  }
  expect(engine.done, isTrue);
  expect(engine.endedEarly, isFalse);
  expect(engine.fullyCompletedExercises, builder.occurrenceCount(plan));
  expect(
    engine.visits.fold(0.0, (sum, visit) => sum + visit.seconds),
    closeTo(cardSeconds, 1),
  );
  expect(plan.toJson(), originalPlan);
}

void main() {
  final catalog = _catalog();
  setUpAll(() {
    expect(catalog.problems, isEmpty);
    expect(catalog['h-squat']!.assets.videos.first.repSeconds, 4);
    expect(rhythmsFromCatalog(catalog)['h-squat']!.cycleFor(), 4);
  });

  for (final rounds in [1, 2, 3]) {
    test('main rounds=$rounds: reps, bilateral sets and group rests agree', () {
      final plan = planOf(
        [
          reps('h-squat', 5, sets: 2, rest: 7),
          timed('s-figure4', 13, sets: 2, perSide: true, rest: 9),
        ],
        rounds: rounds,
        restBetweenRounds: 40,
      );
      _expectCardAndExecutionAgree(plan, catalog);
    });
  }

  for (final rounds in [1, 2, 3]) {
    test('circuit rounds=$rounds retains the same card/execution contract', () {
      final plan = planOf(
        [reps('h-squat', 8), timed('s-figure4', 20, perSide: true)],
        type: BlockType.circuit,
        rounds: rounds,
        restBetweenRounds: 40,
      );
      _expectCardAndExecutionAgree(plan, catalog);
    });
  }

  for (final rest in [0, 5, 15, 50]) {
    test('main round rest=$rest shares Coach transition-floor arithmetic', () {
      _expectCardAndExecutionAgree(
        planOf(
          [timed('s-figure4', 12, perSide: true)],
          rounds: 2,
          restBetweenRounds: rest,
        ),
        catalog,
      );
    });
  }

  test('main rounds repeat ordered bilateral segments inside every set', () {
    final item = PlanItem(
      exerciseId: 's-figure4',
      mode: DoseMode.time,
      sets: 2,
      perSide: true,
      restSeconds: 9,
      segments: const [
        PlanSegment(
          id: 'figure4',
          exerciseId: 's-figure4',
          mode: DoseMode.time,
          workSeconds: 13,
        ),
        PlanSegment(
          id: 'couch',
          exerciseId: 'h-couch-stretch',
          mode: DoseMode.time,
          workSeconds: 7,
        ),
      ],
    );
    _expectCardAndExecutionAgree(
      planOf([item], rounds: 3, restBetweenRounds: 35),
      catalog,
    );
  });

  test('warmup, repeated main and cooldown use one continuous card clock', () {
    final plan = TrainingPlan(
      id: 'mixed-main-rounds',
      source: 'ai',
      title: 'Mixed repeated plan',
      goal: 'mobility',
      scene: 'home',
      level: 1,
      targetMinutes: 10,
      blocks: [
        PlanBlock(
          id: 'warmup',
          name: 'Warm up',
          type: BlockType.warmup,
          items: [reps('h-squat', 4)],
        ),
        PlanBlock(
          id: 'main',
          name: 'Main',
          type: BlockType.main,
          rounds: 3,
          restBetweenRoundsSeconds: 40,
          items: [
            reps('w-dead-bug', 5, sets: 2, rest: 12),
            timed('s-figure4', 12, perSide: true),
          ],
        ),
        PlanBlock(
          id: 'cooldown',
          name: 'Cool down',
          type: BlockType.cooldown,
          items: [timed('h-couch-stretch', 15, perSide: true)],
        ),
      ],
    );
    _expectCardAndExecutionAgree(plan, catalog);
  });
}
