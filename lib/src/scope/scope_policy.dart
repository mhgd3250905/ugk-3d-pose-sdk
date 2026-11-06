part of 'action_scope.dart';

/// Host-owned scope copy. Cross-App guidance is absent unless explicitly set.
final class CoachScopeConversationPolicy {
  CoachScopeConversationPolicy({
    required String specialty,
    List<String> suggestions = const [],
    this.outOfScopeGuidance,
    this.safetyMessage = '先暂停这次训练安排，按安全提示处理。',
    this.languageTag = 'zh',
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
  final String languageTag;
  bool get isEnglish => languageTag.toLowerCase().startsWith('en');
  String pick(String chinese, String english) => isEnglish ? english : chinese;
  String get localizedSafetyMessage =>
      isEnglish && safetyMessage == '先暂停这次训练安排，按安全提示处理。'
      ? 'Pause this training plan and follow the safety guidance first.'
      : safetyMessage;
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

/// Ordinary workflow data for the requested action and its handling.
final class CoachScopeDecisionRecord {
  CoachScopeDecisionRecord({
    required this.kind,
    required this.originalText,
    required this.message,
    this.sourceId,
    this.sourceName,
    this.sourceQuote,
    this.adoptedActionId,
    List<String> candidateIds = const [],
    this.turn,
  }) : candidateIds = List.unmodifiable(candidateIds);
  final CoachScopeDecisionKind kind;
  final String originalText;
  final String message;
  final String? sourceId;
  final String? sourceName;
  final String? sourceQuote;
  final String? adoptedActionId;
  final List<String> candidateIds;
  final int? turn;
  bool get allowPlan => switch (kind) {
    CoachScopeDecisionKind.inScope ||
    CoachScopeDecisionKind.substituted ||
    CoachScopeDecisionKind.removed => true,
    _ => false,
  };
  bool get requiresReplan =>
      kind == CoachScopeDecisionKind.substituted ||
      kind == CoachScopeDecisionKind.removed;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'originalText': originalText,
    'message': message,
    'allowPlan': allowPlan,
    'requiresReplan': requiresReplan,
    'sourceId': ?sourceId,
    'sourceName': ?sourceName,
    'sourceQuote': ?sourceQuote,
    'adoptedActionId': ?adoptedActionId,
    'candidateIds': candidateIds,
    'turn': ?turn,
  };
  factory CoachScopeDecisionRecord.fromJson(Object? value) {
    final json = _scopeMap(value, 'scopeRecord');
    return CoachScopeDecisionRecord(
      kind: CoachScopeDecisionKind.values.byName(json['kind'] as String),
      originalText: json['originalText'] as String,
      message: json['message'] as String,
      sourceId: json['sourceId'] as String?,
      sourceName: json['sourceName'] as String?,
      sourceQuote: json['sourceQuote'] as String?,
      adoptedActionId: json['adoptedActionId'] as String?,
      candidateIds: asStringList(json['candidateIds']),
      turn: json['turn'] as int?,
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
        (name != null && name != id && !fact.names.contains(name))) {
      return false;
    }
    final evidence = originalText;
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
    var fact = manifest._facts[request.sourceActionId];
    if (request.sourceActionId == null && request.sourceActionName != null) {
      final named = manifest._facts.values
          .where(
            (candidate) => candidate.names.contains(request.sourceActionName),
          )
          .toList();
      if (named.length > 1) {
        throw const FormatException('ambiguous_scope_source_name');
      }
      fact = named.firstOrNull;
    }
    // Complete-name lookup identifies the source action, without ranking
    // replacements by name or granting a search receipt.
    final sourceId = request.sourceActionId ?? fact?.id;
    final label =
        fact?.names.firstOrNull ??
        request.sourceActionName?.replaceAll(RegExp(r'[\r\n]+'), ' ') ??
        request.sourceActionId ??
        policy.pick('请求的内容', 'the requested content');
    final unavailable = _scopeUnavailable(this, sourceId, label, policy);
    CoachScopeDecisionRecord decision(
      CoachScopeDecisionKind kind,
      String message, {
      String? adopted,
      List<String> candidates = const [],
    }) => CoachScopeDecisionRecord(
      kind: kind,
      originalText: request.originalText,
      message: message,
      sourceId: sourceId,
      sourceName: label,
      sourceQuote: request.sourceQuote,
      adoptedActionId: adopted,
      candidateIds: candidates,
      turn: request.turn,
    );

    // Safety and explicit user locks take precedence over substitute consent.
    if (request.safetyBlocked) {
      return decision(
        CoachScopeDecisionKind.safetyBlocked,
        '${request.safetyReason ?? policy.localizedSafetyMessage} ${policy.specialty}',
      );
    }
    if (request.outsideSpecialty && (sourceId == null || !contains(sourceId))) {
      return decision(
        CoachScopeDecisionKind.outOfScope,
        policy.pick(
          '这次需求超出本 App 的训练范围。${policy.specialty}',
          'This request is outside this app’s training scope. ${policy.specialty}',
        ),
      );
    }
    if (sourceId == null &&
        request.sourceActionName == null &&
        request.targetBodyCodes.isEmpty) {
      return decision(
        CoachScopeDecisionKind.inScope,
        policy.pick(
          '按本 App 可用范围继续收集条件和安排训练。',
          'Continue gathering conditions and planning within this app’s available actions.',
        ),
      );
    }
    if (sourceId != null && contains(sourceId)) {
      return decision(
        CoachScopeDecisionKind.inScope,
        policy.pick(
          '该动作在本 App 可用范围内，仍需通过当前安全和训练门禁。',
          'This action is available in the app and must still pass the current safety and training checks.',
        ),
      );
    }
    if (request.insists) {
      return decision(
        CoachScopeDecisionKind.insistedUnavailable,
        policy.pick(
          '$unavailable，不能把它安排进计划。${policy.specialty}',
          '$unavailable and cannot be included in the plan. ${policy.specialty}',
        ),
      );
    }
    if (request.locked) {
      return decision(
        CoachScopeDecisionKind.lockedConflict,
        policy.pick(
          '$unavailable；你已锁定的动作或剂量不能被暗中替换，请先选择是否调整。${policy.specialty}',
          '$unavailable. Your locked actions or doses cannot be changed silently; choose whether to adjust them first. ${policy.specialty}',
        ),
      );
    }

    final candidates = _replacementCandidates(this, request, fact);
    if (fact != null && candidates.isNotEmpty) {
      final adopted = candidates.first;
      return decision(
        CoachScopeDecisionKind.substituted,
        policy.pick(
          '$unavailable，用${adopted.name.of()}练同一部位。',
          '$unavailable. Use ${adopted.name.of(policy.languageTag)} to train the same area.',
        ),
        adopted: adopted.id,
        candidates: candidates.map((drill) => drill.id).toList(),
      );
    }
    if (request.hasInScopeContent) {
      return decision(
        CoachScopeDecisionKind.removed,
        policy.pick(
          '$unavailable，也没有同部位、场景和器械都合适的替代，本次去掉它，未覆盖这部分目标。',
          '$unavailable. No alternative matches the area, setting and equipment, so it is omitted and this part of your goal is not covered.',
        ),
      );
    }

    if (sourceId == null &&
        fact == null &&
        request.targetBodyCodes.isNotEmpty &&
        candidates.isNotEmpty) {
      return decision(
        CoachScopeDecisionKind.inScope,
        policy.pick(
          '这些目标可从本 App 范围内动作安排，仍需通过安全和训练门禁。',
          'These goals can use actions within this app’s scope, subject to safety and training checks.',
        ),
        candidates: candidates.map((drill) => drill.id).toList(),
      );
    }
    return decision(
      CoachScopeDecisionKind.outOfScope,
      policy.pick(
        '${sourceId == null ? '这次需求超出本 App 的训练范围。' : '$unavailable。'}${policy.specialty}',
        '${sourceId == null ? 'This request is outside this app’s training scope. ' : '$unavailable. '}${policy.specialty}',
      ),
    );
  }

  /// Adds scope handling copy and checks that a required substitute is present.
  String disclosureFor(
    Iterable<CoachScopeDecisionRecord> records,
    TrainingPlan? finalPlan,
    String text, {
    CoachScopeConversationPolicy? policy,
  }) {
    final active = records.toList();
    final copy =
        policy ??
        CoachScopeConversationPolicy(
          specialty: profile.focus.isEmpty
              ? '${profile.appName}提供当前范围内训练。'
              : profile.focus,
        );
    if (finalPlan != null) {
      for (final record in active) {
        if (!record.allowPlan) {
          throw const CoachScopeDisclosureException(
            'scope_request_refuses_plan',
          );
        }
        if (record.kind == CoachScopeDecisionKind.substituted &&
            !finalPlan.exerciseIds.contains(record.adoptedActionId)) {
          throw const CoachScopeDisclosureException('adopted_action_missing');
        }
      }
    }
    final refusal = active.any((record) => !record.allowPlan);
    return <String>{
      if (!refusal && text.trim().isNotEmpty) text.trim(),
      for (final record in active)
        if (record.kind != CoachScopeDecisionKind.inScope)
          _scopeDisclosure(this, record, copy, delivered: finalPlan != null),
      if (refusal)
        copy.pick(
          '可以选择：${_scopeSuggestions(this, copy).join('；')}。',
          'You can choose: ${_scopeSuggestions(this, copy).join('; ')}.',
        ),
      if (active.any(
            (record) => record.kind != CoachScopeDecisionKind.inScope,
          ) &&
          copy.guidanceEnabled)
        copy.outOfScopeGuidance!,
    }.join('\n');
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
          policy.pick(
            '选择${drill.name.of()}等本 App 范围内动作',
            'Choose an action supported by this app, such as ${drill.name.of(policy.languageTag)}',
          ),
        if (scope.catalog.drills.isEmpty)
          policy.pick(
            '调整条件后再选择本 App 支持的训练',
            'Adjust your conditions, then choose training supported by this app',
          ),
      ]);

String _scopeUnavailable(
  CoachActionScope scope,
  String? sourceId,
  String label,
  CoachScopeConversationPolicy policy,
) => sourceId != null && scope.allowedActionIds.contains(sourceId)
    ? policy.pick(
        '本 App 暂不能将$label用于训练（训练说明不完整或不符合当前范围）',
        'This app cannot currently use $label for training (its instructions are incomplete or it does not meet the current scope)',
      )
    : policy.pick('本 App 没有$label', 'This app does not include $label');

String _scopeDisclosure(
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
      policy.pick('请求的内容', 'the requested content');
  final unavailable = _scopeUnavailable(scope, record.sourceId, label, policy);
  return switch (record.kind) {
    CoachScopeDecisionKind.inScope => policy.pick(
      '该动作在本 App 可用范围内，仍需通过当前安全和训练门禁。',
      'This action is available in the app and must still pass safety and training checks.',
    ),
    CoachScopeDecisionKind.substituted =>
      delivered
          ? policy.pick(
              '$unavailable，用${scope.catalog[record.adoptedActionId!]!.name.of()}练同一部位。',
              '$unavailable. Use ${scope.catalog[record.adoptedActionId!]!.name.of(policy.languageTag)} to train the same area.',
            )
          : policy.pick(
              '$unavailable，可以用${scope.catalog[record.adoptedActionId!]!.name.of()}练同一部位；尚未生成训练计划。',
              '$unavailable. You can use ${scope.catalog[record.adoptedActionId!]!.name.of(policy.languageTag)} to train the same area; no training plan has been generated yet.',
            ),
    CoachScopeDecisionKind.removed => policy.pick(
      '$unavailable，也没有同部位、场景和器械都合适的替代，本次去掉它，未覆盖这部分目标。',
      '$unavailable. No alternative matches the area, setting and equipment, so it is omitted and this part of your goal is not covered.',
    ),
    CoachScopeDecisionKind.outOfScope => policy.pick(
      '${record.sourceId == null ? '这次需求超出本 App 的训练范围。' : '$unavailable。'}${policy.specialty}',
      '${record.sourceId == null ? 'This request is outside this app’s training scope. ' : '$unavailable. '}${policy.specialty}',
    ),
    CoachScopeDecisionKind.insistedUnavailable => policy.pick(
      '$unavailable，不能把它安排进计划。${policy.specialty}',
      '$unavailable and cannot be included in the plan. ${policy.specialty}',
    ),
    CoachScopeDecisionKind.safetyBlocked =>
      '${policy.localizedSafetyMessage} ${policy.specialty}',
    CoachScopeDecisionKind.lockedConflict => policy.pick(
      '$unavailable；你已锁定的动作或剂量不能被暗中替换，请先选择是否调整。${policy.specialty}',
      '$unavailable. Your locked actions or doses cannot be changed silently; choose whether to adjust them first. ${policy.specialty}',
    ),
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
