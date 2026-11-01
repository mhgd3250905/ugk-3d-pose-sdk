part of 'coach_agent.dart';

extension _ScopeSessionHandler on CoachAgent {
  void _completeToolSpan(
    CoachAgentSpanHandle span,
    LlmToolCall call,
    String? response,
  ) {
    if (span.id == 0) return;
    String? code;
    var ok = response != null;
    var deferred = false;
    try {
      final receipt = jsonDecode(response ?? 'null');
      if (receipt is Map) {
        ok = receipt['ok'] != false;
        deferred = receipt['deferred'] == true || receipt['skipped'] == true;
        final rawCode = receipt['code'];
        if (rawCode is String &&
            RegExp(r'^[A-Za-z0-9_]{1,80}$').hasMatch(rawCode)) {
          code = rawCode;
        }
        if (code == 'skipped_after_error' ||
            code == 'skipped_after_completion') {
          deferred = true;
        }
      }
    } on FormatException {
      // A successful virtual-file read is plain text, not a JSON tool receipt.
    }
    if (!ok && code != null && !deferred) {
      // This measures the local repair decision. It is a reason marker,
      // not an estimate of the following HTTP or model generation time.
      _spans
          .start(
            CoachAgentSpanKind.recompile,
            'tool.repair',
            toolCallId: call.id,
            parentId: span.id,
            taskId: _sessionState.task?.type,
            epoch: _modelEpochCounter,
            attributes: {'tool': call.name, 'code': code},
          )
          .finish(ok: false, reason: code);
    }
    span.finish(
      ok: ok,
      reason: code,
      attributes: {
        'responseBytes': utf8.encode(response ?? '').length,
        'deferred': deferred,
        'resultTask': _sessionState.task?.type,
      },
    );
  }

  CoachActionScope? _refreshActionScope() {
    final manifest = scopeManifest;
    if (manifest == null) return null;
    return _actionScope ??= manifest.restrict(
      catalog: _catalogSource(),
      profile: _sourceProfile,
    );
  }

  Catalog _catalog() => _actionScope?.catalog ?? _catalogSource();

  CoachScopeConversationPolicy get _scopeConversationPolicy =>
      scopePolicy ??
      CoachScopeConversationPolicy(
        specialty: '${profile.appName}专注于当前动作范围内的训练。',
      );

  List<CoachScopeDecisionRecord> _readScopeRecords() => [
    for (final value in _sessionState.scopeDecisionRecords)
      CoachScopeDecisionRecord.fromJson(value),
  ];

  List<CoachScopeDecisionRecord> _scopeTurnRecords([CoachSessionState? state]) {
    final current = state ?? _sessionState;
    final turn = current.userTurns.lastOrNull?.turn;
    return [
      for (final value in current.scopeDecisionRecords)
        if (value['turn'] == turn) CoachScopeDecisionRecord.fromJson(value),
    ];
  }

  Set<String> _requiredScopeActionIds(CoachSessionState state) => {
    for (final record in _scopeTurnRecords(state))
      if (record.kind == CoachScopeDecisionKind.substituted &&
          record.adoptedActionId != null)
        record.adoptedActionId!,
  };

  bool get _scopeRefusesPlan =>
      _scopeTurnRecords().any((record) => !record.allowPlan);

  String? _confirmedMovementPain(CoachSessionState state) {
    final user = state.userTurns.lastOrNull;
    final limits = state.params['limits'];
    final quote = limits?.quote;
    if (user == null ||
        limits?.source != 'user' ||
        limits?.turn != user.turn ||
        limits?.value is! List ||
        (limits!.value! as List).isEmpty ||
        quote == null) {
      return null;
    }
    final affirmative = RegExp(
      r'(?:动作|运动|训练|活动|走路|练习)(?:时|中|之后|一开始|一动|就|会|仍然|一直|总是|有些|有点|很|更|加重){0,3}(?:疼痛|疼|痛)'
      r'|(?:正在|现在|仍然|一直|持续|明显)(?:有|感到|觉得)?(?:疼痛|疼|痛)'
      r'|\b(?:movement|exercise|training)\s+(?:hurts|is painful)\b',
      caseSensitive: false,
    );
    for (final clause in quote.split(RegExp(r'[，。；！？,;!?]|但是|不过|\bbut\b'))) {
      if (RegExp(
        r'如果|假如|若|一旦|(?:没有|不会|未|不|无)(?:明显)?(?:疼痛|疼|痛)|\b(?:if|not|never)\b',
        caseSensitive: false,
      ).hasMatch(clause)) {
        continue;
      }
      if (affirmative.hasMatch(clause)) return clause.trim();
    }
    return null;
  }

  String _scopeFinalText(TrainingPlan? plan, String text) {
    final scope = _actionScope;
    return scope == null
        ? text
        : scope.disclosureFor(
            _scopeTurnRecords(),
            plan,
            text,
            policy: _scopeConversationPolicy,
          );
  }

