// Ported from SmartFit@e8981ee lib/ui/exercise_video.dart (poster first,
// then the looping clip on top once its first frame is on screen – the
// HipLab hand-over, no black flash). Changes: takes a [DrillMedia] instead
// of a SmartFit Exercise; colours come from the caller.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'drill_media.dart';
import 'media_controller.dart';
import 'media_view.dart';
import 'training_media_repository.dart';

/// Presentation-only handover for training: settle rapid target changes before
/// resolving a clip, and retain one captured still if its successor lacks a
/// poster. Standalone/manual demonstration views remain immediate by default.
class DrillMediaHandoff extends StatefulWidget {
  const DrillMediaHandoff({
    super.key,
    required this.child,
    this.settleDelay = defaultSettleDelay,
  });
  static const defaultSettleDelay = Duration(milliseconds: 150);
  final Widget child;
  final Duration settleDelay;
  @override
  State<DrillMediaHandoff> createState() => _DrillMediaHandoffState();
}

class _DrillMediaHandoffState extends State<DrillMediaHandoff> {
  final _frames = _CapturedFrame();
  @override
  Widget build(BuildContext context) => _MediaHandoffScope(
    frames: _frames,
    delay: widget.settleDelay,
    child: widget.child,
  );
}

class _CapturedFrame {
  Uint8List? bytes;
  Brightness? brightness;
  bool mirrored = false;
  void remember(Uint8List value, Brightness theme, bool flipped) {
    bytes = value;
    brightness = theme;
    mirrored = flipped;
  }
}

class _MediaSurface {
  const _MediaSurface({
    required this.controller,
    required this.media,
    required this.video,
    required this.resource,
    required this.cacheRevision,
    required this.brightness,
    required this.mirrored,
  });
  final DrillMediaController controller;
  final DrillMedia media;
  final String video;
  final TrainingMediaResource? resource;
  final int cacheRevision;
  final Brightness brightness;
  final bool mirrored;

  _MediaSurface withMirror(bool value) => _MediaSurface(
    controller: controller,
    media: media,
    video: video,
    resource: resource,
    cacheRevision: cacheRevision,
    brightness: brightness,
    mirrored: value,
  );
}

class _MediaHandoffScope extends InheritedWidget {
  const _MediaHandoffScope({
    required this.frames,
    required this.delay,
    required super.child,
  });
  final _CapturedFrame frames;
  final Duration delay;
  static _MediaHandoffScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MediaHandoffScope>();
  @override
  bool updateShouldNotify(_MediaHandoffScope oldWidget) =>
      delay != oldWidget.delay;
}

class DrillMediaView extends StatefulWidget {
  const DrillMediaView({
    super.key,
    required this.media,
    this.playing = true,
    this.paused = false,
    this.mirrored = false,
    this.radius = 16,
    this.stage = const Color(0xFF101013),
    this.errorLabel,
    this.unavailableLabel,
    this.errorColor = const Color(0xB8FFFFFF),
    this.repository,
  });

  final DrillMedia media;
  final bool playing;

  /// Freeze an existing demonstration without discarding its frame.
  final bool paused;

  /// Left side of a unilateral move: the clip shows the right side.
  final bool mirrored;
  final double radius;

  /// What sits behind the clip (the colour its render is baked on).
  final Color stage;

  /// Shown when the clip cannot load.
  final String? errorLabel;

  /// Optional host copy for a move that has only a still illustration.
  /// This is separate from a failure loading a declared video.
  final String? unavailableLabel;
  final Color errorColor;
  final TrainingMediaRepository? repository;

  @override
  State<DrillMediaView> createState() => _DrillMediaViewState();
}

class _DrillMediaViewState extends State<DrillMediaView> {
  DrillMediaController? _controller;
  TrainingMediaRepository? _repository;
  TrainingMediaResource? _resource;
  Object? _downloadError;
  int _request = 0;
  int _cacheRevision = 0;
  bool _resolving = false;
  bool _initialized = false;
  Timer? _loadTimer;
  _MediaHandoffScope? _handoff;
  final _lastFrame = _CapturedFrame();
  _MediaSurface? _surface;
  _MediaSurface? _retiring;

  /// Theme the running clip was started for: a switch reloads the
  /// light/dark render (the poster covers the hand-over).
  Brightness? _brightness;

