part of 'action_scope.dart';

/// Host-owned scope copy. Cross-App guidance is absent unless explicitly set.
final class CoachScopeConversationPolicy {
  CoachScopeConversationPolicy({
    required String specialty,
    List<String> suggestions = const [],
    this.outOfScopeGuidance,
    this.safetyMessage = '先暂停这次训练安排，按安全提示处理。',
  }) : specialty = _scopeText(specialty, 'scopePolicy.specialty'),
       suggestions = List.unmodifiable(suggestions) {
    if (suggestions.any((text) => text.trim().isEmpty)) {
      _badScope('empty_scope_suggestion', 'scopePolicy.suggestions');
    }
    if (outOfScopeGuidance != null && outOfScopeGuidance!.trim().isEmpty) {
      _badScope('empty_scope_guidance', 'scopePolicy.outOfScopeGuidance');
    }
  }

  final String specialty;
  final List<String> suggestions;
  final String? outOfScopeGuidance;
  final String safetyMessage;
  bool get guidanceEnabled => outOfScopeGuidance != null;
}

/// Structured intent with literal source evidence. Target codes are catalogue
/// taxonomy codes; they are never guessed from an action's display name.
final class CoachScopeRequest {
  CoachScopeRequest({
    required this.originalText,
    this.sourceActionId,
    this.sourceActionName,
    this.sourceQuote,
    Set<String> targetBodyCodes = const {},
    this.scene,
    Set<String>? equipment,
    Set<String> avoid = const {},
    this.hasInScopeContent = false,
    this.insists = false,
    this.safetyBlocked = false,
    this.outsideSpecialty = false,
    this.safetyReason,
    this.locked = false,
    this.state,
    this.turn,
  }) : targetBodyCodes = Set.unmodifiable(targetBodyCodes),
       equipment = equipment == null ? null : Set.unmodifiable(equipment),
       avoid = Set.unmodifiable(avoid);

  final String originalText;
  final String? sourceActionId;
  final String? sourceActionName;
  final String? sourceQuote;
  final Set<String> targetBodyCodes;
  final String? scene;
  final Set<String>? equipment;
  final Set<String> avoid;

  /// True only with independently evidenced in-scope content or an existing
  /// explicitly edited in-scope plan. A model boolean alone is not evidence.
  final bool hasInScopeContent;
  final bool insists;
  final bool safetyBlocked;

  /// Deny-only declaration for a whole request beyond the App's specialty.
  /// It never grants an action, a search source or a body taxonomy code.
  final bool outsideSpecialty;
  final String? safetyReason;
  final bool locked;
  final CoachSessionState? state;
  final int? turn;
}

enum CoachScopeDecisionKind {
  inScope,
  substituted,
  removed,
  outOfScope,
  insistedUnavailable,
  safetyBlocked,
  lockedConflict,
}

/// Serializable disclosure evidence, separate from executable plan references.
/// [sourceId] is the user's unsupported request, never an adopted action ID.
final class CoachScopeDecisionRecord {
  CoachScopeDecisionRecord({
    required this.kind,
    required this.originalText,
    required this.scopeIdentity,
    required this.message,
    required this.allowPlan,
    required this.requiresReplan,
    this.sourceId,
    this.sourceName,
    this.sourceQuote,
    this.adoptedActionId,
    List<String> candidateIds = const [],
    List<String> suggestions = const [],
    this.guidance,
    this.turn,
    this.planId,
    this.planVersion,
  }) : candidateIds = List.unmodifiable(candidateIds),
       suggestions = List.unmodifiable(suggestions);

  final CoachScopeDecisionKind kind;
  final String originalText;
  final String scopeIdentity;
  final String message;
  final bool allowPlan;
  final bool requiresReplan;
  final String? sourceId;
  final String? sourceName;
  final String? sourceQuote;
  final String? adoptedActionId;
  final List<String> candidateIds;
  final List<String> suggestions;
  final String? guidance;
  final int? turn;
  final String? planId;
  final int? planVersion;

