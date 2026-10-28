part of 'coach_agent.dart';

extension _SessionSnapshotHandler on CoachAgent {
  CoachSessionSnapshot _captureSessionSnapshot({
    required List<CoachRecommendationSnapshot> recommendations,
    String? pendingQuestionMessageId,
    bool includePendingQuestion = true,
  }) {
    final interruptedExport = _snapshotInterrupted;
    if (!isBusy && interruptedExport != null) {
      return CoachSessionSnapshot.fromJson(
        _redactSnapshotText({
          ...interruptedExport.toJson(),
          'pendingQuestion': includePendingQuestion
              ? interruptedExport.toJson()['pendingQuestion']
              : null,
          'pendingQuestionMessageId':
              includePendingQuestion &&
                  interruptedExport.pendingQuestion != null
              ? pendingQuestionMessageId
              : null,
          'recommendations': [for (final ref in recommendations) ref.toJson()],
        }),
      );
    }
    final cat = _catalog();
    final language =
        _taskSafetyContext?.language ?? _confirmedPlanContext?.language ?? 'zh';
    var state = _sessionState;
    var ledger = _completedLedger();
    final last = state.userTurns.lastOrNull;
    final interrupted =
        isBusy &&
        last != null &&
        !ledger.turns.any((turn) => turn.turn == last.turn);
    final loaded = <String>{
      for (final turn in ledger.turns) ...turn.loadedSkillNames,
      ..._snapshotLoadedSkills,
    };
    final pendingForSnapshot = includePendingQuestion
        ? _pendingConfirmation
        : null;
    final candidates = ActionSearch(
      profile,
      cat,
      minPicks: profile.minActions,
    ).candidateRows(state, language: language);
    if (interrupted) {
      final previousQuestion = _snapshotTurnQuestion == null
          ? null
          : ledger.turns
                .where(
                  (turn) => turn.askQuestions.any(
                    (question) =>
                        jsonEncode(question) ==
                        jsonEncode(_snapshotTurnQuestion!.toJson()),
                  ),
                )
                .lastOrNull;
      final active = state.plans[state.activePlanId]?.lastOrNull;
      final ids = <String>[];
      void collect(Object? value) {
        if (value is Map<Object?, Object?>) {
          if (value['exerciseId'] case final String id) ids.add(id);
          for (final child in value.values) {
            collect(child);
          }
        } else if (value is List<Object?>) {
          for (final child in value) {
            collect(child);
          }
        }
      }

      if (active != null) collect(active.plan);
      ledger = ContextTurnLedger([
        ...ledger.turns,
        CompletedContextTurn(
          turn: last.turn,
          userText: last.text,
          finalDeliveryText: '',
          params: state.params,
          task: state.task,
          picks: state.picks,
          candidates: candidates,
          seenActionIds: state.seenActionIds.toList(),
          loadedSkillNames: loaded.toList(),
          currentPlanRef: active == null
              ? null
              : ContextDeliveryRef(
                  type: 'plan',
                  planId: state.activePlanId,
                  version: active.version,
                  actionIds: ids,
                ),
          answeredAsk: previousQuestion == null || pendingForSnapshot != null
              ? null
              : ContextAskReplyRef(
                  questionTurn: previousQuestion.turn,
                  questionIndex: previousQuestion.askQuestions.indexWhere(
                    (question) =>
                        jsonEncode(question) ==
                        jsonEncode(_snapshotTurnQuestion!.toJson()),
                  ),
                  answerJson: {'text': last.text},
                ),
          outcome: 'interrupted',
        ),
      ]);
    }
    state = state.copyWith(completedContextLedger: ledger.toJson());
    final snapshot = CoachSessionSnapshot(
      sessionState: state,
      ledger: ledger,
      pendingQuestion: pendingForSnapshot,
      pendingQuestionMessageId: pendingForSnapshot == null
          ? null
          : pendingQuestionMessageId,
      candidates: candidates,
      loadedSkillNames: loaded.toList(),
      recommendations: recommendations,
      agentState: {
        'turnCount': _turns + (interrupted ? 1 : 0),
        'questionsAsked': _questionsAsked,
        'relativeDurationPolicy': _relativeDurationPolicy,
        if (_confirmedPlanContext != null)
          'confirmedPlanContext': _snapshotContext(_confirmedPlanContext!),
        if (_taskSafetyContext != null)
          'safetyContext': _snapshotContext(_taskSafetyContext!),
        if (_planFocus != null) 'focus': _planFocus,
        if (_planGoal != null) 'goal': _planGoal,
        if (_lastConfirmedForm != null) 'lastConfirmedForm': _lastConfirmedForm,
        if (_latestExplicitAvoid != null)
          'latestExplicitAvoid': _latestExplicitAvoid!.toList(),
        if (_snapshotMemoryOrigins.isNotEmpty)
          'memoryOrigins': {
            for (final entry in _snapshotMemoryOrigins.entries)
              entry.key: entry.value.toList(),
          },
      },
    );
    return _snapshotForgottenTexts.isEmpty
        ? snapshot
        : CoachSessionSnapshot.fromJson(_redactSnapshotText(snapshot.toJson()));
  }

