import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/src/agent/session_state.dart';
import 'package:ugk_coach/src/catalog/catalog.dart';
import 'package:ugk_coach/src/profile/coach_profile.dart';
import 'package:ugk_coach/src/util/json.dart';

import 'support.dart';

void main() {
  final fixture = loadCatalog();
  const profile = CoachProfile(id: 'test', appName: 'test');
  final catalog = Catalog(
    version: 'test',
    taxonomy: fixture.taxonomy,
    drills: [
      for (final mode in DoseMode.values)
        for (var index = 0; index < 3; index++)
          Drill(
            id: '${mode.name}$index',
            name: LocalizedText({
              'zh': '测试${mode.name}$index',
              'en': 'Exercise ${mode.name}$index',
            }),
            category: 'strength',
            muscleGroups: const ['abs'],
            position: 'standing',
            unilateral: false,
            level: 1,
            scenes: const ['home'],
            defaultDose: Dose(
              mode: mode,
              sets: 1,
              reps: mode == DoseMode.reps ? 12 : null,
              seconds: mode == DoseMode.time ? 35 : null,
              restSeconds: 0,
            ),
          ),
    ],
  );
  final builder = PlanBuilder(profile, catalog, minPicks: 3);
  CoachParamValue param(Object value) =>
      CoachParamValue(value: value, source: 'user', turn: 1);
  CoachSessionState state(DoseMode mode, {int minutes = 4}) {
    final started = AgentTask.start(
      CoachSessionState(
        params: {
          'scene': param('home'),
          'goal': param(['body.abs']),
          'minutes': param(minutes),
          'equipment': param(<String>[]),
          'level': param(1),
          'limits': param(<String>[]),
        },
      ),
      'plan',
    ).state;
    final ids = [for (var i = 0; i < 3; i++) '${mode.name}$i'];
    return started.copyWith(
      task: started.task!.copyWith(
        nodes: [
          for (final node in started.task!.nodes)
            node.copyWith(
              status: node.id == 'planning'
                  ? 'current'
                  : {'understand', 'parameters', 'actions'}.contains(node.id)
                  ? 'done'
                  : 'pending',
              stamp: {'understand', 'parameters', 'actions'}.contains(node.id)
                  ? 'done'
                  : null,
            ),
        ],
      ),
      seenActionIds: ids.toSet(),
      picks: ids,
    );
  }

  Map<String, Object?> draft(DoseMode mode, Map<String, Object?> fields) => {
    'title': 'Test',
    'blocks': [
      {
        'kind': 'main',
        'items': [
          for (var i = 0; i < 3; i++)
            {'id': '${mode.name}$i', 'sets': 2, ...fields},
        ],
      },
    ],
  };
  List<Map<String, Object?>> items(DraftResult result) =>
      (((result.state.plans[result.planId]!.last.plan['blocks'] as List).single
                  as Map<String, Object?>)['items']
              as List)
          .cast<Map<String, Object?>>();

  for (final mode in DoseMode.values) {
    for (final language in ['zh', 'en']) {
      test('legacy ${mode.name} dose fields are ignored ($language)', () {
        final clean = draft(mode, {});
        for (final block in clean['blocks']! as List) {
          for (final item in (block as Map)['items'] as List) {
            (item as Map).remove('sets');
          }
        }
        final baseline = builder.draft(
          state(mode),
          clean,
          newPlanId: 'test',
          language: language,
        );
        final result = builder.draft(
          state(mode),
          draft(mode, mode == DoseMode.reps ? {'seconds': 55} : {'reps': 7}),
          newPlanId: 'test',
          language: language,
        );
        expect(result.ok, isTrue, reason: '${result.error}');
        expect(
          result.state.plans['test']!.single.plan,
          baseline.state.plans['test']!.single.plan,
        );
        expect(result.note, contains(language == 'en' ? 'Ignored' : '已忽略'));
        for (final item in items(result)) {
          expect(item['mode'], mode.name);
          expect(
            item.containsKey(mode == DoseMode.reps ? 'workSeconds' : 'reps'),
            isFalse,
          );
        }
      });
    }
    test('correct legacy ${mode.name} dose cannot override the timer', () {
      final first = builder.draft(
        state(mode, minutes: 5),
        draft(mode, mode == DoseMode.reps ? {'reps': 14} : {'seconds': 40}),
        newPlanId: 'test',
      );
      final other = builder.draft(
        state(mode, minutes: 5),
        draft(mode, mode == DoseMode.reps ? {'reps': 29} : {'seconds': 119}),
        newPlanId: 'test',
      );
      expect(first.ok, isTrue);
      expect(
        first.state.plans['test']!.single.plan,
        other.state.plans['test']!.single.plan,
      );
      expect(first.note, contains('已忽略'));
    });
  }
  test(
    'legacy malformed doses are ignored but unsearched IDs remain rejected',
    () {
      final malformed = builder.draft(
        state(DoseMode.reps),
        draft(DoseMode.reps, {'seconds': '55'}),
        newPlanId: 'test',
      );
      expect(malformed.ok, isTrue);
      expect(malformed.note, contains('已忽略'));
      final unseen = builder.draft(
        state(DoseMode.reps).copyWith(seenActionIds: {}),
        draft(DoseMode.reps, {'seconds': 55}),
        newPlanId: 'test',
      );
      expect(unseen.error!['code'], 'incompatible_action');
    },
  );
}
