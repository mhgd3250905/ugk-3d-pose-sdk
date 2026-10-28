import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/terminal_tool_handler.dart';
import 'package:ugk_coach/ugk_coach.dart';

void main() {
  Drill drill(
    String id,
    List<String> body, {
    List<String> equipment = const [],
    List<String> scenes = const ['home'],
  }) => Drill(
    id: id,
    name: LocalizedText({'zh': '动作$id', 'en': 'Action $id'}),
    category: 'strength',
    muscleGroups: body,
    equipment: equipment,
    scenes: scenes,
    position: 'standing',
    unilateral: false,
    level: 1,
    defaultDose: const Dose(
      mode: DoseMode.reps,
      sets: 1,
      reps: 10,
      restSeconds: 10,
    ),
  );
  final catalog = Catalog(
    version: 'test',
    drills: [
      drill('a', ['chest', 'deltoids']),
      drill('b', ['deltoids']),
      drill('c', ['deltoids']),
      drill('other', ['quadriceps']),
      drill('gear', ['deltoids'], equipment: ['dumbbell']),
      drill('wrong-scene', ['deltoids'], scenes: ['gym']),
      drill('core-child', ['abs']),
    ],
  );
  final profile = const CoachProfile(
    id: 'test',
    appName: 'test',
    minActions: 3,
    bodyGroups: {
      'body.core': ['body.abs'],
    },
  );
  final nodes = NodeGates(profile, catalog, minPicks: 3);
  final toolGate = ToolGate(catalog: catalog, profile: profile);
  CoachParamValue param(Object value) =>
      CoachParamValue(value: value, source: 'user', turn: 1);
  CoachSessionState state(
    Set<String> seen, {
    List<String> goal = const ['body.deltoids'],
  }) => CoachSessionState(
    task: CoachTaskState(
      type: 'recommend',
      reused: false,
      nodes: [
        for (final id in AgentTask.recommendNodes)
          CoachNodeState(
            id: id,
            status: id == 'actions'
                ? 'current'
                : id == 'output'
                ? 'pending'
                : 'done',
          ),
      ],
    ),
    params: {
      'scene': param('home'),
      'goal': param(goal),
      'equipment': param(<String>[]),
      'limits': param(<String>[]),
    },
    seenActionIds: seen,
  );
  AgentOutputResult show(CoachSessionState current, List<String> ids) =>
      toolGate.checkAgentOutput(current, CoachTools.showActions, {
        'ids': ids,
        'note': '按目标部位推荐。',
      });

  test(
    'primary or secondary body tags match, unrelated purpose never fills the quota',
    () {
      final current = state({'a', 'other'});
      expect(show(current, ['a']).ok, isTrue);
      final rejected = show(current, ['a', 'other']);
      expect(rejected.error!['code'], 'recommendation_focus');
      expect(rejected.error!['actual'], ['other']);
      expect(rejected.error!['candidateCount'], 1);
      expect(
        (rejected.error!['candidates'] as List).map(
          (row) => (row as List).first,
        ),
        ['a'],
      );
      expect(
        nodes.check(current, 'actions', picks: ['a', 'other']).error!['code'],
        'recommendation_focus',
      );
    },
  );

  test(
    'body parent expansion and multiple goals use any matching descendant',
    () {
      final parent = state({'core-child'}, goal: ['body.core']);
      expect(show(parent, ['core-child']).ok, isTrue);
      final either = state(
        {'a', 'core-child'},
        goal: ['body.deltoids', 'body.core'],
      );
      expect(show(either, ['a', 'core-child']).ok, isTrue);
    },
  );

  test(
    'dynamic minimum counts only matching, seen and currently legal candidates',
    () {
      for (final count in [1, 2, 3]) {
        final hit = ['a', 'b', 'c'].take(count).toList();
        final current = state({...hit, 'other', 'gear', 'wrong-scene'});
        expect(nodes.recommendationMinimum(current), count);
        expect(nodes.recommendationCandidates(current), hit);
        expect(show(current, hit).ok, isTrue);
        if (count > 1) {
          expect(
            show(current, hit.take(count - 1).toList()).error!['code'],
            'invalid_picks',
          );
        }
      }
      final none = state({'other', 'gear', 'wrong-scene'});
      expect(nodes.recommendationMinimum(none), 1);
      expect(show(none, []).error!['code'], 'invalid_picks');
      expect(show(none, []).error!['candidateCount'], 0);
    },
  );

  test('without body goals the configured minimum remains in force', () {
    final current = state({'a', 'other'}, goal: ['purpose.strength']);
    expect(nodes.recommendationMinimum(current), 3);
    expect(show(current, ['a', 'other']).error!['code'], 'invalid_picks');
  });

  test(
    'explicit actions check cannot bypass focus even after a previous stamp',
    () {
      final current = state({'a', 'other'});
      final selected = nodes.check(current, 'actions', picks: ['a']);
      expect(selected.ok, isTrue);
      expect(
        nodes
            .check(selected.state, 'actions', picks: ['a', 'other'])
            .error!['code'],
        'recommendation_focus',
      );
      final forged = selected.state.copyWith(picks: ['a', 'other']);
      expect(
        show(forged, ['a', 'other']).error!['code'],
        'recommendation_focus',
      );
    },
  );

  test(
    'sparse-pool advice is optional, returned once and preserved across restore',
    () {
      final terminal = TerminalToolHandler(toolGate);
      final first = terminal.show(
        state({'a', 'b'}),
        CoachTools.showActions,
        jsonEncode({
          'ids': ['a'],
          'note': '推荐。',
        }),
        language: 'zh',
      );
      expect(first.rejected, isTrue);
      expect((jsonDecode(first.response) as Map)['notices'], hasLength(1));
      expect(first.state!.recommendationHintShown, isTrue);
      expect(first.state!.task!.nodes[2].status, 'current');
      expect(first.state!.picks, isEmpty);
      final restored = CoachSessionState.fromJson(
        jsonDecode(jsonEncode(first.state!.toJson())) as Map<String, Object?>,
      );
      final retry = terminal.show(
        restored,
        CoachTools.showActions,
        jsonEncode({
          'ids': ['a'],
          'note': '推荐。',
        }),
        language: 'zh',
      );
      expect(
        (jsonDecode(retry.response) as Map).containsKey('notices'),
        isFalse,
      );
      final success = terminal.show(
        restored,
        CoachTools.showActions,
        jsonEncode({
          'ids': ['a', 'b'],
          'note': '推荐。',
        }),
        language: 'zh',
      );
      expect(success.rejected, isFalse);
      expect(success.output!.state.task!.nodes.last.status, 'done');
      final direct = terminal.show(
        state({'a'}),
        CoachTools.showActions,
        jsonEncode({
          'ids': ['a'],
          'note': '推荐。',
        }),
        language: 'en',
      );
      expect(direct.rejected, isFalse);
      expect((jsonDecode(direct.response) as Map)['notices'], hasLength(1));
      expect(
        ((jsonDecode(direct.response) as Map)['notices'] as List).single,
        contains('level/pose'),
      );
      expect(
        AgentTask.start(
          restored,
          'recommend',
          reuse: false,
        ).state.recommendationHintShown,
        isFalse,
      );
      expect(
        CoachSessionState.fromJson({
          'userTurns': [],
          'params': {},
          'seenActionIds': [],
          'picks': [],
          'plans': {},
        }).recommendationHintShown,
        isFalse,
      );
    },
  );
}
