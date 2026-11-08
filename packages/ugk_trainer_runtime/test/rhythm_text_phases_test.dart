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
    final file = File(
      '../ugk_trainer/assets/pose_hub/app-pack-r2-v10/catalog.json',
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

  test('bundled r2-v10: 23 alternating pairs, every other rhythm as r2-v1', () {
    List<Object?> rows(String p) =>
        (jsonDecode(File(p).readAsStringSync()) as Map)['actions']
            as List<Object?>;
    Rhythm rhythmOf(Object? row) => Rhythm.fromJson(
      Map<String, dynamic>.from(
        ((row as Map)['rhythm'] as Map)['execution'] as Map,
      ),
    );
    final bundled = rows(
      '../ugk_trainer/assets/pose_hub/app-pack-r2-v10/catalog.json',
    );
    final v1 = {
      for (final r in rows('test/fixtures/pose_hub/r2-v1/catalog.json'))
        (r as Map)['id']: r,
    };
    expect(bundled.map((r) => (r as Map)['id']).toSet(), v1.keys.toSet());
    final pairs = <String>[];
    for (final row in bundled) {
      final id = (row as Map)['id'] as String;
      final r = rhythmOf(row);
      final old = rhythmOf(v1[id]);
      expect(old.alternatePair, isFalse, reason: id);
      if (r.alternatePair) {
        pairs.add(id);
        // One count = left + right: twice the r2-v1 single-side cycle.
        expect(r.cycleFor(), closeTo(2 * old.cycleFor(), 1e-9), reason: id);
        expect(
          r.planRepSecondsFor(),
          closeTo(old.cycleFor(), 1e-9),
          reason: id,
        );
      } else {
        expect(r.cycleFor(), old.cycleFor(), reason: id);
        expect(r.planRepSecondsFor(), r.cycleFor(), reason: id);
      }
    }
    expect(pairs, hasLength(23));
    expect(
      pairs,
      containsAll([
        'h-mountain-climber',
        'w-dead-bug',
        'h-russian-twist',
        'n-chair-wiper',
      ]),
    );
  });
}
