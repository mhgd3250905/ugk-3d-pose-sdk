import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/trainer_experience.dart';
import '../ui/trainer_poster.dart';
import 'catalog_media_repository.dart';
import 'media_controller.dart';
import 'media_playback_handle.dart';
import 'packed_alpha_video.dart';
import 'training_media_policy.dart';

/// One shared public action, with the same alpha video/poster in both themes.
/// Download and decoder failures affect only this demonstration, never training.
class TrainingActionMedia extends StatefulWidget {
  const TrainingActionMedia({
    super.key,
    required this.actionId,
    this.policy,
    this.playing = true,
    this.prefetchWhenIdle = false,
    this.paused = false,
    this.mirrored = false,
    this.radius = 16,
    this.stage,
    this.playbackHandle,
  });
  final String actionId;
  final TrainingMediaPolicy? policy;
  final bool playing, paused, mirrored;

  /// Prepare the current training demonstration while playback is gated.
  /// Off by default so list/detail previews wait for explicit playback.
  final bool prefetchWhenIdle;
  final double radius;
  final Color? stage;
  final DrillMediaPlaybackHandle? playbackHandle;

  @override
  State<TrainingActionMedia> createState() => _TrainingActionMediaState();
}

class _VideoPin {
  _VideoPin(this._release);
  VoidCallback? _release;
  bool attached = false;
  void release() {
    final callback = _release;
    _release = null;
    callback?.call();
  }
}

class _TrainingActionMediaState extends State<TrainingActionMedia>
    with WidgetsBindingObserver {
  TrainingMediaPolicy? _policy;
  DrillMediaController? _controller;
  _VideoPin? _pin;
  Uri? _source;
  int _request = 0;
  bool _foreground = true;
  bool _visible = true;
  bool _failed = false;

  bool get _canPlay => widget.playing && _foreground && _visible;
  bool get _canPrepare =>
      (widget.playing || widget.prefetchWhenIdle) && _foreground && _visible;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final policy = widget.policy ?? TrainingMediaPolicyScope.maybeOf(context);
    final visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    if (!identical(policy, _policy) || visible != _visible) {
      _policy = policy;
      _visible = visible;
      _reload();
    }
  }

  @override
  void didUpdateWidget(TrainingActionMedia oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playbackHandle != widget.playbackHandle) {
      oldWidget.playbackHandle?.unbind(this);
    }
    if (oldWidget.actionId != widget.actionId ||
        oldWidget.policy != widget.policy ||
        (oldWidget.playing || oldWidget.prefetchWhenIdle) !=
            (widget.playing || widget.prefetchWhenIdle)) {
      _policy = widget.policy ?? TrainingMediaPolicyScope.read(context);
      _reload();
    } else if (oldWidget.paused != widget.paused ||
        oldWidget.playing != widget.playing) {
      _sync();
    }
    _bindHandle();
  }

  void _bindHandle() => widget.playbackHandle?.bind(
    owner: this,
    mediaId: widget.actionId,
    controller: _controller,
    failed: _failed,
    onRetry: () {
      if (mounted) setState(_reload);
    },
  );

  void _stop() {
    ++_request;
    _controller?.removeListener(_decoderChanged);
    _controller?.dispose();
    _controller = null;
    _source = null;
    final pin = _pin;
    _pin = null;
    // An attached native decoder releases its pin after asynchronous disposal.
    if (pin != null && !pin.attached) pin.release();
    _bindHandle();
  }

  void _reload() {
    _stop();
    _failed = false;
    final policy = _policy;
    final action = policy?.actionFor(widget.actionId);
    // Only the current training action opts into preparation before playback.
    // Other idle previews and covered/background routes retain their policy.
    if (!_canPrepare || policy == null || action == null) {
      _bindHandle();
      return;
    }
    if (!UgkPackedAlphaVideo.isSupported) return;
    final pin = _pin = _VideoPin(policy.repository.retainVideo(action.id));
    _bindHandle();
    unawaited(_resolve(_request, policy, pin));
  }

  Future<void> _resolve(
    int request,
    TrainingMediaPolicy policy,
    _VideoPin pin,
  ) async {
    try {
      final uri = await policy.repository.ensureFileWithPriority(
        policy.actionFor(widget.actionId)!.video,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _source = uri;
        _controller = DrillMediaController()..addListener(_decoderChanged);
        _sync();
        _bindHandle();
      });
    } catch (_) {
      if (mounted && request == _request) {
        setState(() {
          _failed = true;
          _pin = null;
          _bindHandle();
        });
      }
      pin.release();
    }
  }

  void _sync() {
    final controller = _controller;
    if (controller == null) return;
    if (!_canPlay || widget.paused) {
      controller.pause();
    } else if (!controller.wantsPlay) {
      controller.toggle();
    }
  }

  void _decoderChanged() {
    if (!mounted) return;
    if (_controller?.failed == true) {
      // Retire the exact failed surface, preserving the bundled still.
      scheduleMicrotask(() {
        if (!mounted || _controller?.failed != true) return;
        setState(() {
          _stop();
          _failed = true;
          _bindHandle();
        });
      });
    } else {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    setState(() {
      _foreground = foreground;
      _reload();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stop();
    widget.playbackHandle?.unbind(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final poster = _policy?.posterAssetFor(widget.actionId);
    final experience = TrainerExperienceScope.maybeOf(context);
    final stage = widget.stage ?? Theme.of(context).colorScheme.surface;
    final controller = _controller;
    final revealed =
        _canPlay && controller?.hasFrame == true && controller?.failed != true;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: ColoredBox(
        color: stage,
        child: AspectRatio(
          aspectRatio: 1,
          child: Transform.flip(
            flipX: widget.mirrored,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (poster != null)
                  AnimatedOpacity(
                    key: const ValueKey('public-action-poster'),
                    opacity: revealed ? 0 : 1,
                    duration: const Duration(milliseconds: 120),
                    child: TrainerPoster(
                      asset: poster,
                      bundle: experience?.bundle,
                      decodeWidth: experience?.decodeWidth,
                    ),
                  )
                else
                  const Center(
                    child: Text(
                      '此动作暂无公共示范',
                      key: ValueKey('public-action-missing'),
                    ),
                  ),
                if (_source != null && controller != null && _pin != null)
                  AnimatedOpacity(
                    opacity: revealed ? 1 : 1 / 255,
                    duration: const Duration(milliseconds: 120),
                    child: _PinnedPackedVideo(
                      key: ObjectKey(controller),
                      source: _source!,
                      controller: controller,
                      pin: _pin!,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PinnedPackedVideo extends StatefulWidget {
  const _PinnedPackedVideo({
    super.key,
    required this.source,
    required this.controller,
    required this.pin,
  });
  final Uri source;
  final DrillMediaController controller;
  final _VideoPin pin;
  @override
  State<_PinnedPackedVideo> createState() => _PinnedPackedVideoState();
}

class _PinnedPackedVideoState extends State<_PinnedPackedVideo> {
  @override
  void initState() {
    super.initState();
    widget.pin.attached = true;
  }

  @override
  Widget build(BuildContext context) => UgkPackedAlphaVideo.source(
    sourceUri: widget.source,
    controller: widget.controller,
    onDisposed: widget.pin.release,
  );
}
