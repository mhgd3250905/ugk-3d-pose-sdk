/// Lossless facts from completed user turns, independent of request history.
library;

import 'dart:convert';

import '../llm/llm_types.dart';
import 'session_state.dart';

/// A delivery reference, never a nested plan or a saved session snapshot.
class ContextDeliveryRef {
  ContextDeliveryRef({
    required this.type,
    this.planId,
    this.version,
    List<String> actionIds = const [],
  }) : actionIds = List.unmodifiable(actionIds);

  final String type;
  final String? planId;
  final int? version;
  final List<String> actionIds;

  Map<String, Object?> toJson() => {
    'type': type,
    if (planId != null) 'plan_id': planId,
    if (version != null) 'version': version,
    'actionIds': List<String>.of(actionIds),
  };

  factory ContextDeliveryRef.fromJson(Map<String, Object?> json) =>
      ContextDeliveryRef(
        type: json['type'] as String,
        planId: json['plan_id'] as String?,
        version: json['version'] as int?,
        actionIds: (json['actionIds'] as List<Object?>? ?? const [])
            .cast<String>(),
      );
}

/// The current turn answers a question in an earlier completed turn.
/// Its full free-text answer is [CompletedContextTurn.userText].
class ContextAskReplyRef {
  ContextAskReplyRef({
    required this.questionTurn,
    this.questionIndex = 0,
    Map<String, Object?>? answerJson,
  }) : answerJson = answerJson == null ? null : _freezeMap(answerJson);

  final int questionTurn;
  final int questionIndex;
  final Map<String, Object?>? answerJson;

  Map<String, Object?> toJson() => {
    'questionTurn': questionTurn,
    'questionIndex': questionIndex,
    if (answerJson != null) 'answerJson': _thaw(answerJson),
  };

  factory ContextAskReplyRef.fromJson(Map<String, Object?> json) =>
      ContextAskReplyRef(
        questionTurn: json['questionTurn'] as int,
        questionIndex: json['questionIndex'] as int? ?? 0,
        answerJson: json['answerJson'] == null
            ? null
            : _map(json['answerJson']),
      );
}

/// An explicit snapshot of one finished user turn. The caller decides when a
/// turn is finished, including awaiting-user and error outcomes. This record
/// does not capture raw messages, reasoning, receipts, rejected calls, or a
/// whole CoachSessionState, so ledgers cannot recursively embed themselves.
class CompletedContextTurn {
  CompletedContextTurn({
    required this.turn,
    required this.userText,
    required this.finalDeliveryText,
    required Map<String, CoachParamValue> params,
    List<ContextDeliveryRef> deliveries = const [],
    List<Map<String, Object?>> askQuestions = const [],
    this.answeredAsk,
    this.task,
    List<String> picks = const [],
    List<Object?> candidates = const [],
    this.currentPlanRef,
    List<String> loadedSkillNames = const [],
    List<String> seenActionIds = const [],
    this.outcome,
  }) : params = Map.unmodifiable(params),
       deliveries = List.unmodifiable(deliveries),
       askQuestions = List.unmodifiable(askQuestions.map(_freezeMap)),
       picks = List.unmodifiable(picks),
       candidates = List.unmodifiable(candidates.map(_freeze)),
       loadedSkillNames = List.unmodifiable(loadedSkillNames),
       seenActionIds = List.unmodifiable(seenActionIds);

  final int turn;
  final String userText;
  final String finalDeliveryText;
  final List<ContextDeliveryRef> deliveries;
  final List<Map<String, Object?>> askQuestions;
  final ContextAskReplyRef? answeredAsk;
  final Map<String, CoachParamValue> params;
  final CoachTaskState? task;
  final List<String> picks;
  final List<Object?> candidates;
  final ContextDeliveryRef? currentPlanRef;

  /// Historical load facts only; these names do not mean skill text is still
  /// visible in the request and must not authorize disclosure deduplication.
  final List<String> loadedSkillNames;
  final List<String> seenActionIds;
  final String? outcome;

