// A custom count above 10 (user report 2026-11-06: set 15, from 11 on only
// the chime played). Every count the voice source has recorded is said; a
// count it lacks falls back to the tick chime; the last rep keeps 「最后一个」.
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';

import 'support.dart';

void main() {
  ManifestVoiceSource source(int maxN) => ManifestVoiceSource.fromJson({
    'clips': {
      'zh': {
        'p.go': 300,
        'p.last_rep': 400,
        'p.right': 300,
        'p.left': 300,
        for (var n = 1; n <= maxN; n++) 'n.$n': 300,
      },
    },
    'chimes': {'start': 100, 'tick': 100},
  });

  Map<String, dynamic> updown({String? perSide, String? repUnit}) => {
    'kind': perSide == null ? 'rep_updown' : 'rep_alternate',
    'leadSeconds': 1,
    'phases': [
      {'id': 'go', 'seconds': 1.0},
      {'id': 'back', 'seconds': 1.0},
    ],
    'perSide': ?perSide,
    'repUnit': ?repUnit,
  };

  List<List<String>> countCues(
    Rhythm r,
    PlanItem item,
    ManifestVoiceSource src,
  ) {
    final work = SessionBuilder(
      rhythms: {item.exerciseId: r},
      prepSeconds: 0,
    ).phases(planOf([item])).firstWhere((p) => p.isWork);
    expect(work.reps, item.reps);
    return [
      for (final c in SessionScript(
        source: src,
      ).cues(work, planSeconds: work.seconds))
        if (c.priority == CuePriority.count) c.clips,
    ];
  }

  Iterable<String> numbers(List<List<String>> cues) =>
      cues.expand((c) => c).where((k) => k.startsWith('n.'));

  test('15 reps: counts 11…14 are said, 15 is 「最后一个」', () {
    final cues = countCues(
      Rhythm.fromJson(updown()),
      reps('x', 15),
      source(60),
    );
    expect(cues, hasLength(15));
    expect(numbers(cues), [for (var k = 1; k <= 14; k++) 'n.$k']);
    expect(cues.last, contains('p.last_rep'));
    expect(cues.expand((c) => c), isNot(contains('chime.tick')));
  });

  test('a source with only 1…10 falls back to the chime from 11', () {
    final cues = countCues(
      Rhythm.fromJson(updown()),
      reps('x', 15),
      source(10),
    );
    expect(cues, hasLength(15));
    expect(numbers(cues), [for (var k = 1; k <= 10; k++) 'n.$k']);
    for (var k = 11; k <= 14; k++) {
      expect(cues[k - 1], contains('chime.tick'));
    }
    expect(cues.last, contains('p.last_rep'));
  });

  test('alternating pairs count past 10 too', () {
    final cues = countCues(
      Rhythm.fromJson(
        updown(perSide: 'alternate', repUnit: 'left+right'),
        startingSide: 'right',
      ),
      reps('x', 15, perSide: true),
      source(60),
    );
    final said = numbers(cues).toList();
    expect(said, [for (var k = 1; k <= 14; k++) 'n.$k']);
    expect(cues.expand((c) => c), contains('p.last_rep'));
  });

  test('dose-paced reps (no catalog rhythm) count past 10', () {
    final item = reps('x', 15);
    final work = SessionBuilder(
      prepSeconds: 0,
    ).phases(planOf([item])).firstWhere((p) => p.isWork);
    final said = [
      for (final c in SessionScript(
        source: source(60),
      ).cues(work, planSeconds: work.seconds))
        ...c.voiceClips.where((k) => k.startsWith('n.')),
    ];
    for (var k = 11; k <= 15; k++) {
      expect(said, contains('n.$k'));
    }
  });
}
