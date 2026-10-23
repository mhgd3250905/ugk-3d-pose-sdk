// Ported from SmartFit@e8981ee test/domain_test.dart (group 'session') and
// test/voice_session_test.dart (early end, group 'session runner'), on
// ugk_coach TrainingPlan + Rhythm; plus ugk_trainer regressions: self-paced
// sets, rep_hold holdSeconds, circuit round rests, substitute.
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

import 'support.dart';

void main() {
  final rhythms = smartRhythms();
  SessionBuilder builder() => SessionBuilder(rhythms: rhythms);

  group('session (SmartFit)', () {
    test('sets × reps, per side, rests and transitions', () {
      final p = planOf([
        reps('h-squat', 10, sets: 2, rest: 30),
        timed('s-figure4', 30, perSide: true, rest: 10),
      ]);
      final ph = builder().phases(p);
      expect(ph.map((x) => x.kind).toList(), [
        PhaseKind.prep,
        PhaseKind.work,
        PhaseKind.rest,
        PhaseKind.work,
        PhaseKind.rest,
        PhaseKind.work,
        PhaseKind.switchSide,
        PhaseKind.work,
        PhaseKind.done,
      ]);
      expect(ph[1].seconds, 10 * 4.0); // h-squat repSeconds 4
      expect(ph[1].reps, 10);
      expect(ph[1].selfPaced, isFalse);
      expect(ph[2].set, 2);
      expect(ph[4].nextExerciseId, 's-figure4');
      expect(ph[5].side, Side.right);
      expect(ph[7].side, Side.left);
      expect(ph[5].seconds, 30);
    });

    test('circuit rounds repeat items and rest between rounds', () {
      final p = planOf(
        [reps('h-squat', 8, rest: 10), reps('w-dead-bug', 8, rest: 10)],
        type: BlockType.circuit,
        rounds: 3,
      );
      final ph = builder().phases(p);
      expect(ph.where((x) => x.isWork).length, 6);
      final rr = ph.where((x) => x.kind == PhaseKind.roundRest).toList();
      expect(rr.length, 2);
      expect(rr.first.seconds, 40);
      expect(rr.first.round, 2);
      expect(rr.first.rounds, 3);
      expect(rr.first.doneExerciseId, 'w-dead-bug');
      // Inside a round: the plain 15 s transition, no round rest.
      final inside = ph.indexWhere((x) => x.kind == PhaseKind.rest);
      expect(ph[inside].seconds, 15);
      expect(ph[inside].round, 1);
    });

    test('round rest never shorter than the transition', () {
      final p = planOf(
        [reps('h-squat', 8), reps('w-dead-bug', 8)],
        type: BlockType.circuit,
        rounds: 2,
        restBetweenRounds: 5,
      );
      final rr = builder()
          .phases(p)
          .singleWhere((x) => x.kind == PhaseKind.roundRest);
      expect(rr.seconds, 15);
    });

    test(
      'absolute clock: a long gap lands in the right phase; skip/previous',
      () {
        final p = planOf([
          reps('h-squat', 10, sets: 3, rest: 30),
          reps('w-dead-bug', 10, sets: 2, rest: 20),
        ]);
        final e = SessionEngine(builder().phases(p));
        e.update(10 + 0.1); // prep is 10 s
        expect(e.phase.kind, PhaseKind.work);
        expect(e.phase.set, 1);
        e.skip(11);
        expect(e.phase.kind, PhaseKind.rest);
        expect(e.phase.nextExerciseId, 'w-dead-bug');
        e.skip(12);
        expect(e.phase.isWork, isTrue);
        expect(e.phase.exerciseId, 'w-dead-bug');
        e.previous(13);
        expect(e.phase.exerciseId, 'h-squat');
        e.update(13 + 10000);
        expect(e.done, isTrue);
        expect(e.completedExercises, 2);
      },
    );

    test('early end preserves progress in prep, work and transition', () {
      final phases = builder().phases(
        planOf([reps('h-squat', 10, rest: 30), reps('w-dead-bug', 10)]),
      );
      final firstWorkEnd = phases[0].seconds + phases[1].seconds;
      for (final (time, completed) in [
        (0.0, 0),
        (11.0, 0),
        (firstWorkEnd, 1),
      ]) {
        final engine = SessionEngine(phases)..finish(time);
        expect(engine.done, isTrue);
        expect(engine.endedEarly, isTrue);
        expect(engine.completedExercises, completed);
        engine.finish(time + 1);
        engine.update(time + 10000);
        expect(engine.completedExercises, completed);
      }
      final natural = SessionEngine(phases)..finish(10000);
      expect(natural.endedEarly, isFalse);
      expect(natural.completedExercises, 2);
    });
  });

  group('session runner (SmartFit)', () {
    final script = SessionScript(source: smartSource());
    SessionRunner runner() => SessionRunner(
      SessionEngine(
        SessionBuilder(rhythms: rhythms).phases(
          planOf([timed('h-squat', 30, rest: 10), timed('w-dead-bug', 30)]),
        ),
      ),
      script,
    );
    List<String> clips(List<FiredCue> cues) => [
      for (final fired in cues) ...fired.cue.clips,
    ];

    test(
      'early end preserves progress and suppresses full completion speech',
      () {
        for (final (time, completed) in [(0.0, 0), (11.0, 0), (41.0, 1)]) {
          final session = runner()..finish(time);
          expect(session.engine.done, isTrue);
          expect(session.engine.completedExercises, completed);
          expect(session.update(time), isEmpty);
        }
        final session = runner();
        expect(clips(session.update(85)), contains('p.finish'));
        expect(session.engine.endedEarly, isFalse);
        expect(session.engine.completedExercises, 2);
      },
    );

    test('phase boundaries speak once at their absolute scheduled time', () {
      final r = runner();
      expect(clips(r.update(0)), contains('p.welcome'));
      expect(r.update(0), isEmpty);
      expect(clips(r.update(7)), contains('n.3'));
      expect(clips(r.update(8)), contains('n.2'));
      expect(clips(r.update(9)), contains('n.1'));
      final work = r.update(10);
      expect(r.engine.phase.kind, PhaseKind.work);
      expect(clips(work), ['chime.start', 'p.go']);
      expect(work.single.time, 10);
      expect(r.update(10), isEmpty);
      final done = r.update(85);
      expect(r.engine.done, isTrue);
      expect(clips(done), ['chime.finish', 'p.finish']);
      expect(r.update(86), isEmpty);
    });

    test('background gaps discard past phases and expired current cues', () {
      final r = runner();
      r.update(0);
      // Rest (15 s transition) began at 40; only its last tick is fresh.
      final due = r.update(54);
      expect(r.engine.phase.kind, PhaseKind.rest);
      expect(r.engine.phaseStart, 40);
      expect(clips(due), ['chime.tick', 'n.1']);
      expect(due.single.time, 54);
      expect(r.update(54), isEmpty);
      expect(clips(r.update(55)), ['chime.start', 'p.go']);
    });

    test('skip and previous reload only the newly entered phase', () {
      final r = runner();
      r.update(10);
      r.skip(11);
      final rest = clips(r.update(11));
      expect(rest, contains('p.rest'));
      expect(rest, isNot(contains('p.nice'))); // No praise for a skipped move.
      expect(rest, isNot(contains('h-squat/finish')));
      expect(rest, isNot(contains('p.welcome')));
      r.skip(12);
      expect(r.engine.phase.exerciseId, 'w-dead-bug');
      expect(clips(r.update(12)), ['chime.start', 'p.go']);
      expect(r.update(12), isEmpty);
      r.previous(13);
      expect(r.engine.phase.exerciseId, 'h-squat');
      expect(clips(r.update(13)), ['chime.start', 'p.go']);
      expect(r.update(13), isEmpty);
    });
  });

  group('explicit self-paced sets', () {
    // Only explicitly marked technique attempts are self-paced.
    final plan = planOf([
      reps('thomas-curl', 12, sets: 2, rest: 20),
      timed('thomas-plank', 30),
    ]);

    test('explicit self-paced reps wait, time doses are timed', () {
      final ph = SessionBuilder(
        rhythms: {
          'thomas-curl': Rhythm.selfPacedReps,
          'h-squat': Rhythm.selfPacedReps,
        },
      ).phases(plan);
      final work = ph.where((p) => p.isWork).toList();
      expect(work.map((p) => p.selfPaced), [true, true, false]);
      expect(work.first.reps, 12);
      expect(work.first.seconds, 36); // estimate 12 × 3 s
      expect(work.last.seconds, 30);
    });

    test('the clock never ends a self-paced set; 完成本组 does', () {
      final e = SessionEngine(
        SessionBuilder(
          rhythms: {
            'thomas-curl': Rhythm.selfPacedReps,
            'h-squat': Rhythm.selfPacedReps,
          },
        ).phases(plan),
      );
      e.update(10.1);
      expect(e.awaitingCompletion, isTrue);
      e.update(10000);
      expect(e.phase.isWork, isTrue, reason: 'still waiting');
      expect(e.secondsLeft(10000), 0);
      expect(e.elapsedIn(10000), closeTo(9990, 1e-6));
      expect(e.completeSet(10005), isTrue);
      expect(e.phase.kind, PhaseKind.rest);
      expect(e.phaseStart, 10005);
      expect(e.visits.last.exit, PhaseExit.completed);
      expect(e.completeSet(10006), isFalse, reason: 'not in a set');
      e.update(10025);
      expect(e.awaitingCompletion, isTrue);
      expect(e.phase.set, 2);
      e.completeSet(10030);
      e.update(10045); // 15 s transition
      expect(e.phase.isWork, isTrue);
      expect(e.phase.selfPaced, isFalse);
      e.update(10075);
      expect(e.done, isTrue);
      expect(e.completedExercises, 2);
    });

    test('a self-paced set only says its start, no count, no countdown', () {
      final script = SessionScript(source: smartSource());
      final ph = SessionBuilder(
        rhythms: {
          'thomas-curl': Rhythm.selfPacedReps,
          'h-squat': Rhythm.selfPacedReps,
        },
      ).phases(planOf([reps('h-squat', 12)]));
      // Explicit catalog self-paced marker preserves manual completion.
      final cues = script.cues(ph[1], planSeconds: 60);
      expect(cues.first.clips, ['chime.start', 'p.go']);
      expect(cues.where((c) => c.priority == CuePriority.count), isEmpty);
    });

    test('the runner speaks the next phase right after 完成本组', () {
      final r = SessionRunner(
        SessionEngine(
          SessionBuilder(
            rhythms: {
              'thomas-curl': Rhythm.selfPacedReps,
              'h-squat': Rhythm.selfPacedReps,
            },
          ).phases(plan),
        ),
        SessionScript(source: smartSource()),
      );
      r.update(10.5);
      final fired = r.completeSet(20);
      expect(r.engine.phase.kind, PhaseKind.rest);
      expect([for (final f in fired) ...f.cue.clips], contains('chime.end'));
    });
  });

  group('rep_hold holdSeconds', () {
    final kits = hipRhythms();
    final sumo = kits['h-sumo-pry']!; // rep_hold, defaults holdSeconds 10

    test('the hold phase takes the hold length; the work grows with it', () {
      final ph10 = SessionBuilder(
        rhythms: kits,
      ).phases(planOf([reps('h-sumo-pry', 3)]));
      final ph5 = SessionBuilder(
        rhythms: {...kits, 'h-sumo-pry': sumo.withHold(5)},
      ).phases(planOf([reps('h-sumo-pry', 3)]));
      final w10 = ph10[1], w5 = ph5[1];
      expect(w10.holdSeconds, 10);
      expect(w5.holdSeconds, 5);
      // lead 1 + 3 × (1.25 + hold + .65 + .45), ceiled.
      expect(w10.seconds, (1 + 3 * (1.25 + 10 + .65 + .45) - 1e-9).ceil());
      expect(w5.seconds, (1 + 3 * (1.25 + 5 + .65 + .45) - 1e-9).ceil());
      final plan = sumo.repPlan(reps: 3, hold: 10, seconds: w10.seconds);
      expect(plan.phases.firstWhere((p) => p.id == 'hold').seconds, 10);
    });

    test('a hold of 6 s or more counts 3-2-1 inside every rep', () {
      final script = SessionScript(source: hipSource());
      final w = SessionBuilder(
        rhythms: kits,
      ).phases(planOf([reps('h-sumo-pry', 3)]))[1];
      final cues = script.cues(w, planSeconds: 60);
      final threes = cues.where((c) => c.clips.contains('n.3')).length;
      // Each rep: the count "3" on rep 3 (last rep says p.last_rep) plus the
      // 3 of each hold countdown.
      expect(threes, greaterThanOrEqualTo(3));
      expect(cues.where((c) => c.clips.contains('w.hold')), hasLength(3));
      expect(cues.where((c) => c.clips.contains('p.last_rep')), hasLength(1));
      final w5 = SessionBuilder(
        rhythms: {...kits, 'h-sumo-pry': sumo.withHold(5)},
      ).phases(planOf([reps('h-sumo-pry', 3)]))[1];
      final short = script.cues(w5, planSeconds: 60);
      expect(
        short.where((c) => c.clips.length == 1 && c.clips.single == 'n.3'),
        isEmpty,
        reason: 'no countdown inside a 5 s hold',
      );
    });

    test('the ring follows the rep on the rhythm', () {
      final w = SessionBuilder(
        rhythms: kits,
      ).phases(planOf([reps('h-sumo-pry', 3)]))[1];
      expect(w.repAt(0), 1);
      expect(w.repAt(w.seconds - .1), 3);
    });
  });

  group('substitute', () {
    test('restartWith swaps the current exercise and keeps earlier visits', () {
      final plan = planOf([timed('h-squat', 30), timed('w-dead-bug', 30)]);
      final b = SessionBuilder(rhythms: rhythms);
      final e = SessionEngine(b.phases(plan));
      e.update(12);
      final swapped = plan.copyWith(
        blocks: [
          PlanBlock(
            id: 'b',
            name: '主训练',
            type: BlockType.main,
            items: [timed('h-couch-stretch', 30), timed('w-dead-bug', 30)],
          ),
        ],
      );
      e.restartWith(b.phases(swapped), 12);
      expect(e.phase.exerciseId, 'h-couch-stretch');
      expect(e.phase.isWork, isTrue);
      expect(e.phaseStart, 12);
      expect(e.visits.last.exit, PhaseExit.replaced);
      expect(e.visits.first.phase.kind, PhaseKind.prep);
    });
  });
}
