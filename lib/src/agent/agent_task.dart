/// Fixed task sequences and immutable node transition results.
library;

import 'session_state.dart';

class NodeResult {
  const NodeResult(
    this.state, {
    this.error,
    this.changes = const [],
    this.warnings = const [],
    this.notices = const [],
  });
  final CoachSessionState state;
  final Map<String, Object?>? error;
  final List<CoachNodeState> changes;
  final List<String> warnings;
  final List<String> notices;
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

  static NodeResult start(CoachSessionState state, String type, {bool? reuse}) {
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
    final focusId = state.focusPlanId;
    if (type == 'plan' &&
        focusId != null &&
        state.plans[focusId]?.isNotEmpty == true) {
      // An explicitly focused saved plan is the editing target even when a
      // model starts a fresh task or another plan was delivered previously.
      // Its admitted conditions and actions already completed the first steps.
      final nodes = [
        for (final id in planNodes)
          CoachNodeState(
            id: id,
            status: switch (id) {
              'planning' => 'current',
              'review' || 'output' => 'pending',
              _ => 'done',
            },
          ),
      ];
      return NodeResult(
        state.copyWith(
          task: CoachTaskState(type: type, nodes: nodes, reused: true),
          activePlanId: focusId,
          consecutiveEmptySearches: 0,
          clearPendingSearchTurn: true,
        ),
        changes: nodes,
      );
    }
    // A delivered plan remains the editable version. Explicit resume opens its
    // editing stages before search, without losing the accumulated candidates.
    if (reuse == true &&
        type == 'plan' &&
        previous?.type == 'plan' &&
        previous!.nodes.lastOrNull?.status == 'done' &&
        previous.nodes.length == planNodes.length &&
        previous.nodes.indexed.every((e) => e.$2.id == planNodes[e.$1]) &&
        previous.nodes.every(
          (n) => n.status == 'done' || n.status == 'updated',
        ) &&
        state.activePlanId != null &&
        state.lastDeliveredPlanId == state.activePlanId &&
        state.plans[state.activePlanId]?.any(
              (v) => v.version == state.lastDeliveredVersion,
            ) ==
            true) {
      final nodes = [
        for (final node in previous.nodes)
          if (['planning', 'review', 'output'].contains(node.id))
            node.copyWith(
              status: node.id == 'planning' ? 'current' : 'pending',
              clearStamp: true,
              clearDoneAtTurn: true,
            )
          else
            node,
      ];
      return NodeResult(
        state.copyWith(
          task: previous.copyWith(nodes: nodes, reused: true),
          consecutiveEmptySearches: 0,
        ),
        changes: nodes
            .where((n) => ['planning', 'review', 'output'].contains(n.id))
            .toList(),
      );
    }
    reuse ??=
        type == 'plan' &&
        previous?.type == 'recommend' &&
        previous!.nodes.length == recommendNodes.length &&
        previous.nodes.last.id == 'output' &&
        previous.nodes.last.status == 'done' &&
        previous.nodes
            .take(3)
            .every((node) => node.status == 'done' || node.status == 'updated');
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
      reuse = false;
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
    final preservePendingSearch =
        previous == null &&
        state.pendingSearchTurn != null &&
        state.pendingSearchTurn == state.userTurns.lastOrNull?.turn;
    final next = state.copyWith(
      task: CoachTaskState(type: type, nodes: nodes, reused: reuse),
      clearActivePlanId: true,
      picks: reuse ? state.picks : const [],
      seenActionIds: reuse || preservePendingSearch
          ? state.seenActionIds
          : const {},
      clearPendingSearchTurn: true,
      emittedWarningCodes: reuse ? state.emittedWarningCodes : const {},
      consecutiveEmptySearches: 0,
      recommendationHintShown: reuse ? state.recommendationHintShown : false,
    );
    return NodeResult(next, changes: List.unmodifiable(nodes));
  }
}