  CoachScopeDecisionRecord bindToPlan(String id, int version) =>
      CoachScopeDecisionRecord(
        kind: kind,
        originalText: originalText,
        scopeIdentity: scopeIdentity,
        message: message,
        allowPlan: allowPlan,
        requiresReplan: requiresReplan,
        sourceId: sourceId,
        sourceName: sourceName,
        sourceQuote: sourceQuote,
        adoptedActionId: adoptedActionId,
        candidateIds: candidateIds,
        suggestions: suggestions,
        guidance: guidance,
        turn: turn,
        planId: id,
        planVersion: version,
      );

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'originalText': originalText,
    'scopeIdentity': scopeIdentity,
    'message': message,
    'allowPlan': allowPlan,
    'requiresReplan': requiresReplan,
    'sourceId': ?sourceId,
    'sourceName': ?sourceName,
    'sourceQuote': ?sourceQuote,
    'adoptedActionId': ?adoptedActionId,
    'candidateIds': candidateIds,
    'suggestions': suggestions,
    'guidance': ?guidance,
    'turn': ?turn,
    'planId': ?planId,
    'planVersion': ?planVersion,
  };

  factory CoachScopeDecisionRecord.fromJson(Object? value) {
    final json = _scopeMap(value, 'scopeRecord');
    final kind = CoachScopeDecisionKind.values
        .where((kind) => kind.name == json['kind'])
        .firstOrNull;
    if (kind == null ||
        json['allowPlan'] is! bool ||
        json['requiresReplan'] is! bool) {
      throw const FormatException('Invalid scope decision record');
    }
    List<String> strings(String field) {
      final value = json[field];
      if (value is! List<Object?> || value.any((item) => item is! String)) {
        throw FormatException('Invalid scope record $field');
      }
      return value.cast<String>();
    }

    String? optional(String field) {
      final value = json[field];
      if (value != null && value is! String) {
        throw FormatException('Invalid scope record $field');
      }
      return value as String?;
    }

    int? integer(String field) {
      final value = json[field];
      if (value != null && (value is! int || value < 0)) {
        throw FormatException('Invalid scope record $field');
      }
      return value as int?;
    }

    return CoachScopeDecisionRecord(
      kind: kind,
      originalText:
          json['originalText'] is String &&
              (json['originalText']! as String).trim().isNotEmpty
          ? json['originalText']! as String
          : throw const FormatException('Invalid scope record originalText'),
      scopeIdentity: _scopeHash(
        json['scopeIdentity'],
        'scopeRecord.scopeIdentity',
      ),
      message: _scopeText(json['message'], 'scopeRecord.message'),
      allowPlan: json['allowPlan']! as bool,
      requiresReplan: json['requiresReplan']! as bool,
      sourceId: optional('sourceId'),
      sourceName: optional('sourceName'),
      sourceQuote: optional('sourceQuote'),
      adoptedActionId: optional('adoptedActionId'),
      candidateIds: strings('candidateIds'),
      suggestions: strings('suggestions'),
      guidance: optional('guidance'),
      turn: integer('turn'),
      planId: optional('planId'),
      planVersion: integer('planVersion'),
    );
  }
}

final class CoachScopeDisclosureException extends FormatException {
  const CoachScopeDisclosureException(this.code)
    : super('Scope disclosure cannot truthfully accompany this result: $code');

  final String code;
}

extension CoachActionScopePolicy on CoachActionScope {
  /// Tests only a body taxonomy code; it never returns a master action index.
  bool isKnownBodyCode(String code) {
    if (!code.startsWith('body.')) return false;
    final known = <String>{
      for (final fact in manifest._facts.values) ...fact.body,
    };
    if (known.contains(code)) return true;
    return profile.bodyGroups.containsKey(code) &&
        ActionTags(
          profile,
          catalog,
        ).expandCodes([code]).intersection(known).isNotEmpty;
  }

  /// Exact known full-name/ID recognition only. It does not search by keyword
  /// or rank replacements by names. The master facts never become a tool index.
  List<CoachScopeRequest> mentionedUnavailableActions(String originalText) =>
      List.unmodifiable([
        for (final fact in manifest._facts.values)
          if (!contains(fact.id) &&
              matchesRequestedAction(fact.id, originalText))
            CoachScopeRequest(
              originalText: originalText,
              sourceActionId: fact.id,
              sourceActionName: fact.names.firstOrNull ?? fact.id,
              sourceQuote: _matchedSourceQuote(fact, originalText),
            ),
      ]);

  bool matchesRequestedAction(
    String id,
    String originalText, {
    String? name,
    String? quote,
  }) {
    final fact = manifest._facts[id];
    if (fact == null ||
        (name != null && name != id && !fact.names.contains(name)) ||
        (quote != null && (quote.isEmpty || !originalText.contains(quote)))) {
      return false;
    }
    final evidence = quote ?? originalText;
    return _mentionsExact(evidence, id, identifier: true) ||
        fact.names.any((value) => _mentionsExact(evidence, value));
  }

