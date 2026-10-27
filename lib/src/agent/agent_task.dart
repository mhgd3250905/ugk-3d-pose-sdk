/// Fixed task sequences and immutable node transition results.
library;

import 'session_state.dart';

class NodeResult {
  const NodeResult(
    this.state, {
    this.error,
    this.changes = const [],
    this.warnings = const [],
  });
  final CoachSessionState state;
  final Map<String, Object?>? error;
  final List<CoachNodeState> changes;
  final List<String> warnings;
  bool get ok => error == null;
}

Map<String, Object?> nodeError(
  String code,
  String field,
  Object? expected,
  Object? actual,
  String fix,
) => {
  'ok': false,
  'code': code,
  'field': field,
  'expected': expected,
  'actual': actual,
  'fix': fix,
};

class AgentTask {
  static const recommendNodes = [
    'understand',
    'parameters',
    'actions',
    'output',
  ];
  static const planNodes = [
    'understand',
    'parameters',
    'actions',
    'planning',
    'review',
    'output',
  ];

  static NodeResult start(
    CoachSessionState state,
    String type, {
    bool reuse = false,
  }) {
    if (type != 'recommend' && type != 'plan') {
      return NodeResult(
        state,
        error: nodeError(
          'invalid_task_type',
          'type',
          ['recommend', 'plan'],
          type,
          '选择 recommend 或 plan；问答无需创建任务。',
        ),
      );
    }
    final previous = state.task;
    if (reuse &&
        (type != 'plan' ||
            previous?.type != 'recommend' ||
            previous!.nodes.length != recommendNodes.length ||
            previous.nodes.last.id != 'output' ||
            previous.nodes.last.status != 'done' ||
            previous.nodes
                .take(3)
                .any(
                  (node) => node.status != 'done' && node.status != 'updated',
                ))) {
      return NodeResult(
        state,
        error: nodeError(
          'reuse_unavailable',
          'reuse',
          '已交付动作推荐后转为计划',
          reuse,
          '先完成动作推荐，或不使用 reuse 创建计划。',
        ),
      );
    }
    final ids = type == 'plan' ? planNodes : recommendNodes;
    final nodes = <CoachNodeState>[
      for (var i = 0; i < ids.length; i++)
        if (reuse && i < 3)
          previous!.nodes[i]
        else
          CoachNodeState(
            id: ids[i],
            status: i == (reuse ? 3 : 0) ? 'current' : 'pending',
          ),
    ];
    final next = state.copyWith(
      task: CoachTaskState(type: type, nodes: nodes, reused: reuse),
      picks: reuse ? state.picks : const [],
      seenActionIds: reuse ? state.seenActionIds : const {},
    );
    return NodeResult(next, changes: List.unmodifiable(nodes));
  }
}
