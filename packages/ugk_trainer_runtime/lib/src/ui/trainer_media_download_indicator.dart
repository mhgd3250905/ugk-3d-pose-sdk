import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../media/catalog_media_repository.dart';
import '../media/media_playback_handle.dart';
import 'trainer_strings.dart';
import 'trainer_surface.dart';
import 'trainer_theme.dart';

/// Download feedback on the player's HUD, independently of the video renderer.
///
/// [state] may come from the shared catalogue repository or a host's downloader.
/// Completion requires both a ready file and a matching [playbackHandle] with a
/// decoded frame. Custom renderers bind the handle supplied by the player.
/// Download scheduling, playback, and retention remain owned by the player.
class TrainerMediaDownloadIndicator extends StatefulWidget {
  static const visualSize = 36.0;
  static const hitTargetSize = 44.0;
  static const visualInset = (hitTargetSize - visualSize) / 2;
  const TrainerMediaDownloadIndicator({
    super.key,
    required this.state,
    required this.actionId,
    required this.theme,
    required this.strings,
    required this.playbackHandle,
    required this.onRetry,
    this.playbackMediaId,
    this.videoSupported = true,
  });

  final ValueListenable<CatalogMediaDownloadState> state;
  final String actionId;
  final String? playbackMediaId;
  final TrainerTheme theme;
  final TrainerStrings strings;
  final DrillMediaPlaybackHandle playbackHandle;
  final VoidCallback onRetry;
  final bool videoSupported;

  @override
  State<TrainerMediaDownloadIndicator> createState() =>
      _TrainerMediaDownloadIndicatorState();
}

