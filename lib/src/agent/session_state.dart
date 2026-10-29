/// Serializable, immutable snapshots of the structured coaching session.
library;

/// One accepted user message, preserving the original input and its sequence.
class CoachUserTurn {
  const CoachUserTurn({required this.turn, required this.text});

  final int turn;
  final String text;

  Map<String, Object?> toJson() => {'turn': turn, 'text': text};

  factory CoachUserTurn.fromJson(Map<String, Object?> json) =>
      CoachUserTurn(turn: json['turn'] as int, text: json['text'] as String);
}

/// A parameter and the source information supplied when it was set.
class CoachParamValue {
  CoachParamValue({
    required Object? value,
    required this.source,
    this.quote,
    required this.turn,
    this.direction,
    this.basedOn,
  }) : value = _freeze(value);

  final Object? value;
  final String source;
  final String? quote;
  final int turn;
  final String? direction;
  final CoachParamValue? basedOn;

  Map<String, Object?> toJson() => {
    'value': _thaw(value),
    'source': source,
    if (quote != null) 'quote': quote,
    'turn': turn,
    if (direction != null) 'direction': direction,
    if (basedOn != null) 'basedOn': basedOn!.toJson(),
  };

  factory CoachParamValue.fromJson(Map<String, Object?> json) =>
      CoachParamValue(
        value: json['value'],
        source: json['source'] as String,
        quote: json['quote'] as String?,
        turn: json['turn'] as int,
        direction: json['direction'] as String?,
        basedOn: json['basedOn'] == null
            ? null
            : CoachParamValue.fromJson(_map(json['basedOn'])),
      );
}

class CoachNodeState {
  const CoachNodeState({
    required this.id,
    required this.status,
    this.stamp,
    this.doneAtTurn,
  });

  final String id;
  final String status;
  final String? stamp;
  final int? doneAtTurn;

  CoachNodeState copyWith({
    String? status,
    String? stamp,
    int? doneAtTurn,
    bool clearStamp = false,
    bool clearDoneAtTurn = false,
  }) => CoachNodeState(
    id: id,
    status: status ?? this.status,
    stamp: clearStamp ? null : stamp ?? this.stamp,
    doneAtTurn: clearDoneAtTurn ? null : doneAtTurn ?? this.doneAtTurn,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'status': status,
    'stamp': stamp,
    'doneAtTurn': doneAtTurn,
  };

  factory CoachNodeState.fromJson(Map<String, Object?> json) => CoachNodeState(
    id: json['id'] as String,
    status: json['status'] as String,
    stamp: json['stamp'] as String?,
    doneAtTurn: json['doneAtTurn'] as int?,
  );
}

class CoachTaskState {
  CoachTaskState({
    required this.type,
    required List<CoachNodeState> nodes,
    required this.reused,
  }) : nodes = List.unmodifiable(nodes);

  final String type;
  final List<CoachNodeState> nodes;
  final bool reused;

  CoachTaskState copyWith({List<CoachNodeState>? nodes, bool? reused}) =>
      CoachTaskState(
        type: type,
        nodes: nodes ?? this.nodes,
        reused: reused ?? this.reused,
      );

  Map<String, Object?> toJson() => {
    'type': type,
    'nodes': [for (final node in nodes) node.toJson()],
    'reused': reused,
  };

  factory CoachTaskState.fromJson(Map<String, Object?> json) => CoachTaskState(
    type: json['type'] as String,
    nodes: [
      for (final node in json['nodes'] as List<Object?>)
        CoachNodeState.fromJson(_map(node)),
    ],
    reused: json['reused'] as bool,
  );
}

/// A version of a plan, including its data and any resulting checks.
class CoachPlanVersion {
  CoachPlanVersion({
    required this.version,
    required Map<String, Object?> plan,
    required this.estimateSec,
    required List<Object?> fitLog,
    Map<String, Object?>? check,
    this.createdAtTurn,
    this.operation,
  }) : plan = _freezeMap(plan),
       fitLog = List.unmodifiable(fitLog.map(_freeze)),
       check = check == null ? null : _freezeMap(check);

  final int version;
  final Map<String, Object?> plan;
  final num estimateSec;
  final List<Object?> fitLog;
  final Map<String, Object?>? check;
  final int? createdAtTurn;
  final String? operation;

