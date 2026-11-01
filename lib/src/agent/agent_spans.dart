/// Content-free, synchronous timing observations for one Agent instance.
library;

import 'dart:async';

/// Operations measured independently; nested durations must not be added twice.
enum CoachAgentSpanKind { http, tool, fit, recompile }

/// An immutable completed observation, measured on a monotonic clock.
///
/// An HTTP span covers the actual request/response attempt, not a separately
/// inferred network, queue or model duration. Keep attributes to counters,
/// stable identifiers and result codes; never put request bodies or secrets here.
class CoachAgentSpan {
  CoachAgentSpan._({
    required this.id,
    required this.kind,
    required this.name,
    required this.startedMicros,
    required this.elapsedMicros,
    required this.ok,
    required this.attributes,
    this.parentId,
    this.turnId,
    this.taskId,
    this.epoch,
    this.toolCallId,
    this.httpOrdinal,
    this.reason,
  });

  final int id;
  final int? parentId;
  final CoachAgentSpanKind kind;
  final String name;
  final int startedMicros;
  final int elapsedMicros;
  final bool ok;
  final String? reason;
  final String? turnId;
  final String? taskId;
  final int? epoch;
  final String? toolCallId;
  final int? httpOrdinal;
  final Map<String, Object?> attributes;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'spanId': id,
    if (parentId != null) 'parentSpanId': parentId,
    'kind': kind.name,
    'name': name,
    'startedMicros': startedMicros,
    'elapsedMicros': elapsedMicros,
    'ok': ok,
    if (reason != null) 'reason': reason,
    if (turnId != null) 'turnId': turnId,
    if (taskId != null) 'taskId': taskId,
    if (epoch != null) 'epoch': epoch,
    if (toolCallId != null) 'toolCallId': toolCallId,
    if (httpOrdinal != null) 'httpOrdinal': httpOrdinal,
    'attributes': _copyJson(attributes),
  };
}

/// Receives a completed span without I/O or awaiting on the Agent path.
typedef CoachAgentSpanObserver = void Function(CoachAgentSpan span);

/// Location inherited by lower-level HTTP/fitting code, without core coupling.
class CoachAgentSpanContext {
  const CoachAgentSpanContext({
    this.turnId,
    this.taskId,
    this.epoch,
    this.toolCallId,
    this.parentId,
    this.httpOrdinal,
  });

  final String? turnId;
  final String? taskId;
  final int? epoch;
  final String? toolCallId;
  final int? parentId;
  final int? httpOrdinal;
}

/// A lightweight recorder. Omitting [onSpan] disables timing reads and events.
///
/// Observer exceptions are isolated, so diagnostics cannot alter tool results,
/// request retries, cancellation, fitting, step limits or delivery decisions.
/// The optional [elapsedMicros] clock is for deterministic unit tests.
class CoachAgentSpanRecorder {
  CoachAgentSpanRecorder({
    CoachAgentSpanObserver? onSpan,
    int Function()? elapsedMicros,
  }) : _onSpan = onSpan {
    final watch = Stopwatch()..start();
    _elapsedMicros = elapsedMicros ?? () => watch.elapsedMicroseconds;
  }

  final CoachAgentSpanObserver? _onSpan;
  late final int Function() _elapsedMicros;
  var _nextId = 0;
  static final _recorderKey = Object();
  static final _contextKey = Object();

  static CoachAgentSpanRecorder? get current =>
      Zone.current[_recorderKey] as CoachAgentSpanRecorder?;

  static CoachAgentSpanContext get currentContext =>
      Zone.current[_contextKey] as CoachAgentSpanContext? ??
      const CoachAgentSpanContext();

  /// Runs synchronous or asynchronous work with inherited observation context.
  /// Different recorder instances never inherit one another's identifiers.
  T run<T>(
    T Function() body, {
    String? turnId,
    String? taskId,
    int? epoch,
    String? toolCallId,
    int? parentId,
    int? httpOrdinal,
  }) {
    if (_onSpan == null) {
      if (current == null) return body();
      return runZoned(
        body,
        zoneValues: {_recorderKey: null, _contextKey: null},
      );
    }
    final parent = identical(current, this)
        ? currentContext
        : const CoachAgentSpanContext();
    final context = CoachAgentSpanContext(
      turnId: turnId ?? parent.turnId,
      taskId: taskId ?? parent.taskId,
      epoch: epoch ?? parent.epoch,
      toolCallId: toolCallId ?? parent.toolCallId,
      parentId: parentId ?? parent.parentId,
      httpOrdinal: httpOrdinal ?? parent.httpOrdinal,
    );
    return runZoned(
      body,
      zoneValues: {_recorderKey: this, _contextKey: context},
    );
  }

