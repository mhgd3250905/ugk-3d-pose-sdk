import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../ui/trainer_experience.dart';
import '../ui/trainer_poster.dart';
import 'catalog_media_repository.dart';
import 'media_controller.dart';
import 'media_playback_control.dart';
import 'media_playback_handle.dart';
import 'packed_alpha_video.dart';
import 'trainer_v1_media_scope.dart';
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
    this.playbackControl,
    this.retainSurfaceDuringRouteExit = false,
    this.retainPausedSurfaceWhileCovered = false,
    this.prepareFirstFrame = false,
    this.showLoadingIndicator = true,
    this.showInlineStatus = true,
    this.nativeAlpha = false,
    this.onFrameReadyChanged,
    this.revealPausedFrame = true,
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
  final DrillMediaPlaybackControl? playbackControl;

  /// Retain an existing paused frame while this route itself reverses out.
  /// Covered routes, backgrounding and disposal still release their surfaces.
  /// Hosts opting in must pause before popping; ordinary hosts are unchanged.
  final bool retainSurfaceDuringRouteExit;

  /// Keep an existing, genuinely decoded paused frame while another route covers
  /// this one. This never starts pending media or plays hidden video. Background,
  /// action/policy changes, [playing] false and disposal still release it.
  /// Ordinary hosts keep their existing route-visibility behavior by default.
  final bool retainPausedSurfaceWhileCovered;

  /// With [playing] true and [paused] true, decode and hold the first frame.
  /// Expanding/resuming can then use the very same controller and texture.
  /// Ordinary paused and poster-only hosts keep their existing behavior.
  final bool prepareFirstFrame;

  /// Whether to show downloading/first-frame progress. When false, keep the
  /// poster without a spinner/live announcement; real failure/retry UI remains.
  /// This affects presentation only; changing it never reloads the decoder.
  final bool showLoadingIndicator;

  /// Standalone previews retain inline loading/failure feedback. A host that
  /// provides its own download HUD opts out explicitly; a playback handle alone
  /// may be used for inspection and never implies that another HUD exists.
  final bool showInlineStatus;

  /// Optional native RGBA output for a backend with that capability. The
  /// default preserves the packed-shader path and other hosts' behavior.
  final bool nativeAlpha;

  /// Reports genuine decoded-frame readiness after the frame, never during a
  /// child's build. Pending reports are coalesced to the current source/state.
  /// Releasing a ready surface reports false, including final disposal; owners
  /// must ignore that final report after their own disposal. Defaults to null.
  final ValueChanged<bool>? onFrameReadyChanged;

  /// Keep the poster over a prepared paused surface until the host reveals it.
  /// This does not stop preparation, replace the decoder or change playback.
  /// Playing video reveals normally. The default preserves existing behavior.
  final bool revealPausedFrame;

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
  ValueListenable<CatalogMediaDownloadState>? _download;
  DrillMediaController? _controller;
  _VideoPin? _pin;
  Uri? _source;
  int _request = 0;
  bool _foreground = true;
  bool _visible = true;
  bool _failed = false;
  bool _tickersEnabled = true;
  bool _routeCurrent = true;
  bool _retainingExit = false;
  bool _retainingCovered = false;
  bool _playerV1 = false;
  Animation<double>? _exitAnimation;
  bool _primeAttempted = false;
  bool _frameReady = false;
  bool _deliveredFrameReady = false;
  int _frameReadyReport = 0;

  bool get _canPlay => widget.playing && _foreground && _visible;
  bool get _canPrepare =>
      (widget.playing || widget.prefetchWhenIdle) && _foreground && _visible;
  bool get _effectiveVisible =>
      (_tickersEnabled && _routeCurrent) || _retainingExit || _retainingCovered;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final policy = widget.policy ?? TrainingMediaPolicyScope.maybeOf(context);
    _playerV1 = TrainerV1MediaScope.of(context);
    _tickersEnabled = TickerMode.valuesOf(context).enabled;
    _routeCurrent = ModalRoute.isCurrentOf(context) ?? true;
    final wasRetainingCovered = _retainingCovered;
    _updateCoveredRetention();
    _bindExitAnimation();
    final visible = _effectiveVisible;
    if (!identical(policy, _policy) || visible != _visible) {
      _policy = policy;
      _visible = visible;
      _reload();
    } else if (_playerV1 && wasRetainingCovered != _retainingCovered) {
      _sync();
    }
  }

  @override
  void didUpdateWidget(TrainingActionMedia oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playbackHandle != widget.playbackHandle) {
      oldWidget.playbackHandle?.unbind(this);
    }
    if (oldWidget.playbackControl != widget.playbackControl) {
      oldWidget.playbackControl?.unbind(this);
    }
    final wasVisible = _visible;
    final wasRetainingCovered = _retainingCovered;
    _updateCoveredRetention();
    _visible = _effectiveVisible;
    if (oldWidget.retainSurfaceDuringRouteExit !=
        widget.retainSurfaceDuringRouteExit) {
      _bindExitAnimation();
      _visible = _effectiveVisible;
    }
    if (oldWidget.actionId != widget.actionId ||
        oldWidget.policy != widget.policy ||
        (oldWidget.playing || oldWidget.prefetchWhenIdle) !=
            (widget.playing || widget.prefetchWhenIdle) ||
        oldWidget.nativeAlpha != widget.nativeAlpha ||
        wasVisible != _visible) {
      _policy = widget.policy ?? TrainingMediaPolicyScope.read(context);
      _reload();
    } else if (oldWidget.paused != widget.paused ||
        oldWidget.playing != widget.playing ||
        oldWidget.prepareFirstFrame != widget.prepareFirstFrame ||
        (_playerV1 && wasRetainingCovered != _retainingCovered)) {
      if (widget.paused && _controller?.hasFrame != true) {
        _primeAttempted = false;
      }
      _sync();
    }
    _bindHandle();
    if (oldWidget.onFrameReadyChanged != widget.onFrameReadyChanged) {
      _deliveredFrameReady = false;
      _scheduleFrameReadiness(force: true);
    }
  }

  void _scheduleFrameReadiness({
    bool force = false,
    bool afterDisposal = false,
  }) {
    final ready = _controller?.hasFrame == true && _controller?.failed != true;
    if (!force && ready == _frameReady) return;
    _frameReady = ready;
    final report = ++_frameReadyReport;
    final callback = widget.onFrameReadyChanged;
    if (callback == null) return;
    final request = _request;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (report != _frameReadyReport ||
          request != _request ||
          (!mounted && !afterDisposal) ||
          callback != widget.onFrameReadyChanged) {
        return;
      }
      _deliveredFrameReady = ready;
      callback(ready);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _updateCoveredRetention() {
    final retain = _playerV1
        ? widget.playing || widget.prefetchWhenIdle
        : widget.retainPausedSurfaceWhileCovered &&
              widget.playing &&
              widget.paused &&
              _controller?.hasFrame == true;
    if (!retain ||
        !_foreground ||
        _controller?.failed == true ||
        ModalRoute.of(context)?.animation?.status == AnimationStatus.reverse) {
      _retainingCovered = false;
    } else if (!_routeCurrent) {
      _retainingCovered = true;
    } else if (_tickersEnabled) {
      _retainingCovered = false;
    }
    // During pop, isCurrent can become true before TickerMode is re-enabled.
    // Keep only a previously retained frame across that ordering; a current
    // route with an unrelated disabled TickerMode never starts retaining.
  }

  void _bindExitAnimation() {
    final animation = widget.retainSurfaceDuringRouteExit
        ? ModalRoute.of(context)?.animation
        : null;
    if (identical(animation, _exitAnimation)) return;
    _exitAnimation?.removeStatusListener(_exitStatusChanged);
    _exitAnimation = animation;
    _retainingExit =
        animation?.status == AnimationStatus.reverse && _controller != null;
    animation?.addStatusListener(_exitStatusChanged);
  }

  void _exitStatusChanged(AnimationStatus status) {
    // Flutter starts the route's reverse animation before notifying its subtree
    // of isCurrent/TickerMode changes. Keep only the surface that already exists;
    // never start a waiting video merely because its route is leaving.
    _retainingExit =
        widget.retainSurfaceDuringRouteExit &&
        status == AnimationStatus.reverse &&
        _controller != null;
    final visible = _effectiveVisible;
    if (!mounted || visible == _visible) return;
    setState(() {
      _visible = visible;
      _reload();
    });
  }

  void _bindHandle() {
    widget.playbackHandle?.bind(
      owner: this,
      mediaId: widget.actionId,
      controller: _controller,
      failed: _failed,
      onRetry: () {
        if (mounted) setState(_reload);
      },
    );
    widget.playbackControl?.bind(owner: this, controller: _controller);
  }

  void _stop({bool afterDisposal = false}) {
    _retainingExit = false;
    _retainingCovered = false;
    _primeAttempted = false;
    ++_request;
    _download?.removeListener(_changed);
    _download = null;
    _controller?.removeListener(_decoderChanged);
    _controller?.dispose();
    _controller = null;
    _source = null;
    _scheduleFrameReadiness(
      force: _deliveredFrameReady,
      afterDisposal: afterDisposal,
    );
    final pin = _pin;
    _pin = null;
    // An attached native decoder releases its pin after asynchronous disposal.
    if (pin != null && !pin.attached) pin.release();
    _bindHandle();
  }

  void _reload() {
    _stop();
    _visible = _effectiveVisible;
    _failed = false;
    final policy = _policy;
    final action = policy?.actionFor(widget.actionId);
    // Prepare only the active action and respect retained-route visibility.
    if (!_canPrepare ||
        policy == null ||
        action == null ||
        !UgkPackedAlphaVideo.isSupportedFor(nativeAlpha: widget.nativeAlpha)) {
      _bindHandle();
      return;
    }
    final pin = _pin = _VideoPin(policy.repository.retainVideo(action.id));
    _download = policy.repository.watchFile(action.video)
      ..addListener(_changed);
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
    if (!_canPlay || (_playerV1 && _retainingCovered)) {
      controller.pause();
    } else if (widget.paused) {
      if (widget.prepareFirstFrame && !controller.hasFrame) {
        if (!controller.ready) controller.pause();
        _primeIfNeeded();
      } else {
        controller.pause();
      }
    } else if (!controller.wantsPlay) {
      controller.toggle();
    }
  }

  void _primeIfNeeded() {
    final controller = _controller;
    if (_primeAttempted ||
        !_canPlay ||
        (_playerV1 && _retainingCovered) ||
        !widget.paused ||
        !widget.prepareFirstFrame ||
        controller == null ||
        !controller.ready ||
        controller.hasFrame ||
        controller.failed) {
      return;
    }
    _primeAttempted = true;
    unawaited(controller.prepareFirstFrame());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _decoderChanged() {
    if (!mounted) return;
    _scheduleFrameReadiness();
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
      _primeIfNeeded();
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
    _exitAnimation?.removeStatusListener(_exitStatusChanged);
    _stop(afterDisposal: true);
    widget.playbackHandle?.unbind(this);
    widget.playbackControl?.unbind(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final poster = _policy?.posterAssetFor(widget.actionId);
    final experience = TrainerExperienceScope.maybeOf(context);
    final stage = widget.stage ?? Theme.of(context).colorScheme.surface;
    final controller = _controller;
    final revealed =
        controller?.hasFrame == true &&
        controller?.failed != true &&
        (_playerV1 || !widget.paused || widget.revealPausedFrame);
    final revealDuration = _playerV1
        ? Duration.zero
        : const Duration(milliseconds: 120);
    final progress = _download?.value.progress;
    final supported = UgkPackedAlphaVideo.isSupportedFor(
      nativeAlpha: widget.nativeAlpha,
    );
    // Preserve standalone silent preparation and failure/retry feedback while
    // allowing the player's separate download HUD to own presentation.
    final showStatus =
        widget.showInlineStatus &&
        poster != null &&
        _canPlay &&
        supported &&
        !revealed &&
        (_failed ||
            (widget.showLoadingIndicator &&
                !(widget.paused && !widget.revealPausedFrame)));
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
                    duration: revealDuration,
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
                    duration: revealDuration,
                    child: _PinnedPackedVideo(
                      key: ObjectKey(controller),
                      source: _source!,
                      controller: controller,
                      pin: _pin!,
                      nativeAlpha: widget.nativeAlpha,
                    ),
                  ),
                if (showStatus)
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: Center(
                      child: _failed
                          ? TextButton(
                              key: const ValueKey('public-action-retry'),
                              onPressed: () => setState(_reload),
                              child: const Text('视频暂不可用，训练继续 · 重试'),
                            )
                          : Semantics(
                              liveRegion: true,
                              child: SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  key: const ValueKey('public-action-progress'),
                                  value: progress,
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
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
    required this.nativeAlpha,
  });
  final Uri source;
  final DrillMediaController controller;
  final _VideoPin pin;
  final bool nativeAlpha;
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
    nativeAlpha: widget.nativeAlpha,
  );
}