  Map<String, Object?> toJson() => {
    'turn': turn,
    'userText': userText,
    'finalDeliveryText': finalDeliveryText,
    'deliveries': [for (final ref in deliveries) ref.toJson()],
    'askQuestions': [for (final question in askQuestions) _thaw(question)],
    if (answeredAsk != null) 'answeredAsk': answeredAsk!.toJson(),
    'params': {
      for (final entry in params.entries) entry.key: entry.value.toJson(),
    },
    'task': task?.toJson(),
    'picks': List<String>.of(picks),
    'candidates': [for (final candidate in candidates) _thaw(candidate)],
    if (currentPlanRef != null) 'currentPlanRef': currentPlanRef!.toJson(),
    'loadedSkillNames': List<String>.of(loadedSkillNames),
    'seenActionIds': List<String>.of(seenActionIds),
    if (outcome != null) 'outcome': outcome,
  };

  factory CompletedContextTurn.fromJson(
    Map<String, Object?> json,
  ) => CompletedContextTurn(
    turn: json['turn'] as int,
    userText: json['userText'] as String,
    finalDeliveryText: json['finalDeliveryText'] as String,
    deliveries: [
      for (final ref in json['deliveries'] as List<Object?>? ?? const [])
        ContextDeliveryRef.fromJson(_map(ref)),
    ],
    askQuestions: [
      for (final question in json['askQuestions'] as List<Object?>? ?? const [])
        _map(question),
    ],
    answeredAsk: json['answeredAsk'] == null
        ? null
        : ContextAskReplyRef.fromJson(_map(json['answeredAsk'])),
    params: {
      for (final entry in _map(json['params']).entries)
        entry.key: CoachParamValue.fromJson(_map(entry.value)),
    },
    task: json['task'] == null
        ? null
        : CoachTaskState.fromJson(_map(json['task'])),
    picks: (json['picks'] as List<Object?>? ?? const []).cast<String>(),
    candidates: json['candidates'] as List<Object?>? ?? const [],
    currentPlanRef: json['currentPlanRef'] == null
        ? null
        : ContextDeliveryRef.fromJson(_map(json['currentPlanRef'])),
    loadedSkillNames: (json['loadedSkillNames'] as List<Object?>? ?? const [])
        .cast<String>(),
    seenActionIds: (json['seenActionIds'] as List<Object?>? ?? const [])
        .cast<String>(),
    outcome: json['outcome'] as String?,
  );
}

/// Deterministic request view of caller-selected completed turns. This class
/// neither folds a partial turn nor modifies the caller's current messages.
class ContextTurnLedger {
  ContextTurnLedger(List<CompletedContextTurn> turns)
    : turns = List.unmodifiable(turns);

  static const summaryPrefix = '以下是本次会话之前的记录（系统生成）';
  final List<CompletedContextTurn> turns;

  Map<String, Object?> toJson() => {
    'turns': [for (final turn in turns) turn.toJson()],
  };

  factory ContextTurnLedger.fromJson(Map<String, Object?> json) =>
      ContextTurnLedger([
        for (final turn in json['turns'] as List<Object?>? ?? const [])
          CompletedContextTurn.fromJson(_map(turn)),
      ]);

  LlmMessage summaryMessage() =>
      LlmMessage.user('$summaryPrefix\n${jsonEncode(toJson())}');
}

Map<String, Object?> _map(Object? value) =>
    (value as Map<Object?, Object?>).cast<String, Object?>();
Map<String, Object?> _freezeMap(Map<String, Object?> value) =>
    _freeze(value) as Map<String, Object?>;

Object? _freeze(Object? value) {
  if (value is Map<Object?, Object?>) {
    final map = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw ArgumentError('JSON keys must be strings');
      }
      map[entry.key as String] = _freeze(entry.value);
    }
    return Map<String, Object?>.unmodifiable(map);
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(value.map(_freeze));
  }
  if (value == null || value is String || value is bool || value is num) {
    return value;
  }
  throw ArgumentError('Completed turn values must be JSON-compatible');
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
