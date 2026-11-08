// Counted moves are coached like timed holds (2026-11-06): their key points
// are spoken in the gaps between the counts, not only the numbers. Before
// this, SessionScript._rhythmCues (catalog rep_* rhythms) said only
// "开始, 1, 2, 3…" while _hold spread cue1/cue2 over the hold; on the
// SmartFit test pack every rep_cycle / rep_alternate / rep_updown /
// rep_hold move trained without any guidance.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/engine.dart';

import 'support.dart';

const _catalog = 'assets/pose_hub/app-pack-r2-v10/catalog.json';

/// The r2 execution of 坐姿猫牛式 / 坐椅雨刷 (built-in catalog values).
const catCow = {
  'kind': 'rep_cycle',
  'leadSeconds': 1,
  'phases': 'go=3.8s@phase.start; back=3.6s@phase.end; rest=0.6s',
  'reps': 6,
};
const wiper = {
  'kind': 'rep_alternate',
  'leadSeconds': 1,
  'phases':
      'go=0.8s@phase.start; hold=1.4s@phase.peak; back=0.7s@phase.end; '
      'rest=1.1s',
  'reps': 6,
  'perSide': 'alternate',
  'repUnit': 'left+right',
  'startingSide': 'right',
};

/// Every own line a move can have, so the sweep tests the script and not
/// which moves happen to have recorded clips.
Map<String, dynamic> _packFor(String id) => {
  'id': id,
  'voice': {
    'lines': [
      for (final (line, ms) in const [
        ('name', 1200),
        ('intro', 2600),
        ('cue1', 2200),
        ('cue2', 2400),
        ('cue3', 2000),
        ('side_switch', 1800),
        ('rest', 2000),
        ('finish', 1500),
      ])
        {
          'id': line,
          'role': line,
          'text': {'zh': '$id $line'},
          'ms': {'zh': ms},
        },
    ],
  },
};

