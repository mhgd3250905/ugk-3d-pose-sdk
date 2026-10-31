import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

import 'support.dart';

List<SessionPhase> _work(List<SessionPhase> phases) =>
    phases.where((phase) => phase.isWork).toList();

void main() {
  for (final rounds in [1, 2, 3]) {
    test(
      'main $rounds rounds repeats the whole block and preserves sets/sides',
      () {
        final plan = planOf(
          [timed('a', 11, sets: 2, rest: 7), timed('b', 13, perSide: true)],
          rounds: rounds,
          restBetweenRounds: 37,
        );
        final builder = SessionBuilder(prepSeconds: 0);
        final phases = builder.phases(plan);
        final work = _work(phases);

        expect(builder.occurrenceCount(plan), rounds * 2);
        expect(
          work.map(
            (phase) =>
                (phase.exerciseId, phase.itemIndex, phase.set, phase.side),
          ),
          [
            for (var round = 0; round < rounds; round++) ...[
              ('a', round * 2, 1, null),
              ('a', round * 2, 2, null),
              ('b', round * 2 + 1, 1, Side.right),
              ('b', round * 2 + 1, 1, Side.left),
            ],
          ],
        );
        expect(work.map((phase) => (phase.round, phase.rounds)), [
          for (var round = 1; round <= rounds; round++)
            for (var part = 0; part < 4; part++)
              (rounds > 1 ? round : 0, rounds > 1 ? rounds : 0),
        ]);
        expect(
          work
              .where((phase) => phase.exerciseId == 'a')
              .map((phase) => phase.sets),
          everyElement(2),
        );
        expect(
          phases.where((phase) => phase.kind == PhaseKind.switchSide),
          hasLength(rounds),
        );
        expect(
          phases
              .where(
                (phase) =>
                    phase.kind == PhaseKind.rest &&
                    phase.nextExerciseId == null,
              )
              .map((phase) => phase.seconds),
          List.filled(rounds, 7),
        );
        final rests = phases
            .where((phase) => phase.kind == PhaseKind.roundRest)
            .toList();
        expect(rests, hasLength(rounds - 1));
        expect(
          rests.map(
            (phase) => (
              phase.round,
              phase.rounds,
              phase.nextExerciseId,
              phase.doneExerciseId,
            ),
          ),
          [
            for (var round = 2; round <= rounds; round++)
              (round, rounds, 'a', 'b'),
          ],
        );
      },
    );
  }

  test(
    'main multi-round grouping retains every segment on both sides in every set',
    () {
      const group = PlanItem(
        exerciseId: 'group',
        mode: DoseMode.time,
        sets: 2,
        perSide: true,
        restSeconds: 9,
        segments: [
          PlanSegment(
            id: 'y',
            exerciseId: 'y',
            mode: DoseMode.time,
            workSeconds: 4,
          ),
          PlanSegment(
            id: 't',
            exerciseId: 't',
            mode: DoseMode.time,
            workSeconds: 6,
          ),
        ],
      );
      final phases = SessionBuilder(
        prepSeconds: 0,
      ).phases(planOf([group, timed('b', 8)], rounds: 2));
      final work = _work(phases);
      expect(work, hasLength(18));
      expect(
        work.map(
          (phase) => (phase.itemIndex, phase.set, phase.segmentId, phase.side),
        ),
        [
          for (var round = 0; round < 2; round++) ...[
            for (var set = 1; set <= 2; set++)
              for (final segment in ['y', 't'])
                for (final side in [Side.right, Side.left])
                  (round * 2, set, segment, side),
            (round * 2 + 1, 1, null, null),
          ],
        ],
      );
      expect(
        phases.where((phase) => phase.kind == PhaseKind.switchSide),
        hasLength(8),
      );
      expect(
        phases
            .where(
              (phase) =>
                  phase.kind == PhaseKind.rest && phase.nextExerciseId == null,
            )
            .map((phase) => (phase.itemIndex, phase.seconds)),
        [(0, 9), (2, 9)],
      );
      final engine = SessionEngine(phases)..update(10000);
      final result = SessionRecorder(
        plan: planOf([group, timed('b', 8)], rounds: 2),
        totalExercises: 4,
      ).finish(engine, activeSeconds: 1);
      expect(result.items.first.plannedSets, 4);
      expect(result.items.first.completedSets, 4);
      expect(result.items.first.plannedSideSets, {'right': 4, 'left': 4});
      expect(result.items.first.completedSideSets, {'right': 4, 'left': 4});
      expect(result.completedExercises, 4);
      expect(result.full, isTrue);
    },
  );

  test(
    'circuit retains one set per round while main retains authored sets',
    () {
      final items = [timed('a', 10, sets: 3, rest: 4), timed('b', 12)];
      final builder = SessionBuilder(prepSeconds: 0);
      final main = _work(builder.phases(planOf(items, rounds: 2)));
      final circuit = _work(
        builder.phases(planOf(items, type: BlockType.circuit, rounds: 2)),
      );
      expect(main.where((phase) => phase.exerciseId == 'a'), hasLength(6));
      expect(circuit.where((phase) => phase.exerciseId == 'a'), hasLength(2));
      expect(circuit.map((phase) => phase.sets), everyElement(1));
    },
  );

  test(
    'main round boundary receives the same finish and ordinal voice as circuit',
    () {
      final source = smartSource();
      final script = SessionScript(source: source);
      List<VoiceCue> cues(BlockType type) {
        final phases = SessionBuilder().phases(
          planOf(
            [timed('h-squat', 10), timed('w-dead-bug', 10)],
            type: type,
            rounds: 3,
            restBetweenRounds: 40,
          ),
        );
        final rest = phases.firstWhere(
          (phase) => phase.kind == PhaseKind.roundRest,
        );
        expect((rest.round, rest.rounds), (2, 3));
        return script.cues(rest, planSeconds: 300);
      }

      final main = cues(BlockType.main);
      final circuit = cues(BlockType.circuit);
      expect(main.map((cue) => cue.at), circuit.map((cue) => cue.at));
      expect(main.map((cue) => cue.clips), circuit.map((cue) => cue.clips));
      expect(
        main.expand((cue) => cue.clips),
        containsAll(['p.round_done', 'p.di', 'n.2', 'u.rounds']),
      );
    },
  );

  test(
    'skip and previous navigate occurrences without removing future rounds',
    () {
      final plan = planOf([timed('a', 10), timed('b', 10)], rounds: 3);
      final engine = SessionEngine(SessionBuilder(prepSeconds: 0).phases(plan))
        ..update(0);
      expect(
        (engine.phase.exerciseId, engine.phase.round, engine.phase.itemIndex),
        ('a', 1, 0),
      );
      engine.skip(1);
      expect(
        (
          engine.phase.kind,
          engine.phase.nextExerciseId,
          engine.phase.itemIndex,
        ),
        (PhaseKind.rest, 'b', 1),
      );
      engine.skip(1);
      expect(
        (engine.phase.exerciseId, engine.phase.round, engine.phase.itemIndex),
        ('b', 1, 1),
      );
      engine.skip(2);
      expect(
        (engine.phase.kind, engine.phase.round, engine.phase.itemIndex),
        (PhaseKind.roundRest, 2, 2),
      );
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
      expect(
        engine.visits.where((visit) => visit.exit == PhaseExit.skipped),
        isNotEmpty,
      );
    },
  );

  test('main round previews still announce authored multiple sets', () {
    final source = smartSource();
    final script = SessionScript(source: source);
    final plan = planOf(
      [timed('h-squat', 30, sets: 2), timed('w-dead-bug', 30, sets: 2)],
      rounds: 2,
      restBetweenRounds: 80,
    );
    final phases = SessionBuilder(transitionSeconds: 80).phases(plan);
    final previews = phases.where((phase) => phase.nextExerciseId != null);
    expect(previews, isNotEmpty);
    for (final phase in previews) {
      expect(phase.sets, 2);
      expect(
        script.cues(phase, planSeconds: 600).expand((cue) => cue.clips),
        containsAll(source.setsPhrase(2)),
      );
    }
  });

  test('unknown main action retains its full planned sets across rounds', () {
    final plan = planOf([timed('missing', 10, sets: 2)], rounds: 3);
    final builder = SessionBuilder(known: (_) => false);
    final engine = SessionEngine(builder.phases(plan));
    final result = SessionRecorder(
      plan: plan,
      totalExercises: 0,
    ).finish(engine, activeSeconds: 0);
    expect(result.items.single.plannedSets, 6);
    expect(result.items.single.completedSets, 0);
    expect(result.items.single.status, ItemStatus.notReached);
  });

  test(
    'ending during the second round records only completed occurrences and actual work',
    () {
      final plan = planOf(
        [timed('a', 5), timed('b', 7)],
        rounds: 3,
        restBetweenRounds: 0,
      );
      final builder = SessionBuilder(prepSeconds: 0, transitionSeconds: 0);
      final engine = SessionEngine(builder.phases(plan))..update(15);
      expect(
        (engine.phase.exerciseId, engine.phase.round, engine.phase.itemIndex),
        ('a', 2, 2),
      );
      engine.finish(15);
      final result = SessionRecorder(
        plan: plan,
        totalExercises: builder.occurrenceCount(plan),
      ).finish(engine, activeSeconds: 15);
      expect(result.endedEarly, isTrue);
      expect(result.full, isFalse);
      expect((result.completedExercises, result.totalExercises), (2, 6));
      expect(
        result.items.map((item) => (item.plannedSets, item.completedSets)),
        [(3, 1), (3, 1)],
      );
      expect(result.items.map((item) => item.activeSeconds), [8, 7]);
      expect(engine.visits.where((visit) => visit.phase.round == 3), isEmpty);
      expect(SessionResult.fromJson(result.toJson()).toJson(), result.toJson());
    },
  );

  test(
    'ending partway through a bilateral set never counts that repeated set complete',
    () {
      final plan = planOf(
        [timed('a', 4, perSide: true)],
        rounds: 2,
        restBetweenRounds: 0,
      );
      final builder = SessionBuilder(
        prepSeconds: 0,
        transitionSeconds: 0,
        switchSideSeconds: 0,
      );
      final engine = SessionEngine(builder.phases(plan))..finish(10);
      final result = SessionRecorder(
        plan: plan,
        totalExercises: 2,
      ).finish(engine, activeSeconds: 10);
      expect(result.completedExercises, 1);
      expect(result.items.single.plannedSets, 2);
      expect(result.items.single.completedSets, 1);
      expect(result.items.single.plannedSideSets, {'right': 2, 'left': 2});
      expect(result.items.single.completedSideSets, {'right': 1, 'left': 1});
      expect(result.items.single.status, ItemStatus.partial);
    },
  );

  test(
    'early ending a later round suppresses finish speech just like circuit',
    () {
      for (final type in [BlockType.main, BlockType.circuit]) {
        final plan = planOf(
          [timed('h-squat', 5), timed('w-dead-bug', 7)],
          type: type,
          rounds: 3,
          restBetweenRounds: 0,
        );
        final runner = SessionRunner(
          SessionEngine(
            SessionBuilder(prepSeconds: 0, transitionSeconds: 0).phases(plan),
          ),
          SessionScript(source: smartSource()),
        );
        runner.update(15);
        expect(runner.engine.phase.round, 2);
        runner.finish(15);
        expect(runner.engine.endedEarly, isTrue);
        expect(runner.update(15), isEmpty);
        expect(runner.update(10000), isEmpty);
      }
    },
  );
}