  ({CoachSessionState state, Map<String, Object?> receipt}) _assessScope(
    CoachSessionState state,
    Object? value,
    CoachContext context,
  ) {
    final scope = _actionScope!;
    final raw = value is Map ? value : const <String, Object?>{};
    String? text(String key) =>
        raw[key] is String && (raw[key] as String).trim().isNotEmpty
        ? (raw[key] as String).trim()
        : null;
    final current = state.userTurns.last;
    final sourceId = text('sourceActionId');
    final sourceName = text('sourceActionName');
    final mentions = scope.mentionedUnavailableActions(current.text);
    final pain = _confirmedMovementPain(state);
    final safety =
        raw['safetyBlocked'] == true ||
        pain != null ||
        _scopeTurnRecords(
          state,
        ).any((record) => record.kind == CoachScopeDecisionKind.safetyBlocked);
    final outside = raw['outsideSpecialty'] == true;
    final hasSource = sourceId != null
        ? !scope.contains(sourceId)
        : sourceName != null &&
              !scope.catalog.drills.any(
                (drill) => drill.name.of(context.language) == sourceName,
              );
    // Normal in-scope discussion needs no per-turn assessment or quote proof.
    if (mentions.isEmpty && !hasSource && !outside && !safety) {
      return (state: state, receipt: const {});
    }
    final tags = ActionTags(profile, scope.catalog);
    final namedInside = scope.catalog.drills.any(
      (drill) => current.text.contains(drill.name.of(context.language)),
    );
    final operation = state.params['operation'];
    final editing =
        operation?.value == 'edit' &&
        state
                .plans[state.focusPlanId ?? state.lastDeliveredPlanId]
                ?.isNotEmpty ==
            true;
    final hasContent =
        raw['hasInScopeContent'] == true ||
        namedInside ||
        editing ||
        !outside && text('inScopeQuote') != null;
    final nodes = NodeGates(
      profile,
      scope.catalog,
      minPicks: profile.minActions,
    );
    final equipment = <String>{
      for (final code in nodes.effectiveEquipment(state))
        ?tags.equipmentId(code),
    };
    final requested = <String?, CoachScopeRequest>{
      for (final mention in mentions) mention.sourceActionId: mention,
      if (hasSource &&
          !mentions.any(
            (mention) =>
                mention.sourceActionId == sourceId ||
                mention.sourceActionName == sourceName,
          ))
        sourceId: CoachScopeRequest(
          originalText: current.text,
          sourceActionId: sourceId,
          sourceActionName: sourceName,
        ),
    };
    if (requested.isEmpty) {
      requested[null] = CoachScopeRequest(originalText: current.text);
    }
    final records = [
      for (final item in requested.values)
        scope.evaluateRequest(
          CoachScopeRequest(
            originalText: current.text,
            sourceActionId: item.sourceActionId,
            sourceActionName: item.sourceActionName,
            sourceQuote: item.sourceQuote,
            targetBodyCodes: (raw['targetBodyCodes'] as List? ?? const [])
                .whereType<String>()
                .toSet(),
            scene: state.params['scene']?.value as String? ?? context.scene,
            equipment: equipment,
            avoid: context.avoid,
            hasInScopeContent: hasContent,
            insists: raw['insists'] == true,
            locked: raw['locked'] == true,
            outsideSpecialty: outside,
            safetyBlocked: safety,
            safetyReason: pain ?? text('safetyReason'),
            state: state,
            turn: current.turn,
          ),
          _scopeConversationPolicy,
        ),
    ];
    final next = state.copyWith(
      scopeDecisionRecords: [
        for (final old in state.scopeDecisionRecords)
          if (old['turn'] != current.turn) old,
        for (final record in records) record.toJson(),
      ],
    );
    final required = _requiredScopeActionIds(next).toList();
    return (
      state: next,
      receipt: {
        'records': records.map((record) => record.toJson()).toList(),
        'allowPlan': records.every((record) => record.allowPlan),
        'requiredActionIds': required,
        if (required.isNotEmpty)
          'requiredActionsNotice':
              '以下代码已选替代动作必须出现在草稿中：${required.join('、')}。仍须真实检索，不会自动加入计划。',
      },
    );
  }

  Map<String, Object?>? _scopeToolProblem(LlmToolCall call, String language) {
    if (_actionScope == null) return null;
    if ({AgentTools.draftPlan, AgentTools.showPlan}.contains(call.name) &&
        _scopeRefusesPlan) {
      return nodeError(
        'scope_request_refuses_plan',
        'scope',
        '按范围或安全说明回答',
        call.name,
        '本轮不生成计划；说明专长/安全，并给范围内建议。',
      );
    }
    if (call.name == AgentTools.showActions &&
        _scopeTurnRecords().any(
          (record) => record.kind == CoachScopeDecisionKind.safetyBlocked,
        )) {
      return nodeError(
        'scope_safety_priority',
        'scope',
        '先处理当前伤痛',
        call.name,
        '先安全暂停，不推荐替代训练。',
      );
    }
    return null;
  }

  List<PlanRule> get _effectivePlanRules => [
    ...extraRules,
    if (_actionScope != null) (plan, _, _) => _actionScope!.validatePlan(plan),
  ];

  // Snapshot import is a real cross-App plan admission path.
  bool _isScopedStateValid(CoachSessionState state) {
    final scope = _actionScope;
    if (scope == null) return true;
    for (final versions in state.plans.values) {
      for (final version in versions) {
        final decoded = const PlanCodec().decodeStrict(version.plan);
        if (!decoded.ok || scope.validatePlan(decoded.plan!).isNotEmpty) {
          return false;
        }
      }
    }
    return true;
  }

  bool _isScopedSnapshotValid(CoachSessionSnapshot snapshot) =>
      _isScopedStateValid(snapshot.sessionState);

  ValidatedPlan? _prepareScopedTraining(
    TrainingPlan plan,
    CoachContext context,
  ) {
    if (_scopeRefusesPlan) return null;
    final effective = _actionScope == null
        ? context
        : context.copyWith(
            avoid: {
              ...context.avoid,
              ...?_taskSafetyContext?.avoid,
              ...?_latestExplicitAvoid,
            },
          );
    return gateFor(_catalog())
        .admitTraining(plan, context: effective)
        ?.withSessionVersion(_sessionState);
  }
}
