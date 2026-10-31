import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/ugk_coach.dart';

void main() {
  const profile = CoachProfile(
    id: 'timing',
    appName: 'timing',
    limits: PlanLimits(
      rounds: IntRange(1, 2),
      restBetweenRoundsSeconds: IntRange(0, 0),
      sets: IntRange(1, 3),
      minutes: IntRange(1, 60),
    ),
  );
  final catalog = Catalog(
    version: 'timing',
    drills: [
      for (final row in [
        ('a', 'abs'),
        ('b', 'abs'),
        ('c', 'deltoids'),
        ('d', 'abs'),
        ('e', 'deltoids'),
      ])
        Drill(
          id: row.$1,
          name: LocalizedText({'en': row.$1}),
          category: 'core',
          muscleGroups: [row.$2],
          position: 'standing',
          unilateral: false,
          level: 1,
          scenes: const ['home'],
          defaultDose: const Dose(
            mode: DoseMode.time,
            sets: 1,
            seconds: 100,
            restSeconds: 0,
          ),
          doseRange: const DoseRange(
            sets: IntRange(1, 3),
            seconds: IntRange(100, 100),
            restSeconds: IntRange(0, 0),
          ),
        ),
    ],
  );
  final builder = PlanBuilder(profile, catalog, minPicks: 3);
  CoachParamValue param(Object value) =>
      CoachParamValue(value: value, source: 'user', quote: 'explicit', turn: 1);
  CoachSessionState ready(int minutes, {List<Map<String, Object?>>? dose}) =>
      CoachSessionState(
        userTurns: const [CoachUserTurn(turn: 1, text: 'explicit')],
        task: CoachTaskState(
          type: 'plan',
          reused: false,
          nodes: [
            for (final id in [
              'understand',
              'parameters',
              'actions',
              'planning',
              'review',
              'output',
            ])
              CoachNodeState(
                id: id,
                status: id == 'planning'
                    ? 'current'
                    : ['understand', 'parameters', 'actions'].contains(id)
                    ? 'done'
                    : 'pending',
              ),
          ],
        ),
        params: {
          'scene': param('home'),
          'minutes': param(minutes),
          'goal': param(['body.abs']),
          'equipment': param(<String>[]),
          'limits': param(<String>[]),
          if (dose != null) 'dose': param(dose),
        },
        seenActionIds: {'a', 'b', 'c', 'd', 'e'},
        picks: ['a', 'b', 'c', 'd', 'e'],
      );
  Map<String, Object?> draft({List<String> ids = const ['a']}) => {
    'title': 'Timing',
    'blocks': [
      {
        'kind': 'main',
        'items': [
          for (final id in ids) <String, Object?>{'id': id},
        ],
      },
    ],
  };
  Map<String, Object?> plan(DraftResult result) =>
      result.state.plans[result.planId]!.last.plan;
  List<Map<String, Object?>> items(DraftResult result) =>
      (((plan(result)['blocks'] as List).first as Map)['items'] as List)
          .map((item) => (item as Map).cast<String, Object?>())
          .toList();

  test(
    'legacy doses of any type are ignored, with exactly the baseline card',
    () {
      final baseline = builder.draft(ready(3), draft(), newPlanId: 'p');
      final payload = draft();
      final block = (payload['blocks'] as List).first as Map;
      block['rounds'] = {'malformed': true};
      (block['items'] as List)[0] = <String, Object?>{
        'id': 'a',
        'sets': 99,
        'seconds': '10000',
        'reps': -1,
      };
      final normalized = builder.draft(ready(3), payload, newPlanId: 'p');
      expect(normalized.ok, isTrue);
      expect(plan(normalized), plan(baseline));
      expect(normalized.note, contains('已忽略'));
      expect(normalized.notes.single, contains('4'));
    },
  );
  test(
    'structured fit changes include stable block/action identity and measured before/after time',
    () {
      final result = builder.draft(ready(3), draft(), newPlanId: 'p');
      expect(result.ok, isTrue);
      expect(result.fitLog, isNotEmpty);
      final step = result.fitLog.first;
      expect(step['blockId'], 'b1');
      expect(step['field'], 'rounds');
      expect(step['before'], 1);
      expect(step['after'], 2);
      expect(step['beforeEstimatedSec'], 110);
      // 240 -> 225: the round rest replaces, rather than adds to, transition.
      expect(step['afterEstimatedSec'], 225);
      final restored = CoachSessionState.fromJson(
        jsonDecode(jsonEncode(result.state.toJson())) as Map<String, Object?>,
      );
      expect(restored.plans['p']!.single.fitLog, result.fitLog);
    },
  );
  test(
    'an interior integer-dose gap delivers heuristic best, with its error and no duration rejection',
    () {
      // Legal endpoints 110/225 straddle 180; neither meets ±10%. This is not
      // interval impossibility and must not be sent back as a model mistake.
      final result = builder.draft(
        ready(
          3,
          dose: [
            {'field': 'sets', 'value': 1},
          ],
        ),
        draft(),
        newPlanId: 'p',
      );
      expect(result.ok, isTrue);
      expect(result.planId, 'p');
      expect(result.feasibility, isNull);
      // One repeated boundary no longer contributes an extra 15 seconds.
      expect(result.state.plans['p']!.single.estimateSec, 225);
      expect(result.durationErrorPercent, closeTo(25, .001));
      expect(result.toJson()['withinTolerance'], isFalse);
    },
  );
  test(
    'bounds include legal unsearched rounds and rest, so the heuristic cannot falsely prove impossibility',
    () {
      const broadProfile = CoachProfile(
        id: 'timing',
        appName: 'timing',
        limits: PlanLimits(
          sets: IntRange(1, 1),
          rounds: IntRange(1, 6),
          restBetweenRoundsSeconds: IntRange(0, 300),
          minutes: IntRange(1, 60),
        ),
      );
      final result = PlanBuilder(
        broadProfile,
        catalog,
        minPicks: 3,
      ).draft(ready(20), draft(), newPlanId: 'broad');
      expect(result.ok, isTrue);
      expect(result.feasibility, isNull);
      expect(result.planId, 'broad');
      // Four searched rounds have three boundaries: 500 - 3 * 15 = 455.
      expect(result.state.plans['broad']!.single.estimateSec, 455);
      expect(result.durationErrorPercent, greaterThan(10));
    },
  );

  test(
    'proven minimum longer than target is a structured non-rejection without a card',
    () {
      final original = ready(1);
      final result = builder.draft(original, draft(), newPlanId: 'p');
      expect(result.ok, isTrue);
      expect(result.toJson()['status'], 'infeasible');
      expect(result.toJson()['needsUserChoice'], isTrue);
      expect(result.feasibility!['reason'], 'minimum_exceeds_target');
      expect(result.feasibility!['minEstimatedSec'], 110);
      expect(result.planId, isNull);
      expect(result.state, same(original));
    },
  );
  test('proven maximum shorter than target reports both bounds', () {
    final result = builder.draft(ready(60), draft(), newPlanId: 'p');
    expect(result.ok, isTrue);
    expect(result.feasibility!['reason'], 'maximum_below_target');
    expect(result.feasibility!['minEstimatedSec'], 110);
    // Two rounds of three 100-second sets + 10 prep + one 15-second rest.
    expect(result.feasibility!['maxEstimatedSec'], 625);
    expect(result.planId, isNull);
  });
  test(
    'explicit sets and rounds remain locked; conflict asks for user choice',
    () {
      final good = builder.draft(
        ready(
          5,
          dose: [
            {'field': 'sets', 'value': 3},
            {'field': 'rounds', 'value': 1},
          ],
        ),
        draft(),
        newPlanId: 'p',
      );
      expect(good.ok, isTrue);
      expect(items(good).single['sets'], 3);
      expect(((plan(good)['blocks'] as List).first as Map)['rounds'], 1);
      final conflict = builder.draft(
        ready(
          1,
          dose: [
            {'field': 'sets', 'value': 3},
            {'field': 'rounds', 'value': 1},
          ],
        ),
        draft(),
        newPlanId: 'p',
      );
      expect(conflict.ok, isTrue);
      expect(conflict.planId, isNull);
      expect(conflict.feasibility!['reason'], 'minimum_exceeds_target');
      final outOfRange = builder.draft(
        ready(
          5,
          dose: [
            {'field': 'sets', 'value': 9},
          ],
        ),
        draft(),
        newPlanId: 'p',
      );
      expect(outOfRange.feasibility!['reason'], 'explicit_dose_conflict');
      expect(outOfRange.toJson()['ok'], isTrue);
    },
  );
  test(
    'specific action dose overrides the global dose without weakening catalogue ranges',
    () {
      final result = builder.draft(
        ready(
          9,
          dose: [
            {'field': 'sets', 'value': 3},
            {'field': 'sets', 'value': 2, 'actionId': 'a'},
            {'field': 'rounds', 'value': 1},
          ],
        ),
        draft(ids: ['a', 'c']),
        newPlanId: 'p',
      );
      expect(result.planId, 'p', reason: '${result.feasibility}');
      final doses = {
        for (final item in items(result)) item['exerciseId']: item['sets'],
      };
      expect(doses, {'a': 2, 'c': 3});
    },
  );
  test(
    'duplicate same-block ids merge dose; distinct selection and stable group order remain',
    () {
      final result = builder.draft(
        ready(20),
        draft(ids: ['a', 'b', 'c', 'a', 'd', 'e']),
        newPlanId: 'p',
      );
      expect(result.ok, isTrue);
      expect(items(result).map((item) => item['exerciseId']), [
        'a',
        'c',
        'b',
        'e',
        'd',
      ]);
      expect(
        items(result).where((item) => item['exerciseId'] == 'a'),
        hasLength(1),
      );
      expect(result.notes.any((note) => note.contains('已合并')), isTrue);
    },
  );
}
