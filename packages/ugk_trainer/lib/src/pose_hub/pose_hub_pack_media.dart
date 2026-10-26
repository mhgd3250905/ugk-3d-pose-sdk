import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../media/media_controller.dart';
import '../ui/trainer_theme.dart';
import 'pose_hub_media_prefetcher.dart';
import 'pose_hub_media_preparation.dart';
import 'pose_hub_pack_image.dart';
import 'pose_hub_pack_surface.dart';

enum PoseHubPackPlaybackStatus {
  cover,
  loading,
  playing,
  paused,
  unsupported,
  error,
}

/// Bundled standing image first, then a 180 ms dissolve after a composed frame.
/// Media preparation is independent of session timing and speech.
class PoseHubPackMedia extends StatefulWidget {
  const PoseHubPackMedia({
    super.key,
    required this.action,
    required this.baseUri,
    this.playing = false,
    this.paused = false,
    this.theme = TrainerTheme.light,
    this.onStatus,
    this.mediaPreparer,
  });
  final PoseHubPackAction action;
  final Uri baseUri;
  final bool playing, paused;
  final TrainerTheme theme;
  final ValueChanged<PoseHubPackPlaybackStatus>? onStatus;
  final PoseHubMediaPreparer? mediaPreparer;
  static bool get supportsPlayback => supportsPoseHubPackPlayback;

  @override
  State<PoseHubPackMedia> createState() => _PoseHubPackMediaState();
}

class _PoseHubPackMediaState extends State<PoseHubPackMedia> {
  late DrillMediaController _controller;
  PoseHubPackPlaybackStatus? _lastStatus;
  final _preparation = PoseHubMediaPreparationController();
  PoseHubMediaPrefetcher? _ownedPrefetcher;
  Future<void>? _preparerRetirement;

  PoseHubMediaPreparer? get _preparer =>
      _ownedPrefetcher ?? widget.mediaPreparer;

  void _bindPreparer() {
    final previous = _ownedPrefetcher;
    previous?.dispose();
    _preparerRetirement = previous?.cancellationComplete ?? _preparerRetirement;
    _ownedPrefetcher =
        widget.mediaPreparer != null &&
            widget.mediaPreparer is! PoseHubMediaPrefetcher
        ? PoseHubMediaPrefetcher(
            widget.mediaPreparer!,
            afterCancellation: _preparerRetirement,
          )
        : null;
  }

  bool get _prepared =>
      widget.mediaPreparer == null ||
      _preparation.state.status == PoseHubMediaPreparationStatus.ready;
  bool get _preparationFailed =>
      widget.mediaPreparer != null &&
      _preparation.state.status == PoseHubMediaPreparationStatus.failed;
  Uri get _mediaBase => widget.mediaPreparer == null
      ? widget.baseUri
      : _preparation.state.mediaBaseUri ?? widget.baseUri;

  PoseHubPackPlaybackStatus get _status => !widget.playing
      ? PoseHubPackPlaybackStatus.cover
      : _preparationFailed
      ? PoseHubPackPlaybackStatus.error
      : !_prepared
      ? PoseHubPackPlaybackStatus.loading
      : !supportsPoseHubPackPlayback
      ? PoseHubPackPlaybackStatus.unsupported
      : _controller.failed
      ? PoseHubPackPlaybackStatus.error
      : !_controller.hasFrame
      ? PoseHubPackPlaybackStatus.loading
      : widget.paused
      ? PoseHubPackPlaybackStatus.paused
      : PoseHubPackPlaybackStatus.playing;

  @override
  void initState() {
    super.initState();
    _preparation.addListener(_preparationChanged);
    _bind();
    _bindPreparer();
    _ensurePreparation();
  }

  void _ensurePreparation() {
    final preparer = _preparer;
    if (widget.playing &&
        preparer != null &&
        _preparation.state.status != PoseHubMediaPreparationStatus.preparing &&
        _preparation.state.status != PoseHubMediaPreparationStatus.ready) {
      _preparation.start(preparer, widget.action);
    }
  }

  void _preparationChanged() {
    if (!mounted) return;
    _sync();
    setState(() {});
    _report();
  }

  void _bind() {
    _controller = DrillMediaController()..addListener(_changed);
    _sync();
    _report();
  }

  void _sync() {
    if (!widget.playing || widget.paused || !_prepared) {
      _controller.pause();
    } else if (!_controller.wantsPlay) {
      _controller.toggle();
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _report();
  }

  void _report() {
    final status = _status;
    if (_lastStatus == status) return;
    _lastStatus = status;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _lastStatus == status) widget.onStatus?.call(status);
    });
  }

  @override
  void didUpdateWidget(PoseHubPackMedia oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sourceChanged =
        oldWidget.action.id != widget.action.id ||
        oldWidget.action.files.entries.any(
          (entry) =>
              entry.value.sha256 != widget.action.files[entry.key]?.sha256 ||
              entry.value.bytes != widget.action.files[entry.key]?.bytes ||
              entry.value.path != widget.action.files[entry.key]?.path,
        ) ||
        oldWidget.baseUri != widget.baseUri ||
        oldWidget.mediaPreparer != widget.mediaPreparer;
    if ((sourceChanged &&
            (oldWidget.mediaPreparer != null ||
                widget.mediaPreparer != null)) ||
        (!widget.playing &&
            _preparation.state.status ==
                PoseHubMediaPreparationStatus.preparing)) {
      _preparation.cancel();
    }
    if (sourceChanged) _bindPreparer();
    if (sourceChanged || oldWidget.playing != widget.playing) {
      _controller.removeListener(_changed);
      _controller.dispose();
      _lastStatus = null;
      _bind();
    } else {
      _sync();
      _report();
    }
    if (sourceChanged || (!oldWidget.playing && widget.playing)) {
      _ensurePreparation();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
    _preparation.removeListener(_preparationChanged);
    _preparation.dispose();
    _ownedPrefetcher?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasFrame = _controller.hasFrame && !_controller.failed;
    return Semantics(
      label: '${widget.action.nameZh}动作示范',
      child: AspectRatio(
        aspectRatio: 1,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (widget.playing && _prepared && supportsPoseHubPackPlayback)
              PoseHubPackSurface(
                sourceUri: widget.action.video.resolve(_mediaBase),
                controller: _controller,
              ),
            IgnorePointer(
              child: AnimatedOpacity(
                opacity: widget.playing && hasFrame && _prepared ? 0 : 1,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                child: ColoredBox(
                  key: const ValueKey('pose-hub-pack-cover'),
                  color: widget.theme.mediaStage,
                  child: PoseHubStandingImage(
                    action: widget.action,
                    theme: widget.theme,
                  ),
                ),
              ),
            ),
            if (widget.playing && !hasFrame)
              Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Tooltip(
                    message: '视频加载中',
                    child: Icon(
                      Icons.slow_motion_video,
                      key: const ValueKey('posehub-video-loading'),
                      size: 16,
                      color: widget.theme.muted.withValues(alpha: .55),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
