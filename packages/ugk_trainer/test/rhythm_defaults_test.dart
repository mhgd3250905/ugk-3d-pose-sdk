import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

import 'support.dart';

Catalog catalog({Map<String, dynamic>? rhythm, double? hold}) {
  final drill = const DrillPackAdapter().toDrillJson(
    loadJson('smartfit/packs/h-squat/pack.json'),
  );
  drill.remove('rhythm');
  if (rhythm != null) drill['rhythm'] = rhythm;
  final assets = drill['assets'] as Map;
  assets['video'] = <String, Object?>{
    'sources': [
      {'app': 'test', 'path': 'loop.mp4', 'loopSeconds': 90},
    ],
  };
  if (hold != null) (drill['defaultDose'] as Map)['holdSeconds'] = hold;
  return Catalog.fromJson({
    'format': catalogFormat,
    'formatVersion': 1,
    'version': 'test',
    'drills': [drill],
  });
}

void main() {
  test('no rhythm automatically counts and ends without user clicks', () {
    final plan = planOf([reps('h-squat', 4)]);
    final phases = SessionBuilder(prepSeconds: 0).phases(plan);
    final work = phases.firstWhere((p) => p.isWork);
    expect(work.selfPaced, isFalse);
    expect(work.seconds, 12);
    expect(work.repAt(6), 3);
    final engine = SessionEngine(phases)..update(12);
    expect(engine.done, isTrue);
    expect(engine.fullyCompletedExercises, 1);
    final cues = SessionScript(
      source: smartSource(),
    ).cues(work, planSeconds: 12);
    expect(
      cues.where((c) => c.priority == CuePriority.count).map((c) => c.clips),
      [
        ['n.1'],
        ['n.2'],
        ['n.3'],
        ['n.4'],
      ],
    );
  });

  test('category defaults are public overrides, loop length is ignored', () {
    final c = catalog();
    expect(c.problems, isEmpty);
    expect(rhythmsFromCatalog(c)['h-squat']!.cycleFor(), 3);
    final result = rhythmsFromCatalog(
      c,
      defaults: const RhythmDefaults(categoryRepSeconds: {'strength': 4.5}),
    );
    expect(result['h-squat']!.cycleFor(), 4.5);
    expect(
      Rhythm.forDose(
        DoseMode.reps,
        defaults: const RhythmDefaults(
          defaultRepSeconds: 5,
          categoryRepSeconds: {},
        ),
      ).cycleFor(),
      5,
    );
  });

  test('holdSeconds supplies each repetition duration before video hints', () {
    final c = catalog(hold: 7.5);
    final r = rhythmsFromCatalog(c)['h-squat']!;
    expect(r.counted, isTrue);
    expect(r.cycleFor(), 7.5);
    final work = SessionBuilder(
      rhythms: {'h-squat': r},
    ).phases(planOf([reps('h-squat', 4)])).firstWhere((p) => p.isWork);
    expect(work.seconds, 30);
    expect(work.repSeconds, 7.5);
  });

  test('only explicit self_paced waits for completion', () {
    final r = rhythmsFromCatalog(catalog(rhythm: {'kind': 'self_paced'}));
    final engine = SessionEngine(
      SessionBuilder(
        rhythms: r,
        prepSeconds: 0,
      ).phases(planOf([reps('h-squat', 4)])),
    )..update(100);
    expect(engine.done, isFalse);
    expect(engine.phase.selfPaced, isTrue);
    engine.completeSet(100);
    expect(engine.done, isTrue);
  });

  test('authored rhythm and App override win over defaults', () {
    final c = catalog(
      rhythm: {
        'kind': 'rep_updown',
        'leadSeconds': 0,
        'phases': [
          {'id': 'go', 'seconds': 6},
        ],
      },
    );
    expect(rhythmsFromCatalog(c)['h-squat']!.cycleFor(), 6);
    expect(
      rhythmsFromCatalog(
        c,
        overrides: {'h-squat': Rhythm.fromRepSeconds(4)},
      )['h-squat']!.cycleFor(),
      4,
    );
    expect(Rhythm.forDose(DoseMode.time), same(Rhythm.timedHold));
  });

  test('invalid configured duration fails clearly', () {
    for (final value in [0.0, -1.0, double.nan, double.infinity]) {
      expect(
        () => Rhythm.forDose(
          DoseMode.reps,
          defaults: RhythmDefaults(defaultRepSeconds: value),
        ),
        throwsArgumentError,
      );
    }
  });

  test(
    'short App cadence falls back to chimes without a negative timeline',
    () {
      final work = SessionBuilder(
        rhythmDefaults: const RhythmDefaults(defaultRepSeconds: .1),
      ).phases(planOf([reps('h-squat', 1)])).firstWhere((p) => p.isWork);
      final cues = SessionScript(
        source: smartSource(),
      ).cues(work, planSeconds: .1);
      expect(cues.where((c) => c.priority == CuePriority.count).single.clips, [
        'chime.tick',
      ]);
      expect(cues.every((c) => c.at >= 0 && c.at <= .1), isTrue);
    },
  );
}
