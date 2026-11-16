import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../media/media_controller.dart';
import '../media/trainer_v1_media_scope.dart';
import '../ui/trainer_experience.dart';
import '../ui/trainer_poster.dart';
import '../ui/trainer_theme.dart';
import 'pose_hub_media_prefetcher.dart';
import 'pose_hub_media_preparation.dart';
import 'pose_hub_media_theme.dart';
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
    this.posterAsset,
  });
  final PoseHubPackAction action;
  final Uri baseUri;
  final bool playing, paused;
  final TrainerTheme theme;
  final ValueChanged<PoseHubPackPlaybackStatus>? onStatus;
  final PoseHubMediaPreparer? mediaPreparer;

  /// Optional host asset used by the shared experience's warmed poster path.
  final String? posterAsset;
  static bool get supportsPlayback => supportsPoseHubPackPlayback;

  @override
  State<PoseHubPackMedia> createState() => _PoseHubPackMediaState();
}

class _PoseHubPackMediaState extends State<PoseHubPackMedia> {
  late DrillMediaController _controller;
  late PoseHubPackAction _sourceAction;
  PoseHubMediaTheme? _mediaTheme;
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
    _sourceAction = widget.action;
    _preparation.addListener(_preparationChanged);
    _bind();
    _bindPreparer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final theme = poseHubMediaThemeOf(context);
    if (theme == _mediaTheme) return;
    _mediaTheme = theme;
    _updateSource();
  }

  void _ensurePreparation() {
    final preparer = _preparer;
    if (widget.playing &&
        preparer != null &&
        _preparation.state.status != PoseHubMediaPreparationStatus.preparing &&
        _preparation.state.status != PoseHubMediaPreparationStatus.ready) {
      _preparation.start(preparer, _sourceAction);
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
    _mediaTheme = poseHubMediaThemeOf(context);
    _updateSource(oldWidget: oldWidget);
  }

  void _updateSource({PoseHubPackMedia? oldWidget}) {
    final action = widget.action.forMediaTheme(_mediaTheme);
    final sourceChanged =
        _sourceAction.id != action.id ||
        _sourceAction.files.entries.any((entry) {
          final next = action.files[entry.key];
          return entry.value.sha256 != next?.sha256 ||
              entry.value.bytes != next?.bytes ||
              entry.value.path != next?.path;
        }) ||
        (oldWidget != null &&
            (oldWidget.baseUri != widget.baseUri ||
                oldWidget.mediaPreparer != widget.mediaPreparer));
    _sourceAction = action;
    if ((sourceChanged &&
            (oldWidget?.mediaPreparer != null ||
                widget.mediaPreparer != null)) ||
        (!widget.playing &&
            _preparation.state.status ==
                PoseHubMediaPreparationStatus.preparing)) {
      _preparation.cancel();
    }
    if (sourceChanged) _bindPreparer();
    if (sourceChanged ||
        (oldWidget != null && oldWidget.playing != widget.playing)) {
      _controller.removeListener(_changed);
      _controller.dispose();
      _lastStatus = null;
      _bind();
    } else {
      _sync();
      _report();
    }
    if (sourceChanged || oldWidget == null || !oldWidget.playing) {
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
    final experience = TrainerExperienceScope.maybeOf(context);
    final poster = experience != null && widget.posterAsset != null
        ? TrainerPoster(
            asset: widget.posterAsset!,
            bundle: experience.bundle,
            decodeWidth: experience.decodeWidth,
          )
        : null;
    final hasThemedPoster = widget.action.themedMedia.containsKey(_mediaTheme);
    return Semantics(
      label: '${widget.action.nameZh}动作示范',
      child: AspectRatio(
        aspectRatio: 1,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (widget.playing && _prepared && supportsPoseHubPackPlayback)
              PoseHubPackSurface(
                sourceUri: _sourceAction.video.resolve(_mediaBase),
                controller: _controller,
              ),
            IgnorePointer(
              child: AnimatedOpacity(
                opacity: widget.playing && hasFrame && _prepared ? 0 : 1,
                duration: TrainerV1MediaScope.of(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                child: ColoredBox(
                  key: const ValueKey('pose-hub-pack-cover'),
                  color: widget.theme.mediaStage,
                  child: poster != null && !hasThemedPoster
                      ? poster
                      : PoseHubStandingImage(
                          action: widget.action,
                          theme: widget.theme,
                          mediaBaseUri: _mediaBase,
                          legacyFallback: poster,
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
