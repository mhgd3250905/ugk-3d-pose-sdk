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
      test(
        'wrong ${mode.name} field uses catalogue default and retains sets ($language)',
        () {
          final result = builder.draft(
            state(mode),
            draft(mode, mode == DoseMode.reps ? {'seconds': 55} : {'reps': 7}),
            newPlanId: 'test',
            language: language,
          );
          expect(result.ok, isTrue, reason: '${result.error}');
          expect(result.notes, hasLength(3));
          expect(result.toJson()['notes'], result.notes);
          for (final item in items(result)) {
            expect(item['sets'], 2);
            expect(item['mode'], mode.name);
            expect(
              item[mode == DoseMode.reps ? 'reps' : 'workSeconds'],
              mode == DoseMode.reps ? 12 : 35,
            );
            expect(
              item.containsKey(mode == DoseMode.reps ? 'workSeconds' : 'reps'),
              isFalse,
            );
          }
          expect(
            result.notes.first,
            contains(language == 'en' ? 'Exercise' : '测试'),
          );
          expect(
            result.notes.first,
            contains(language == 'en' ? 'retained 2 sets' : '保留 2 组'),
          );
        },
      );
    }
    test(
      'correct ${mode.name} field remains an explicit override without fallback note',
      () {
        final result = builder.draft(
          state(mode, minutes: 5),
          draft(mode, mode == DoseMode.reps ? {'reps': 14} : {'seconds': 40}),
          newPlanId: 'test',
        );
        expect(result.ok, isTrue, reason: '${result.error}');
        expect(result.notes, isEmpty);
        for (final item in items(result)) {
          expect(
            item[mode == DoseMode.reps ? 'reps' : 'workSeconds'],
            mode == DoseMode.reps ? 14 : 40,
          );
        }
      },
    );
  }
  test(
    'incorrect value types and unsearched IDs still fail without relaxing safety',
    () {
      final malformed = builder.draft(
        state(DoseMode.reps),
        draft(DoseMode.reps, {'seconds': '55'}),
        newPlanId: 'test',
      );
      expect(malformed.error!['code'], 'invalid_item');
      final unseen = builder.draft(
        state(DoseMode.reps).copyWith(seenActionIds: {}),
        draft(DoseMode.reps, {'seconds': 55}),
        newPlanId: 'test',
      );
      expect(unseen.error!['code'], 'incompatible_action');
    },
  );
}
