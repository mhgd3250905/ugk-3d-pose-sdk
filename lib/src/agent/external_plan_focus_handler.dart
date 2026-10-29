part of 'coach_agent.dart';

extension _ExternalPlanFocusHandler on CoachAgent {
  CoachPlanFocusResult _focusExternalPlan({
    required String externalId,
    required TrainingPlan plan,
    String? title,
  }) {
    if (isBusy) {
      return CoachPlanFocusResult.failure([
        const PlanIssue('busy', '请在当前请求结束后选择计划。'),
      ]);
    }
    if (externalId.trim().isEmpty) {
      return CoachPlanFocusResult.failure([
        const PlanIssue(
          IssueCodes.schema,
          'externalId 不能为空。',
          path: 'externalId',
        ),
      ]);
    }
    final cat = _catalog();
    final id = 'ext:$externalId';
    final language = _taskSafetyContext?.language ?? 'zh';
    final TrainingPlan imported;
    final CoachContext context;
    final CoachSessionState next;
    final int version;
    try {
      // Clone and strictly decode before touching any live state. This also
      // rejects non-JSON segment/rhythm data supplied by an external host.
      final raw = jsonDecode(
        jsonEncode({...plan.toJson(), 'id': id, 'title': ?title}),
      );
      final decoded = const PlanCodec().decodeStrict(raw);
      if (!decoded.ok) return CoachPlanFocusResult.failure(decoded.issues);
      imported = decoded.plan!;
      context = CoachContext(
        scene: imported.scene,
        equipment: imported.equipment.toSet(),
        minutes: imported.targetMinutes,
        level: imported.level,
        goal: imported.goal,
        avoid: {
          ...imported.avoid,
          ...?_taskSafetyContext?.avoid,
          ...?_latestExplicitAvoid,
        },
        language: language,
        notes: {
          ...?_taskSafetyContext?.notes,
          ...imported.safetyNotes,
        }.toList(),
      );
      final report = PlanValidator(
        catalog: cat,
        profile: profile,
        extraRules: extraRules,
        enforceDrillDoseRange: enforceDrillDoseRange,
      ).validate(imported, context);
      if (!report.ok) return CoachPlanFocusResult.failure(report.errors);
      final previous = _sessionState.plans[id] ?? const <CoachPlanVersion>[];
      final same =
          previous.isNotEmpty &&
          _focusCanonical(previous.last.plan) ==
              _focusCanonical(imported.toJson());
      version = same
          ? previous.last.version
          : previous.isEmpty
          ? 1
          : previous.map((v) => v.version).reduce(math.max) + 1;
      final versions = same
          ? previous
          : [
              ...previous,
              CoachPlanVersion(
                version: version,
                plan: imported.toJson(),
                estimateSec: const PlanDuration().estimateSeconds(
                  imported,
                  cat,
                ),
                fitLog: const [],
                operation: 'import',
              ),
            ];
      final tags = ActionTags(profile, cat);
      final mapped = SessionParams(tags).applyHost(
        _sessionState.copyWith(
          params: const {},
          hostValues: const {},
          clearTask: true,
          clearPendingSearchTurn: true,
          consecutiveEmptySearches: 0,
          recommendationHintShown: false,
          plans: {..._sessionState.plans, id: versions},
          activePlanId: id,
          focusPlanId: id,
          savedRef: CoachSavedPlanRef(
            externalId: externalId,
            baseVersion: version,
          ),
          picks: imported.exerciseIds.toList(),
          seenActionIds: {
            ..._sessionState.seenActionIds,
            ...imported.exerciseIds,
          },
        ),
        context,
      );
      if (!mapped.ok) {
        return CoachPlanFocusResult.failure([
          const PlanIssue(IssueCodes.contextConflict, '计划条件无法用于当前动作库。'),
        ]);
      }
      final preferredGoal = 'purpose.${imported.goal}';
      final goals = tags.goalCodes.contains(preferredGoal)
          ? [preferredGoal]
          : ({
              for (final action in imported.exerciseIds)
                ...tags.forActionId(action).where(tags.goalCodes.contains),
            }.toList()..sort());
      final turn = _sessionState.userTurns.lastOrNull?.turn ?? 0;
      next = mapped.state.copyWith(
        params: {
          ...mapped.state.params,
          if (goals.isNotEmpty)
            'goal': CoachParamValue(value: goals, source: 'host', turn: turn),
        },
      );
    } on Object {
      return CoachPlanFocusResult.failure([
        const PlanIssue(IssueCodes.schema, '计划结构或剂量无效。', path: 'plan'),
      ]);
    }
    final selection = LlmMessage.user(
      '$externalPlanSelectionPrefix${jsonEncode(focusPlanSummary(next, cat, language))}',
    );
    _sessionState = next;
    _confirmedPlanContext = context;
    _taskSafetyContext = context;
    _lastConfirmedForm = trainingSelections(context, cat);
    _planFocus = null;
    _planGoal = imported.goal;
    _relativeDurationPolicy = false;
    _planningFailure = false;
    dismissConfirmation();
    _snapshotInterrupted = null;
    _snapshotTurnQuestion = null;
    _history.add(selection);
    // A host selection is a new context epoch, not a fabricated user turn or
    // model request. Existing completed-turn facts and plans remain intact.
    _modelContext = null;
    _modelEpochKey = null;
    return CoachPlanFocusResult.success(planId: id, version: version);
  }

  String _focusCanonical(Object? value) {
    Object? ordered(Object? node, [String? key]) {
      if (node is Map) {
        final keys = node.keys.cast<String>().toList()..sort();
        return {for (final name in keys) name: ordered(node[name], name)};
      }
      if (node is List) {
        final result = node.map((item) => ordered(item)).toList();
        if (key == 'equipment' || key == 'avoid') {
          result.sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
        }
        return result;
      }
      return node;
    }

    return jsonEncode(ordered(value));
  }
}
