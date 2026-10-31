import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

import 'support.dart';

final _catalog = Catalog(
  version: 'non-main-rounds',
  drills: [
    for (final id in ['a', 'b', 'tail'])
      Drill(
        id: id,
        name: LocalizedText({'en': id}),
        category: 'mobility',
        muscleGroups: const ['abs'],
        position: 'standing',
        unilateral: id == 'b',
        level: 1,
        scenes: const ['home'],
        defaultDose: const Dose(
          mode: DoseMode.time,
          sets: 1,
          seconds: 10,
          restSeconds: 0,
        ),
      ),
  ],
);

void _expectTimeParity(TrainingPlan plan, SessionBuilder builder) {
  final phases = builder.phases(plan);
  final scheduled = phases.fold(0.0, (sum, phase) => sum + phase.seconds);
  final card = const PlanDuration(
    prepSeconds: 15,
  ).estimateSeconds(plan, _catalog);
  expect(scheduled, card);
  final engine = SessionEngine(phases)..update(scheduled);
  expect(engine.done, isTrue);
  expect(engine.fullyCompletedExercises, builder.occurrenceCount(plan));
  expect(
    engine.visits.fold(0.0, (sum, visit) => sum + visit.seconds),
    scheduled,
  );
}

void main() {
  test(
    'ordered warmup/main/cooldown each finish all rounds before the next block',
    () {
      final plan = TrainingPlan(
        id: 'all-three',
        source: 'ai',
        title: 'All three phases',
        goal: 'mobility',
        scene: 'home',
        level: 1,
        targetMinutes: 5,
        blocks: [
          PlanBlock(
            id: 'warmup',
            name: 'Warmup',
            type: BlockType.warmup,
            rounds: 2,
            restBetweenRoundsSeconds: 21,
            items: [timed('a', 8, sets: 2, rest: 7)],
          ),
          PlanBlock(
            id: 'main',
            name: 'Main',
            type: BlockType.main,
            rounds: 3,
            restBetweenRoundsSeconds: 29,
            items: [timed('b', 9, perSide: true)],
          ),
          PlanBlock(
            id: 'cooldown',
            name: 'Cooldown',
            type: BlockType.cooldown,
            rounds: 2,
            restBetweenRoundsSeconds: 17,
            items: [timed('tail', 10)],
          ),
        ],
      );
      final builder = SessionBuilder(prepSeconds: 15);
      final phases = builder.phases(plan);
      expect(builder.occurrenceCount(plan), 7);
      expect(
        phases.where((phase) => phase.isWork).map((phase) => phase.blockName),
        [
          for (var i = 0; i < 4; i++) 'Warmup',
          for (var i = 0; i < 6; i++) 'Main',
          for (var i = 0; i < 2; i++) 'Cooldown',
        ],
      );
      expect(
        phases
            .where((phase) => phase.kind == PhaseKind.roundRest)
            .map((phase) => phase.seconds),
        [21, 29, 29, 17],
      );
      _expectTimeParity(plan, builder);
      final result = SessionRecorder(
        plan: plan,
        totalExercises: 7,
      ).finish(SessionEngine(phases)..update(10000), activeSeconds: 1);
      expect(result.full, isTrue);
      expect(result.items.map((item) => item.plannedSets), [4, 3, 2]);
      expect(result.items.map((item) => item.completedSets), [4, 3, 2]);
    },
  );

  for (final type in [BlockType.warmup, BlockType.cooldown]) {
    for (final rounds in [2, 3]) {
      for (final rest in [0, 37]) {
        test(
          '${type.name} x$rounds repeats ordered sets/sides with round rest $rest',
          () {
            final plan = planOf(
              [timed('a', 11, sets: 2, rest: 7), timed('b', 13, perSide: true)],
              type: type,
              rounds: rounds,
              restBetweenRounds: rest,
              more: [
                PlanBlock(
                  id: 'tail',
                  type: BlockType.main,
                  name: 'Next block',
                  items: [timed('tail', 9)],
                ),
              ],
            );
            final builder = SessionBuilder(prepSeconds: 15);
            final phases = builder.phases(plan);
            final work = phases.where((phase) => phase.isWork).toList();
            expect(builder.occurrenceCount(plan), rounds * 2 + 1);
            expect(
              work.map(
                (phase) => (
                  phase.exerciseId,
                  phase.itemIndex,
                  phase.set,
                  phase.side,
                  phase.round,
                  phase.rounds,
                ),
              ),
              [
                for (var round = 1; round <= rounds; round++) ...[
                  ('a', (round - 1) * 2, 1, null, round, rounds),
                  ('a', (round - 1) * 2, 2, null, round, rounds),
                  ('b', (round - 1) * 2 + 1, 1, Side.right, round, rounds),
                  ('b', (round - 1) * 2 + 1, 1, Side.left, round, rounds),
                ],
                ('tail', rounds * 2, 1, null, 0, 0),
              ],
            );
            expect(
              phases
                  .where((phase) => phase.kind == PhaseKind.roundRest)
                  .map((phase) => (phase.round, phase.rounds, phase.seconds)),
              [
                for (var round = 2; round <= rounds; round++)
                  (round, rounds, rest < 15 ? 15.0 : rest.toDouble()),
              ],
            );
            expect(
              phases.where((phase) => phase.kind == PhaseKind.switchSide),
              hasLength(rounds),
            );
            _expectTimeParity(plan, builder);
            final engine = SessionEngine(phases)..update(10000);
            final result = SessionRecorder(
              plan: plan,
              totalExercises: builder.occurrenceCount(plan),
            ).finish(engine, activeSeconds: 1);
            expect(result.full, isTrue);
            expect(result.items.map((item) => item.plannedSets), [
              rounds * 2,
              rounds,
              1,
            ]);
            expect(result.items.map((item) => item.completedSets), [
              rounds * 2,
              rounds,
              1,
            ]);
            expect(result.items[1].plannedSideSets, {
              'right': rounds,
              'left': rounds,
            });
          },
        );
      }
    }

    test(
      '${type.name} rounds preserve grouped segments and their set rests',
      () {
        const group = PlanItem(
          exerciseId: 'a',
          mode: DoseMode.time,
          sets: 2,
          perSide: true,
          restSeconds: 9,
          segments: [
            PlanSegment(
              id: 'first',
              exerciseId: 'a',
              mode: DoseMode.time,
              workSeconds: 4,
            ),
            PlanSegment(
              id: 'second',
              exerciseId: 'b',
              mode: DoseMode.time,
              workSeconds: 6,
            ),
          ],
        );
        final plan = planOf(
          [group],
          type: type,
          rounds: 2,
          restBetweenRounds: 37,
        );
        final builder = SessionBuilder(prepSeconds: 15);
        final phases = builder.phases(plan);
        expect(
          phases
              .where((phase) => phase.isWork)
              .map(
                (phase) => (
                  phase.round,
                  phase.itemIndex,
                  phase.set,
                  phase.segmentId,
                  phase.side,
                ),
              ),
          [
            for (var round = 1; round <= 2; round++)
              for (var set = 1; set <= 2; set++)
                for (final segment in ['first', 'second'])
                  for (final side in [Side.right, Side.left])
                    (round, round - 1, set, segment, side),
          ],
        );
        expect(
          phases
              .where(
                (phase) =>
                    phase.kind == PhaseKind.rest &&
                    phase.nextExerciseId == null,
              )
              .map((phase) => phase.seconds),
          [9, 9],
        );
        _expectTimeParity(plan, builder);
        final result = SessionRecorder(
          plan: plan,
          totalExercises: 2,
        ).finish(SessionEngine(phases)..update(10000), activeSeconds: 1);
        expect(result.items.single.plannedSets, 4);
        expect(result.items.single.completedSets, 4);
        expect(result.items.single.completedSideSets, {'right': 4, 'left': 4});
      },
    );

    test('${type.name} round boundary retains the generic ordinal voice', () {
      final script = SessionScript(source: smartSource());
      Iterable<String> clips(BlockType kind) {
        final phases = SessionBuilder().phases(
          planOf(
            [timed('h-squat', 10), timed('w-dead-bug', 10)],
            type: kind,
            rounds: 3,
            restBetweenRounds: 40,
          ),
        );
        final rest = phases.firstWhere(
          (phase) => phase.kind == PhaseKind.roundRest,
        );
        return script.cues(rest, planSeconds: 300).expand((cue) => cue.clips);
      }

      expect(clips(type), clips(BlockType.main));
      expect(
        clips(type),
        containsAll(['p.round_done', 'p.di', 'n.2', 'u.rounds']),
      );
    });

    test(
      '${type.name} unknown action fallback retains every planned round set',
      () {
        final plan = planOf(
          [timed('missing', 10, sets: 2)],
          type: type,
          rounds: 3,
        );
        final builder = SessionBuilder(known: (_) => false);
        final result = SessionRecorder(
          plan: plan,
          totalExercises: 0,
        ).finish(SessionEngine(builder.phases(plan)), activeSeconds: 0);
        expect(result.items.single.plannedSets, 6);
        expect(result.items.single.completedSets, 0);
        expect(result.items.single.status, ItemStatus.notReached);
      },
    );

    test(
      '${type.name} skip/previous retain later rounds and early finish state',
      () {
        final plan = planOf(
          [timed('a', 10), timed('b', 10)],
          type: type,
          rounds: 3,
        );
        final engine = SessionEngine(
          SessionBuilder(prepSeconds: 0).phases(plan),
        )..update(0);
        engine.skip(1);
        engine.skip(1);
        expect(
          (engine.phase.exerciseId, engine.phase.round, engine.phase.itemIndex),
          ('b', 1, 1),
        );
        engine.skip(2);
        engine.skip(2);
        expect(
          (engine.phase.exerciseId, engine.phase.round, engine.phase.itemIndex),
          ('a', 2, 2),
        );
        engine.previous(3);
        expect(
          (engine.phase.exerciseId, engine.phase.round, engine.phase.itemIndex),
          ('b', 1, 1),
        );
        expect(
          engine.phases.where((phase) => phase.isWork && phase.round == 3),
          hasLength(2),
        );
        engine.finish(4);
        final result = SessionRecorder(
          plan: plan,
          totalExercises: 6,
        ).finish(engine, activeSeconds: 4);
        expect(result.endedEarly, isTrue);
        expect(result.full, isFalse);
        expect(result.items.map((item) => item.plannedSets), [3, 3]);
        expect(engine.visits.where((visit) => visit.phase.round == 3), isEmpty);
      },
    );
  }
}
