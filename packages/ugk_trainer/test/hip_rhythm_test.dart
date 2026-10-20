// Ported from HipLab@99fcc83 test/hip/hip_rep_rhythm_test.dart,
// test/hip/action_kit_test.dart and test/hip/hip_voice_android_timeline_test.dart
// (switch gap), on ugk_trainer Rhythm + TrainingPlan with HipLab's kits and
// manifest (test/fixtures/hiplab).
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

import 'support.dart';

void main() {
  final kits = hipRhythms();
  final zh = SessionScript(source: hipSource());
  final en = SessionScript(source: hipSource(), lang: 'en');

  SessionPhase work(PlanItem item) => SessionBuilder(
    rhythms: kits,
    switchSecondsFor: zh.switchSecondsFor,
  ).phases(planOf([item])).firstWhere((p) => p.isWork);

  group('Rhythm', () {
    test('action-kit json: kind, lead, phases, defaults', () {
      final squat = kits['h-squat']!;
      expect(squat.kind, ActionKind.repUpdown);
      expect(squat.source, RhythmSource.actionKit);
      expect(squat.lead, 1.0);
      expect(squat.phases.map((p) => p.id), ['go', 'hold', 'back', 'rest']);
      expect(squat.phases.first.cues, ['w.squat_down']);
      expect(squat.counted, isTrue);
      expect(kits['h-couch-stretch']!.counted, isFalse);
      expect(kits['h-hip-gate']!.phases.first.cues, [
        'w.gate_open',
        'w.gate_close',
      ]);
      expect(kits['h-sumo-pry']!.holdSeconds, 10);
    });

    test('catalog json round trip and self_paced', () {
      final j = kits['h-sumo-pry']!.toJson();
      final back = Rhythm.fromJson(Map<String, dynamic>.from(j));
      expect(back.kind, ActionKind.repHold);
      expect(back.holdSeconds, 10);
      expect(back.phases.length, 4);
      expect(back.phases[1].cues, ['w.hold']);
      expect(Rhythm.fromJson({'kind': 'self_paced'}).selfPaced, isTrue);
    });

    test('derivations: repSeconds → rep_updown, dose defaults', () {
      final r = Rhythm.fromRepSeconds(4);
      expect(r.kind, ActionKind.repUpdown);
      expect(r.derived, isTrue);
      expect(r.cycleFor(), 4);
      expect(Rhythm.forDose(DoseMode.reps).selfPaced, isTrue);
      expect(Rhythm.forDose(DoseMode.time).kind, ActionKind.hold);
      // A time dose on a derived rhythm is a timed hold (SmartFit).
      expect(r.effectiveFor(timed('x', 30)).counted, isFalse);
      // A reps dose on a hold kit is counted by the user.
      expect(
        kits['h-couch-stretch']!.effectiveFor(reps('x', 8)).selfPaced,
        isTrue,
      );
    });

    test('the routine budget slows reps down instead of leaving silence', () {
      final squat = kits['h-squat']!;
      final plan = squat.repPlan(reps: 8, seconds: 60);
      expect(plan.reps, 8);
      expect(plan.lead + plan.reps * plan.cycle, closeTo(60, 1e-6));
      // Movements keep the demo's speed; pauses take the extra time.
      expect(plan.phases[0].seconds, squat.phases[0].seconds);
      expect(plan.phases[1].seconds, greaterThan(squat.phases[1].seconds));
    });

    test('停 N 秒 stays N seconds when the reps are slowed down', () {
      final sumo = kits['h-sumo-pry']!;
      final plan = sumo.repPlan(reps: 3, seconds: 60);
      expect(plan.phases.firstWhere((p) => p.id == 'hold').seconds, 10);
    });

    test('a shortened phase never starts a rep it cannot finish', () {
      final squat = kits['h-squat']!;
      final plan = squat.repPlan(reps: 8, seconds: 10);
      expect(plan.reps, lessThan(8));
      expect(plan.lead + plan.reps * plan.cycle, lessThanOrEqualTo(10 + 1e-9));
    });
  });

  group('rhythm counting (HipLab _repCues)', () {
    test('rep_updown: 开始, each count with the go word, the back word, the '
        'last rep in full', () {
      final w = work(reps('h-squat', 8));
      expect(w.seconds, (1 + 8 * kits['h-squat']!.cycleFor() - 1e-9).ceil());
      final cues = zh.cues(w, planSeconds: 300);
      expect(cues.first.clips, ['chime.start', 'p.go']);
      final counts = cues.where((c) => c.clips.contains('w.squat_down'));
      expect(counts, hasLength(8));
      expect(counts.first.clips, ['n.1', 'w.squat_down']);
      expect(counts.last.clips, ['p.last_rep', 'w.squat_down']);
      expect(cues.where((c) => c.clips.contains('w.stand_up')), hasLength(8));
      final plan = kits['h-squat']!.repPlan(reps: 8, seconds: w.seconds);
      expect(counts.first.at, closeTo(plan.lead, 1e-9));
      // Every count lands inside the phase.
      expect(cues.every((c) => c.at < w.seconds), isTrue);
    });

    test('rep_alternate rotates the go word', () {
      final w = work(reps('h-hip-gate', 6, perSide: true));
      final cues = zh.cues(w, planSeconds: 300);
      final words = [
        for (final c in cues)
          for (final k in c.clips)
            if (k.startsWith('w.gate')) k,
      ];
      expect(words.take(4), [
        'w.gate_open',
        'w.gate_close',
        'w.gate_open',
        'w.gate_close',
      ]);
    });

    test('english uses english clips with the same timeline', () {
      final w = work(reps('h-squat', 8));
      final a = zh.cues(w, planSeconds: 300).map((c) => c.at).toList();
      final b = en.cues(w, planSeconds: 300).map((c) => c.at).toList();
      expect(b, a);
    });

    test('hold kit: start, halfway, 还剩 10 秒, 5-4-3-2-1', () {
      final w = work(timed('h-couch-stretch', 40, perSide: true));
      final cues = zh.cues(w, planSeconds: 300);
      expect(cues.first.clips, ['chime.start', 'p.go']);
      for (var k = 5; k >= 1; k--) {
        expect(
          cues.where((c) => c.at == 40 - k && c.clips.contains('n.$k')),
          hasLength(1),
          reason: 'n.$k',
        );
      }
    });
  });

  group('side switch (Android voice fix: switchMargin)', () {
    test(
      'the switch gap fits its line before the 3-2-1, in both languages',
      () {
        for (final s in [zh, en]) {
          for (final item in [
            timed('h-couch-stretch', 40, perSide: true),
            reps('h-hip-gate', 6, perSide: true),
          ]) {
            final b = SessionBuilder(
              rhythms: kits,
              switchSecondsFor: s.switchSecondsFor,
            );
            final sw = b
                .phases(planOf([item]))
                .firstWhere((p) => p.kind == PhaseKind.switchSide);
            final cues = s.cues(sw, planSeconds: 300);
            final line = cues.first;
            final three = cues.firstWhere(
              (c) => c.clips.contains('chime.tick'),
            );
            expect(
              line.at + s.len(line.clips) + SessionScript.switchMargin,
              lessThanOrEqualTo(three.at + 1e-9),
              reason: '${s.lang} ${item.exerciseId}: ${line.clips}',
            );
            expect(sw.seconds, sw.seconds.roundToDouble());
            expect(sw.seconds, greaterThanOrEqualTo(5));
          }
        }
      },
    );

    test('after a hold kit the switch says the kit end, then 换左边', () {
      final b = SessionBuilder(rhythms: kits);
      final sw = b
          .phases(planOf([timed('h-couch-stretch', 40, perSide: true)]))
          .firstWhere((p) => p.kind == PhaseKind.switchSide);
      final clips = zh.cues(sw, planSeconds: 300).first.clips;
      expect(clips.first, 'chime.end');
      expect(clips.last, 'p.switch_left');
    });
  });

  test('a whole HipLab session: never two voices, counts never cut', () {
    for (final lang in ['zh', 'en']) {
      final sim = hipSim(lang)..run();
      final lines = sim.lines;
      for (var i = 1; i < lines.length; i++) {
        expect(
          lines[i].start,
          greaterThanOrEqualTo(lines[i - 1].end - 1e-9),
          reason: '$lang: ${lines[i - 1]} / ${lines[i]}',
        );
      }
      final counts = lines.where((l) => l.priority == CuePriority.count);
      expect(counts.where((l) => l.cutAt != null), isEmpty, reason: lang);
      expect(sim.engine.done, isTrue);
      expect(sim.output.spoken.last.single, endsWith('/p.finish.m4a'));
    }
  });
}
