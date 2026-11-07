import 'dart:async';

import 'package:flutter/foundation.dart';

import 'media_controller.dart';

/// Immutable inspection of the action that was visible when capture began.
/// Session elapsed time is deliberately not used as the video's position.
class DrillMediaPlaybackSnapshot {
  const DrillMediaPlaybackSnapshot({
    required this.mediaId,
    required this.videoSeconds,
    required this.ready,
    required this.capturedAt,
  });

  final String mediaId;
  final double? videoSeconds;
  final bool ready;
  final DateTime capturedAt;
}

/// App-owned inspection and visual status. It does not own the decoder or clock.
/// A view binds its identity even while displaying a waiting/static image.
class DrillMediaPlaybackHandle extends ChangeNotifier {
  Object? _owner;
  String? _mediaId;
  DrillMediaController? _controller;
  bool _disposed = false;
  bool _failed = false;
  VoidCallback? _retry;
  bool _notificationPending = false;
  (String?, bool, bool, bool)? _lastVisualState;

  /// Visual state only; listening never queries the decoder's position.
  String? get mediaId => _mediaId;
  bool get isBound => _owner != null;
  bool get hasFrame => _controller?.hasFrame == true && !failed;
  bool get failed => _failed || _controller?.failed == true;

  void bind({
    required Object owner,
    required String mediaId,
    required DrillMediaController? controller,
    bool failed = false,
    VoidCallback? onRetry,
  }) {
    if (_disposed) return;
    if (!identical(_controller, controller)) {
      _controller?.removeListener(_visualChanged);
      controller?.addListener(_visualChanged);
    }
    _owner = owner;
    _mediaId = mediaId;
    _controller = controller;
    _failed = failed;
    _retry = onRetry;
    _visualChanged();
  }

  void unbind(Object owner) {
    if (!identical(_owner, owner)) return;
    _controller?.removeListener(_visualChanged);
    _owner = null;
    _mediaId = null;
    _controller = null;
    _failed = false;
    _retry = null;
    _visualChanged();
  }

  /// Recreates the bound demonstration after a download or decoder failure.
  /// The owning view retains control of its lifecycle and cache pin.
  void retry() => _retry?.call();

  void _visualChanged() {
    final next = (_mediaId, hasFrame, failed, isBound);
    if (_disposed || next == _lastVisualState) return;
    _lastVisualState = next;
    if (_notificationPending) return;
    _notificationPending = true;
    // Binding can happen while a sibling HUD is building. Coalesce that
    // notification after the build, rather than forcing a sibling rebuild.
    scheduleMicrotask(() {
      _notificationPending = false;
      if (!_disposed) notifyListeners();
    });
  }

  Future<DrillMediaPlaybackSnapshot?> capture() async {
    final id = _mediaId;
    if (_disposed || id == null) return null;
    final capturedAt = DateTime.now().toUtc();
    final decoder = _controller;
    final ready =
        decoder != null && decoder.ready && decoder.hasFrame && !decoder.failed;
    final position = ready ? await decoder.readPosition() : null;
    // Keep the captured identity if a rapid switch retired its decoder while
    // awaiting the reply. Never pair an old time with the new action's id.
    return DrillMediaPlaybackSnapshot(
      mediaId: id,
      videoSeconds: position,
      ready: ready,
      capturedAt: capturedAt,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _controller?.removeListener(_visualChanged);
    _owner = null;
    _mediaId = null;
    _controller = null;
    _retry = null;
    super.dispose();
  }
}
