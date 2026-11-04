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
}
