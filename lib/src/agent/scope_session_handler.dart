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
    final source = _catalogSource();
    // Check the complete projection even if a host reuses the same object.
    // Mutable raw metadata must not change doses or authorization in place.
    if (computePlanningCatalogSha256(source) !=
        manifest.planningCatalogSha256) {
      throw const CoachActionScopeConfigurationException(
        'planning_catalog_changed',
        'catalog',
      );
    }
    if (_actionScope == null || !identical(source, _scopeSource)) {
      _actionScope = manifest.restrict(
        catalog: source,
        profile: _sourceProfile,
      );
      _scopeSource = source;
    }
    return _actionScope;
  }

  Catalog _catalog() => _refreshActionScope()?.catalog ?? _catalogSource();

  CoachScopeConversationPolicy get _scopeConversationPolicy =>
      scopePolicy ??
      CoachScopeConversationPolicy(
        specialty: '${profile.appName}专注于当前授权动作范围内的训练。',
      );

  List<CoachScopeDecisionRecord> _readScopeRecords() => List.unmodifiable([
    for (final json in _sessionState.scopeDecisionRecords)
      if (json['superseded'] != true) CoachScopeDecisionRecord.fromJson(json),
  ]);

  bool get _scopeAssessedNow =>
      scopeManifest == null ||
      (_sessionState.scopeAssessmentTurn != null &&
          _sessionState.scopeAssessmentTurn ==
              _sessionState.userTurns.lastOrNull?.turn);

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
        quote == null ||
        !user.text.contains(quote)) {
      return null;
    }
    // This is not a symptom classifier: reuse a confirmed protection limit
    // only when its literal evidence says that movement currently hurts.
    // Avoidance alone, a hypothetical warning and a negated pain report do
    // not establish a red flag or change the pre-existing safety policy.
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
    final scope = _refreshActionScope();
    if (scope == null) return text;
    if (!_scopeAssessedNow) {
      throw const CoachScopeDisclosureException('scope_assessment_required');
    }
    final records = _scopeTurnRecords();
    if (plan != null &&
        scope
            .mentionedUnavailableActions(text)
            .any(
              (request) => !records.any(
                (record) => record.sourceId == request.sourceActionId,
              ),
            )) {
      throw const CoachScopeDisclosureException('unreported_scope_reference');
    }
    // A model caption cannot claim that a removed action is included. The
    // adjustment caption is generated exclusively from checked code records.
    final adjusted = records.any(
      (record) => record.kind != CoachScopeDecisionKind.inScope,
    );
    return scope.disclosureFor(
      records,
      plan,
      adjusted ? '' : text,
      policy: _scopeConversationPolicy,
    );
  }

  CoachSessionState _bindScopePlanRecords(
    CoachSessionState state, {
    bool force = false,
  }) {
    if (scopeManifest == null) return state;
    final id = state.activePlanId;
    final version = state.plans[id]?.lastOrNull;
    if (id == null || version == null) return state;
    if (!force &&
        _sessionState.plans[id]?.lastOrNull?.version == version.version) {
      return state;
    }
    final turn = state.userTurns.lastOrNull?.turn;
    return state.copyWith(
      scopeDecisionRecords: [
        for (final json in state.scopeDecisionRecords)
          if (json['turn'] == turn && json['superseded'] != true)
            CoachScopeDecisionRecord.fromJson(
              json,
            ).bindToPlan(id, version.version).toJson()
          else
            json,
      ],
    );
  }

  String _scopeConditions(CoachSessionState state) => jsonEncode({
    for (final field in [
      'scene',
      'equipment',
      'equipment_exclude',
      'limits',
      'level',
    ])
      field: state.params[field]?.value,
    'host': state.hostValues,
  });

  CoachSessionState _invalidateScopeAssessment(CoachSessionState state) {
    final turn = state.userTurns.lastOrNull?.turn;
    return state.copyWith(
      clearScopeAssessment: true,
      scopeDecisionRecords: [
        for (final record in state.scopeDecisionRecords)
          if (record['turn'] == turn && record['allowPlan'] != false)
            {...record, 'superseded': true}
          else
            record,
      ],
    );
  }

  ({CoachSessionState state, Map<String, Object?> receipt}) _assessScope(
    CoachSessionState state,
    Object? raw,
    CoachContext context,
  ) {
    final scope = _refreshActionScope()!;
    if (raw is! Map<String, Object?>) {
      throw const FormatException('invalid_scope_request');
    }
    final current = state.userTurns.last;
    final quote = raw['quote'];
    if (quote is! String || quote != current.text) {
      throw const FormatException('scope_quote_not_current_input');
    }
    final allowedKeys =
        (CoachScopeToolProtocol.schema['properties']! as Map).keys;
    if (raw.keys.any((key) => !allowedKeys.contains(key))) {
      throw const FormatException('unknown_scope_field');
    }
    String? text(String key) {
      final value = raw[key];
      if (value == null) return null;
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('invalid_scope_$key');
      }
      return value.trim();
    }

    bool flag(String key) {
      final value = raw[key];
      if (value != null && value is! bool) {
        throw FormatException('invalid_scope_$key');
      }
      return value == true;
    }

    final outside = flag('outsideSpecialty');
    final targets = raw['targetBodyCodes'];
    if (targets is! List<Object?> || targets.any((code) => code is! String)) {
      throw const FormatException('invalid_scope_body_codes');
    }
    final codes = targets.cast<String>().toSet();
    if (!outside && codes.any((code) => !scope.isKnownBodyCode(code))) {
      throw const FormatException('unknown_scope_body_code');
    }
    final sourceId = text('sourceActionId');
    final sourceName = text('sourceActionName');
    final sourceQuote = text('sourceQuote');
    if (sourceId != null &&
        !scope.matchesRequestedAction(
          sourceId,
          current.text,
          name: sourceName,
          quote: sourceQuote,
        )) {
      throw const FormatException('scope_source_without_user_evidence');
    }
    if (sourceId == null &&
        sourceName != null &&
        !current.text.contains(sourceName)) {
      throw const FormatException('scope_source_without_user_evidence');
    }
    final inScopeQuote = text('inScopeQuote');
    if (inScopeQuote != null && !current.text.contains(inScopeQuote)) {
      throw const FormatException('scope_content_without_user_evidence');
    }
    final tags = ActionTags(profile, scope.catalog);
    final availableNamed = scope.catalog.drills.any(
      (drill) =>
          current.text.contains(drill.name.of(context.language)) ||
          RegExp(
            '(?<![A-Za-z0-9_-])${RegExp.escape(drill.id)}(?![A-Za-z0-9_-])',
          ).hasMatch(current.text),
    );
    final bodyEvidence =
        inScopeQuote != null &&
        tags.goalCodes.any(
          (code) =>
              code.startsWith('body.') &&
              inScopeQuote.contains(
                tags.localizedLabel(code, context.language),
              ),
        );
    final operation = state.params['operation'];
    final editing =
        operation?.turn == current.turn &&
        operation?.value == 'edit' &&
        (state
                .plans[state.focusPlanId ?? state.lastDeliveredPlanId]
                ?.isNotEmpty ??
            false);
    final hasContent = availableNamed || bodyEvidence || editing;
    final statedRisk = text('safetyReason');
    final statedBlocked = flag('safetyBlocked');
    if (statedBlocked &&
        (statedRisk == null || !current.text.contains(statedRisk))) {
      throw const FormatException('scope_safety_without_user_evidence');
    }
    final confirmedPain = _confirmedMovementPain(state);
    final risk = confirmedPain ?? statedRisk;
    final blocked = statedBlocked || confirmedPain != null;
    if (_scopeTurnRecords().any(
          (record) => record.kind == CoachScopeDecisionKind.safetyBlocked,
        ) &&
        !blocked) {
      throw const FormatException('scope_safety_cannot_be_downgraded');
    }
    final nodes = NodeGates(
      profile,
      scope.catalog,
      minPicks: profile.minActions,
    );
    final equipment = <String>{
      for (final code in nodes.effectiveEquipment(state))
        ?tags.equipmentId(code),
    };
    final mentions = scope.mentionedUnavailableActions(current.text);
    final requested = <String?, CoachScopeRequest>{
      for (final item in mentions) item.sourceActionId: item,
      if (sourceId != null ||
          sourceName != null &&
              !mentions.any((item) => item.sourceActionName == sourceName))
        sourceId: CoachScopeRequest(
          originalText: current.text,
          sourceActionId: sourceId,
          sourceActionName: sourceName,
          sourceQuote: sourceQuote,
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
            targetBodyCodes: codes,
            scene: state.params['scene']?.value as String? ?? context.scene,
            equipment: equipment,
            avoid: context.avoid,
            hasInScopeContent: hasContent,
            insists: flag('insists'),
            locked: flag('locked'),
            outsideSpecialty: outside,
            safetyBlocked: blocked,
            safetyReason: risk,
            state: state,
            turn: current.turn,
          ),
          _scopeConversationPolicy,
        ),
    ];
    for (final record in records) {
      if (scope.validateRecord(record).isNotEmpty) {
        throw const FormatException('invalid_scope_decision');
      }
    }
    final next = state.copyWith(
      actionScopeIdentity: scope.identity,
      scopeAssessmentTurn: current.turn,
      scopeDecisionRecords: [
        for (final old in state.scopeDecisionRecords)
          if (old['turn'] == current.turn)
            {...old, 'superseded': true}
          else
            old,
        for (final record in records) record.toJson(),
      ],
    );
    return (
      state: next,
      receipt: {
        'identity': scope.identity,
        'records': records.map((record) => record.toJson()).toList(),
        'allowPlan': records.every((record) => record.allowPlan),
        'needsDraftRebuild': records.any((record) => record.requiresReplan),
        'source':
            'code-validated scope decision; candidate IDs are not search receipts',
      },
    );
  }

  Map<String, Object?>? _scopeToolProblem(LlmToolCall call, String language) {
    final scope = _refreshActionScope();
    if (scope == null) return null;
    Map<String, Object?> problem(String code, String fix) => {
      ...nodeError(
        code,
        'scope',
        'current authorized catalog and scope receipt',
        call.name,
        fix,
      ),
      'candidates': ActionSearch(
        profile,
        scope.catalog,
        minPicks: profile.minActions,
      ).candidateRows(_sessionState, language: language),
      'scopeIdentity': scope.identity,
    };
    if (call.name == AgentTools.draftPlan) {
      try {
        final raw = jsonDecode(call.arguments);
        if (raw is Map && raw['blocks'] is List) {
          for (final block in raw['blocks'] as List) {
            if (block is! Map || block['items'] is! List) continue;
            for (final item in block['items'] as List) {
              if (item is Map &&
                  item['id'] is String &&
                  !scope.contains(item['id'] as String)) {
                return problem(
                  'action_scope_violation',
                  '非法草稿未写入plans；仅从受限候选重新draft_plan，不得伪造ID。',
                );
              }
            }
          }
        }
        if (scope.validateReferences(raw).isNotEmpty) {
          return problem(
            'action_scope_violation',
            '父动作、segment及替代/引用元数据都必须属于当前受限目录。',
          );
        }
      } on FormatException {
        // The existing tool decoder produces the original JSON/schema error.
      }
    }
    if ({
          AgentTools.draftPlan,
          AgentTools.showPlan,
          AgentTools.showActions,
          AgentTools.askUser,
        }.contains(call.name) &&
        !_scopeAssessedNow) {
      return problem(
        'scope_assessment_required',
        '先set_params(fields可为空,scope_request)，quote逐字复制action_scope.userText；然后沿用同一task/search来源继续。',
      );
    }
    if ({AgentTools.draftPlan, AgentTools.showPlan}.contains(call.name) &&
        _scopeRefusesPlan) {
      return problem(
        'scope_request_refuses_plan',
        '本轮不生成计划；按scope回执说明专长/安全及范围内建议，直接文字回答。',
      );
    }
    if (call.name == AgentTools.showActions &&
        _scopeTurnRecords().any(
          (record) => record.kind == CoachScopeDecisionKind.safetyBlocked,
        )) {
      return problem('scope_safety_priority', '先处理原安全问题，不用动作卡或替代训练绕过安全暂停。');
    }
    return null;
  }

  List<CoachScopeDecisionRecord> _scopeTurnRecords() {
    final turn = _sessionState.userTurns.lastOrNull?.turn;
    return _readScopeRecords().where((record) => record.turn == turn).toList();
  }

  List<PlanRule> get _effectivePlanRules => [
    ...extraRules,
    if (scopeManifest != null)
      (plan, _, _) => _refreshActionScope()!.validatePlan(plan),
  ];

  bool _isScopedStateValid(
    CoachSessionState state, {
    bool allowUnbound = false,
  }) {
    final scope = _refreshActionScope();
    if (scope == null) return true;
    if (state.actionScopeIdentity != scope.identity &&
        !(allowUnbound && state.actionScopeIdentity == null)) {
      return false;
    }
    if (scope.validateReferences(state.toJson()).isNotEmpty ||
        state.pendingSearchIds.any((id) => !scope.contains(id))) {
      return false;
    }
    for (final versions in state.plans.values) {
      if (versions.isEmpty) return false;
      for (final version in versions) {
        final decoded = const PlanCodec().decodeStrict(version.plan);
        if (!decoded.ok || scope.validatePlan(decoded.plan!).isNotEmpty) {
          return false;
        }
      }
    }
    for (final entry in state.plans.entries) {
      var previousVersion = 0;
      for (final version in entry.value) {
        if (version.version <= previousVersion ||
            version.plan['id'] != entry.key) {
          return false;
        }
        previousVersion = version.version;
      }
    }
    for (final json in state.scopeDecisionRecords) {
      final record = CoachScopeDecisionRecord.fromJson(json);
      if (scope.validateRecord(record).isNotEmpty ||
          !state.userTurns.any(
            (turn) =>
                turn.turn == record.turn && turn.text == record.originalText,
          )) {
        return false;
      }
      if ((record.planId == null) != (record.planVersion == null)) return false;
      if (record.planId != null) {
        final bound = state.plans[record.planId]
            ?.where((version) => version.version == record.planVersion)
            .firstOrNull;
        if (bound == null) return false;
        final decoded = const PlanCodec().decodeStrict(bound.plan);
        if (!decoded.ok) return false;
        // Recheck the exact immutable historical version, not today's active
        // plan. A persisted claim of a substitute must match real plan items.
        try {
          scope.disclosureFor(
            [record],
            decoded.plan!,
            '',
            policy: _scopeConversationPolicy,
          );
        } on CoachScopeDisclosureException {
          return false;
        }
      }
    }
    if (state.scopeAssessmentTurn != null &&
        !state.scopeDecisionRecords.any(
          (record) =>
              record['turn'] == state.scopeAssessmentTurn &&
              record['superseded'] != true,
        )) {
      return false;
    }
    // Explicit unavailable mentions survive even a forged removal of both
    // the assessment pointer and the record list. They can be reconstructed
    // from the actual user journal without trusting model or snapshot flags.
    for (final turn in state.userTurns) {
      for (final mention in scope.mentionedUnavailableActions(turn.text)) {
        if (!state.scopeDecisionRecords.any(
          (json) =>
              json['turn'] == turn.turn &&
              json['sourceId'] == mention.sourceActionId,
        )) {
          return false;
        }
      }
    }
    return true;
  }

  bool _isScopedSnapshotValid(CoachSessionSnapshot snapshot) {
    final scope = _refreshActionScope();
    if (scope == null) return true;
    if (!_isScopedStateValid(snapshot.sessionState) ||
        scope.validateReferences(snapshot.ledger.toJson()).isNotEmpty ||
        scope
            .validateReferences(
              snapshot.recommendations.map((r) => r.toJson()).toList(),
            )
            .isNotEmpty) {
      return false;
    }
    for (final row in snapshot.candidates) {
      if (row is! List<Object?> ||
          row.isEmpty ||
          row.first is! String ||
          !scope.contains(row.first! as String)) {
        return false;
      }
    }
    return true;
  }

  ValidatedPlan? _prepareScopedTraining(
    TrainingPlan plan,
    CoachContext context,
  ) {
    if (scopeManifest != null && _scopeRefusesPlan) return null;
    final safety = _taskSafetyContext;
    final effective = scopeManifest == null
        ? context
        : context.copyWith(
            avoid: {
              ...context.avoid,
              ...?safety?.avoid,
              ...?_latestExplicitAvoid,
            },
          );
    return gateFor(_catalog())
        .admitTraining(plan, context: effective)
        ?.withSessionVersion(_sessionState);
  }
}