  Map<String, Object?> toJson() => {
    'version': version,
    'plan': _thaw(plan),
    'estimateSec': estimateSec,
    'fitLog': _thaw(fitLog),
    'check': _thaw(check),
    if (createdAtTurn != null) 'createdAtTurn': createdAtTurn,
    if (operation != null) 'operation': operation,
  };

  factory CoachPlanVersion.fromJson(Map<String, Object?> json) =>
      CoachPlanVersion(
        version: json['version'] as int,
        plan: _map(json['plan']),
        estimateSec: json['estimateSec'] as num,
        fitLog: (json['fitLog'] as List<Object?>? ?? const []),
        check: json['check'] == null ? null : _map(json['check']),
        createdAtTurn: json['createdAtTurn'] as int?,
        operation: json['operation'] as String?,
      );
}

/// The saved host plan from which the current discussion was imported.
///
/// [baseVersion] stays at the version selected by the host while edits append
/// later SDK versions, so the host can identify the saved plan being revised.
class CoachSavedPlanRef {
  const CoachSavedPlanRef({
    required this.externalId,
    required this.baseVersion,
  });

  final String externalId;
  final int baseVersion;

  Map<String, Object?> toJson() => {
    'externalId': externalId,
    'baseVersion': baseVersion,
  };

  factory CoachSavedPlanRef.fromJson(Map<String, Object?> json) =>
      CoachSavedPlanRef(
        externalId: json['externalId'] as String,
        baseVersion: json['baseVersion'] as int,
      );

  @override
  bool operator ==(Object other) =>
      other is CoachSavedPlanRef &&
      other.externalId == externalId &&
      other.baseVersion == baseVersion;

  @override
  int get hashCode => Object.hash(externalId, baseVersion);
}

/// Complete state: messages, fixed task progress, sourced conditions and plans.
///
/// Collection inputs and exported JSON are copied recursively, so callers
/// cannot mutate an already saved snapshot through a nested value.
class CoachSessionState {
  CoachSessionState({
    List<CoachUserTurn> userTurns = const [],
    this.task,
    Map<String, CoachParamValue> params = const {},
    Set<String> seenActionIds = const {},
    this.consecutiveEmptySearches = 0,
    this.recommendationHintShown = false,
    this.pendingSearchTurn,
    Set<String> emittedWarningCodes = const {},
    List<String> picks = const [],
    Map<String, List<CoachPlanVersion>> plans = const {},
    this.activePlanId,
    this.focusPlanId,
    this.savedRef,
    this.lastDeliveredPlanId,
    this.lastDeliveredVersion,
    this.lastDeliveredTurn,
    this.lastOperationRequestTurn,
    this.legacyPlanFallback = false,
    Map<String, Object?> hostValues = const {},
    Map<String, Object?>? completedContextLedger,
  }) : userTurns = List.unmodifiable(userTurns),
       params = Map.unmodifiable(params),
       seenActionIds = Set.unmodifiable(seenActionIds),
       emittedWarningCodes = Set.unmodifiable(emittedWarningCodes),
       picks = List.unmodifiable(picks),
       plans = Map.unmodifiable({
         for (final entry in plans.entries)
           entry.key: List<CoachPlanVersion>.unmodifiable(entry.value),
       }),
       hostValues = _freezeMap(hostValues),
       completedContextLedger = completedContextLedger == null
           ? null
           : _freezeMap(completedContextLedger);

  final List<CoachUserTurn> userTurns;
  final CoachTaskState? task;
  final Map<String, CoachParamValue> params;
  final Set<String> seenActionIds;

  /// Consecutive successful searches that returned no previously unseen IDs.
  final int consecutiveEmptySearches;

  /// Whether this task has already suggested broadening a sparse body search.
  final bool recommendationHintShown;
  final int? pendingSearchTurn;
  final Set<String> emittedWarningCodes;
  final List<String> picks;
  final Map<String, List<CoachPlanVersion>> plans;

  /// Current draft plan, independent of retained previous task plans.
  final String? activePlanId;

  /// The external plan currently being discussed, retained until cleared.
  final String? focusPlanId;
  final CoachSavedPlanRef? savedRef;

  final String? lastDeliveredPlanId;
  final int? lastDeliveredVersion;
  final int? lastDeliveredTurn;

