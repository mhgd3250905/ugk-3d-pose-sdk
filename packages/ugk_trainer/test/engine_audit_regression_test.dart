import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';
import 'support.dart';

SessionPhase work(
  PlanItem item, {
  Side? side,
  int index = 0,
  int set = 1,
  int itemInBlock = 0,
  String? segmentId,
  double seconds = 10,
}) => SessionPhase(
  kind: PhaseKind.work,
  seconds: seconds,
  exerciseId: item.exerciseId,
  item: item,
  itemIndex: index,
  blockIndex: 0,
  itemInBlock: itemInBlock,
  set: set,
  sets: item.sets,
  side: side,
  segmentId: segmentId,
);
SessionPhase done(int count) =>
    SessionPhase(kind: PhaseKind.done, seconds: 0, itemIndex: count);
SessionResult result(
  TrainingPlan p,
  SessionEngine e, {
  int occurrences = 1,
  double seconds = 0,
}) => SessionRecorder(
  plan: p,
  totalExercises: occurrences,
).finish(e, activeSeconds: seconds);
PlanItem compound({bool perSide = false, int sets = 1}) => PlanItem(
  exerciseId: 'ytw',
  mode: DoseMode.time,
  sets: sets,
  workSeconds: 30,
  perSide: perSide,
  restSeconds: 5,
  segments: [
    for (final id in ['Y', 'T', 'W'])
      PlanSegment(id: id, exerciseId: id, mode: DoseMode.time, workSeconds: 10),
  ],
);

