/// Portable session facts, independent of UI messages and model wire history.
library;

import 'dart:convert';

import '../tools/ask_user.dart';
import 'context_turn_ledger.dart';
import 'session_state.dart';

/// The identity and explanation of one previously delivered recommendation.
/// Names and media are resolved against the host's current catalogue.
class CoachRecommendationSnapshot {
  CoachRecommendationSnapshot({
    required this.messageId,
    required List<String> actionIds,
    required this.note,
  }) : actionIds = List.unmodifiable(actionIds);

  final String messageId;
  final List<String> actionIds;
  final String note;

  Map<String, Object?> toJson() => {
    'messageId': messageId,
    'actionIds': List<String>.of(actionIds),
    'note': note,
  };

  factory CoachRecommendationSnapshot.fromJson(Map<String, Object?> json) {
    final messageId = _string(json['messageId']);
    final ids = _strings(json['actionIds']);
    final note = _string(json['note']);
    if (messageId.isEmpty || ids.isEmpty || ids.any((id) => id.isEmpty)) {
      throw const FormatException('Invalid recommendation reference');
    }
    return CoachRecommendationSnapshot(
      messageId: messageId,
      actionIds: ids,
      note: note,
    );
  }
}

/// Serializable truth for plan, recommendation, chat and interrupted sessions.
///
/// [fromJson] never throws for an unreadable or unsupported snapshot. Such an
/// instance has [isValid] false and lets the controller use legacy history and
/// emit a restore-fallback event. It never retains the corrupted payload.
///
/// No credentials, raw assistant reasoning or old tool messages are captured.
/// [candidates] and [loadedSkillNames] are derived state metadata, serialized
/// inside `sessionState` without changing the legacy CoachSessionState model.
class CoachSessionSnapshot {
  CoachSessionSnapshot({
    required this.sessionState,
    required this.ledger,
    this.pendingQuestion,
    this.pendingQuestionMessageId,
    List<Object?> candidates = const [],
    List<String> loadedSkillNames = const [],
    Map<String, Object?> agentState = const {},
    List<CoachRecommendationSnapshot> recommendations = const [],
  }) : schemaVersion = currentSchemaVersion,
       invalidReason = null,
       candidates = List.unmodifiable(candidates.map(_freeze)),
       loadedSkillNames = List.unmodifiable(loadedSkillNames),
       agentState = _freezeMap(agentState),
       recommendations = List.unmodifiable(recommendations);

  CoachSessionSnapshot._invalid(this.schemaVersion, this.invalidReason)
    : sessionState = CoachSessionState(),
      ledger = ContextTurnLedger(const []),
      pendingQuestion = null,
      pendingQuestionMessageId = null,
      candidates = const [],
      loadedSkillNames = const [],
      agentState = const {},
      recommendations = const [];

  static const currentSchemaVersion = 1;

  final int schemaVersion;
  final CoachSessionState sessionState;
  final ContextTurnLedger ledger;
  final AskUserQuestion? pendingQuestion;
  final String? pendingQuestionMessageId;
  final List<Object?> candidates;
  final List<String> loadedSkillNames;

  /// Serializable continuation markers owned by the SDK, never wire messages.
  final Map<String, Object?> agentState;
  final List<CoachRecommendationSnapshot> recommendations;
  final String? invalidReason;
  bool get isValid => invalidReason == null;

  Map<String, Object?> toJson() => !isValid
      ? {
          'schemaVersion': schemaVersion,
          'invalid': true,
          'invalidReason': invalidReason,
        }
      : {
          'schemaVersion': schemaVersion,
          'sessionState': {
            ...sessionState.toJson(),
            'candidates': _thaw(candidates),
            'loadedSkillNames': List<String>.of(loadedSkillNames),
          },
          'ledger': ledger.toJson(),
          'pendingQuestion': pendingQuestion == null
              ? null
              : {
                  ...pendingQuestion!.toJson(),
                  'language':
                      pendingQuestion!.skipLabel == 'Show suggestions' ||
                          pendingQuestion!.skipLabel == 'Use defaults'
                      ? 'en'
                      : 'zh',
                },
          'pendingQuestionMessageId': pendingQuestionMessageId,
          'agentState': _thaw(agentState),
          'recommendations': [
            for (final reference in recommendations) reference.toJson(),
          ],
        };