class _TrainerMediaDownloadIndicatorState
    extends State<TrainerMediaDownloadIndicator>
    with TickerProviderStateMixin {
  late final AnimationController _opacity = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
    reverseDuration: const Duration(milliseconds: 200),
  )..addListener(_opacityChanged);
  late final AnimationController _progress = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  late final AnimationController _rotation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );
  Timer? _delay;
  Timer? _completion;
  Timer? _chipExpiry;
  CatalogMediaDownloadPhase? _phase;
  double _maximumProgress = 0;
  bool _visible = false;
  bool _complete = false;
  bool _hiding = false;
  bool _failureExplained = false;
  bool _announce = false;
  int _announcement = 0;
  String? _chip;

  bool get _bound =>
      widget.playbackHandle.isBound &&
      (widget.playbackHandle.mediaId == widget.actionId ||
          widget.playbackHandle.mediaId == widget.playbackMediaId);
  bool get _decoderFailed => _bound && widget.playbackHandle.failed;
  bool get _hasFrame => _bound && widget.playbackHandle.hasFrame;
  bool get _failed => _phase == CatalogMediaDownloadPhase.failed;
  bool get _verifying => _phase == CatalogMediaDownloadPhase.verifying;
  bool get _indeterminate =>
      !_failed &&
      !_verifying &&
      _phase != CatalogMediaDownloadPhase.ready &&
      (_phase != CatalogMediaDownloadPhase.downloading ||
          widget.state.value.progress == null);

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_changed);
    widget.playbackHandle.addListener(_changed);
    _reset();
  }

  @override
  void didUpdateWidget(TrainerMediaDownloadIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_changed);
      widget.state.addListener(_changed);
    }
    if (oldWidget.playbackHandle != widget.playbackHandle) {
      oldWidget.playbackHandle.removeListener(_changed);
      widget.playbackHandle.addListener(_changed);
    }
    if (oldWidget.actionId != widget.actionId ||
        oldWidget.state != widget.state ||
        oldWidget.videoSupported != widget.videoSupported) {
      _reset();
    } else {
      _refresh();
    }
  }

  void _reset() {
    _delay?.cancel();
    _completion?.cancel();
    _chipExpiry?.cancel();
    _delay = null;
    _completion = null;
    _chip = null;
    _phase = null;
    _maximumProgress = 0;
    _visible = false;
    _complete = false;
    _hiding = false;
    _failureExplained = false;
    _opacity.value = 0;
    _progress.value = 0;
    _refresh();
  }

  void _changed() {
    if (!mounted) return;
    setState(_refresh);
  }

  void _refresh() {
    if (!widget.videoSupported) return;
    final state = widget.state.value;
    final phase = _decoderFailed
        ? CatalogMediaDownloadPhase.failed
        : state.phase;
    final phaseChanged = phase != _phase;
    _phase = phase;
    if (phaseChanged) _announceChange();
    _maximumProgress = math.max(_maximumProgress, state.progress ?? 0);

    if (_failed) {
      _delay?.cancel();
      _delay = null;
      _completion?.cancel();
      _completion = null;
      _complete = false;
      _show();
      _progress.stop();
      _progress.value = 0;
      if (!_failureExplained) {
        _failureExplained = true;
        _showChip(
          widget.strings.mediaDownloadFailed,
          const Duration(seconds: 3),
        );
      }
    } else if (phase == CatalogMediaDownloadPhase.ready) {
      _delay?.cancel();
      _delay = null;
      _maximumProgress = 1;
      _animateProgress(1);
      if (_visible && _complete && !_hasFrame) {
        _completion?.cancel();
        _completion = null;
        _complete = false;
        _announceChange();
        _show();
      }
      if (_visible && _hasFrame && !_complete) {
        _complete = true;
        _chipExpiry?.cancel();
        _chip = null;
        _announceChange();
        _completion = Timer(const Duration(milliseconds: 400), () {
          if (!mounted) return;
          if (widget.state.value.phase != CatalogMediaDownloadPhase.ready ||
              !_hasFrame) {
            _changed();
            return;
          }
          _hiding = true;
          _opacity.reverse();
        });
      }
    } else {
      if (_complete) {
        _complete = false;
        _hiding = false;
        _completion?.cancel();
        _completion = null;
      }
      if (_verifying) _maximumProgress = 1;
      _animateProgress(_verifying ? 1 : _maximumProgress);
      _delay ??= Timer(const Duration(milliseconds: 400), () {
        if (!mounted ||
            widget.state.value.phase == CatalogMediaDownloadPhase.ready) {
          return;
        }
        setState(_show);
      });
    }
    _syncAnimations();
  }

  void _show() {
    if (!_visible) _announceChange();
    _visible = true;
    _hiding = false;
    _opacity.forward();
    _syncAnimations();
  }

  void _animateProgress(double value) {
    if (_progress.value == value) return;
    _progress.animateTo(
      value,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _syncAnimations() {
    if (_visible && _indeterminate) {
      if (!_rotation.isAnimating) _rotation.repeat();
    } else {
      _rotation.stop();
    }
    if (_visible && _verifying) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
    }
  }

  void _opacityChanged() {
    // AnimationController reports dismissed on the frame after its interpolation
    // reaches zero. Remove the hit target as soon as the 200 ms fade is invisible.
    if (_opacity.value == 0 && _hiding && mounted) {
      setState(() {
        _visible = false;
        _hiding = false;
        _syncAnimations();
      });
    }
  }

  void _announceChange() {
    _announce = true;
    final announcement = ++_announcement;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && announcement == _announcement && _announce) {
        setState(() => _announce = false);
      }
    });
  }

  int? get _percentage => widget.state.value.progress == null
      ? null
      : (_maximumProgress * 100).round().clamp(0, 100);

  void _showChip(String message, Duration duration) {
    _chipExpiry?.cancel();
    _chip = message;
    _chipExpiry = Timer(duration, () {
      if (mounted) setState(() => _chip = null);
    });
  }

  void _activate() {
    if (_failed) {
      _completion?.cancel();
      _completion = null;
      _complete = false;
      _maximumProgress = 0;
      _progress.value = 0;
      widget.onRetry();
    } else if (!_complete) {
      setState(() {
        _showChip(
          widget.strings.mediaDownloading(_percentage),
          const Duration(seconds: 2),
        );
      });
    }
  }

  String get _semanticsLabel => _failed
      ? widget.strings.mediaDownloadFailedSemantics
      : _complete
      ? widget.strings.mediaDownloadReady
      : _verifying
      ? widget.strings.mediaDownloadVerifying
      : widget.strings.mediaDownloadingSemantics(_percentage);

  @override
  Widget build(BuildContext context) {
    if (!widget.videoSupported || !_visible) return const SizedBox.shrink();
    final theme = widget.theme;
    final color = _failed ? theme.caution : theme.accent;
    final ring = SizedBox.square(
      dimension: 22,
      child: _failed
          ? _ring(color.withValues(alpha: 0), 0)
          : _indeterminate
          ? RotationTransition(
              key: const ValueKey('media-download-indeterminate'),
              turns: _rotation,
              child: _ring(color, .25),
            )
          : AnimatedBuilder(
              animation: _progress,
              builder: (context, _) => _ring(color, _progress.value),
            ),
    );
    final icon = Icon(
      _failed
          ? CupertinoIcons.arrow_clockwise
          : _complete
          ? CupertinoIcons.check_mark
          : CupertinoIcons.arrow_down,
      key: ValueKey(
        _failed
            ? 'media-download-retry'
            : _complete
            ? 'media-download-ready'
            : 'media-download-arrow',
      ),
      size: 12,
      color: color,
    );
    return FadeTransition(
      key: const ValueKey('media-download-visibility'),
      opacity: _opacity,
      child: Semantics(
        key: const ValueKey('media-download-status'),
        button: true,
        label: _semanticsLabel,
        liveRegion: _announce,
        onTap: _activate,
        excludeSemantics: true,
        child: GestureDetector(
          key: const ValueKey('media-download-indicator'),
          behavior: HitTestBehavior.opaque,
          onTap: _activate,
          child: SizedBox.square(
            dimension: TrainerMediaDownloadIndicator.hitTargetSize,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.centerRight,
              children: [
                TrainerSurface(
                  key: const ValueKey('media-download-surface'),
                  theme: theme,
                  width: TrainerMediaDownloadIndicator.visualSize,
                  height: TrainerMediaDownloadIndicator.visualSize,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      ring,
                      if (_verifying)
                        FadeTransition(
                          key: const ValueKey('media-download-verifying'),
                          opacity: Tween(begin: .65, end: 1.0).animate(_pulse),
                          child: icon,
                        )
                      else
                        icon,
                    ],
                  ),
                ),
                if (_chip case final message?)
                  Positioned(
                    right: 44 + TrainerSpace.x2,
                    top: 6,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: math.max(
                          100,
                          MediaQuery.sizeOf(context).width - 100,
                        ),
                      ),
                      child: TrainerSurface(
                        key: const ValueKey('media-download-chip'),
                        theme: theme,
                        padding: const EdgeInsets.symmetric(
                          horizontal: TrainerSpace.x3,
                          vertical: TrainerSpace.x2,
                        ),
                        child: Text(
                          message,
                          maxLines: 2,
                          style: TextStyle(
                            fontFamily: theme.fontFamily,
                            fontSize: 12,
                            color: theme.text,
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

  Widget _ring(Color color, double value) => CircularProgressIndicator(
    key: const ValueKey('media-download-progress'),
    value: value,
    color: color,
    backgroundColor: widget.theme.text.withValues(alpha: .12),
    strokeWidth: 2,
    strokeCap: StrokeCap.round,
    trackGap: 0,
    constraints: const BoxConstraints.tightFor(width: 22, height: 22),
  );

  @override
  void dispose() {
    widget.state.removeListener(_changed);
    widget.playbackHandle.removeListener(_changed);
    _delay?.cancel();
    _completion?.cancel();
    _chipExpiry?.cancel();
    _opacity.dispose();
    _progress.dispose();
    _rotation.dispose();
    _pulse.dispose();
    super.dispose();
  }
}