  CoachScopeDecisionRecord evaluateRequest(
    CoachScopeRequest request,
    CoachScopeConversationPolicy policy,
  ) {
    if (request.originalText.trim().isEmpty) {
      throw const FormatException('scope_request requires original user text');
    }
    final fact = manifest._facts[request.sourceActionId];
    if (fact != null &&
        !matchesRequestedAction(
          fact.id,
          request.originalText,
          name: request.sourceActionName,
          quote: request.sourceQuote,
        )) {
      throw const FormatException('scope_request_without_user_evidence');
    }
    if (fact == null &&
        request.sourceActionId != null &&
        !_mentionsExact(
          request.originalText,
          request.sourceActionId!,
          identifier: true,
        ) &&
        !(request.sourceActionName != null &&
            request.originalText.contains(request.sourceActionName!))) {
      throw const FormatException('scope_request_without_user_evidence');
    }
    final label =
        fact?.names.firstOrNull ??
        request.sourceActionName?.replaceAll(RegExp(r'[\r\n]+'), ' ') ??
        request.sourceActionId ??
        '请求的内容';
    final unavailable = _scopeUnavailable(this, request.sourceActionId, label);
    final suggestions = _scopeSuggestions(this, policy);
    CoachScopeDecisionRecord decision(
      CoachScopeDecisionKind kind,
      String message, {
      bool allowPlan = false,
      bool requiresReplan = false,
      String? adopted,
      List<String> candidates = const [],
    }) => CoachScopeDecisionRecord(
      kind: kind,
      originalText: request.originalText,
      scopeIdentity: identity,
      message: message,
      allowPlan: allowPlan,
      requiresReplan: requiresReplan,
      sourceId: request.sourceActionId,
      sourceName: label,
      sourceQuote: request.sourceQuote,
      adoptedActionId: adopted,
      candidateIds: candidates,
      suggestions: suggestions,
      guidance: policy.outOfScopeGuidance,
      turn: request.turn,
    );

    // Safety and explicit user locks take precedence over substitute consent.
    if (request.safetyBlocked) {
      return decision(
        CoachScopeDecisionKind.safetyBlocked,
        '${request.safetyReason ?? policy.safetyMessage} ${policy.specialty}',
      );
    }
    if (request.outsideSpecialty &&
        (request.sourceActionId == null ||
            !contains(request.sourceActionId!))) {
      return decision(
        CoachScopeDecisionKind.outOfScope,
        '这次需求超出本 App 的训练范围。${policy.specialty}',
      );
    }
    if (request.sourceActionId == null &&
        request.sourceActionName == null &&
        request.targetBodyCodes.isEmpty) {
      return decision(
        CoachScopeDecisionKind.inScope,
        '按本 App 可用范围继续收集条件和安排训练。',
        allowPlan: true,
      );
    }
    if (request.sourceActionId != null && contains(request.sourceActionId!)) {
      return decision(
        CoachScopeDecisionKind.inScope,
        '该动作在本 App 可用范围内，仍需通过当前安全和训练门禁。',
        allowPlan: true,
      );
    }
    if (request.insists) {
      return decision(
        CoachScopeDecisionKind.insistedUnavailable,
        '$unavailable，不能把它安排进计划。${policy.specialty}',
      );
    }
    if (request.locked) {
      return decision(
        CoachScopeDecisionKind.lockedConflict,
        '$unavailable；你已锁定的动作或剂量不能被暗中替换，请先选择是否调整。${policy.specialty}',
      );
    }

    final candidates = _replacementCandidates(this, request, fact);
    if (fact != null && candidates.isNotEmpty) {
      final adopted = candidates.first;
      return decision(
        CoachScopeDecisionKind.substituted,
        '$unavailable，用${adopted.name.of()}练同一部位。',
        allowPlan: true,
        requiresReplan: true,
        adopted: adopted.id,
        candidates: candidates.map((drill) => drill.id).toList(),
      );
    }
    if (request.hasInScopeContent) {
      return decision(
        CoachScopeDecisionKind.removed,
        '$unavailable，也没有同部位、场景和器械都合适的替代，本次去掉它，未覆盖这部分目标。',
        allowPlan: true,
        requiresReplan: true,
      );
    }

    if (request.sourceActionId == null &&
        fact == null &&
        request.targetBodyCodes.isNotEmpty &&
        candidates.isNotEmpty) {
      return decision(
        CoachScopeDecisionKind.inScope,
        '这些目标可从本 App 范围内动作安排，仍需通过安全和训练门禁。',
        allowPlan: true,
        candidates: candidates.map((drill) => drill.id).toList(),
      );
    }
    return decision(
      CoachScopeDecisionKind.outOfScope,
      '${request.sourceActionId == null ? '这次需求超出本 App 的训练范围。' : '$unavailable。'}${policy.specialty}',
    );
  }

