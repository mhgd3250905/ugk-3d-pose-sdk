import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_search.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/session_state.dart';
import 'package:ugk_coach/src/catalog/catalog.dart';
import 'package:ugk_coach/src/profile/coach_profile.dart';
import 'package:ugk_coach/src/util/json.dart';

import 'support.dart';

void main() {
  final fixture = loadCatalog();
  const profile = CoachProfile(
    id: 'test',
    appName: 'test',
    bodyGroups: {
      'body.core': ['body.abs'],
    },
  );
  Drill drill(
    String id, {
    String category = 'strength',
    String body = 'abs',
    String pose = 'standing',
    int level = 1,
    List<String> equipment = const [],
    List<String> cautions = const [],
  }) => Drill(
    id: id,
    name: LocalizedText({'zh': '动作$id', 'en': 'Action $id'}),
    category: category,
    muscleGroups: [body],
    position: pose,
    level: level,
    equipment: equipment,
    cautions: cautions,
    scenes: const ['home'],
    unilateral: false,
    defaultDose: Dose(
      mode: id == 'timed' ? DoseMode.time : DoseMode.reps,
      sets: 1,
      reps: id == 'timed' ? null : 12,
      seconds: id == 'timed' ? 30 : null,
      restSeconds: 0,
    ),
  );
  final catalog = Catalog(
    version: 'test',
    taxonomy: fixture.taxonomy,
    drills: [
      drill('strength-abs'),
      drill('stretch-abs', category: 'stretch', pose: 'seated', level: 2),
      drill('strength-shoulder', body: 'deltoids', level: 2),
      drill('mobility', category: 'mobility', pose: 'kneeling', level: 3),
      drill('unsafe', cautions: ['膝']),
      drill('requires-dumbbell', equipment: ['dumbbell']),
      drill('timed', category: 'stretch'),
    ],
  );
  final search = ActionSearch(profile, catalog, minPicks: 3);
  CoachParamValue param(Object value) =>
      CoachParamValue(value: value, source: 'user', turn: 1);
  CoachSessionState active() => AgentTask.start(
    CoachSessionState(
      params: {
        'scene': param('home'),
        'limits': param(['limit.knee']),
      },
    ),
    'recommend',
  ).state;
  Set<Object?> ids(CoachSessionState state, List<String> tags) =>
      search.search(state, tags: tags).items.map((row) => row['id']).toSet();

  test(
    'search requires a live recommend or plan, and returns the specified repair',
    () {
      for (final state in [
        CoachSessionState(),
        active().copyWith(
          task: CoachTaskState(
            type: 'qa',
            nodes: const [CoachNodeState(id: 'output', status: 'pending')],
            reused: false,
          ),
        ),
        active().copyWith(
          task: CoachTaskState(
            type: 'recommend',
            nodes: const [CoachNodeState(id: 'output', status: 'done')],
            reused: false,
          ),
        ),
      ]) {
        final result = search.search(state);
        expect(result.ok, isTrue);
        expect(result.items, isNotEmpty);
        for (final item in result.items) {
          expect(
            search.gate.actionProblem(state, item['id'] as String),
            isNull,
          );
        }
      }
      expect(search.search(active()).ok, isTrue);
      expect(
        search.search(AgentTask.start(CoachSessionState(), 'plan').state).ok,
        isTrue,
      );
    },
  );

  test(
    'purpose body pose and level each use OR, with AND between groups and safety still enforced',
    () {
      expect(
        ids(active(), [
          'purpose.strength',
          'purpose.stretch',
          'body.abs',
          'body.deltoids',
          'pose.standing',
          'pose.seated',
          'level.1',
          'level.2',
        ]),
        {'strength-abs', 'stretch-abs', 'strength-shoulder', 'timed'},
      );
      expect(ids(active(), ['body.abs', 'body.deltoids', 'purpose.stretch']), {
        'stretch-abs',
        'timed',
      });
      expect(
        ids(active(), ['purpose.strength', 'purpose.stretch', 'body.core']),
        {'strength-abs', 'stretch-abs', 'timed'},
      );
    },
  );

  test(
    'other tag prefixes retain AND and cannot weaken equipment or injury filters',
    () {
      expect(ids(active(), ['equip.dumbbell']), isEmpty);
      final owned = active().copyWith(
        params: {
          ...active().params,
          'equipment': param(['equip.dumbbell']),
        },
      );
      expect(ids(owned, ['equip.dumbbell', 'purpose.strength']), {
        'requires-dumbbell',
      });
      expect(
        ids(owned, [
          'equip.dumbbell',
          'scene.home',
          'purpose.strength',
          'purpose.stretch',
        ]),
        {'requires-dumbbell'},
      );
      expect(ids(active(), ['purpose.strength']), isNot(contains('unsafe')));
      final excludes = owned.copyWith(
        params: {
          ...owned.params,
          'equipment_exclude': param(['equip.dumbbell']),
        },
      );
      expect(
        ids(excludes, ['purpose.strength', 'purpose.stretch']),
        contains('requires-dumbbell'),
      );
      final reduced = excludes.copyWith(
        params: {...excludes.params, 'equipment': param(<String>[])},
      );
      expect(
        ids(reduced, ['purpose.strength', 'purpose.stretch']),
        isNot(contains('requires-dumbbell')),
      );
    },
  );

  test(
    'every fresh repeated and candidate row gives an explicit catalogue dose mode',
    () {
      final first = search.search(active(), tags: ['purpose.stretch']);
      expect(
        first.items.singleWhere((row) => row['id'] == 'timed')['doseMode'],
        'seconds',
      );
      expect(
        first.items.singleWhere(
          (row) => row['id'] == 'stretch-abs',
        )['doseMode'],
        'reps',
      );
      final repeat = search.search(first.state, tags: ['purpose.stretch']);
      expect(repeat.items, [
        {'id': 'stretch-abs', 'doseMode': 'reps', 'level': 2},
        {'id': 'timed', 'doseMode': 'seconds', 'level': 1},
      ]);
      final candidates = search.candidateRows(repeat.state, language: 'en');
      expect(candidates, [
        ['stretch-abs', 'Action stretch-abs', 'body.abs', 'reps', 2],
        ['timed', 'Action timed', 'body.abs', 'seconds', 1],
      ]);
    },
  );
}