  factory CoachSessionSnapshot.fromJson(Object? json) {
    var version = 0;
    try {
      final root = _object(json);
      version = root['schemaVersion'] is int
          ? root['schemaVersion']! as int
          : 0;
      if (version != currentSchemaVersion) {
        return CoachSessionSnapshot._invalid(version, 'unsupported_schema');
      }
      if (root['invalid'] == true) {
        return CoachSessionSnapshot._invalid(version, 'invalid_snapshot');
      }
      // JSON cloning rejects cycles, non-string map keys and non-JSON values.
      final clean = _object(jsonDecode(jsonEncode(root)));
      final state = _object(clean['sessionState']);
      _validateState(state);
      final ledger = _object(clean['ledger']);
      _validateLedger(ledger);
      if (state['completedContextLedger'] != null &&
          !_sameJson(state['completedContextLedger'], ledger)) {
        throw const FormatException('Conflicting completed-turn ledgers');
      }
      final pending = clean['pendingQuestion'] == null
          ? null
          : _question(_object(clean['pendingQuestion']));
      final pendingId = _nullableString(clean['pendingQuestionMessageId']);
      if (pending == null && pendingId != null) {
        throw const FormatException('Missing pending question');
      }
      final references = [
        for (final entry in _array(clean['recommendations']))
          CoachRecommendationSnapshot.fromJson(_object(entry)),
      ];
      if (references.map((entry) => entry.messageId).toSet().length !=
          references.length) {
        throw const FormatException('Duplicate delivery identity');
      }
      final agentState = _object(clean['agentState']);
      _validateAgentState(agentState);
      return CoachSessionSnapshot(
        sessionState: CoachSessionState.fromJson(state),
        ledger: ContextTurnLedger.fromJson(ledger),
        pendingQuestion: pending,
        pendingQuestionMessageId: pendingId,
        candidates: _array(state['candidates']),
        loadedSkillNames: _strings(state['loadedSkillNames']),
        agentState: agentState,
        recommendations: references,
      );
    } on Object {
      return CoachSessionSnapshot._invalid(version, 'invalid_snapshot');
    }
  }
}

void _validateAgentState(Map<String, Object?> state) {
  for (final key in ['turnCount', 'questionsAsked']) {
    if (state.containsKey(key) && _integer(state[key]) < 0) {
      throw const FormatException('Invalid continuation count');
    }
  }
  if (state.containsKey('relativeDurationPolicy') &&
      state['relativeDurationPolicy'] is! bool) {
    throw const FormatException('Invalid duration policy');
  }
  for (final key in ['confirmedPlanContext', 'safetyContext']) {
    if (!state.containsKey(key)) continue;
    final context = _object(state[key]);
    for (final field in ['scene', 'goal', 'language']) {
      if (context.containsKey(field)) _string(context[field]);
    }
    for (final field in ['equipment', 'avoid', 'notes']) {
      if (context.containsKey(field)) _strings(context[field]).toList();
    }
    for (final field in ['level', 'minutes']) {
      if (context.containsKey(field)) _integer(context[field]);
    }
    if (context.containsKey('hasExplicitAvoid') &&
        context['hasExplicitAvoid'] is! bool) {
      throw const FormatException('Invalid explicit safety marker');
    }
  }
  if (state.containsKey('lastConfirmedForm')) {
    for (final value in _object(state['lastConfirmedForm']).values) {
      _strings(value).toList();
    }
  }
  if (state.containsKey('latestExplicitAvoid')) {
    _strings(state['latestExplicitAvoid']).toList();
  }
  for (final key in ['focus', 'goal']) {
    if (state.containsKey(key)) _string(state[key]);
  }
  if (state.containsKey('memoryOrigins')) {
    for (final turns in _object(state['memoryOrigins']).values) {
      for (final value in _array(turns)) {
        if (_integer(value) <= 0) {
          throw const FormatException('Invalid memory-origin turn');
        }
      }
    }
  }
}

