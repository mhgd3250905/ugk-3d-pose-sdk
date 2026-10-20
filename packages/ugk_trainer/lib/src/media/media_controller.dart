// Ported from SmartFit@e8981ee lib/core/media/media_controller.dart (3D-Body
// DrillMediaController / DrillPlaybackCoordinator). Unchanged.
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
      case 'state':
        playing = value['playing'] == true;
        _wantsPlay = playing;
      default:
        return;
    }
    notifyListeners();
  }

  void reportError() => receive({'source': 'drill-media', 'type': 'error'});
  @override
  void dispose() {
    pause();
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