  /// Execution time of a literally supported operation request, separate from
  /// the immutable proof of an unchanged operation value in [params].
  final int? lastOperationRequestTurn;

  /// True only for restored snapshots written before activePlanId existed.
  final bool legacyPlanFallback;

  /// Last values explicitly supplied by the host, used to distinguish a new
  /// host update from a repeated context after a user adjustment.
  final Map<String, Object?> hostValues;

  /// Completed-turn facts only; never raw model reasoning or tool history.
  final Map<String, Object?>? completedContextLedger;

  CoachSessionState copyWith({
    List<CoachUserTurn>? userTurns,
    CoachTaskState? task,
    bool clearTask = false,
    Map<String, CoachParamValue>? params,
    Set<String>? seenActionIds,
    int? consecutiveEmptySearches,
    bool? recommendationHintShown,
    int? pendingSearchTurn,
    bool clearPendingSearchTurn = false,
    Set<String>? emittedWarningCodes,
    List<String>? picks,
    Map<String, List<CoachPlanVersion>>? plans,
    String? activePlanId,
    bool clearActivePlanId = false,
    String? focusPlanId,
    CoachSavedPlanRef? savedRef,
    bool clearPlanFocus = false,
    String? lastDeliveredPlanId,
    int? lastDeliveredVersion,
    int? lastDeliveredTurn,
    int? lastOperationRequestTurn,
    bool clearLastDelivered = false,
    Map<String, Object?>? hostValues,
    Map<String, Object?>? completedContextLedger,
    bool clearCompletedContextLedger = false,
  }) => CoachSessionState(
    userTurns: userTurns ?? this.userTurns,
    task: clearTask ? null : task ?? this.task,
    params: params ?? this.params,
    seenActionIds: seenActionIds ?? this.seenActionIds,
    consecutiveEmptySearches:
        consecutiveEmptySearches ?? this.consecutiveEmptySearches,
    recommendationHintShown:
        recommendationHintShown ?? this.recommendationHintShown,
    pendingSearchTurn: clearPendingSearchTurn
        ? null
        : pendingSearchTurn ?? this.pendingSearchTurn,
    emittedWarningCodes: emittedWarningCodes ?? this.emittedWarningCodes,
    picks: picks ?? this.picks,
    plans: plans ?? this.plans,
    activePlanId: clearActivePlanId ? null : activePlanId ?? this.activePlanId,
    focusPlanId: clearPlanFocus ? null : focusPlanId ?? this.focusPlanId,
    savedRef: clearPlanFocus ? null : savedRef ?? this.savedRef,
    lastDeliveredPlanId: clearLastDelivered
        ? null
        : lastDeliveredPlanId ?? this.lastDeliveredPlanId,
    lastDeliveredVersion: clearLastDelivered
        ? null
        : lastDeliveredVersion ?? this.lastDeliveredVersion,
    lastDeliveredTurn: clearLastDelivered
        ? null
        : lastDeliveredTurn ?? this.lastDeliveredTurn,
    lastOperationRequestTurn:
        lastOperationRequestTurn ?? this.lastOperationRequestTurn,
    legacyPlanFallback: clearActivePlanId || activePlanId != null
        ? false
        : legacyPlanFallback,
    hostValues: hostValues ?? this.hostValues,
    completedContextLedger: clearCompletedContextLedger
        ? null
        : completedContextLedger ?? this.completedContextLedger,
  );

  CoachSessionState appendUserTurn(String text) => copyWith(
    userTurns: [
      ...userTurns,
      CoachUserTurn(
        turn: userTurns.isEmpty ? 1 : userTurns.last.turn + 1,
        text: text,
      ),
    ],
  );