void main() {
  group('FlareLab audit: six minimal reproductions', () {
    for (final first in [Side.left, Side.right]) {
      test('${first.name}_first_partial', () {
        final item = timed('audit', 10, perSide: true);
        final e = SessionEngine([
          work(item, side: first),
          work(item, side: first == Side.left ? Side.right : Side.left),
          done(1),
        ]);
        e.update(10);
        e.finish(12);
        final r = result(planOf([item]), e, seconds: 12);
        expect(r.items.single.completedSets, 0);
        expect(r.items.single.status, ItemStatus.partial);
        expect(r.completedExercises, 0);
        expect(r.full, isFalse);
      });
    }
    test('left_first_complete_control', () {
      final item = timed('audit', 10, perSide: true);
      final e = SessionEngine([
        work(item, side: Side.left),
        work(item, side: Side.right),
        done(1),
      ])..update(20);
      final r = result(planOf([item]), e);
      expect(r.items.single.completedSets, 1);
      expect(r.items.single.status, ItemStatus.completed);
      expect(r.completedExercises, 1);
      expect(r.full, isTrue);
    });
    test('same compound set requires explicit Y/T/W segment identities', () {
      final item = compound();
      final e = SessionEngine([
        for (final id in ['Y', 'T', 'W']) work(item, segmentId: id),
        done(1),
      ]);
      e.update(10);
      e.skip(11);
      final r = result(planOf([item]), e);
      expect(r.items.single.completedSets, 0);
      expect(r.items.single.status, ItemStatus.partial);
      expect(r.completedExercises, 0);
      expect(r.full, isFalse);
    });
    test('distinct_plan_items_segments_control', () {
      final items = [
        for (final id in ['Y', 'T', 'W']) timed(id, 10),
      ];
      final e = SessionEngine([
        for (var n = 0; n < 3; n++) work(items[n], index: n, itemInBlock: n),
        done(3),
      ]);
      e.update(10);
      e.skip(11);
      e.skip(12);
      final r = result(planOf(items), e, occurrences: 3);
      expect(r.items.map((i) => i.status), [
        ItemStatus.completed,
        ItemStatus.skipped,
        ItemStatus.skipped,
      ]);
      expect(r.completedExercises, 1);
      expect(r.full, isFalse);
    });
    test(
      'default_builder_repeated_set_visit counts once but accumulates time',
      () {
        final p = planOf([timed('audit', 10, sets: 2, rest: 0)]);
        final e = SessionEngine(SessionBuilder(prepSeconds: 0).phases(p));
        e.update(10);
        e.previous(11);
        e.update(21);
        e.finish(22);
        final r = result(p, e, seconds: 22);
        expect(r.items.single.completedSets, 1);
        expect(r.items.single.activeSeconds, 22);
        expect(r.items.single.status, ItemStatus.partial);
        expect(r.completedExercises, 0);
        expect(r.full, isFalse);
      },
    );
  });
  test('fractional exact endpoint advances despite subtraction rounding', () {
    final item = timed('a', 1);
    final e = SessionEngine([
      work(item, seconds: 0.1),
      work(item, set: 2, seconds: 0.2),
      done(1),
    ]);
    e.update(0.3);
    expect(e.done, isTrue);
    expect(e.visits.length, 2);
    final before = SessionEngine([work(item, seconds: 0.3), done(1)]);
    before.update(0.3 - 0.000001);
    expect(before.done, isFalse);
  });
  test(
    'segments keep one occurrence and require every side of every segment',
    () {
      final item = compound(perSide: true, sets: 2);
      final p = planOf([item]);
      final builder = SessionBuilder(prepSeconds: 0, switchSideSeconds: 0);
      final phases = builder.phases(p);
      final workPhases = phases.where((p) => p.isWork).toList();
      expect(builder.occurrenceCount(p), 1);
      expect(workPhases.map((p) => p.exerciseId), [
        'Y',
        'Y',
        'T',
        'T',
        'W',
        'W',
        'Y',
        'Y',
        'T',
        'T',
        'W',
        'W',
      ]);
      expect(workPhases.every((p) => identical(p.item, item)), isTrue);
      final e = SessionEngine(phases)..update(125);
      final r = result(p, e);
      expect(r.items.single.exerciseId, 'ytw');
      expect(r.items.single.replacedFrom, isNull);
      expect(r.items.single.completedSets, 2);
      expect(r.items.single.completedSideSets, {'right': 2, 'left': 2});
      expect(r.completedExercises, 1);
    },
  );
  test('skipping a segment retains later segments but marks item partial', () {
    final p = planOf([compound()]);
    final e = SessionEngine(SessionBuilder(prepSeconds: 0).phases(p));
    e.update(10);
    expect(e.skipSegment(11), isTrue);
    expect(e.phase.segmentId, 'W');
    e.update(21);
    final r = result(p, e);
    expect(r.items.single.completedSets, 0);
    expect(r.items.single.status, ItemStatus.partial);
    expect(r.completedExercises, 0);
    expect(r.items.single.activeSeconds, 21);
  });
  test(
    'rest extension preserves elapsed time and naturally finishes later',
    () {
      final p = planOf([timed('a', 10, sets: 2, rest: 5)]);
      final e = SessionEngine(SessionBuilder(prepSeconds: 0).phases(p))
        ..update(12);
      expect(e.extendRest(12), isTrue);
      expect(e.phaseStart, 10);
      expect(e.remainingIn(12), 18);
      expect(e.phase.seconds, 20);
      e.update(29.9);
      expect(e.phase.kind, PhaseKind.rest);
      e.update(30);
      expect(e.phase.set, 2);
      expect(e.phase.isWork, isTrue);
      expect(e.extendRest(31), isFalse);
      expect(() => e.extendRest(31, seconds: double.nan), throwsArgumentError);
    },
  );
  test(
    'early timed completion counts its side, counted work cannot use it',
    () {
      final p = planOf([timed('a', 10, perSide: true)]);
      final e = SessionEngine(
        SessionBuilder(prepSeconds: 0, switchSideSeconds: 0).phases(p),
      );
      e.update(0);
      e.update(0);
      expect(e.completeTimedPhase(2), isTrue);
      e.update(2);
      expect(e.completeTimedPhase(4), isTrue);
      final r = result(p, e);
      expect(r.items.single.completedSets, 1);
      expect(r.items.single.activeSeconds, 4);
      final counted = SessionEngine(
        SessionBuilder(
          prepSeconds: 0,
          rhythms: {'a': Rhythm.fromRepSeconds(3)},
        ).phases(planOf([reps('a', 5)])),
      );
      expect(counted.completeTimedPhase(1), isFalse);
    },
  );
  test('late timed completion never completes the next segment', () {
    final p = planOf([compound()]);
    final e = SessionEngine(SessionBuilder(prepSeconds: 0).phases(p))
      ..update(0);
    expect(e.completeTimedPhase(10), isFalse);
    expect(e.phase.segmentId, 'T');
    expect(e.visits.where((v) => v.phase.isWork).length, 1);
    expect(e.skipSegment(20), isFalse);
    expect(e.phase.segmentId, 'W');
  });
  test('missing rhythm automatically counts at public configured pace', () {
    final p = planOf([reps('unknown', 4)]);
    final e = SessionEngine(
      SessionBuilder(
        prepSeconds: 0,
        rhythmDefaults: const RhythmDefaults(defaultRepSeconds: 2.5),
      ).phases(p),
    );
    e.update(0);
    expect(e.phase.countedOnClock, isTrue);
    expect(e.phase.repAt(5), 3);
    expect(e.awaitingCompletion, isFalse);
    e.update(10);
    expect(e.done, isTrue);
    expect(result(p, e).items.single.completedSets, 1);
  });
  test(
    'each segment uses its own dose and explicit rhythm or hold default',
    () {
      final item = PlanItem(
        exerciseId: 'parent',
        mode: DoseMode.time,
        sets: 1,
        workSeconds: 999,
        perSide: false,
        restSeconds: 0,
        segments: const [
          PlanSegment(
            id: 'hold',
            exerciseId: 'hold',
            mode: DoseMode.reps,
            reps: 3,
            holdSeconds: 7,
          ),
          PlanSegment(
            id: 'paced',
            exerciseId: 'paced',
            mode: DoseMode.reps,
            reps: 2,
            rhythm: {
              'kind': 'rep_updown',
              'leadSeconds': 0,
              'phases': [
                {'id': 'go', 'seconds': 2},
              ],
            },
          ),
        ],
      );
      final phases = SessionBuilder()
          .phases(planOf([item]))
          .where((p) => p.isWork)
          .toList();
      expect(phases.map((p) => p.seconds), [21, 4]);
      expect(phases.map((p) => p.reps), [3, 2]);
      expect(phases.first.holdSeconds, 7);
      expect(phases.every((p) => p.item == item), isTrue);
    },
  );
  test(
    'substituted compound item reports parent identity and adds retry time',
    () {
      final original = compound();
      final p = planOf([original]);
      final b = SessionBuilder(prepSeconds: 0);
      final e = SessionEngine(b.phases(p))..update(2);
      final replacement = original.copyWith(exerciseId: 'gentle-ytw');
      e.restartWith(b.phases(planOf([replacement])), 2);
      e.update(32);
      final r = result(p, e);
      expect(r.items.single.exerciseId, 'gentle-ytw');
      expect(r.items.single.replacedFrom, 'ytw');
      expect(r.items.single.activeSeconds, 32);
      expect(r.items.single.completedSets, 1);
      expect(r.completedExercises, 1);
    },
  );
  test('direct plans cannot collapse segments by reusing their identity', () {
    final part = compound().segments.first;
    final item = compound().copyWith(segments: [part, part]);
    expect(() => SessionBuilder().phases(planOf([item])), throwsArgumentError);
  });
  test('segment hold overrides catalog default go pace', () {
    final item = PlanItem(
      exerciseId: 'parent',
      mode: DoseMode.time,
      sets: 1,
      workSeconds: 999,
      perSide: false,
      restSeconds: 0,
      segments: const [
        PlanSegment(
          id: 'hold',
          exerciseId: 'hold',
          mode: DoseMode.reps,
          reps: 3,
          holdSeconds: 7,
        ),
      ],
    );
    final phase = SessionBuilder(
      rhythms: {'hold': Rhythm.forDose(DoseMode.reps)},
    ).phases(planOf([item])).singleWhere((p) => p.isWork);
    expect(phase.seconds, 21);
    expect(phase.repSeconds, 7);
    expect(phase.holdSeconds, 7);
  });
  test('plans cannot introduce self paced markers outside the catalog', () {
    final item = compound().copyWith(
      segments: const [
        PlanSegment(
          id: 'try',
          exerciseId: 'a',
          mode: DoseMode.reps,
          reps: 2,
          rhythm: {'kind': 'self_paced'},
        ),
      ],
    );
    expect(() => SessionBuilder().phases(planOf([item])), throwsArgumentError);
  });
  test('legacy SessionBuilder rhythmOf override remains active', () {
    final phase = _CustomRhythmBuilder()
        .phases(planOf([reps('a', 2)]))
        .singleWhere((p) => p.isWork);
    expect(phase.seconds, 8);
  });
}

class _CustomRhythmBuilder extends SessionBuilder {
  @override
  Rhythm rhythmOf(PlanItem item) => Rhythm.fromRepSeconds(4);
}
