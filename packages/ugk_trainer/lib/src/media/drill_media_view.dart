// Ported from SmartFit@e8981ee lib/ui/exercise_video.dart (poster first,
// then the looping clip on top once its first frame is on screen – the
// HipLab hand-over, no black flash). Changes: takes a [DrillMedia] instead
// of a SmartFit Exercise; colours come from the caller.
import 'package:flutter/material.dart';

import 'drill_media.dart';
import 'media_controller.dart';
import 'media_view.dart';

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
    this.errorColor = const Color(0xB8FFFFFF),
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
  final Color errorColor;

  @override
  State<DrillMediaView> createState() => _DrillMediaViewState();
}

class _DrillMediaViewState extends State<DrillMediaView> {
  DrillMediaController? _controller;

  /// Theme the running clip was started for: a switch reloads the
  /// light/dark render (the poster covers the hand-over).
  Brightness? _brightness;

  bool get _light => _brightness == Brightness.light;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final b = Theme.of(context).brightness;
    if (_brightness != null &&
        b != _brightness &&
        widget.media.lightVideoAsset != null &&
        _controller != null) {
      _brightness = b;
      _stop();
      _start();
    }
    _brightness = b;
  }

  @override
  void initState() {
    super.initState();
    if (widget.playing) _start();
  }

  @override
  void didUpdateWidget(DrillMediaView old) {
    super.didUpdateWidget(old);
    if (old.media.id != widget.media.id || old.playing != widget.playing) {
      _stop();
      if (widget.playing) _start();
    } else if (old.paused != widget.paused) {
      final c = _controller;
      if (widget.paused) {
        c?.pause();
      } else if (c != null && !c.wantsPlay) {
        c.toggle();
      }
    }
  }

  void _start() {
    final c = DrillMediaController()..addListener(_changed);
    if (!widget.paused) c.toggle(); // play as soon as the page is ready
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
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.media;
    final c = _controller;
    final video = m.videoFor(light: _light);
    final poster = m.posterFor(light: _light);
    Widget content = Stack(
      fit: StackFit.expand,
      children: [
        if (c != null)
          DrillMediaPlatformView(
            key: ValueKey('${m.id}/$video'),
            media: m,
            controller: c,
            videoAsset: video,
          ),
        if (c == null || !c.hasFrame)
          Image.asset(
            poster,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => ColoredBox(
              color: widget.stage,
              child: Center(
                child: widget.errorLabel == null
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