  /// Validates persisted decision identity and all adopted/candidate IDs.
  List<PlanIssue> validateRecord(CoachScopeDecisionRecord record) => [
    if (record.scopeIdentity != identity)
      const PlanIssue('scope_record_identity_mismatch', '范围处理记录属于另一份授权或目录。'),
    for (final id in [
      if (record.adoptedActionId != null) record.adoptedActionId!,
      ...record.candidateIds,
    ])
      if (!contains(id))
        PlanIssue('action_scope_violation', '范围处理记录包含不可采用的动作。', exerciseId: id),
    if (record.sourceId != null &&
        manifest._facts.containsKey(record.sourceId) &&
        !matchesRequestedAction(
          record.sourceId!,
          record.originalText,
          name: record.sourceName,
          quote: record.sourceQuote,
        ))
      const PlanIssue(
        'scope_record_without_user_evidence',
        '范围处理记录缺少原用户输入中的动作证据。',
      ),
    if (record.sourceId != null &&
        !manifest._facts.containsKey(record.sourceId) &&
        !_mentionsExact(
          record.originalText,
          record.sourceId!,
          identifier: true,
        ) &&
        !(record.sourceName != null &&
            record.originalText.contains(record.sourceName!)))
      const PlanIssue('scope_record_without_user_evidence', '未知动作来源必须有原话字面证据。'),
    if (record.sourceQuote != null &&
        (record.sourceQuote!.isEmpty ||
            !record.originalText.contains(record.sourceQuote!)))
      const PlanIssue('scope_record_without_user_evidence', '来源引句必须是原话中的非空子串。'),
    if (record.kind == CoachScopeDecisionKind.substituted &&
        (record.sourceId == null ||
            record.adoptedActionId == null ||
            !_recordSubstitutionMatches(this, record)))
      const PlanIssue(
        'scope_record_substitution_mismatch',
        '替代记录不满足同部位、同场景和同器械约束。',
      ),
    if (record.allowPlan !=
        {
          CoachScopeDecisionKind.inScope,
          CoachScopeDecisionKind.substituted,
          CoachScopeDecisionKind.removed,
        }.contains(record.kind))
      const PlanIssue('scope_record_decision_mismatch', '范围记录的计划准入标志与决策不一致。'),
    if (record.requiresReplan !=
        {
          CoachScopeDecisionKind.substituted,
          CoachScopeDecisionKind.removed,
        }.contains(record.kind))
      const PlanIssue('scope_record_decision_mismatch', '范围记录的重编标志与决策不一致。'),
    if (record.kind == CoachScopeDecisionKind.inScope &&
        record.sourceId != null &&
        !contains(record.sourceId!))
      const PlanIssue(
        'scope_record_decision_mismatch',
        '范围外来源不能伪装成无需告知的范围内决策。',
      ),
    if (record.kind != CoachScopeDecisionKind.substituted &&
        record.adoptedActionId != null)
      const PlanIssue('scope_record_decision_mismatch', '只有替代决策可以携带采用动作。'),
  ];