  /// Optional observation from code that has no dependency on an Agent object.
  static CoachAgentSpanHandle? startCurrent(
    CoachAgentSpanKind kind,
    String name, {
    Map<String, Object?> attributes = const {},
  }) => current?.start(kind, name, attributes: attributes);

  CoachAgentSpanHandle start(
    CoachAgentSpanKind kind,
    String name, {
    int? parentId,
    String? turnId,
    String? taskId,
    int? epoch,
    String? toolCallId,
    int? httpOrdinal,
    Map<String, Object?> attributes = const {},
  }) {
    final parent = identical(current, this)
        ? currentContext
        : const CoachAgentSpanContext();
    return CoachAgentSpanHandle._(
      recorder: this,
      id: _onSpan == null ? 0 : ++_nextId,
      kind: kind,
      name: name,
      startedMicros: _onSpan == null ? 0 : _elapsedMicros(),
      parentId: parentId ?? parent.parentId,
      turnId: turnId ?? parent.turnId,
      taskId: taskId ?? parent.taskId,
      epoch: epoch ?? parent.epoch,
      toolCallId: toolCallId ?? parent.toolCallId,
      httpOrdinal: httpOrdinal ?? parent.httpOrdinal,
      attributes: _onSpan == null ? const {} : _freezeMap(attributes),
    );
  }
}

/// End exactly once, usually in a `finally` block around the real operation.
class CoachAgentSpanHandle {
  CoachAgentSpanHandle._({
    required CoachAgentSpanRecorder recorder,
    required this.id,
    required this.kind,
    required this.name,
    required this.startedMicros,
    required this.attributes,
    this.parentId,
    this.turnId,
    this.taskId,
    this.epoch,
    this.toolCallId,
    this.httpOrdinal,
  }) : _recorder = recorder;

  final CoachAgentSpanRecorder _recorder;
  final int id;
  final int? parentId;
  final CoachAgentSpanKind kind;
  final String name;
  final int startedMicros;
  final String? turnId;
  final String? taskId;
  final int? epoch;
  final String? toolCallId;
  final int? httpOrdinal;
  final Map<String, Object?> attributes;
  CoachAgentSpan? _completed;
  var _finished = false;

  /// Completes the observation once. A repeated call returns the first result.
  /// Returns null when observation was disabled.
  CoachAgentSpan? finish({
    bool ok = true,
    String? reason,
    Map<String, Object?> attributes = const {},
  }) {
    if (_finished) return _completed;
    _finished = true;
    final observer = _recorder._onSpan;
    if (observer == null) return null;
    final elapsed = _recorder._elapsedMicros() - startedMicros;
    final span = CoachAgentSpan._(
      id: id,
      parentId: parentId,
      kind: kind,
      name: name,
      startedMicros: startedMicros,
      elapsedMicros: elapsed < 0 ? 0 : elapsed,
      ok: ok,
      reason: reason,
      turnId: turnId,
      taskId: taskId,
      epoch: epoch,
      toolCallId: toolCallId,
      httpOrdinal: httpOrdinal,
      attributes: _freezeMap({...this.attributes, ...attributes}),
    );
    _completed = span;
    try {
      observer(span);
    } on Object {
      // Observability is outside every Agent decision and retry gate.
    }
    return span;
  }
}

Map<String, Object?> _freezeMap(Map<String, Object?> map) => Map.unmodifiable({
  for (final entry in map.entries) entry.key: _freezeJson(entry.value),
});

Object? _freezeJson(Object? value) => switch (value) {
  null || String() || bool() || int() => value,
  double() => value.isFinite ? value : null,
  List<Object?>() => List.unmodifiable(value.map(_freezeJson)),
  Map<String, Object?>() => _freezeMap(value),
  _ => null,
};

Object? _copyJson(Object? value) => switch (value) {
  List<Object?>() => value.map(_copyJson).toList(),
  Map<String, Object?>() => {
    for (final entry in value.entries) entry.key: _copyJson(entry.value),
  },
  _ => value,
};
