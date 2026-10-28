import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();
  final source = loadProfile('smartfit').toJson()
    ..['ambientEquipmentUnknown'] = ['equip.wall', 'equip.mat'];
  final profile = CoachProfile.fromJson(source);
  final gate = NodeGates(profile, catalog, minPicks: 3);
  CoachParamValue param(Object value) =>
      CoachParamValue(value: value, source: 'user', turn: 1);

  CoachSessionState parameterState({List<String> excluded = const []}) {
    var state = AgentTask.start(
      CoachSessionState(
        params: {
          'goal': param(['purpose.stretch']),
          if (excluded.isNotEmpty) 'equipment_exclude': param(excluded),
        },
      ),
      'recommend',
    ).state;
    state = gate.check(state, 'understand').state;
    return state;
  }

  test(
    'unknown scene names available floor and wall without assuming a chair',
    () {
      final result = gate.check(parameterState(), 'parameters');
      expect(result.ok, isTrue);
      final stamp = result.state.task!.nodes[1].stamp!;
      expect(stamp, contains('徒手（可用地面/墙）'));
      expect(stamp, isNot(contains('椅')));
      final english = gate.check(
        parameterState(),
        'parameters',
        language: 'en',
      );
      expect(
        english.state.task!.nodes[1].stamp,
        contains('Bodyweight (floor, wall available)'),
      );
    },
  );

  test('unknown ambient stamp respects individual exclusions', () {
    final noFloor = gate.check(
      parameterState(excluded: ['equip.mat']),
      'parameters',
    );
    expect(noFloor.state.task!.nodes[1].stamp, contains('徒手（可用墙）'));
    final noWall = gate.check(
      parameterState(excluded: ['equip.wall']),
      'parameters',
    );
    expect(noWall.state.task!.nodes[1].stamp, contains('徒手（可用地面）'));
    final none = gate.check(
      parameterState(excluded: ['equip.mat', 'equip.wall']),
      'parameters',
    );
    expect(none.state.task!.nodes[1].stamp, contains('徒手（默认）'));
  });

  test(
    'legacy nonambient exclusions cannot block newly confirmed equipment',
    () {
      final state = CoachSessionState(
        params: {
          'scene': param('home'),
          'equipment': param(['equip.dumbbell']),
          'equipment_exclude': param(['equip.dumbbell', 'equip.chair']),
        },
      );
      expect(gate.effectiveEquipment(state), contains('equip.dumbbell'));
      expect(gate.effectiveEquipment(state), isNot(contains('equip.chair')));
    },
  );

  CoachSessionState reviewedPlanState(Map<String, Object?> item) =>
      CoachSessionState(
        task: CoachTaskState(
          type: 'plan',
          reused: false,
          nodes: [
            for (final id in AgentTask.planNodes)
              CoachNodeState(
                id: id,
                status: id == 'review'
                    ? 'current'
                    : id == 'output'
                    ? 'pending'
                    : 'done',
              ),
          ],
        ),
        params: {
          'scene': param('home'),
          'equipment': param(<String>[]),
          'minutes': param(10),
        },
        activePlanId: 'p',
        plans: {
          'p': [
            CoachPlanVersion(
              version: 1,
              plan: {
                'id': 'p',
                'scene': 'home',
                'blocks': [
                  {
                    'items': [item],
                  },
                ],
              },
              estimateSec: 600,
              fitLog: const [],
              check: {'ok': true},
            ),
          ],
        },
      );

  test(
    'review and delivery list only ambient items actually used by catalogue actions',
    () {
      final original = reviewedPlanState({'exerciseId': 'h-chair-lat'});
      final review = gate.check(original, 'review', planId: 'p');
      expect(review.ok, isTrue);
      expect(review.changes.first.stamp, contains('实际用到环境物：椅子/凳子'));
      expect(review.changes.first.stamp, isNot(contains('墙')));
      expect(review.changes.first.stamp, isNot(contains('瑜伽垫')));
      final output = gate.completeOutput(review.state);
      expect(output.changes.single.stamp, contains('实际用到环境物：椅子/凳子'));
    },
  );

  test(
    'segmented items use executed segments rather than the parent fallback ID',
    () {
      final original = reviewedPlanState({
        'exerciseId': 'h-chair-lat',
        'segments': [
          {'exerciseId': 'h-wall-angel'},
        ],
      });
      final review = gate.check(
        original,
        'review',
        planId: 'p',
        language: 'en',
      );
      expect(review.changes.first.stamp, contains('Ambient items used: wall'));
      expect(review.changes.first.stamp, isNot(contains('chair')));
    },
  );

  test(
    'plan with no ambient actions explicitly says no ambient items used',
    () {
      final review = gate.check(
        reviewedPlanState({'exerciseId': 'h-squat'}),
        'review',
        planId: 'p',
      );
      expect(review.changes.first.stamp, contains('未使用环境物'));
      expect(
        gate.completeOutput(review.state).changes.single.stamp,
        contains('未使用环境物'),
      );
    },
  );
}