  /// Returns final copy with truthful template disclosure. A missing adopted
  /// action or a rejected request with a plan is a recompile error, not a text
  /// patch that would conceal an invalid card. Call with records for this card.
  String disclosureFor(
    Iterable<CoachScopeDecisionRecord> records,
    TrainingPlan? finalPlan,
    String text, {
    CoachScopeConversationPolicy? policy,
  }) {
    final trustedPolicy =
        policy ??
        CoachScopeConversationPolicy(
          specialty: profile.focus.trim().isEmpty
              ? '${profile.appName}只提供当前范围内训练。'
              : profile.focus,
        );
    final active = records.toList();
    final ids = <String>{
      if (finalPlan != null)
        for (final block in finalPlan.blocks)
          for (final item in block.items) ...[
            item.exerciseId,
            for (final segment in item.segments) segment.exerciseId,
          ],
    };
    if (finalPlan != null && validatePlan(finalPlan).isNotEmpty) {
      throw const CoachScopeDisclosureException('invalid_final_scope');
    }
    for (final record in active) {
      if (validateRecord(record).isNotEmpty) {
        throw const CoachScopeDisclosureException('invalid_scope_record');
      }
      if (finalPlan != null && !record.allowPlan) {
        throw const CoachScopeDisclosureException('scope_request_refuses_plan');
      }
      if (finalPlan != null &&
          record.kind == CoachScopeDecisionKind.substituted &&
          !ids.contains(record.adoptedActionId)) {
        throw const CoachScopeDisclosureException('adopted_action_missing');
      }
    }
    // No-plan refusal uses trusted scope/safety copy, rather than preserving a
    // model's claim that it delivered an unavailable or cross-App workout.
    final refusal = active.where((record) => !record.allowPlan).toList();
    if (finalPlan == null && refusal.isNotEmpty) {
      return <String>{
        for (final record in refusal)
          _truthfulScopeMessage(this, record, trustedPolicy, delivered: false),
        '可以选择：${_scopeSuggestions(this, trustedPolicy).join('；')}。',
        if (trustedPolicy.outOfScopeGuidance != null)
          trustedPolicy.outOfScopeGuidance!,
      }.join('\n');
    }
    final lines = <String>[if (text.trim().isNotEmpty) text.trim()];
    for (final record in active) {
      if (record.kind == CoachScopeDecisionKind.inScope) continue;
      final message = _truthfulScopeMessage(
        this,
        record,
        trustedPolicy,
        delivered: finalPlan != null,
      );
      if (!lines.any((line) => line.contains(message))) lines.add(message);
      if (trustedPolicy.outOfScopeGuidance != null &&
          !lines.any(
            (line) => line.contains(trustedPolicy.outOfScopeGuidance!),
          )) {
        lines.add(trustedPolicy.outOfScopeGuidance!);
      }
    }
    return lines.join('\n');
  }
}

String? _matchedSourceQuote(_ScopeActionFact fact, String original) {
  if (_mentionsExact(original, fact.id, identifier: true)) return fact.id;
  return fact.names.where((name) => _mentionsExact(original, name)).firstOrNull;
}

bool _mentionsExact(String text, String value, {bool identifier = false}) {
  if (value.isEmpty) return false;
  final latin = identifier || RegExp(r'^[A-Za-z0-9 _-]+$').hasMatch(value);
  return latin
      ? RegExp(
          '(?<![A-Za-z0-9_-])${RegExp.escape(value)}(?![A-Za-z0-9_-])',
          caseSensitive: identifier,
        ).hasMatch(text)
      : text.contains(value);
}

List<String> _scopeSuggestions(
  CoachActionScope scope,
  CoachScopeConversationPolicy policy,
) => policy.suggestions.isNotEmpty
    ? policy.suggestions
    : List.unmodifiable([
        for (final drill in scope.catalog.drills.take(3))
          '选择${drill.name.of()}等本 App 范围内动作',
        if (scope.catalog.drills.isEmpty) '调整条件后再选择本 App 支持的训练',
      ]);

bool _recordSubstitutionMatches(
  CoachActionScope scope,
  CoachScopeDecisionRecord record,
) {
  final source = scope.manifest._facts[record.sourceId];
  if (source == null || !source.complete || scope.contains(source.id)) {
    return false;
  }
  final tags = ActionTags(scope.profile, scope.catalog);
  final target = tags.expandCodes(source.body);
  for (final id in {
    if (record.adoptedActionId != null) record.adoptedActionId!,
    ...record.candidateIds,
  }) {
    final drill = scope.catalog[id];
    if (drill == null ||
        tags.forAction(drill).intersection(target).isEmpty ||
        source.scenes.intersection(drill.scenes.toSet()).isEmpty ||
        !_setEquals(
          source.equipment,
          drill.equipment.where((e) => e != 'none').toSet(),
        )) {
      return false;
    }
  }
  return true;
}

String _scopeUnavailable(
  CoachActionScope scope,
  String? sourceId,
  String label,
) => sourceId != null && scope.allowedActionIds.contains(sourceId)
    ? '本 App 暂不能将$label用于训练（训练说明不完整或不符合当前范围）'
    : '本 App 没有$label';