  bool get _light => _brightness == Brightness.light;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final repository = widget.repository ?? TrainingMediaScope.maybeOf(context);
    _handoff = _MediaHandoffScope.of(context);
    final brightness = Theme.of(context).brightness;
    final assetThemeChanged =
        _initialized &&
        brightness != _brightness &&
        repository == null &&
        widget.media.lightVideoAsset != null;
    // Resolve inherited inputs before creating a controller. Starting in
    // initState briefly created an extra controller before the scope was known.
    _brightness = brightness;
    if (!_initialized || _repository != repository) {
      _initialized = true;
      _repository?.removeListener(_repositoryChanged);
      _repository = repository;
      _cacheRevision = repository?.cacheRevision ?? 0;
      _repository?.addListener(_repositoryChanged);
      _reload();
    } else if (assetThemeChanged) {
      _reload();
    }
  }

  @override
  void didUpdateWidget(DrillMediaView old) {
    super.didUpdateWidget(old);
    if (old.media.id != widget.media.id ||
        old.media.actionId != widget.media.actionId ||
        old.media.skin != widget.media.skin ||
        old.media.theme != widget.media.theme ||
        old.media.videoAvailable != widget.media.videoAvailable ||
        old.media.videoAsset != widget.media.videoAsset ||
        old.media.lightVideoAsset != widget.media.lightVideoAsset ||
        old.repository != widget.repository ||
        old.playing != widget.playing) {
      if (old.repository != widget.repository) {
        _repository?.removeListener(_repositoryChanged);
        _repository = widget.repository ?? TrainingMediaScope.maybeOf(context);
        _cacheRevision = _repository?.cacheRevision ?? 0;
        _repository?.addListener(_repositoryChanged);
      }
      _reload();
    } else if (old.paused != widget.paused) {
      final c = _controller;
      if (widget.paused) {
        c?.pause();
      } else if (c != null && !c.wantsPlay) {
        c.toggle();
      }
    }
    if (old.mirrored != widget.mirrored) {
      _surface = _surface?.withMirror(widget.mirrored);
    }
  }

  void _reload() {
    _request++;
    _loadTimer?.cancel();
    _loadTimer = null;
    _retireCurrent();
    _resource = null;
    _downloadError = null;
    _resolving = false;
    _cacheRevision = _repository?.cacheRevision ?? 0;
    if (!widget.playing || !widget.media.videoAvailable) return;
    final request = _request;
    final delay = _handoff?.delay ?? Duration.zero;
    if (delay > Duration.zero) {
      _loadTimer = Timer(delay, () {
        _loadTimer = null;
        if (!mounted || request != _request) return;
        setState(() => _load(request));
      });
    } else {
      _load(request);
    }
  }

  void _load(int request) {
    if (_repository == null) {
      _start();
    } else {
      unawaited(_resolve(request));
    }
  }

  Future<void> _resolve(int request) async {
    _resolving = true;
    try {
      final media = widget.media;
      final resource = await _repository!.ensureVideo(
        media.actionId ?? media.id,
        skin: media.skin,
        theme: media.theme,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _resource = resource;
        _start();
      });
    } catch (error) {
      if (mounted && request == _request) {
        setState(() => _downloadError = error);
      }
    } finally {
      if (request == _request) _resolving = false;
    }
  }

  void _repositoryChanged() {
    if (!mounted) return;
    final repository = _repository!;
    if (!widget.playing || !widget.media.videoAvailable) {
      _cacheRevision = repository.cacheRevision;
      return;
    }
    final id = widget.media.actionId ?? widget.media.id;
    if (_cacheRevision != repository.cacheRevision) {
      _cacheRevision = repository.cacheRevision;
      if (_resource?.assetKey == null) {
        _request++;
        _resolving = false;
        _stop();
        _resource = null;
        _downloadError = StateError('Media cache cleared');
      }
      setState(() {});
      return;
    }
    if (!repository.visibleActions.any((a) => a.id == id)) {
      _request++;
      _resolving = false;
      _stop();
      _resource = null;
      _downloadError = StateError('Action is not release eligible');
    } else if (widget.playing &&
        _resource == null &&
        !_resolving &&
        _loadTimer == null) {
      final phase = repository.stateFor(id).phase;
      if ([
        TrainingMediaPhase.queued,
        TrainingMediaPhase.downloading,
        TrainingMediaPhase.ready,
      ].contains(phase)) {
        _downloadError = null;
        unawaited(_resolve(++_request));
      }
    }
    setState(() {});
  }

  void _start() {
    if (!widget.playing || !widget.media.videoAvailable) return;
    _stop();
    final c = DrillMediaController();
    if (!widget.paused) c.toggle(); // play as soon as the page is ready
    c.addListener(_changed);
    _controller = c;
    _surface = _MediaSurface(
      controller: c,
      media: widget.media,
      video: _resource?.assetKey ?? widget.media.videoFor(light: _light),
      resource: _resource,
      cacheRevision: _cacheRevision,
      brightness: _brightness!,
      mirrored: widget.mirrored,
    );
  }

  void _stop() {
    _controller?.removeListener(_changed);
    _controller?.dispose();
    _controller = null;
    _surface = null;
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _retireCurrent() {
    final surface = _surface;
    if (surface == null || !surface.controller.hasFrame || _handoff == null) {
      _stop();
      return;
    }
    // Keep at most one bounded, immediately paused surface solely to capture
    // its current frame. It is never a live cross-fading previous video.
    _retiring?.controller.dispose();
    _retiring = surface;
    _controller?.removeListener(_changed);
    _controller = null;
    _surface = null;
    unawaited(_captureAndRetire(surface));
  }

  Future<void> _captureAndRetire(_MediaSurface surface) async {
    final bytes = await surface.controller.captureFrameAndPause();
    if (mounted && identical(_retiring, surface) && bytes != null) {
      await precacheImage(
        MemoryImage(bytes),
        context,
        onError: (_, _) {},
      ).timeout(const Duration(milliseconds: 40), onTimeout: () {});
      if (mounted && identical(_retiring, surface)) {
        _lastFrame.remember(bytes, surface.brightness, surface.mirrored);
        _handoff?.frames.remember(bytes, surface.brightness, surface.mirrored);
      }
    }
    if (mounted && identical(_retiring, surface)) {
      setState(() => _retiring = null);
    }
    surface.controller.dispose();
  }

  Widget _fallback() {
    final local =
        _lastFrame.brightness == _brightness && _lastFrame.bytes != null
        ? _lastFrame
        : null;
    final shared = _handoff?.frames;
    final frame = local ?? (shared?.brightness == _brightness ? shared : null);
    final bytes = frame?.bytes;
    if (bytes == null) return ColoredBox(color: widget.stage);
    return Transform.flip(
      flipX: frame!.mirrored != widget.mirrored,
      child: Image.memory(
        bytes,
        key: const ValueKey('drill-static-frame'),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => ColoredBox(color: widget.stage),
      ),
    );
  }

  Widget _platformSurface(_MediaSurface surface, {bool retiring = false}) {
    final hasFrame = surface.controller.hasFrame && !surface.controller.failed;
    final keepFrozen =
        retiring &&
        widget.media.posterFor(light: _light).isEmpty &&
        surface.brightness == _brightness;
    return IgnorePointer(
      key: ValueKey(('drill-surface', surface.controller)),
      child: AnimatedOpacity(
        key: ValueKey(('drill-video-reveal', surface.controller)),
        // One alpha step keeps the native surface compositing until rVFC while
        // the target poster remains visible beneath it.
        opacity: retiring ? (keepFrozen ? 1 : 0) : (hasFrame ? 1 : 1 / 255),
        duration:
            retiring || (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
            ? Duration.zero
            : const Duration(milliseconds: 120),
        child: Transform.flip(
          flipX: retiring && surface.mirrored != widget.mirrored,
          child: DrillMediaPlatformView(
            key: ValueKey((
              surface.controller,
              surface.video,
              surface.resource?.cachePath,
              surface.cacheRevision,
            )),
            media: surface.media,
            controller: surface.controller,
            videoAsset: surface.video,
            resource: surface.resource,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _request++;
    _loadTimer?.cancel();
    _repository?.removeListener(_repositoryChanged);
    _stop();
    _retiring?.controller.dispose();
    _retiring = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.media;
    final c = _controller;
    final poster = m.posterFor(light: _light);
    Widget content = Stack(
      fit: StackFit.expand,
      children: [
        if (poster.isEmpty)
          _fallback()
        else
          Image.asset(
            poster,
            key: ValueKey('drill-poster-$poster'),
            fit: BoxFit.contain,
            gaplessPlayback: false,
            frameBuilder: (_, child, frame, wasSync) =>
                frame != null || wasSync ? child : _fallback(),
            errorBuilder: (_, _, _) => _fallback(),
          ),
        if (_retiring case final previous?)
          _platformSurface(previous, retiring: true),
        if (_surface case final current?) _platformSurface(current),
        if (_repository != null &&
            m.videoAvailable &&
            widget.playing &&
            (_resource == null || c?.failed == true))
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Semantics(
              liveRegion: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_downloadError == null && _resource == null)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  Text(
                    _downloadError != null || c?.failed == true
                        ? (widget.errorLabel ?? '动作视频暂不可用，训练继续')
                        : '正在加载动作视频',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: widget.errorColor),
                  ),
                ],
              ),
            ),
          ),
        if (!m.videoAvailable && widget.unavailableLabel != null)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Text(
              widget.unavailableLabel!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: widget.errorColor),
            ),
          ),
      ],
    );
    // Keep the subtree shape stable when changing sides. Inserting/removing
    // this transform would recreate the native view behind the same owner.
    content = Transform.flip(flipX: widget.mirrored, child: content);
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: ColoredBox(
        color: widget.stage,
        child: AspectRatio(aspectRatio: 1, child: content),
      ),
    );
  }
}