  bool _restoreSessionSnapshot(CoachSessionSnapshot snapshot) {
    if (!snapshot.isValid) {
      _emitEvent(
        AgentEvent(
          _ids.next('restore'),
          AgentEventKind.snapshotRestoreFallback,
          path: snapshot.invalidReason ?? 'invalid_snapshot',
        ),
      );
      return false;
    }
    reset();
    // The standalone ledger is authoritative even if the optional legacy
    // copy inside CoachSessionState was not saved by a caller.
    _sessionState = snapshot.sessionState.copyWith(
      completedContextLedger: snapshot.ledger.toJson(),
    );
    _snapshotResume = true;
    _snapshotLoadedSkills.addAll(snapshot.loadedSkillNames);
    if (snapshot.agentState['memoryOrigins']
        case final Map<Object?, Object?> origins) {
      for (final entry in origins.entries) {
        _snapshotMemoryOrigins[entry.key as String] =
            (entry.value as List<Object?>).cast<int>().toSet();
      }
    }
    _pendingConfirmation = snapshot.pendingQuestion;
    final saved = snapshot.agentState;
    _turns = saved['turnCount'] as int? ?? snapshot.ledger.turns.length;
    _questionsAsked =
        saved['questionsAsked'] as int? ??
        (snapshot.pendingQuestion == null ? 0 : 1);
    _relativeDurationPolicy = saved['relativeDurationPolicy'] as bool? ?? false;
    _confirmedPlanContext = _readSnapshotContext(saved['confirmedPlanContext']);
    _taskSafetyContext = _readSnapshotContext(saved['safetyContext']);
    _planFocus = saved['focus'] as String?;
    _planGoal = saved['goal'] as String?;
    if (saved['lastConfirmedForm'] case final Map<Object?, Object?> form) {
      _lastConfirmedForm = {
        for (final key in form.keys)
          key as String: (form[key] as List<Object?>).cast<String>(),
      };
    }
    if (saved['latestExplicitAvoid'] case final List<Object?> avoid) {
      _latestExplicitAvoid = avoid.cast<String>().toSet();
    }
    return true;
  }

  ValidatedActions? _restoreRecommendation(CoachRecommendationSnapshot ref) =>
      gateFor(_catalog()).check('', [
        LlmToolCall(
          id: 'restore',
          name: CoachTools.showActions,
          arguments: jsonEncode({
            'items': [
              for (final id in ref.actionIds) {'actionId': id},
            ],
          }),
        ),
      ]).actions;

  Map<String, Object?> _snapshotContext(CoachContext context) => {
    ...context.toJson(),
    'hasExplicitAvoid': context.hasExplicitAvoid,
  };

  CoachContext? _readSnapshotContext(Object? raw) {
    if (raw is! Map<Object?, Object?>) return null;
    return CoachContext(
      scene: raw['scene'] as String?,
      equipment: (raw['equipment'] as List<Object?>?)?.cast<String>().toSet(),
      avoid: raw['hasExplicitAvoid'] == true
          ? (raw['avoid'] as List<Object?>? ?? const []).cast<String>().toSet()
          : null,
      level: raw['level'] as int?,
      minutes: raw['minutes'] as int?,
      goal: raw['goal'] as String?,
      language: raw['language'] as String? ?? 'zh',
      notes: (raw['notes'] as List<Object?>? ?? const []).cast<String>(),
    );
  }

  // Privacy operations do not rewrite the live conversation. Their export
  // view omits deleted memory and the exact user message that created it.
  Object? _redactSnapshotText(Object? value, [String key = '']) {
    if (value is Map<Object?, Object?>) {
      return {
        for (final entry in value.entries)
          entry.key:
              entry.key == 'quote' &&
                  _snapshotForgottenTurns.contains(value['turn'])
              ? '[已忘记]'
              : _redactSnapshotText(entry.value, entry.key as String),
      };
    }
    if (value is List<Object?>) {
      return [for (final child in value) _redactSnapshotText(child, key)];
    }
    if (value is String &&
        const {
          'text',
          'userText',
          'finalDeliveryText',
          'quote',
          'stamp',
          'note',
          'notes',
          'title',
          'summary',
          'question',
          'label',
          'options',
        }.contains(key)) {
      var result = value;
      for (final forgotten in _snapshotForgottenTexts) {
        if (forgotten.isNotEmpty) {
          result = result.replaceAll(forgotten, '[已忘记]');
        }
      }
      return result;
    }
    return value;
  }
}
