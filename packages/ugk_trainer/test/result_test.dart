// ugk_trainer regressions: one SessionResult per session, its id fixed at
// start; saving again (retry) never makes a second record (3D-Body's
// Session ID collision).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

import 'support.dart';

void main() {
  final plan = planOf([
    reps('h-squat', 10, sets: 2, rest: 30),
    timed('s-figure4', 30, perSide: true),
    reps('w-dead-bug', 8),
  ]);
  SessionBuilder builder() => SessionBuilder(rhythms: smartRhythms());

  test('the id is fixed at start and the result is frozen on finish', () {
    final e = SessionEngine(builder().phases(plan));
    final r = SessionRecorder(plan: plan, totalExercises: 3);
    final id = r.sessionId;
    expect(id, startsWith('s-'));
    e.update(1e6);
    final a = r.finish(e, activeSeconds: 300);
    final b = r.finish(e, activeSeconds: 999);
    expect(identical(a, b), isTrue);
    expect(a.sessionId, id);
    expect(a.activeSeconds, 300);
    expect(SessionRecorder(plan: plan, totalExercises: 3).sessionId, isNot(id));
    expect(
      SessionRecorder(
        plan: plan,
        totalExercises: 3,
        sessionId: 'fixed',
      ).sessionId,
      'fixed',
    );
  });

  test('per item: sets done, active seconds, skipped, not reached', () {
    final e = SessionEngine(builder().phases(plan));
    final r = SessionRecorder(plan: plan, totalExercises: 3);
    e.update(10 + 40 + 30 + 40 + 1); // into the transition after h-squat
    e.update(15 + 10 + 40 + 30 + 40 + 2); // into s-figure4 right side
    e.skip(e.phaseStart + 5);
    r.discomfort(
      DiscomfortEvent(
        at: 1,
        exerciseId: 'w-dead-bug',
        action: DiscomfortAction.end,
      ),
    );
    e.finish(e.phaseStart + 1);
    final res = r.finish(e, activeSeconds: 200);
    expect(res.endedEarly, isTrue);
    expect(res.items.map((i) => i.status), [
      ItemStatus.completed,
      ItemStatus.skipped,
      ItemStatus.notReached,
    ]);
    expect(res.items[0].completedSets, 2);
    expect(res.items[0].plannedSets, 2);
    expect(res.items[0].activeSeconds, closeTo(80, 1e-6));
    expect(res.items[1].completedSets, 0);
    expect(res.discomfort.single.action, DiscomfortAction.end);
    final back = SessionResult.fromJson(res.toJson());
    expect(back.toJson(), res.toJson());
  });

  test('a circuit item counts one set per round', () {
    final c = planOf(
      [reps('h-squat', 8), reps('w-dead-bug', 8)],
      type: BlockType.circuit,
      rounds: 3,
    );
    final e = SessionEngine(builder().phases(c))..update(1e6);
    final res = SessionRecorder(
      plan: c,
      totalExercises: 6,
    ).finish(e, activeSeconds: 1);
    expect(res.items.map((i) => (i.plannedSets, i.completedSets)), [
      (3, 3),
      (3, 3),
    ]);
    expect(res.full, isTrue);
  });

  test('self-paced sets count when completed', () {
    final p = planOf([reps('thomas-curl', 12, sets: 2)]);
    final e = SessionEngine(
      SessionBuilder(rhythms: {'thomas-curl': Rhythm.selfPacedReps}).phases(p),
    );
    e.update(10.5);
    e.completeSet(30);
    e.update(30 + 20 + .1);
    e.completeSet(70);
    final res = SessionRecorder(
      plan: p,
      totalExercises: 1,
    ).finish(e, activeSeconds: 70);
    expect(res.items.single.completedSets, 2);
    expect(res.items.single.status, ItemStatus.completed);
    expect(res.items.single.activeSeconds, closeTo(40, 1e-6));
  });

  test('ResultSaver retries a synchronously thrown save error', () async {
    final e = SessionEngine(builder().phases(plan))..update(1e6);
    final result = SessionRecorder(
      plan: plan,
      totalExercises: 3,
    ).finish(e, activeSeconds: 1);
    var calls = 0;
    final saver = ResultSaver((r) {
      if (++calls == 1) throw StateError('disk full');
      return Future<void>.value();
    });
    expect(await saver(result), isFalse);
    expect(await saver(result), isTrue);
    expect(calls, 2);
  });

  test(
    'ResultSaver: a failed save can be retried with the same result; a '
    'saved one is never sent again; concurrent calls share one save',
    () async {
      final e = SessionEngine(builder().phases(plan))..update(1e6);
      final result = SessionRecorder(
        plan: plan,
        totalExercises: 3,
      ).finish(e, activeSeconds: 1);
      final store = <String, SessionResult>{};
      var calls = 0;
      var fail = true;
      final gate = Completer<void>();
      final saver = ResultSaver((r) async {
        calls++;
        await gate.future;
        if (fail) throw StateError('disk full');
        store[r.sessionId] = r; // the app upserts by id
      });
      final a = saver(result);
      final b = saver(result);
      gate.complete();
      expect(await a, isFalse);
      expect(await b, isFalse);
      expect(calls, 1);
      expect(saver.lastError, isA<StateError>());
      fail = false;
      expect(await saver(result), isTrue);
      expect(await saver(result), isTrue);
      expect(calls, 2);
      expect(store.keys, [result.sessionId]);
    },
  );
}
