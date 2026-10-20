// ugk_trainer regression (decision B): a voice language the source has no
// clips for plays chimes and the on-screen countdown only, and never says
// half a phrase.
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/engine.dart';

import 'support.dart';

void main() {
  for (final (name, make) in [
    (
      'drill packs',
      () => Sim(
        smartSim().plan,
        source: smartSource(),
        rhythms: smartRhythms(),
        lang: 'ja',
      ),
    ),
    (
      'manifest',
      () => Sim(
        hipSim('zh').plan,
        source: hipSource(),
        rhythms: hipRhythms(),
        lang: 'de',
      ),
    ),
  ]) {
    test('$name, no voice in the language: chimes only, whole session', () {
      final sim = make();
      expect(sim.script.voiced, isFalse);
      sim.run();
      expect(sim.engine.done, isTrue);
      expect(sim.output.spoken, isEmpty);
      expect(sim.lines, isEmpty);
      final chimes = sim.output.chimes.map((a) => a.split('/').last).toSet();
      expect(
        chimes,
        containsAll(['start.m4a', 'tick.m4a', 'end.m4a', 'finish.m4a']),
      );
      for (final f in sim.fired) {
        expect(f.cue.voiceClips, isEmpty, reason: '$f');
      }
    });
  }

  test('a phrase with a missing piece is left out, not said in part', () {
    // HipLab manifest has no 'sec.13': the rest says 「休息」 alone, never
    // a bare number.
    final script = SessionScript(source: hipSource());
    final rest = SessionPhase(
      kind: PhaseKind.rest,
      seconds: 13,
      exerciseId: 'h-squat',
      item: reps('h-squat', 8),
      set: 2,
      sets: 2,
    );
    final heads = script.cues(rest, planSeconds: 300).first.clips;
    expect(heads, contains('p.rest'));
    expect(heads.where((k) => k.startsWith('sec.')), isEmpty);
    // Reps doses cannot be said from the manifest: no dose, no lone 每侧.
    expect(script.dose(reps('h-squat', 8, perSide: true)), isEmpty);
  });
}
