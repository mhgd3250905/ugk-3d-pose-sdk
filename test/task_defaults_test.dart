import 'dart:convert';
import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/structured_tool_handler.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'support.dart';

void main() {
  final profile = loadProfile('smartfit');
  final catalog = loadCatalog();
  CoachSessionState completed() => CoachSessionState(
    task: CoachTaskState(
      type: 'recommend',
      reused: false,
      nodes: [
        for (final id in AgentTask.recommendNodes)
          CoachNodeState(
            id: id,
            status: id == 'parameters' ? 'updated' : 'done',
            stamp: 'Complete $id',
            doneAtTurn: 1,
          ),
      ],
    ),
    params: {'scene': CoachParamValue(value: 'home', source: 'user', turn: 1)},
    picks: const ['standing-calf-raise'],
    seenActionIds: const {'standing-calf-raise'},
    consecutiveEmptySearches: 2,
  );
  test('completed recommendation defaults to reuse with no intent parsing', () {
    final state = completed();
    final result = AgentTask.start(state, 'plan');
    expect(result.ok, isTrue);
    expect(result.state.task!.reused, isTrue);
    expect(result.state.task!.nodes[3].status, 'current');
    expect(
      result.state.task!.nodes.take(3).map((n) => n.toJson()),
      state.task!.nodes.take(3).map((n) => n.toJson()),
    );
    expect(result.state.picks, state.picks);
    expect(result.state.seenActionIds, state.seenActionIds);
    expect(result.state.consecutiveEmptySearches, 0);
    expect(
      AgentTask.start(
        CoachSessionState.fromJson(state.toJson()),
        'plan',
      ).state.task!.reused,
      isTrue,
    );
  });
  test(
    'explicit false restarts and a parameter change prevents default reuse',
    () {
      final state = completed();
      final restarted = AgentTask.start(state, 'plan', reuse: false).state;
      expect(restarted.task!.reused, isFalse);
      expect(restarted.task!.nodes.first.status, 'current');
      expect(restarted.seenActionIds, isEmpty);
      final changed = NodeGates(profile, catalog, minPicks: 3)
          .parametersChanged(
            state.copyWith(
              params: {
                'scene': CoachParamValue(
                  value: 'office',
                  source: 'user',
                  turn: 2,
                ),
              },
            ),
            changedFields: {'scene'},
            valueChangedFields: {'scene'},
          )
          .state;
      expect(AgentTask.start(changed, 'plan').state.task!.reused, isFalse);
      expect(AgentTask.start(changed, 'plan', reuse: true).ok, isFalse);
    },
  );
  test('start_task handler preserves omitted versus explicit false', () {
    final handler = StructuredToolHandler(
      profile,
      catalog,
      newPlanId: () => 'new-plan',
      files: SkillFiles.build(profile, catalog, memory: false),
    );
    final automatic = handler.task(
      completed(),
      'start_task',
      '{"type":"plan"}',
      'zh',
    );
    expect((jsonDecode(automatic.response) as Map)['ok'], isTrue);
    expect(automatic.state.task!.reused, isTrue);
    final explicit = handler.task(
      completed(),
      'start_task',
      '{"type":"plan","reuse":false}',
      'zh',
    );
    expect(explicit.state.task!.reused, isFalse);
  });
}
