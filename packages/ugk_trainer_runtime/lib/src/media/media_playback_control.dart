import 'package:flutter/foundation.dart';

import 'media_controller.dart';

/// Explicit demonstration control, separate from the read-only playback handle.
/// It never owns a training clock, video file or native decoder.
class DrillMediaPlaybackControl {
  Object? _owner;
  DrillMediaController? _controller;
  bool _disposed = false;

  @internal
  void bind({
    required Object owner,
    required DrillMediaController? controller,
  }) {
    if (_disposed) return;
    if (!identical(owner, _owner) || !identical(controller, _controller)) {
      _controller?.cancelReturnToStart();
    }
    _owner = owner;
    _controller = controller;
  }

  @internal
  void unbind(Object owner) {
    if (!identical(owner, _owner)) return;
    _controller?.cancelReturnToStart();
    _owner = null;
    _controller = null;
  }

  /// Runs the rest of the current loop forward, then holds its first frame.
  /// [duration] is a target, not a promise to skip intermediate video poses.
  /// An unavailable, unsupported or cancelled demonstration returns false.
  Future<bool> returnToStart({
    Duration duration = const Duration(milliseconds: 400),
  }) => _disposed
      ? Future.value(false)
      : _controller?.returnToStart(duration: duration) ?? Future.value(false);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _controller?.cancelReturnToStart();
    _owner = null;
    _controller = null;
  }
}
