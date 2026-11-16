import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

void main() {
  test('r2 compact text phases parse to id/seconds without cues', () {
    final r = Rhythm.fromJson({
      'kind': 'rep_alternate',
      'leadSeconds': 1,
      'phases':
          'go=0.8s@phase.start; hold=1.2s@phase.peak; back=0.8s@phase.end; rest=1.2s',
      'source': 'spec-timeline manual r2',
      'reps': 6,
    });
    expect(r.phases.map((p) => p.id), ['go', 'hold', 'back', 'rest']);
    expect(r.phases.map((p) => p.seconds), [0.8, 1.2, 0.8, 1.2]);
    expect(r.phases.every((p) => p.cues.isEmpty), isTrue);
    expect(r.defaultReps, 6);
    expect(r.counted, isTrue);
  });

  test('empty text means no phases, same as an absent list', () {
    final empty = Rhythm.fromJson({
      'kind': 'hold',
      'leadSeconds': 1,
      'phases': '',
    });
    final absent = Rhythm.fromJson({'kind': 'hold', 'leadSeconds': 1});
    expect(empty.phases, isEmpty);
    expect(empty.kind, absent.kind);
  });

  test('list phases are unchanged', () {
    final r = Rhythm.fromJson({
      'kind': 'rep_hold',
      'phases': [
        {'id': 'go', 'seconds': 1.2, 'cue': 'w.up'},
      ],
    });
    expect(r.phases.single.cues, ['w.up']);
  });

  test('malformed text and wrong types fail loudly', () {
    expect(
      () => Rhythm.fromJson({'kind': 'rep_hold', 'phases': 'go=fast'}),
      throwsFormatException,
    );
    expect(
      () => Rhythm.fromJson({'kind': 'rep_hold', 'phases': 3}),
      throwsFormatException,
    );
  });

  test('every bundled execution parses', () {
    // Integrity only: whatever pack is bundled, each execution must parse.
    final file = File(
      '${PoseHubActionLibrary.assetRoot.replaceFirst('packages/ugk_trainer/', '../ugk_trainer/')}catalog.json',
    );
    final rows =
        (jsonDecode(file.readAsStringSync()) as Map)['actions'] as List;
    var parsed = 0;
    for (final row in rows) {
      final execution = ((row as Map)['rhythm'] as Map?)?['execution'];
      if (execution is! Map) continue;
      Rhythm.fromJson(Map<String, dynamic>.from(execution));
      parsed++;
    }
    expect(parsed, rows.length);
  });

  test('r2-v2 execution with repUnit left+right is an alternating pair', () {
    // r2-v2 puts perSide / repUnit / startingSide into rhythm.execution for
    // actions that really alternate, so Rhythm.fromJson(execution) is enough.
    final r = Rhythm.fromJson({
      'kind': 'rep_alternate',
      'leadSeconds': 1,
      'phases':
          'go=0.8s@phase.start; hold=1.1s@phase.peak; back=0.8s@phase.end; rest=1.3s',
      'reps': 8,
      'perSide': 'alternate',
      'repUnit': 'left+right',
      'startingSide': 'right',
    });
    expect(r.alternatePair, isTrue);
    expect(r.pairFirstSide, 'right');
    expect(r.cycleFor(), closeTo(8.0, 1e-9));
    // Plans count 每侧 N 次 × 2 sides: a pair costs half its cycle per side.
    expect(r.planRepSecondsFor(), closeTo(4.0, 1e-9));
    expect(r.withHold(2).alternatePair, isTrue);
  });

  test('r2-v1 execution without repUnit keeps one side per count', () {
    final r = Rhythm.fromJson({
      'kind': 'rep_alternate',
      'leadSeconds': 1,
      'phases': 'go=0.8s; rest=1.2s',
    });
    expect(r.alternatePair, isFalse);
  });

  // Execution text phases on a fixed sample (test/fixtures/rhythm/), copied
  // once from the bundled r2-v16 pack. The fixture never follows the bundled
  // pack, so swapping the pack does not touch these expectations.
  group('fixed execution sample', () {
    final sample =
        jsonDecode(
              File(
                'test/fixtures/rhythm/execution-sample-r2-v16.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final rows = [
      for (final row in sample['actions'] as List)
        Map<String, dynamic>.from(row as Map),
    ];
    Map<String, dynamic> executionOf(Map<String, dynamic> row) =>
        Map<String, dynamic>.from((row['rhythm'] as Map)['execution'] as Map);
    Rhythm rhythmOf(String id) =>
        Rhythm.fromJson(executionOf(rows.firstWhere((r) => r['id'] == id)));

    // id -> (phase ids, seconds of one side, pair first side or null).
    const expected = <String, (List<String>, double, String?)>{
      'h-mountain-climber': (['go', 'hold', 'back'], 2.5, 'right'),
      'w-dead-bug': (['go', 'hold', 'back'], 3.5, 'right'),
      'h-russian-twist': (['go', 'hold', 'back'], 2.0, 'right'),
      'n-chair-wiper': (['go', 'hold', 'back'], 2.5, 'right'),
      'n-squat-shift': (['go', 'hold', 'back'], 4.0, 'left'),
      'adductors-A': (['go', 'hold', 'back', 'rest'], 4.0, 'right'),
      'h-squat': (['go', 'hold', 'back'], 3.5, null),
      'h-db-press': (['go', 'hold', 'back', 'rest'], 3.5, null),
      'chest-B': (['go', 'hold', 'back', 'rest'], 3.5, null),
      'h-side-leg-raise': (['go', 'hold', 'back'], 3.0, null),
      'h-calf-raise': (['go', 'hold', 'back'], 3.0, null),
      'abs-C': (['go', 'hold', 'back', 'rest'], 3.5, null),
      'h-hip-gate': (['go', 'hold', 'back', 'rest'], 5.0, null),
      'o-seated-catcow': (['go', 'back'], 5.0, null),
      'n-pelvis-circle': (['go'], 4.0, null),
      's-butterfly': (<String>[], 0.0, null),
      's-kneel-hipflex': (<String>[], 0.0, null),
      'abs-A': (<String>[], 0.0, null),
      'abs-B': (<String>[], 0.0, null),
      't-flare-side-hold': (<String>[], 0.0, null),
    };

    test('sample covers every execution kind and its rows are all checked', () {
      expect(rows.map((r) => r['id']).toSet(), expected.keys.toSet());
      expect(rows.map((r) => executionOf(r)['kind']).toSet(), {
        'hold',
        'rep_hold',
        'rep_updown',
        'rep_alternate',
        'rep_cycle',
      });
    });

    test('text phases parse to ids and seconds without cues', () {
      for (final MapEntry(key: id, value: (ids, side, _)) in expected.entries) {
        final r = rhythmOf(id);
        expect(r.phases.map((p) => p.id), ids, reason: id);
        expect(
          r.phases.fold(0.0, (s, p) => s + p.seconds),
          closeTo(side, 1e-9),
          reason: id,
        );
        expect(r.phases.every((p) => p.cues.isEmpty), isTrue, reason: id);
      }
    });

    test('left+right counts are alternating pairs, everything else is not', () {
      for (final row in rows) {
        final id = row['id'] as String;
        final execution = executionOf(row);
        final r = Rhythm.fromJson(execution);
        final (_, side, first) = expected[id]!;
        expect(
          r.alternatePair,
          execution['repUnit'] == 'left+right',
          reason: id,
        );
        expect(r.pairFirstSide, first, reason: id);
        if (r.alternatePair) {
          // One count = left + right; plans count per side.
          expect(r.cycleFor(), closeTo(2 * side, 1e-9), reason: id);
          expect(r.planRepSecondsFor(), closeTo(side, 1e-9), reason: id);
          expect(r.withHold(2).alternatePair, isTrue, reason: id);
        } else {
          expect(r.cycleFor(), closeTo(side, 1e-9), reason: id);
          expect(r.planRepSecondsFor(), r.cycleFor(), reason: id);
        }
      }
    });

    test('counted executions carry their default reps; holds are timed', () {
      for (final row in rows) {
        final id = row['id'] as String;
        final execution = executionOf(row);
        final r = Rhythm.fromJson(execution);
        if (execution['kind'] == 'hold') {
          expect(r.phases, isEmpty, reason: id);
          expect(r.counted, isFalse, reason: id);
        } else {
          expect(r.counted, isTrue, reason: id);
          expect(r.defaultReps, execution['reps'], reason: id);
        }
      }
    });

    test('rep_hold hold override replaces only the hold phase', () {
      final r = rhythmOf('h-calf-raise');
      expect(r.cycleFor(), closeTo(3.0, 1e-9));
      expect(r.cycleFor(hold: 2), closeTo(4.2, 1e-9));
    });
  });
}
