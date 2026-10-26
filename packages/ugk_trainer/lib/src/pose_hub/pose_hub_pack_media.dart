import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../media/media_controller.dart';
import '../ui/trainer_theme.dart';
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

/// Demonstration of one original RGB-over-alpha clip. Its catalog cover may be
/// any source frame: it is deliberately not passed as a frame-zero poster.
/// The cover stays over the live surface until a real composed frame exists.
class PoseHubPackMedia extends StatefulWidget {
  const PoseHubPackMedia({
    super.key,
    required this.action,
    required this.baseUri,
    this.playing = false,
    this.paused = false,
    this.theme = TrainerTheme.light,
    this.onStatus,
  });
  final PoseHubPackAction action;
  final Uri baseUri;
  final bool playing, paused;
  final TrainerTheme theme;
  final ValueChanged<PoseHubPackPlaybackStatus>? onStatus;
  static bool get supportsPlayback => supportsPoseHubPackPlayback;

  @override
  State<PoseHubPackMedia> createState() => _PoseHubPackMediaState();
}

class _PoseHubPackMediaState extends State<PoseHubPackMedia> {
  late DrillMediaController _controller;
  PoseHubPackPlaybackStatus? _lastStatus;

  PoseHubPackPlaybackStatus get _status => !widget.playing
      ? PoseHubPackPlaybackStatus.cover
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
    _bind();
  }

  void _bind() {
    _controller = DrillMediaController()..addListener(_changed);
    _sync();
    _report();
  }

  void _sync() {
    if (!widget.playing || widget.paused) {
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
    if (oldWidget.action.id != widget.action.id ||
        oldWidget.action.video.path != widget.action.video.path ||
        oldWidget.baseUri != widget.baseUri ||
        oldWidget.playing != widget.playing) {
      _controller.removeListener(_changed);
      _controller.dispose();
      _lastStatus = null;
      _bind();
    } else {
      _sync();
      _report();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
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
            if (widget.playing && supportsPoseHubPackPlayback)
              PoseHubPackSurface(
                sourceUri: widget.action.video.resolve(widget.baseUri),
                controller: _controller,
              ),
            if (!widget.playing || !hasFrame)
              ColoredBox(
                key: const ValueKey('pose-hub-pack-cover'),
                color: widget.theme.mediaStage,
                child: PoseHubPackImage(
                  file: widget.action.cover,
                  baseUri: widget.baseUri,
                  theme: widget.theme,
                  semanticLabel: '${widget.action.nameZh}封面（非固定帧零）',
                ),
              ),
            if (_status == PoseHubPackPlaybackStatus.unsupported ||
                _status == PoseHubPackPlaybackStatus.error)
              Align(
                alignment: Alignment.bottomCenter,
                child: ColoredBox(
                  color: widget.theme.surface,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      _status == PoseHubPackPlaybackStatus.unsupported
                          ? '当前平台仅显示封面'
                          : '动作视频暂不可播放',
                      key: const ValueKey('pose-hub-pack-playback-message'),
                      style: widget.theme.label,
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
