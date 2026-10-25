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

/// App-owned, read-only inspection handle. It does not own the decoder or clock.
/// A view binds its identity even while displaying a waiting/static image.
class DrillMediaPlaybackHandle {
  Object? _owner;
  String? _mediaId;
  DrillMediaController? _controller;
  bool _disposed = false;

  void bind({
    required Object owner,
    required String mediaId,
    required DrillMediaController? controller,
  }) {
    if (_disposed) return;
    _owner = owner;
    _mediaId = mediaId;
    _controller = controller;
  }

  void unbind(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _mediaId = null;
    _controller = null;
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

  void dispose() {
    _disposed = true;
    _owner = null;
    _mediaId = null;
    _controller = null;
  }
}
