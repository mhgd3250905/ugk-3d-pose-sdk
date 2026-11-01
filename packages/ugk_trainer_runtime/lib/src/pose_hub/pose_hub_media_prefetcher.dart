import 'dart:async';

import 'package:ugk_coach/ugk_coach.dart';

import 'pose_hub_media_preparation.dart';

/// Session-scoped scheduling around the host's verified download/cache.
/// At most two actions prepare at once. Failed attempts retry quietly with
/// bounded exponential backoff; training clocks never depend on this queue.
final class PoseHubMediaPrefetcher implements PoseHubMediaPreparer {
  PoseHubMediaPrefetcher(this.host, {Future<void>? afterCancellation})
    : _startBarrier = afterCancellation ?? Future<void>.value(),
      _canStart = afterCancellation == null {
    if (!_canStart) {
      unawaited(
        _startBarrier.then((_) {
          _canStart = true;
          _pump();
        }),
      );
    }
  }

  final PoseHubMediaPreparer host;
  final _entries = <String, _Entry>{};
  final _queue = <_Entry>[];
  final Future<void> _startBarrier;
  final _pendingStops = <Future<void>>{};
  Future<void> _cancellation = Future<void>.value();
  bool _canStart;
  Future<void> get cancellationComplete => _cancellation;
  int _active = 0;
  bool _disposed = false;
  bool _pumping = false;

  String _key(PoseHubPackAction action) =>
      '${action.id}:'
      '${action.files.entries.map((e) => '${e.key}:${e.value.path}:${e.value.bytes}:${e.value.sha256}').join('|')}';

  _Entry _entry(PoseHubPackAction action) =>
      _entries.putIfAbsent(_key(action), () => _Entry(action));

  /// Call with the visible/upcoming action first, followed by plan order.
  /// In-flight verified downloads are retained rather than restarted.
  void prioritize(Iterable<PoseHubPackAction> actions) {
    if (_disposed) return;
    final ordered = <_Entry>[];
    for (final action in actions) {
      final entry = _entry(action);
      if (!ordered.contains(entry)) ordered.add(entry);
    }
    for (final entry in _entries.values) {
      entry.rank = (1 << 20) + entry.rank;
    }
    for (final (rank, entry) in ordered.indexed) {
      entry.rank = rank;
      if (_canQueue(entry) && !_queue.contains(entry)) _queue.add(entry);
    }
    if (ordered.isNotEmpty) _makeRoomFor(ordered.first);
    _sortQueue();
    _pump();
  }

  void _makeRoomFor(_Entry current) {
    if (_canQueue(current) && current.rank == 0 && _active == 2) {
      final running = _entries.values.where((e) => e.running).toList()
        ..sort((a, b) => b.rank.compareTo(a.rank));
      if (running.isEmpty) return;
      final retired = running.first;
      if (retired.rank <= current.rank) return;
      _retire(retired, retired.controller!);
    }
  }

  bool _canQueue(_Entry entry) =>
      !entry.running &&
      !entry.retiring &&
      entry.ready == null &&
      entry.retry == null;

  @override
  Stream<PoseHubMediaPreparationEvent> prepareAction(PoseHubPackAction action) {
    late StreamController<PoseHubMediaPreparationEvent> output;
    StreamSubscription<PoseHubMediaPreparationEvent>? subscription;
    output = StreamController<PoseHubMediaPreparationEvent>(
      sync: true,
      onListen: () {
        if (_disposed) {
          unawaited(output.close());
          return;
        }
        final entry = _entry(action);
        if (entry.ready case final ready?) {
          output.add(ready);
          unawaited(output.close());
          return;
        }
        subscription = entry.events.stream.listen((event) {
          output.add(event);
          if (event is PoseHubMediaReady) unawaited(output.close());
        }, onDone: () => unawaited(output.close()));
        // Install the consumer before starting a possibly synchronous host.
        _queue.remove(entry);
        if (_canQueue(entry)) _queue.add(entry);
        _sortQueue();
        _pump();
      },
      onCancel: () => subscription?.cancel(),
    );
    return output.stream;
  }

  void _sortQueue() => _queue.sort((a, b) => a.rank.compareTo(b.rank));

  void _retire(_Entry entry, PoseHubMediaPreparationController controller) {
    entry.controller = null;
    entry.running = false;
    entry.retiring = true;
    // The slot remains occupied until asynchronous host cancellation finishes.
    controller.cancel();
    final stop = Future<void>.microtask(() async {
      controller.dispose();
      await controller.cancellationComplete;
      entry.retiring = false;
      _active--;
      if (_disposed) return;
      if (_canQueue(entry) && !_queue.contains(entry)) _queue.add(entry);
      _sortQueue();
      _pump();
    });
    _pendingStops.add(stop);
    unawaited(stop.whenComplete(() => _pendingStops.remove(stop)));
  }

  void _pump() {
    if (_pumping || _disposed || !_canStart) return;
    _pumping = true;
    try {
      while (_active < 2 && _queue.isNotEmpty && !_disposed) {
        final entry = _queue.removeAt(0);
        if (!_canQueue(entry)) continue;
        entry.running = true;
        _active++;
        final controller = PoseHubMediaPreparationController();
        entry.controller = controller;
        controller.addListener(() => _changed(entry, controller));
        controller.start(host, entry.action);
      }
    } finally {
      _pumping = false;
    }
  }

  void _changed(_Entry entry, PoseHubMediaPreparationController controller) {
    if (_disposed || entry.controller != controller) return;
    final state = controller.state;
    if (state.status == PoseHubMediaPreparationStatus.preparing) {
      if (state.progress case final progress?) entry.events.add(progress);
      return;
    }
    if (state.status != PoseHubMediaPreparationStatus.ready &&
        state.status != PoseHubMediaPreparationStatus.failed) {
      return;
    }
    _retire(entry, controller);
    if (_disposed) return;
    if (state.mediaBaseUri case final base?) {
      final ready = PoseHubMediaReady(mediaBaseUri: base);
      entry.ready = ready;
      entry.events.add(ready);
    } else {
      entry.failures++;
      final seconds = (1 << entry.failures.clamp(1, 5)).clamp(2, 30);
      entry.retry = Timer(Duration(seconds: seconds), () {
        entry.retry = null;
        if (_disposed) return;
        if (!_queue.contains(entry)) _queue.add(entry);
        _makeRoomFor(entry);
        _sortQueue();
        _pump();
      });
    }
    _pump();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _queue.clear();
    final stops = <Future<void>>[_startBarrier, ..._pendingStops];
    for (final entry in _entries.values) {
      entry.retry?.cancel();
      entry.controller?.dispose();
      if (entry.controller case final controller?) {
        stops.add(controller.cancellationComplete);
      }
      unawaited(entry.events.close());
    }
    _entries.clear();
    _cancellation = Future.wait<void>(stops).then((_) {});
  }
}

final class _Entry {
  _Entry(this.action);
  final PoseHubPackAction action;
  final events = StreamController<PoseHubMediaPreparationEvent>.broadcast(
    sync: true,
  );
  PoseHubMediaPreparationController? controller;
  PoseHubMediaReady? ready;
  Timer? retry;
  bool running = false;
  bool retiring = false;
  int failures = 0;
  int rank = 0;
}