void _validateState(Map<String, Object?> state) {
  for (final raw in _array(state['userTurns'])) {
    final turn = _object(raw);
    _integer(turn['turn']);
    _string(turn['text']);
  }
  _validateTask(state['task']);
  _validateParams(_object(state['params']));
  _strings(state['seenActionIds']);
  _strings(state['picks']);
  _array(state['candidates']);
  _strings(state['loadedSkillNames']);
  for (final versions in _object(state['plans']).values) {
    for (final raw in _array(versions)) {
      final version = _object(raw);
      _integer(version['version']);
      _object(version['plan']);
      if (version['estimateSec'] is! num) {
        throw const FormatException('Missing plan duration');
      }
      _array(version['fitLog']);
      if (version['check'] != null) _object(version['check']);
      _nullableInteger(version['createdAtTurn']);
      _nullableString(version['operation']);
    }
  }
  for (final key in [
    'pendingSearchTurn',
    'lastDeliveredVersion',
    'lastDeliveredTurn',
    'lastOperationRequestTurn',
    'consecutiveEmptySearches',
  ]) {
    _nullableInteger(state[key]);
  }
  for (final key in ['activePlanId', 'lastDeliveredPlanId']) {
    _nullableString(state[key]);
  }
  if (state['recommendationHintShown'] != null &&
      state['recommendationHintShown'] is! bool) {
    throw const FormatException('Invalid recommendation hint state');
  }
  if (state['emittedWarningCodes'] != null) {
    _strings(state['emittedWarningCodes']);
  }
  if (state['hostValues'] != null) _object(state['hostValues']);
  if (state['completedContextLedger'] != null) {
    _validateLedger(_object(state['completedContextLedger']));
  }
}

void _validateParams(Map<String, Object?> params) {
  for (final raw in params.values) {
    final param = _object(raw);
    if (!param.containsKey('value')) {
      throw const FormatException('Missing parameter value');
    }
    if (!{
      'user',
      'host',
      'preselect',
      'default',
      'derived',
    }.contains(param['source'])) {
      throw const FormatException('Invalid parameter source');
    }
    _integer(param['turn']);
    _nullableString(param['quote']);
    _nullableString(param['direction']);
    if (param['basedOn'] != null) {
      _validateParams({'basedOn': param['basedOn']});
    }
  }
}

void _validateTask(Object? raw) {
  if (raw == null) return;
  final task = _object(raw);
  _string(task['type']);
  if (task['reused'] is! bool) {
    throw const FormatException('Invalid task reuse');
  }
  for (final raw in _array(task['nodes'])) {
    final node = _object(raw);
    _string(node['id']);
    if (!{'pending', 'current', 'done', 'updated'}.contains(node['status'])) {
      throw const FormatException('Invalid node state');
    }
    _nullableString(node['stamp']);
    _nullableInteger(node['doneAtTurn']);
  }
}

void _validateLedger(Map<String, Object?> ledger) {
  for (final raw in _array(ledger['turns'])) {
    final turn = _object(raw);
    _integer(turn['turn']);
    _string(turn['userText']);
    _string(turn['finalDeliveryText']);
    _validateParams(_object(turn['params']));
    _validateTask(turn['task']);
    _strings(turn['picks']);
    _array(turn['candidates']);
    _strings(turn['seenActionIds']);
    _strings(turn['loadedSkillNames']);
    for (final ref in _array(turn['deliveries'])) {
      _validateRef(_object(ref));
    }
    if (turn['currentPlanRef'] != null) {
      _validateRef(_object(turn['currentPlanRef']));
    }
    for (final question in _array(turn['askQuestions'])) {
      // These records preserve past question JSON; they never reopen a form.
      final map = _object(question);
      _string(map['question']);
      _string(map['mode']);
    }
    if (turn['answeredAsk'] != null) {
      final answer = _object(turn['answeredAsk']);
      _integer(answer['questionTurn']);
      _nullableInteger(answer['questionIndex']);
      if (answer['answerJson'] != null) _object(answer['answerJson']);
    }
    _nullableString(turn['outcome']);
  }
}

