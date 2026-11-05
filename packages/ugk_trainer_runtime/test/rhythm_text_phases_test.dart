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
    final empty = Rhythm.fromJson({'kind': 'hold', 'leadSeconds': 1, 'phases': ''});
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

  test('every bundled r2-v1 execution parses', () {
    final file = File('../ugk_trainer/assets/pose_hub/app-pack-r2-v1/catalog.json');
    final rows = (jsonDecode(file.readAsStringSync()) as Map)['actions'] as List;
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
}
