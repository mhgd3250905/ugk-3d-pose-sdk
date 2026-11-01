part of 'coach_agent.dart';

extension _OutputCommitHandler on CoachAgent {
  void _commitOutput({
    required AgentOutputResult output,
    required GateResult card,
    required int safetyRevision,
    required String turnId,
    required CoachContext context,
    required Catalog catalog,
    required bool Function() dead,
    required void Function(CoachTaskState?) updateAdmittedTask,
    required LlmMessage userMessage,
    required LlmMessage Function() visibleAssistant,
  }) {
    _sessionState = output.state;
    if (card.plan != null) {
      final deliveredId = card.plan!.plan.id;
      final versions = _sessionState.plans[deliveredId];
      if (versions != null && versions.isNotEmpty) {
        _sessionState = _sessionState.copyWith(
          lastDeliveredPlanId: deliveredId,
          lastDeliveredVersion: versions.last.version,
          lastDeliveredTurn: _sessionState.userTurns.isEmpty
              ? 0
              : _sessionState.userTurns.last.turn,
        );
      }
    }
    final committedTask = _sessionState.task;
    updateAdmittedTask(committedTask);
    _emitNodeChanges(
      turnId,
      NodeResult(_sessionState, changes: output.changes),
    );
    if (dead() ||
        _hostSafetyRevision != safetyRevision ||
        !identical(_sessionState.task, committedTask)) {
      return;
    }
    _pendingConfirmation = null;
    if (card.plan != null) {
      _confirmedPlanContext = CoachContext(
        scene: context.scene,
        equipment: context.equipment,
        minutes: card.plan!.plan.targetMinutes,
        avoid: context.avoid,
        level: context.level,
        goal: context.goal,
        language: context.language,
        notes: context.notes,
      );
      _lastConfirmedForm = trainingSelections(_confirmedPlanContext!, catalog);
    }
    _questionsAsked = 0;
    _turns++;
    _history
      ..add(userMessage)
      ..add(visibleAssistant());
  }
}