String _truthfulScopeMessage(
  CoachActionScope scope,
  CoachScopeDecisionRecord record,
  CoachScopeConversationPolicy policy, {
  required bool delivered,
}) {
  final source = scope.manifest._facts[record.sourceId];
  final label =
      source?.names.firstOrNull ??
      record.sourceName ??
      record.sourceId ??
      '请求的内容';
  final unavailable = _scopeUnavailable(scope, record.sourceId, label);
  return switch (record.kind) {
    CoachScopeDecisionKind.inScope => '该动作在本 App 可用范围内，仍需通过当前安全和训练门禁。',
    CoachScopeDecisionKind.substituted =>
      delivered
          ? '$unavailable，用${scope.catalog[record.adoptedActionId!]!.name.of()}练同一部位。'
          : '$unavailable，可以用${scope.catalog[record.adoptedActionId!]!.name.of()}练同一部位；尚未生成训练计划。',
    CoachScopeDecisionKind.removed =>
      '$unavailable，也没有同部位、场景和器械都合适的替代，本次去掉它，未覆盖这部分目标。',
    CoachScopeDecisionKind.outOfScope =>
      '${record.sourceId == null ? '这次需求超出本 App 的训练范围。' : '$unavailable。'}${policy.specialty}',
    CoachScopeDecisionKind.insistedUnavailable =>
      '$unavailable，不能把它安排进计划。${policy.specialty}',
    CoachScopeDecisionKind.safetyBlocked =>
      '${policy.safetyMessage} ${policy.specialty}',
    CoachScopeDecisionKind.lockedConflict =>
      '$unavailable；你已锁定的动作或剂量不能被暗中替换，请先选择是否调整。${policy.specialty}',
  };
}

List<Drill> _replacementCandidates(
  CoachActionScope scope,
  CoachScopeRequest request,
  _ScopeActionFact? source,
) {
  if (source != null && !source.complete) return const [];
  final tags = ActionTags(scope.profile, scope.catalog);
  final target = source?.body ?? request.targetBodyCodes;
  final expanded = tags.expandCodes(target);
  if (expanded.isEmpty) return const [];
  final scene =
      request.scene?.replaceFirst('scene.', '') ??
      request.state?.params['scene']?.value as String?;
  final equipment = <String>{
    for (final raw in request.equipment ?? const <String>{})
      if (raw != 'none' && raw.isNotEmpty)
        raw.startsWith('equip.') ? tags.equipmentId(raw) ?? raw : raw,
  };
  final state =
      request.state ??
      CoachSessionState(
        params: {
          if (scene != null)
            'scene': CoachParamValue(value: scene, source: 'host', turn: 0),
          'equipment': CoachParamValue(
            value: equipment
                .map(tags.equipmentCode)
                .whereType<String>()
                .toList(),
            source: 'host',
            turn: 0,
          ),
          'limits': CoachParamValue(
            value: request.avoid
                .map((v) => tags.canonicalLimitCode(v) ?? v)
                .toList(),
            source: 'host',
            turn: 0,
          ),
        },
      );
  final extraLimits = request.avoid
      .map((value) => tags.canonicalLimitCode(value) ?? value)
      .toSet();
  final gates = NodeGates(scope.profile, scope.catalog, minPicks: 1);
  final candidates = [
    for (final drill in scope.catalog.drills)
      if (gates.actionProblem(state, drill.id) == null &&
          ![...drill.cautions, ...drill.contraindications].any(
            (value) => extraLimits.contains(tags.canonicalLimitCode(value)),
          ) &&
          tags.forAction(drill).intersection(expanded).isNotEmpty &&
          (source == null ||
              (source.scenes.intersection(drill.scenes.toSet()).isNotEmpty &&
                  _setEquals(
                    source.equipment,
                    drill.equipment.where((e) => e != 'none').toSet(),
                  ))))
        drill,
  ];
  candidates.sort((a, b) {
    int score(Drill drill) =>
        tags.forAction(drill).intersection(expanded).length * 100 +
        (source?.category == drill.category ? 20 : 0) -
        (drill.level - (source?.level ?? 1)).abs();
    final difference = score(b).compareTo(score(a));
    return difference != 0 ? difference : a.id.compareTo(b.id);
  });
  return List.unmodifiable(candidates.take(8));
}

bool _setEquals<T>(Set<T> first, Set<T> second) =>
    first.length == second.length && first.containsAll(second);
