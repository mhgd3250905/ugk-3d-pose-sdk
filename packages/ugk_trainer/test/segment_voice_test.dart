import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

import 'support.dart';

void main() {
  test('long segment names never suppress default-paced counts', () {
    final source = ManifestVoiceSource.fromJson({
      'clips': {
        'zh': {'drill.y': 5000, 'n.1': 250, 'n.2': 250, 'n.3': 250},
      },
      'chimes': {'start': 100, 'tick': 100},
    });
    for (final hold in [null, 1]) {
      final segment = PlanSegment(
        id: 'y',
        exerciseId: 'y',
        mode: DoseMode.reps,
        reps: 3,
        holdSeconds: hold,
      );
      final item = PlanItem(
        exerciseId: 'ytw',
        mode: DoseMode.reps,
        sets: 1,
        perSide: false,
        restSeconds: 0,
        segments: [segment],
      );
      final phase = SessionBuilder(
        prepSeconds: 0,
      ).phases(planOf([item])).firstWhere((phase) => phase.isWork);
      final script = SessionScript(source: source);
      final cues = script.cues(phase, planSeconds: phase.seconds);
      expect(
        cues.expand((cue) => cue.voiceClips),
        containsAll(['n.1', 'n.2', 'n.3']),
      );
      expect(cues.expand((cue) => cue.voiceClips), isNot(contains('drill.y')));
    }
  });

  test('each segment names its own App-provided clip with its own dose', () {
    final source = ManifestVoiceSource.fromJson({
      'clips': {
        'zh': {'drill.y': 300, 'drill.t': 300, 'sec.4': 300, 'sec.7': 300},
      },
      'chimes': {'start': 100, 'tick': 100},
    });
    final item = PlanItem(
      exerciseId: 'ytw',
      mode: DoseMode.time,
      sets: 1,
      perSide: false,
      restSeconds: 0,
      segments: const [
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
          workSeconds: 7,
        ),
      ],
    );
    final script = SessionScript(source: source);
    final phases = SessionBuilder(prepSeconds: 0).phases(planOf([item]));
    final work = phases.where((phase) => phase.isWork).toList();
    expect(work.map((phase) => phase.seconds), [4, 7]);
    expect(
      script.cues(work[0], planSeconds: 11).first.clips,
      contains('drill.y'),
    );
    expect(
      script.cues(work[1], planSeconds: 11).first.clips,
      contains('drill.t'),
    );
  });

  test(
    'automatic reps without language assets fall back to an App chime per rep',
    () {
      final source = ManifestVoiceSource.fromJson({
        'clips': {
          'zh': {'num.1': 300},
        },
        'chimes': {'start': 100, 'tick': 100},
      });
      final script = SessionScript(source: source, lang: 'de');
      final phase = SessionBuilder(
        prepSeconds: 0,
      ).phases(planOf([reps('a', 4)])).firstWhere((phase) => phase.isWork);
      final cues = script.cues(phase, planSeconds: phase.seconds);
      expect(
        cues.where((cue) => cue.priority == CuePriority.count),
        hasLength(4),
      );
      expect(cues.expand((cue) => cue.voiceClips), isEmpty);
      expect(
        cues.where((cue) => cue.clips.contains('chime.tick')),
        hasLength(4),
      );
    },
  );

  test(
    'rest extension moves countdown and does not repeat the rest announcement',
    () {
      final engine = SessionEngine([
        const SessionPhase(kind: PhaseKind.rest, seconds: 10),
        const SessionPhase(kind: PhaseKind.done, seconds: 0),
      ]);
      final runner = SessionRunner(engine, SessionScript(source: hipSource()));
      expect(runner.update(0), isNotEmpty);
      runner.update(7);
      expect(runner.extendRest(7), isTrue);
      expect(runner.update(7), isEmpty);
      expect(runner.update(8), isEmpty);
      expect(
        runner.update(22).where((cue) => cue.cue.clips.contains('chime.tick')),
        isNotEmpty,
      );
      expect(engine.phase.kind, PhaseKind.rest);
    },
  );
}
