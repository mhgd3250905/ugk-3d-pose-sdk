import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

import 'support.dart';

void main() {
  Map<String, dynamic> rhythmJson({String? source}) => {
    'kind': 'rep_updown',
    'leadSeconds': 0,
    'phases': [
      {'id': 'go', 'seconds': 4},
    ],
    'source': ?source,
  };

  Map<String, Rhythm> catalogRhythms() {
    final drill = const DrillPackAdapter().toDrillJson(
      loadJson('smartfit/packs/h-squat/pack.json'),
    );
    drill['rhythm'] = rhythmJson(source: 'repSeconds');
    final catalog = Catalog.fromJson({
      'format': catalogFormat,
      'formatVersion': 1,
      'version': '0.3.0',
      'drills': [drill],
    });
    expect(catalog.problems, isEmpty);
    return rhythmsFromCatalog(catalog);
  }

  test('catalog repSeconds keeps its derived cadence', () {
    final rhythms = catalogRhythms();
    final parsed = rhythms['h-squat']!;
    final direct = Rhythm.fromRepSeconds(4);
    expect(parsed.source, RhythmSource.repSeconds);
    expect(parsed.derived, isTrue);
    expect(parsed.lead, direct.lead);
    expect(parsed.cycleFor(), direct.cycleFor());
    final plan = planOf([reps('h-squat', 8)]);
    SessionPhase work(Map<String, Rhythm> byId) =>
        SessionBuilder(rhythms: byId).phases(plan).firstWhere((p) => p.isWork);
    final actual = work(rhythms);
    final expected = work({'h-squat': direct});
    expect(actual.seconds, expected.seconds);
    expect(actual.repSeconds, expected.repSeconds);
    for (final elapsed in [0.0, 3.99, 4.0, 20.0, 31.99]) {
      expect(actual.repAt(elapsed), expected.repAt(elapsed));
    }
  });

  test('catalog repSeconds reaches the voice output as every rep number', () {
    final source = smartSource();
    final output = RecordingOutput();
    final queue = VoiceQueue(
      output: output,
      lib: source,
      settings: const VoiceSettings(),
    );
    final work = SessionBuilder(
      rhythms: catalogRhythms(),
    ).phases(planOf([reps('h-squat', 12)])).firstWhere((p) => p.isWork);
    final cues = SessionScript(source: source).cues(work, planSeconds: 48);
    for (final cue in cues) {
      queue.submit(cue, cue.at);
      queue.tick(cue.at);
    }
    final counts = queue.log.where((l) => l.priority == CuePriority.count);
    expect(counts.map((l) => l.clips), [
      for (var n = 1; n <= 12; n++) ['n.$n'],
    ]);
    final spokenCounts = output.spoken.where(
      (assets) => assets.length == 1 && assets.single.contains('/n.'),
    );
    expect(spokenCounts, [
      for (var n = 1; n <= 12; n++) ['assets/packs/_common/voice/zh/n.$n.m4a'],
    ]);
    expect(counts.first.start, closeTo(4 - .45, 1e-9));
  });

  test('catalog repSeconds with a time dose becomes a timed hold', () {
    final rhythms = catalogRhythms();
    final item = timed('h-squat', 30);
    expect(rhythms['h-squat']!.effectiveFor(item), same(Rhythm.timedHold));
    final work = SessionBuilder(
      rhythms: rhythms,
    ).phases(planOf([item])).firstWhere((p) => p.isWork);
    expect(work.seconds, 30);
    expect(work.countedOnClock, isFalse);
    expect(work.repAt(12), isNull);
  });

  test('other catalog source values retain catalog semantics', () {
    for (final source in [null, 'catalog', 'hiplab', 'actionKit', 'unknown']) {
      final rhythm = Rhythm.fromJson(rhythmJson(source: source));
      expect(rhythm.source, RhythmSource.catalog, reason: 'source=$source');
      expect(rhythm.derived, isFalse, reason: 'source=$source');
    }
  });
}