void main() {
  final common = loadJson('smartfit/packs/_common/pack.json');

  bool own(String id, VoiceCue c) => c.clips.any((k) => k.startsWith('$id/'));
  bool keyPoint(String id, VoiceCue c) => c.clips.any(
    (k) =>
        const ['cue1', 'cue2', 'cue3', 'side_switch'].any((l) => k == '$id/$l'),
  );

  void noOverlap(String where, VoiceSource s, List<VoiceCue> cues) {
    final sorted = [...cues]..sort((a, b) => a.at.compareTo(b.at));
    for (var i = 1; i < sorted.length; i++) {
      final prevEnd =
          sorted[i - 1].at + s.total(sorted[i - 1].clips, lang: 'zh');
      expect(
        sorted[i].at,
        greaterThanOrEqualTo(prevEnd - 1e-9),
        reason: '$where: ${sorted[i - 1]} overlaps ${sorted[i]}',
      );
    }
  }

  group('rep_cycle and rep_alternate are coached during the set', () {
    final source = smartSource();
    final script = SessionScript(source: source);

    for (final (name, json, perSide) in [
      ('rep_cycle', catCow, false),
      ('rep_alternate', wiper, true),
    ]) {
      test(name, () {
        final rhythm = Rhythm.fromJson(Map<String, dynamic>.from(json));
        expect(rhythm.counted, isTrue);
        expect(rhythm.derived, isFalse);
        final plan = planOf([reps('h-squat', 6, sets: 2, perSide: perSide)]);
        final b = SessionBuilder(
          rhythms: {'h-squat': rhythm},
          switchSecondsFor: script.switchSecondsFor,
        );
        final phases = b.phases(plan);
        final works = phases.where((p) => p.isWork).toList();
        // An alternating pair is one phase per set (no side switch).
        expect(works, hasLength(2), reason: '$works');
        final spoken = <String>[];
        for (final w in works) {
          final cues = script.cues(w, planSeconds: b.planSeconds(plan));
          noOverlap('$name $w', source, cues);
          // Every count is still said, and still on its beat.
          for (var k = 1; k <= 6; k++) {
            expect(
              cues.where((c) => c.clips.contains('n.$k')),
              hasLength(1),
              reason: '$name set ${w.set}: count $k',
            );
          }
          final points = cues.where((c) => keyPoint('h-squat', c)).toList();
          expect(points, isNotEmpty, reason: '$name set ${w.set}: $cues');
          for (final c in points) {
            expect(c.priority, CuePriority.coach);
            expect(
              c.at + source.total(c.clips, lang: 'zh'),
              lessThanOrEqualTo(w.seconds),
            );
          }
          spoken.addAll([for (final c in points) ...c.clips]);
        }
        // The whole introduction is not repeated inside the set.
        expect(spoken.where((k) => k == 'h-squat/intro'), isEmpty);

        // And it reaches the output: the queue speaks a key point.
        final output = RecordingOutput();
        final queue = VoiceQueue(
          output: output,
          lib: source,
          settings: const VoiceSettings(),
        );
        final work = works.first;
        final cues = script.cues(work, planSeconds: b.planSeconds(plan));
        for (var t = 0.0; t <= work.seconds; t += .05) {
          for (final c in cues) {
            if (c.at <= t && c.at > t - .05) queue.submit(c, t);
          }
        }
        final assets = output.spoken.expand((s) => s).toList();
        expect(
          assets.any((a) => a.contains('/h-squat/voice/zh/cue')),
          isTrue,
          reason: '$assets',
        );
      });
    }
  });

  test('all 249 built-in actions: every kind gets name/intro before the '
      'first set and a key point during it', () {
    final catalog =
        jsonDecode(File(_catalog).readAsStringSync()) as Map<String, dynamic>;
    final actions = [
      for (final a in catalog['actions'] as List)
        Map<String, dynamic>.from(a as Map),
    ];
    expect(actions, hasLength(249));
    final source = DrillPackVoiceSource.fromPacks(
      common: common,
      packs: {
        for (final a in actions) a['id'] as String: _packFor(a['id'] as String),
      },
    );
    final script = SessionScript(source: source);
    final kinds = <String, int>{};
    final failures = <String>[];
    for (final a in actions) {
      final id = a['id'] as String;
      final execution = Map<String, dynamic>.from(
        (a['rhythm'] as Map)['execution'] as Map,
      );
      final kind = execution['kind'] as String;
      kinds[kind] = (kinds[kind] ?? 0) + 1;
      final rhythm = Rhythm.fromJson(
        execution,
        startingSide: execution['startingSide'] as String?,
      );
      final dose = Map<String, dynamic>.from(a['defaultDose'] as Map);
      final perSide = a['unilateral'] == true;
      final item = dose['mode'] == 'reps'
          ? reps(id, dose['reps'] as int, perSide: perSide)
          : timed(
              id,
              (dose['seconds'] ?? dose['workSeconds']) as int,
              perSide: perSide,
            );
      final plan = planOf([item]);
      final b = SessionBuilder(
        rhythms: {id: rhythm},
        switchSecondsFor: script.switchSecondsFor,
      );
      final phases = b.phases(plan);
      final prep = phases.firstWhere((p) => p.kind == PhaseKind.prep);
      final work = phases.firstWhere((p) => p.isWork);
      final total = b.planSeconds(plan);
      final prepCues = script.cues(prep, planSeconds: total);
      final workCues = script.cues(work, planSeconds: total);
      final intro = [...prepCues, ...workCues].any(
        (c) => c.clips.contains('$id/name') || c.clips.contains('$id/intro'),
      );
      final guided = workCues.any((c) => keyPoint(id, c));
      if (!intro || !guided) {
        failures.add(
          '$id ($kind, ${dose['mode']}): intro=$intro keyPoint=$guided '
          'prep=${prepCues.where((c) => own(id, c)).toList()} '
          'work=${workCues.map((c) => c.clips.join('+')).toList()}',
        );
      }
    }
    expect(kinds, {
      'hold': 62,
      'rep_hold': 89,
      'rep_updown': 68,
      'rep_alternate': 23,
      'rep_cycle': 7,
    });
    expect(failures, isEmpty, reason: failures.join('\n'));
  });
}
