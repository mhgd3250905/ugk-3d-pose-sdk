import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  const codec = PlanCodec();
  final catalog = loadCatalog();
  final validator = PlanValidator(catalog: catalog, profile: loadProfile('smartfit'));

  test('codec agrees with the shared formal JSON Schema fixtures', () {
    final cases = jsonDecode(File('test/fixtures/plan-segments-schema.json').readAsStringSync()) as List;
    for (final raw in cases) {
      final entry = raw as Map;
      final env = okEnvelope();
      final item = itemOf(env, 1, 1);
      item.clear();
      item.addAll({
        'exerciseId': 's-butterfly',
        'mode': 'time',
        'sets': 1,
        'perSide': false,
        'restSeconds': 0,
        ...Map<String, Object?>.from(entry['patch'] as Map),
      });
      expect(codec.decodeStrict(planOf(env)).ok, entry['valid'], reason: entry['name'] as String);
    }
  });

  Map<String, Object?> payload([Object? segments]) {
    final env = okEnvelope();
    if (segments != null) itemOf(env, 1, 1)['segments'] = segments;
    return planOf(env);
  }

  Map<String, Object?> segment(String id, {String exerciseId = 's-butterfly'}) => {
    'id': id,
    'exerciseId': exerciseId,
    'mode': 'time',
    'workSeconds': 20,
  };

  test('legacy plan preserves JSON exactly without empty segments', () {
    final old = codec.decode(payload()).toJson();
    final decoded = codec.decode(codec.encode(codec.decode(old)));
    expect(decoded.toJson(), old);
    expect(decoded.items.every((i) => i.segments.isEmpty), isTrue);
    expect(jsonEncode(decoded.toJson()), isNot(contains('segments')));
  });

  test('ordered segments round trip with independent rhythm and materials', () {
    final input = payload([
      segment('y'),
      {
        'id': 't',
        'exerciseId': 'n-windshield',
        'mode': 'reps',
        'reps': 6,
        'holdSeconds': 2,
        'label': 'T 型',
        'rhythm': {
          'kind': 'rep_hold',
          'leadSeconds': 0,
          'phases': [
            {'id': 'go', 'seconds': 1, 'cue': 'w.up'},
            {
              'id': 'hold',
              'seconds': 2,
              'cue': ['w.hold', 'w.breathe'],
              'cueAt': 1,
            },
          ],
        },
      },
      segment('w'),
    ]);
    final result = codec.decodeStrict(input);
    expect(result.ok, isTrue, reason: '${result.issues}');
    final parent = result.plan!.blocks[1].items[1];
    expect(parent.segments.map((s) => s.id), ['y', 't', 'w']);
    expect(codec.decode(codec.encode(result.plan!)).toJson(), result.plan!.toJson());
    expect(parent.copyWith(sets: 3).segments, same(parent.segments));
    expect(parent.copyWith(segments: []).segments, isEmpty);
    final effective = parent.segments[1].toPlanItem(parent);
    expect(effective.exerciseId, 'n-windshield');
    expect(effective.mode, DoseMode.reps);
    expect(effective.reps, 6);
    expect(effective.sets, parent.sets);
    expect(effective.perSide, parent.perSide);
    expect(effective.restSeconds, parent.restSeconds);
    expect(effective.segments, isEmpty);
  });

  test('exerciseIds includes distinct segment media IDs', () {
    final plan = codec.decode(payload([segment('y', exerciseId: 'h-wall-angel')]));
    expect(plan.exerciseIds, contains('h-wall-angel'));
    expect(plan.items.length, 6);
  });

  for (final mode in DoseMode.values) {
    test('segmented ${mode.name} parent can omit unused dose without readback defaults', () {
      final env = okEnvelope();
      final item = itemOf(env, 1, 1);
      item['mode'] = mode.name;
      item.remove('workSeconds');
      item.remove('reps');
      item['segments'] = [segment('y'), segment('t')];
      final decoded = codec.decodeStrict(planOf(env));
      expect(decoded.ok, isTrue, reason: '${decoded.issues}');
      final parent = decoded.plan!.blocks[1].items[1];
      expect(parent.reps, isNull);
      expect(parent.workSeconds, isNull);
      final roundTrip = codec.decode(codec.encode(decoded.plan!));
      expect(roundTrip.toJson(), decoded.plan!.toJson());
      expect(validator.validate(roundTrip).ok, isTrue);
      item['segments'] = [];
      expect(codec.decodeStrict(planOf(env)).ok, isFalse);
      final legacy = codec.decode(planOf(env)).blocks[1].items[1];
      expect(mode == DoseMode.reps ? legacy.reps : legacy.workSeconds, mode == DoseMode.reps ? 10 : 30);
    });
  }

  final invalidCases = <String, Object?>{
    'not an array': {},
    'not an object': [42],
    'missing id': [
      {'exerciseId': 's-butterfly', 'mode': 'time', 'workSeconds': 20},
    ],
    'duplicate id': [segment('y'), segment('y')],
    'unknown mode': [
      {...segment('y'), 'mode': 'seconds'},
    ],
    'fraction dose': [
      {...segment('y'), 'workSeconds': 2.5},
    ],
    'zero dose': [
      {...segment('y'), 'workSeconds': 0},
    ],
    'wrong dose': [
      {...segment('y'), 'reps': 3},
    ],
    'own sets': [
      {...segment('y'), 'sets': 2},
    ],
    'own sides': [
      {...segment('y'), 'perSide': true},
    ],
    'own rest': [
      {...segment('y'), 'restSeconds': 2},
    ],
    'negative hold': [
      {...segment('y'), 'holdSeconds': -1},
    ],
    'empty label': [
      {...segment('y'), 'label': ''},
    ],
    'bad rhythm object': [
      {...segment('y'), 'rhythm': 'bad'},
    ],
    'inline self paced': [
      {
        ...segment('y'),
        'rhythm': {'kind': 'self_paced'},
      },
    ],
    'bad rhythm kind': [
      {
        ...segment('y'),
        'rhythm': {'kind': 'invalid'},
      },
    ],
    'bad phase': [
      {
        ...segment('y'),
        'rhythm': {
          'kind': 'rep_cycle',
          'phases': [false],
        },
      },
    ],
    'bad phase seconds': [
      {
        ...segment('y'),
        'rhythm': {
          'kind': 'rep_cycle',
          'phases': [
            {'id': 'go', 'seconds': -1},
          ],
        },
      },
    ],
    'bad phase cue': [
      {
        ...segment('y'),
        'rhythm': {
          'kind': 'rep_cycle',
          'phases': [
            {
              'id': 'go',
              'seconds': 1,
              'cue': [3],
            },
          ],
        },
      },
    ],
  };
  for (final entry in invalidCases.entries) {
    test('strict codec rejects ${entry.key}', () {
      final result = codec.decodeStrict(payload(entry.value));
      expect(result.ok, isFalse);
      expect(result.issues.any((i) => i.path!.contains('.segments')), isTrue);
      expect(() => codec.decode(payload(entry.value)), throwsFormatException);
    });
  }

  test('validator checks segment scope, required sides and equipment', () {
    final plan = codec.decode(
      payload([
        segment('unknown', exerciseId: 'not-in-catalog'),
        segment('side', exerciseId: 's-figure4'),
        {'id': 'curl', 'exerciseId': 'h-db-curl', 'mode': 'reps', 'reps': 10},
      ]),
    );
    final result = validator.validate(plan, const CoachContext(equipment: {}));
    expect(
      result.errors.where((e) => e.path!.contains('.segments')).map((e) => e.code),
      containsAll([IssueCodes.unknownExercise, IssueCodes.perSide, IssueCodes.equipment]),
    );
  });

  test('validator checks constructor-created segment identity and dose', () {
    final base = codec.decode(payload());
    final b = base.blocks[1];
    final invalid = b.items[1].copyWith(
      segments: const [
        PlanSegment(id: 'x', exerciseId: 's-butterfly', mode: DoseMode.time, workSeconds: 0),
        PlanSegment(id: 'x', exerciseId: 's-butterfly', mode: DoseMode.time, workSeconds: 20),
      ],
    );
    final plan = base.copyWith(
      blocks: [
        PlanBlock(id: b.id, name: b.name, type: b.type, items: [invalid]),
      ],
    );
    final result = validator.validate(plan);
    expect(result.errors.map((e) => e.code), containsAll([IssueCodes.schema, IssueCodes.workSecondsRange]));
  });

  test('duration sums every segment without multiplying parent dose or rest', () {
    final base = codec.decode(payload());
    final item = base.blocks[1].items[1].copyWith(
      sets: 2,
      restSeconds: 7,
      segments: const [
        PlanSegment(id: 'y', exerciseId: 's-butterfly', mode: DoseMode.time, workSeconds: 20),
        PlanSegment(id: 't', exerciseId: 'n-windshield', mode: DoseMode.reps, reps: 4, holdSeconds: 5),
      ],
    );
    final plan = base.copyWith(
      blocks: [
        PlanBlock(id: 'b', name: 'Y/T', type: BlockType.main, items: [item]),
      ],
    );
    expect(const PlanDuration().estimateSeconds(plan, catalog), 10 + 2 * (20 + 4 * 5) + 7);
  });

  test('segment rhythm duration includes lead and hold override per side', () {
    final base = codec.decode(payload());
    final item = base.blocks[1].items[0].copyWith(
      sets: 1,
      segments: const [
        PlanSegment(
          id: 'a',
          exerciseId: 's-figure4',
          mode: DoseMode.reps,
          reps: 2,
          holdSeconds: 4,
          rhythm: {
            'kind': 'rep_hold',
            'leadSeconds': 1,
            'phases': [
              {'id': 'go', 'seconds': 1},
              {'id': 'hold', 'seconds': 2},
            ],
          },
        ),
        PlanSegment(id: 'b', exerciseId: 's-figure4', mode: DoseMode.time, workSeconds: 10),
      ],
    );
    final plan = base.copyWith(
      blocks: [
        PlanBlock(id: 'b', name: 'A/B', type: BlockType.main, items: [item]),
      ],
    );
    expect(const PlanDuration().estimateSeconds(plan, catalog), 10 + 2 * (1 + 2 * (1 + 4) + 10) + 2 * 5);
  });

  test('segment hold overrides derived go-only rhythm while authored phases retain pace', () {
    final base = codec.decode(payload());
    for (final source in ['dose', 'repSeconds', 'catalog']) {
      final item = base.blocks[1].items[1].copyWith(
        sets: 1,
        segments: [
          PlanSegment(
            id: 'a',
            exerciseId: 'n-windshield',
            mode: DoseMode.reps,
            reps: 3,
            holdSeconds: 7,
            rhythm: {
              'kind': 'rep_updown',
              'source': source,
              'leadSeconds': 0,
              'phases': [
                {'id': 'go', 'seconds': 3},
              ],
            },
          ),
        ],
      );
      final plan = base.copyWith(
        blocks: [
          PlanBlock(id: 'b', name: 'A', type: BlockType.main, items: [item]),
        ],
      );
      expect(const PlanDuration().estimateSeconds(plan, catalog), 10 + (source == 'catalog' ? 9 : 21));
    }
  });
}
