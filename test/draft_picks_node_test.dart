import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/session_state.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('smartfit');
  final gate = NodeGates(profile, catalog, minPicks: profile.minActions);
  final task = CoachTaskState(
    type: 'plan',
    reused: false,
    nodes: [
      const CoachNodeState(id: 'understand', status: 'done'),
      const CoachNodeState(id: 'parameters', status: 'done'),
      const CoachNodeState(
        id: 'actions',
        status: 'done',
        stamp: '选了 3 个动作',
        doneAtTurn: 1,
      ),
      const CoachNodeState(id: 'planning', status: 'current'),
      const CoachNodeState(id: 'review', status: 'pending'),
      const CoachNodeState(id: 'output', status: 'pending'),
    ],
  );
  CoachSessionState base() => CoachSessionState(
    task: task,
    params: {
      'scene': CoachParamValue(value: 'home', source: 'host', turn: 0),
      'equipment': CoachParamValue(value: <String>[], source: 'host', turn: 0),
    },
    picks: ['h-squat', 'n-pelvis-circle', 'o-stand-sidebend'],
    seenActionIds: {
      'h-squat',
      'n-pelvis-circle',
      'o-stand-sidebend',
      'h-step-jack',
      's-figure4',
    },
  );

  test(
    'adds searched action once and preserves completed status with one update',
    () {
      final old = base();
      final result = gate.addDraftPicks(old, ['h-step-jack', 'h-step-jack']);
      expect(result.ok, isTrue);
      expect(result.state.picks, [
        'h-squat',
        'n-pelvis-circle',
        'o-stand-sidebend',
        'h-step-jack',
      ]);
      expect(old.picks, hasLength(3));
      final node = result.state.task!.nodes[2];
      expect(node.status, 'done');
      expect(node.stamp, '选了 4 个动作');
      expect(node.doneAtTurn, 1);
      expect(result.changes, hasLength(1));
      expect(result.changes.single.id, 'actions');
      expect(result.state.task!.nodes[3].status, 'current');
      final noChange = gate.addDraftPicks(result.state, ['h-step-jack']);
      expect(noChange.state, same(result.state));
      expect(noChange.changes, isEmpty);
    },
  );

  test('unseen and incompatible additions fail atomically', () {
    final source = base();
    final unseen = gate.addDraftPicks(source, ['h-step-jack', 'not-searched']);
    expect(unseen.error!['code'], 'unseen_actions');
    expect(unseen.state, same(source));
    expect(unseen.changes, isEmpty);
    final needsMat = gate.addDraftPicks(source, ['h-step-jack', 's-figure4']);
    expect(needsMat.error!['code'], 'incompatible_actions');
    expect(needsMat.state, same(source));
    expect(needsMat.changes, isEmpty);
  });

  test('English stamp and unchanged minimum-picks check', () {
    final result = gate.addDraftPicks(base(), ['h-step-jack'], language: 'en');
    expect(result.state.task!.nodes[2].stamp, 'Selected 4 actions');
    final initial = base().copyWith(
      task: task.copyWith(
        nodes: [
          task.nodes[0],
          task.nodes[1],
          const CoachNodeState(id: 'actions', status: 'current'),
          const CoachNodeState(id: 'planning', status: 'pending'),
          task.nodes[4],
          task.nodes[5],
        ],
      ),
    );
    expect(
      gate.addDraftPicks(initial, ['h-step-jack']).error!['code'],
      'actions_not_complete',
    );
    expect(
      gate
          .check(initial, 'actions', picks: ['h-squat', 'h-step-jack'])
          .error!['code'],
      'invalid_picks',
    );
  });
}