void _validateRef(Map<String, Object?> ref) {
  if (!{'plan', 'actions'}.contains(ref['type'])) {
    throw const FormatException('Invalid card reference');
  }
  _strings(ref['actionIds']);
  _nullableString(ref['plan_id']);
  _nullableInteger(ref['version']);
}

AskUserQuestion _question(Map<String, Object?> raw) {
  _string(raw['question']);
  final language = _string(raw['language']);
  if (!{'text', 'choice', 'form'}.contains(raw['mode'])) {
    throw const FormatException('Invalid question mode');
  }
  if (raw['isConfirmation'] == true) {
    final fields = [
      for (final entry in _array(raw['fields'])) _field(_object(entry)),
    ];
    final defaults = _object(raw['defaultSelections']);
    return AskUserQuestion.confirmation(
      question: _string(raw['question']),
      fields: fields,
      focus: _nullableString(raw['focus']),
      language: language,
      defaultSelections: {
        for (final entry in defaults.entries) entry.key: _strings(entry.value),
      },
    );
  }
  if (raw['mode'] == 'choice') {
    _strings(raw['options']);
    if (raw['multiple'] is! bool) {
      throw const FormatException('Invalid choices');
    }
  }
  if (raw['mode'] == 'form') {
    for (final entry in _array(raw['fields'])) {
      _field(_object(entry));
    }
  }
  final checked = AskUserGate.check(jsonEncode(raw), language: language);
  if (!checked.ok) throw const FormatException('Invalid pending question');
  // Stored questions were already admitted. A corrupt payload must not be
  // normalized into a different question while being restored.
  final restored = checked.question!;
  final expected = Map<String, Object?>.of(raw)..remove('language');
  if (!_sameJson(restored.toJson(), expected)) {
    throw const FormatException('Pending question changed during decoding');
  }
  return restored;
}

AskUserField _field(Map<String, Object?> field) => AskUserField(
  key: _string(field['key']),
  label: _string(field['label']),
  options: _strings(field['options']),
  multiple: field['multiple']! as bool,
  preselected: field['preselected'] == null
      ? const []
      : _strings(field['preselected']),
  previousSelections: field['previousSelections'] == null
      ? const []
      : _strings(field['previousSelections']),
  optionsByScene: {
    for (final entry in _object(
      field['optionsByScene'] ?? const <String, Object?>{},
    ).entries)
      entry.key: _strings(entry.value),
  },
);

Map<String, Object?> _object(Object? value) =>
    (value! as Map<Object?, Object?>).cast<String, Object?>();
List<Object?> _array(Object? value) => value! as List<Object?>;
List<String> _strings(Object? value) => _array(value).cast<String>();
String _string(Object? value) => value! as String;
int _integer(Object? value) => value! as int;
String? _nullableString(Object? value) => value as String?;
int? _nullableInteger(Object? value) => value as int?;

Map<String, Object?> _freezeMap(Map<String, Object?> value) =>
    _freeze(value)! as Map<String, Object?>;
Object? _freeze(Object? value) {
  if (value is Map<Object?, Object?>) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        entry.key as String: _freeze(entry.value),
    });
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(value.map(_freeze));
  }
  if (value == null || value is String || value is bool || value is num) {
    return value;
  }
  throw ArgumentError('Snapshot facts must be JSON-compatible');
}

Object? _thaw(Object? value) {
  if (value is Map<Object?, Object?>) {
    return {
      for (final entry in value.entries)
        entry.key as String: _thaw(entry.value),
    };
  }
  if (value is List<Object?>) return [for (final item in value) _thaw(item)];
  return value;
}

bool _sameJson(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _sameJson(a[key], b[key]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        Iterable<int>.generate(a.length).every((i) => _sameJson(a[i], b[i]));
  }
  return a == b;
}
