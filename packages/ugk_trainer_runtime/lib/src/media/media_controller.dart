// Ported from SmartFit@e8981ee lib/core/media/media_controller.dart (3D-Body
// DrillMediaController / DrillPlaybackCoordinator). Unchanged.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

typedef MediaCommandSink = void Function(Map<String, Object?> command);

/// Owns only demonstration playback. No training clock or records are exposed.
class DrillMediaController extends ChangeNotifier {
  MediaCommandSink? _sink;
  bool _active = true;
  bool _disposed = false;
  bool _wantsPlay = false;
  bool ready = false;
  bool hasFrame = false;
  bool failed = false;
  bool playing = false;
  Uint8List? _frameBytes;
  Completer<Uint8List?>? _capturePending;
  int _captureId = 0;
  Completer<double?>? _positionPending;
  int _positionId = 0;

  /// A bounded static capture from a decoded video frame, never a live player.
  Uint8List? get frameBytes => _frameBytes;
  bool get active => _active;
  bool get wantsPlay => _wantsPlay;

  void attach(MediaCommandSink sink) => _sink = sink;
  void detach(MediaCommandSink sink) {
    if (_sink == sink) _sink = null;
  }

  void setActive(bool value) {
    if (_active == value) return;
    _active = value;
    if (!value) _wantsPlay = false;
    _sink?.call({'type': 'active', 'value': value});
  }

  void pause() {
    _wantsPlay = false;
    _sink?.call({'type': 'pause'});
  }

  void toggle() {
    if (!_active || _disposed) return;
    _wantsPlay = !_wantsPlay;
    if (ready) _sink?.call({'type': _wantsPlay ? 'play' : 'pause'});
    notifyListeners();
  }

  void receive(Map<Object?, Object?> value) {
    if (_disposed || value['source'] != 'drill-media') return;
    switch (value['type']) {
      case 'ready':
        ready = true;
        _sink?.call({'type': 'active', 'value': _active});
        if (_active && _wantsPlay) _sink?.call({'type': 'play'});
      case 'error':
        failed = true;
        hasFrame = false;
        playing = false;
        _wantsPlay = false;
      case 'first-frame':
        if (failed || hasFrame) return;
        hasFrame = true;
      case 'frame':
        if (!hasFrame || failed || value['captureId'] != _captureId) return;
        final pending = _capturePending;
        if (pending == null || pending.isCompleted) return;
        final bytes = _capture(value['frame']);
        pending.complete(bytes);
      case 'state':
        playing = value['playing'] == true;
        _wantsPlay = playing;
      case 'position':
        if (value['requestId'] != _positionId) return;
        final pending = _positionPending;
        if (pending == null || pending.isCompleted) return;
        final time = value['time'];
        pending.complete(
          time is num && time.isFinite && time >= 0 ? time.toDouble() : null,
        );
        // A one-shot inspection must not repaint the player or alter playback.
        return;
      default:
        return;
    }
    notifyListeners();
  }

  void reportError() => receive({'source': 'drill-media', 'type': 'error'});

  /// Query the decoder's current time only on demand, never on a frame timer.
  /// An unavailable/stale backend reports null rather than a guessed zero.
  Future<double?> readPosition() async {
    if (_disposed || !ready || !hasFrame || failed || _sink == null) {
      return null;
    }
    final existing = _positionPending;
    if (existing != null) return existing.future;
    final pending = Completer<double?>();
    _positionPending = pending;
    final request = ++_positionId;
    _sink?.call({'type': 'position', 'requestId': request});
    try {
      return await pending.future.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {
          if (!pending.isCompleted) pending.complete(null);
          return null;
        },
      );
    } finally {
      if (identical(_positionPending, pending)) _positionPending = null;
    }
  }

  Uint8List? _capture(Object? value) {
    // A bounded 480px JPEG/alpha PNG is normally small. Ignore oversized
    // platform messages without turning a successful video into a failure.
    if (value is! String || value.length > 350000) return null;
    try {
      final bytes = base64Decode(value);
      if (bytes.isNotEmpty && bytes.length <= 256 * 1024) {
        _frameBytes = bytes.asUnmodifiableView();
        return _frameBytes;
      }
    } on FormatException {
      /* A snapshot is optional; the target poster remains available. */
    }
    return null;
  }

  /// Pause and capture the current decoded frame before retiring its surface.
  /// A missing/stale platform reply cannot keep the old player alive.
  Future<Uint8List?> captureFrameAndPause() async {
    if (_disposed || !hasFrame || failed || _sink == null) {
      pause();
      return null;
    }
    final existing = _capturePending;
    if (existing != null) {
      return existing.future.timeout(
        const Duration(milliseconds: 60),
        onTimeout: () => null,
      );
    }
    final pending = Completer<Uint8List?>();
    _capturePending = pending;
    _wantsPlay = false;
    final id = ++_captureId;
    _sink?.call({'type': 'capture-and-pause', 'captureId': id});
    try {
      return await pending.future.timeout(
        const Duration(milliseconds: 60),
        onTimeout: () => null,
      );
    } finally {
      if (identical(_capturePending, pending)) _capturePending = null;
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    pause();
    final capture = _capturePending;
    if (capture != null && !capture.isCompleted) capture.complete(null);
    _capturePending = null;
    final position = _positionPending;
    if (position != null && !position.isCompleted) position.complete(null);
    _positionPending = null;
    _disposed = true;
    _sink = null;
    super.dispose();
  }
}

/// At most one demonstration is retained across cards and pages.
class DrillPlaybackCoordinator {
  static final shared = DrillPlaybackCoordinator();
  Object? _owner;
  VoidCallback? _release;
  void claim(Object owner, VoidCallback release) {
    if (_owner == owner) return;
    final previous = _release;
    _owner = owner;
    _release = release;
    previous?.call();
  }

  void release(Object owner) {
    if (_owner != owner) return;
    _owner = null;
    _release = null;
  }
}
