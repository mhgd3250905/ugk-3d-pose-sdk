// Ported from SmartFit@e8981ee lib/ui/exercise_video.dart (poster first,
// then the looping clip on top once its first frame is on screen – the
// HipLab hand-over, no black flash). Changes: takes a [DrillMedia] instead
// of a SmartFit Exercise; colours come from the caller.
import 'dart:async';

import 'package:flutter/material.dart';

import 'drill_media.dart';
import 'media_controller.dart';
import 'media_view.dart';
import 'training_media_repository.dart';

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

  /// Theme the running clip was started for: a switch reloads the
  /// light/dark render (the poster covers the hand-over).
  Brightness? _brightness;

  bool get _light => _brightness == Brightness.light;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final repository = widget.repository ?? TrainingMediaScope.maybeOf(context);
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
  }

  void _reload() {
    _request++;
    _stop();
    _resource = null;
    _downloadError = null;
    _resolving = false;
    _cacheRevision = _repository?.cacheRevision ?? 0;
    if (!widget.playing || !widget.media.videoAvailable) return;
    if (_repository == null) {
      _start();
    } else {
      unawaited(_resolve(_request));
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
    } else if (widget.playing && _resource == null && !_resolving) {
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
  }

  void _stop() {
    _controller?.removeListener(_changed);
    _controller?.dispose();
    _controller = null;
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _request++;
    _repository?.removeListener(_repositoryChanged);
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.media;
    final c = _controller;
    final video = _resource?.assetKey ?? m.videoFor(light: _light);
    final poster = m.posterFor(light: _light);
    Widget content = Stack(
      fit: StackFit.expand,
      children: [
        if (c != null && (_repository == null || _resource != null))
          DrillMediaPlatformView(
            key: ValueKey(
              '${m.id}/$video/${_resource?.cachePath}/$_cacheRevision',
            ),
            media: m,
            controller: c,
            videoAsset: video,
            resource: _resource,
          ),
        if (c == null || !c.hasFrame)
          Image.asset(
            poster,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => ColoredBox(
              color: widget.stage,
              child: Center(
                child:
                    !widget.playing ||
                        !m.videoAvailable ||
                        widget.errorLabel == null ||
                        _repository != null
                    ? null
                    : Text(
                        widget.errorLabel!,
                        style: TextStyle(
                          fontSize: 13,
                          color: widget.errorColor,
                        ),
                      ),
              ),
            ),
          ),
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
    if (widget.mirrored) {
      content = Transform.flip(flipX: true, child: content);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: ColoredBox(
        color: widget.stage,
        child: AspectRatio(aspectRatio: 1, child: content),
      ),
    );
  }
}
