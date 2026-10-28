import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

void main() {
  test(
    'a shortened custom clock phase records complete cycles, not its target',
    () {
      final plan = planOf([reps('a', 10)]);
      final engine = SessionEngine([
        SessionPhase(
          kind: PhaseKind.work,
          seconds: 4,
          exerciseId: 'a',
          item: plan.blocks.single.items.single,
          itemIndex: 0,
          blockIndex: 0,
          itemInBlock: 0,
          set: 1,
          sets: 1,
          reps: 10,
          rhythm: Rhythm.fromRepSeconds(2),
        ),
        const SessionPhase(kind: PhaseKind.done, seconds: 0),
      ])..update(5);
      final result = SessionRecorder(
        plan: plan,
        totalExercises: 1,
      ).finish(engine, activeSeconds: 4);
      expect(result.items.single.completedReps, 2);
    },
  );

  test('only completed clock cycles count on a partial or skipped action', () {
    final plan = planOf([reps('a', 10), timed('b', 40)]);
    final engine = SessionEngine(
      SessionBuilder(
        prepSeconds: 0,
        transitionSeconds: 0,
        rhythms: {'a': Rhythm.fromRepSeconds(2)},
      ).phases(plan),
    );
    engine.update(5.9);
    engine.skip(5.9);
    engine.finish(9.9);
    final result = SessionRecorder(
      plan: plan,
      totalExercises: 2,
    ).finish(engine, activeSeconds: 9.9);
    expect(result.items.first.completedReps, 2);
    expect(result.items.first.status, ItemStatus.skipped);
    expect(result.items.last.completedReps, isNull);
    expect(result.completedReps, 2);
    expect(result.workSeconds, closeTo(9.9, .001));
    expect(SessionResult.fromJson(result.toJson()).toJson(), result.toJson());
  });

  test('self-paced repetitions are recorded only after user confirmation', () {
    final plan = planOf([reps('a', 8, sets: 2, rest: 0)]);
    final engine = SessionEngine(
      SessionBuilder(
        prepSeconds: 0,
        transitionSeconds: 0,
        rhythms: {'a': Rhythm.selfPacedReps},
      ).phases(plan),
    );
    engine.update(1);
    engine.completeSet(6);
    engine.update(7);
    engine.finish(9);
    final result = SessionRecorder(
      plan: plan,
      totalExercises: 1,
    ).finish(engine, activeSeconds: 9);
    expect(result.items.single.completedReps, 8);
    expect(result.completedReps, 8);
  });

  test('feeling is additive; old JSON remains readable and omits it', () {
    final plan = planOf([timed('a', 1)]);
    final engine = SessionEngine(SessionBuilder(prepSeconds: 0).phases(plan))
      ..update(2);
    final result = SessionRecorder(
      plan: plan,
      totalExercises: 1,
    ).finish(engine, activeSeconds: 1);
    expect(result.toJson().containsKey('feeling'), isFalse);
    final feedback = result.withFeeling(TrainingFeeling.justRight);
    expect(feedback.sessionId, result.sessionId);
    expect(feedback.items, same(result.items));
    expect(
      SessionResult.fromJson(feedback.toJson()).feeling,
      TrainingFeeling.justRight,
    );
    expect(SessionResult.fromJson(result.toJson()).feeling, isNull);
  });
}
