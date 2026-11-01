// Pose-Hub v3 alternating actions: `training.repUnit: "left+right"` makes one
// count a pair (one left + one right movement) instead of one side.
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';
import 'package:ugk_trainer/ugk_trainer.dart' show TrainerStrings;

import 'support.dart';

void main() {
  // Same shape as the v3 text of h-bridge-march (one side = 4.0 s).
  Map<String, dynamic> training({
    String kind = 'rep_alternate',
    String? perSide = 'alternate',
    String? repUnit = 'left+right',
    String? startingSide,
  }) => {
    'kind': kind,
    'leadSeconds': 1,
    'phases': [
      {'id': 'go', 'seconds': 0.8, 'cue': 'phase.start'},
      {'id': 'hold', 'seconds': 1.2, 'cue': 'phase.peak'},
      {'id': 'back', 'seconds': 0.8, 'cue': 'phase.end'},
      {'id': 'rest', 'seconds': 1.2},
    ],
    'perSide': ?perSide,
    'repUnit': ?repUnit,
    'startingSide': ?startingSide,
  };

  List<SessionPhase> phasesOf(Rhythm r, PlanItem item) => SessionBuilder(
    rhythms: {item.exerciseId: r},
    prepSeconds: 0,
  ).phases(planOf([item]));

  group('rhythm', () {
    test('a left+right pair plays both sides inside one count', () {
      final r = Rhythm.fromJson(training(), startingSide: 'right');
      expect(r.alternatePair, isTrue);
      expect(r.pairFirstSide, 'right');
      final ph = r.phasesFor();
      expect(ph.map((p) => p.side), [
        ...List.filled(4, 'right'),
        ...List.filled(4, 'left'),
      ]);
      expect(ph.map((p) => p.id), [
        'go', 'hold', 'back', 'rest', 'go', 'hold', 'back', 'rest', //
      ]);
      expect(r.cycleFor(), closeTo(8.0, 1e-9));
      // lead 1 + 6 pairs × 8 s.
      expect(r.sideSeconds(reps: 6, budget: 0), 49);
      final plan = r.repPlan(reps: 6, seconds: 49);
      expect(plan.reps, 6);
      expect(plan.cycle, closeTo(8.0, 1e-9));
      expect(plan.setSeconds, closeTo(49, 1e-9));
    });

    test('startingSide picks the side that moves first', () {
      final fromAction = Rhythm.fromJson(training(), startingSide: 'left');
      expect(fromAction.phasesFor().first.side, 'left');
      expect(fromAction.phasesFor().last.side, 'right');
      final fromBlock = Rhythm.fromJson(
        training(startingSide: 'left'),
        startingSide: 'right',
      );
      expect(fromBlock.pairFirstSide, 'left');
    });

    test('perSide alternate pairs even when the kind is not rep_alternate', () {
      final r = Rhythm.fromJson(training(kind: 'rep_updown'));
      expect(r.alternatePair, isTrue);
      expect(r.cycleFor(), closeTo(8.0, 1e-9));
    });

    test('a slowed pair spreads the extra time over both sides', () {
      final r = Rhythm.fromJson(training());
      // 6 pairs in 61 s: lead 1 + 6 × 10 s.
      final plan = r.repPlan(reps: 6, seconds: 61);
      expect(plan.reps, 6);
      expect(plan.cycle, closeTo(10.0, 1e-9));
      expect(plan.setSeconds, closeTo(61, 1e-9));
      final right = plan.phases.where((p) => p.side == 'right');
      final left = plan.phases.where((p) => p.side == 'left');
      double sum(Iterable<KitPhase> ph) =>
          ph.fold(0.0, (s, p) => s + p.seconds);
      expect(sum(right), closeTo(5.0, 1e-9));
      expect(sum(left), closeTo(5.0, 1e-9));
    });

    test('legacy rep_alternate without repUnit stays one side per count', () {
      final r = Rhythm.fromJson(training(perSide: null, repUnit: null));
      expect(r.kind, ActionKind.repAlternate);
      expect(r.alternatePair, isFalse);
      expect(r.phasesFor(), hasLength(4));
      expect(r.phasesFor().every((p) => p.side == null), isTrue);
      expect(r.cycleFor(), closeTo(4.0, 1e-9));
    });

    test('toJson round-trips the pair', () {
      final r = Rhythm.fromJson(training(), startingSide: 'left');
      final back = Rhythm.fromJson(r.toJson());
      expect(back.alternatePair, isTrue);
      expect(back.pairFirstSide, 'left');
      expect(back.cycleFor(), r.cycleFor());
      expect(
        Rhythm.fromJson(training(repUnit: null)).toJson(),
        isNot(contains('repUnit')),
      );
    });
  });

  group('engine', () {
    test('a pair set is one work phase with no side switch', () {
      final r = Rhythm.fromJson(training(), startingSide: 'right');
      final item = reps('h-bridge-march', 6, sets: 3, perSide: true);
      final phases = phasesOf(r, item);
      final work = phases.where((p) => p.isWork).toList();
      expect(work, hasLength(3));
      expect(phases.where((p) => p.kind == PhaseKind.switchSide), isEmpty);
      for (final w in work) {
        expect(w.side, isNull);
        expect(w.reps, 6);
        expect(w.repSeconds, closeTo(8.0, 1e-9));
        expect(w.seconds, 49);
      }
    });

    test('legacy rep_alternate without repUnit keeps the right/left split', () {
      final r = Rhythm.fromJson(training(perSide: null, repUnit: null));
      final phases = phasesOf(r, reps('x', 6, perSide: true));
      final work = phases.where((p) => p.isWork).toList();
      expect(work.map((p) => p.side), [Side.right, Side.left]);
      expect(phases.where((p) => p.kind == PhaseKind.switchSide), hasLength(1));
      expect(work.first.repSeconds, closeTo(4.0, 1e-9));
      expect(work.first.seconds, 25);
    });

    test('each-side-separately unilateral moves keep the right/left split', () {
      final r = Rhythm.fromJson({
        'kind': 'rep_updown',
        'leadSeconds': 1,
        'phases': [
          {'id': 'go', 'seconds': 1.5},
          {'id': 'back', 'seconds': 1.5},
        ],
        'perSide': 'each',
      });
      expect(r.alternatePair, isFalse);
      final phases = phasesOf(r, reps('y', 8, sets: 2, perSide: true));
      final work = phases.where((p) => p.isWork).toList();
      expect(work.map((p) => p.side), [
        Side.right,
        Side.left,
        Side.right,
        Side.left,
      ]);
      expect(phases.where((p) => p.kind == PhaseKind.switchSide), hasLength(2));
    });

    test('dose text still says 每侧 N 次 for a pair', () {
      expect(
        TrainerStrings.zh().dose(reps: true, amount: 6, perSide: true),
        '每侧 6 次',
      );
    });
  });

  group('voice', () {
    ManifestVoiceSource source() => ManifestVoiceSource.fromJson({
      'clips': {
        'zh': {
          'p.go': 300,
          'p.right': 300,
          'p.left': 300,
          for (var n = 1; n <= 6; n++) 'n.$n': 300,
        },
      },
      'chimes': {'start': 100, 'tick': 100},
    });

    test('the side word rotates 右 → 左 inside every count', () {
      final r = Rhythm.fromJson(training(), startingSide: 'right');
      final work = phasesOf(
        r,
        reps('h-bridge-march', 6, perSide: true),
      ).firstWhere((p) => p.isWork);
      final cues = SessionScript(
        source: source(),
      ).cues(work, planSeconds: work.seconds);
      final right = [
        for (final c in cues)
          if (c.voiceClips.contains('p.right')) c.at,
      ];
      final left = [
        for (final c in cues)
          if (c.voiceClips.contains('p.left')) c.at,
      ];
      // Count k starts at 1 + (k - 1) × 8 with 右; 左 four seconds later.
      expect(right, [for (var k = 0; k < 6; k++) closeTo(1 + k * 8.0, 1e-6)]);
      expect(left, [for (var k = 0; k < 6; k++) closeTo(5 + k * 8.0, 1e-6)]);
      // One number per pair, said with 右.
      for (var k = 1; k <= 6; k++) {
        final c = cues.where((c) => c.voiceClips.contains('n.$k')).toList();
        if (c.isEmpty) continue; // the last count may be p.last_rep
        expect(c.single.voiceClips, contains('p.right'));
      }
    });

    test('a pair starting left says 左 first', () {
      final r = Rhythm.fromJson(training(), startingSide: 'left');
      final work = phasesOf(
        r,
        reps('x', 2, perSide: true),
      ).firstWhere((p) => p.isWork);
      final cues = SessionScript(
        source: source(),
      ).cues(work, planSeconds: work.seconds);
      final sides = [
        for (final c in cues)
          for (final k in c.voiceClips)
            if (k == 'p.right' || k == 'p.left') k,
      ];
      expect(sides, ['p.left', 'p.right', 'p.left', 'p.right']);
    });

    test('a source without side clips stays silent and still counts', () {
      final plain = ManifestVoiceSource.fromJson({
        'clips': {
          'zh': {for (var n = 1; n <= 6; n++) 'n.$n': 300},
        },
        'chimes': {'start': 100, 'tick': 100},
      });
      final r = Rhythm.fromJson(training());
      final work = phasesOf(
        r,
        reps('x', 3, perSide: true),
      ).firstWhere((p) => p.isWork);
      final clips = SessionScript(
        source: plain,
      ).cues(work, planSeconds: work.seconds).expand((c) => c.voiceClips);
      expect(clips, containsAll(['n.1', 'n.2', 'n.3']));
      expect(clips, isNot(contains('p.right')));
    });
  });
}