  Map<String, Object?> toJson() => {
    'userTurns': [for (final turn in userTurns) turn.toJson()],
    'task': task?.toJson(),
    'params': {
      for (final entry in params.entries) entry.key: entry.value.toJson(),
    },
    'seenActionIds': seenActionIds.toList(),
    if (consecutiveEmptySearches != 0)
      'consecutiveEmptySearches': consecutiveEmptySearches,
    if (recommendationHintShown) 'recommendationHintShown': true,
    if (pendingSearchTurn != null) 'pendingSearchTurn': pendingSearchTurn,
    if (emittedWarningCodes.isNotEmpty)
      'emittedWarningCodes': emittedWarningCodes.toList(),
    'picks': List<String>.of(picks),
    'plans': {
      for (final entry in plans.entries)
        entry.key: [for (final version in entry.value) version.toJson()],
    },
    if (!legacyPlanFallback || activePlanId != null)
      'activePlanId': activePlanId,
    if (focusPlanId != null) 'focusPlanId': focusPlanId,
    if (savedRef != null) 'savedRef': savedRef!.toJson(),
    if (lastDeliveredPlanId != null) 'lastDeliveredPlanId': lastDeliveredPlanId,
    if (lastDeliveredVersion != null)
      'lastDeliveredVersion': lastDeliveredVersion,
    if (lastDeliveredTurn != null) 'lastDeliveredTurn': lastDeliveredTurn,
    if (lastOperationRequestTurn != null)
      'lastOperationRequestTurn': lastOperationRequestTurn,
    if (hostValues.isNotEmpty) 'hostValues': _thaw(hostValues),
    if (completedContextLedger != null)
      'completedContextLedger': _thaw(completedContextLedger),
  };

  factory CoachSessionState.fromJson(Map<String, Object?> json) =>
      CoachSessionState(
        userTurns: [
          for (final turn in json['userTurns'] as List<Object?>? ?? const [])
            CoachUserTurn.fromJson(_map(turn)),
        ],
        task: json['task'] == null
            ? null
            : CoachTaskState.fromJson(_map(json['task'])),
        params: {
          for (final entry in _map(json['params'] ?? const {}).entries)
            entry.key: CoachParamValue.fromJson(_map(entry.value)),
        },
        seenActionIds: (json['seenActionIds'] as List<Object?>? ?? const [])
            .cast<String>()
            .toSet(),
        consecutiveEmptySearches: json['consecutiveEmptySearches'] as int? ?? 0,
        recommendationHintShown:
            json['recommendationHintShown'] as bool? ?? false,
        pendingSearchTurn: json['pendingSearchTurn'] as int?,
        emittedWarningCodes:
            (json['emittedWarningCodes'] as List<Object?>? ?? const [])
                .cast<String>()
                .toSet(),
        picks: (json['picks'] as List<Object?>? ?? const []).cast<String>(),
        plans: {
          for (final entry in _map(json['plans'] ?? const {}).entries)
            entry.key: [
              for (final version in entry.value as List<Object?>)
                CoachPlanVersion.fromJson(_map(version)),
            ],
        },
        activePlanId: json['activePlanId'] as String?,
        focusPlanId: json['focusPlanId'] as String?,
        savedRef: json['savedRef'] == null
            ? null
            : CoachSavedPlanRef.fromJson(_map(json['savedRef'])),
        lastDeliveredPlanId: json['lastDeliveredPlanId'] as String?,
        lastDeliveredVersion: json['lastDeliveredVersion'] as int?,
        lastDeliveredTurn: json['lastDeliveredTurn'] as int?,
        lastOperationRequestTurn: json['lastOperationRequestTurn'] as int?,
        legacyPlanFallback: !json.containsKey('activePlanId'),
        hostValues: _map(json['hostValues'] ?? const {}),
        completedContextLedger: json['completedContextLedger'] == null
            ? null
            : _map(json['completedContextLedger']),
      );
}

Map<String, Object?> _map(Object? value) =>
    (value as Map<Object?, Object?>).cast<String, Object?>();

Map<String, Object?> _freezeMap(Map<String, Object?> value) =>
    _freeze(value) as Map<String, Object?>;

Object? _freeze(Object? value) {
  if (value is Map<Object?, Object?>) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw ArgumentError('JSON object keys must be strings');
      }
      result[entry.key as String] = _freeze(entry.value);
    }
    return Map<String, Object?>.unmodifiable(result);
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(value.map(_freeze));
  }
  if (value == null || value is String || value is bool || value is num) {
    return value;
  }
  throw ArgumentError('State values must be JSON-compatible');
}

Object? _thaw(Object? value) {
  if (value is Map<Object?, Object?>) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key as String: _thaw(entry.value),
    };
  }
  if (value is List<Object?>) return [for (final item in value) _thaw(item)];
  return value;
}
