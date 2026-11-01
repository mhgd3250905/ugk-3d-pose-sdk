import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'countdown_ring.dart';
import 'trainer_strings.dart';
import 'trainer_theme.dart';

/// The shared training play/pause control. [isPlaying] is the source of truth;
/// a local tap responds immediately, then reconciles with the host's state.
class UgkPlayPauseButton extends StatefulWidget {
  const UgkPlayPauseButton({
    super.key,
    required this.isPlaying,
    required this.progress,
    required this.onTap,
    required this.theme,
    required this.strings,
    this.progressColor,
    this.trackColor,
    this.knobColor,
    this.size = 76,
    this.ringSize = 96,
    this.iconSize = 38,
  }) : assert(size >= 48),
       assert(ringSize >= size),
       assert(iconSize > 0);

  final bool isPlaying;
  final ValueListenable<double> progress;
  final VoidCallback onTap;
  final TrainerTheme theme;
  final TrainerStrings strings;
  final Color? progressColor;
  final Color? trackColor;
  final Color? knobColor;
  final double size;
  final double ringSize;
  final double iconSize;

  @override
  State<UgkPlayPauseButton> createState() => _UgkPlayPauseButtonState();
}

class _UgkPlayPauseButtonState extends State<UgkPlayPauseButton>
    with TickerProviderStateMixin {
  static const _morphDuration = Duration(milliseconds: 260);
  static const _colorDuration = Duration(milliseconds: 280);
  static const _reducedDuration = Duration(milliseconds: 150);
  static const _confirmationWindow = Duration(milliseconds: 320);

  late bool _playing = widget.isPlaying;
  bool _reduced = false;
  bool _focused = false;
  bool _pressed = false;
  bool _pointerCancelled = false;
  bool _optimistic = false;
  Timer? _confirmation;

  // Unbounded morph permits the specified easeOutBack overshoot. Every new
  // target animates from the controller's current value, including reversals.
  late final _morph = AnimationController.unbounded(
    vsync: this,
    value: _playing ? 1 : 0,
  );
  late final _settle = AnimationController.unbounded(vsync: this);
  late final _color = AnimationController.unbounded(vsync: this);
  late final _ripple = AnimationController.unbounded(vsync: this);
  late final _press = AnimationController.unbounded(vsync: this, value: 1);
  late final _atmosphere = AnimationController(
    vsync: this,
    value: _playing ? 1 : 0,
    duration: const Duration(milliseconds: 200),
  );
  late final _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  late final _animation = Listenable.merge([
    _morph,
    _settle,
    _color,
    _ripple,
    _press,
    _atmosphere,
    _breath,
  ]);

  late Color _baseColor = _discColor;
  Color? _newColor;
  final _layers = <_ColorLayer>[];
  double _colorStart = 0;
  int _colorOwner = 0;
  double _settleStart = -1;
  double _initialX = 0;
  double _initialYScale = 1;
  double _rippleStart = -1;
  Color? _rippleColor;

  Color get _discColor =>
      _playing ? widget.theme.accent : widget.theme.pausedColor;
  double get _colorProgress => (_color.value - _colorStart).clamp(0.0, 1.0);
  double get _settleProgress => (_settle.value - _settleStart).clamp(0.0, 1.0);
  double get _rippleProgress => (_ripple.value - _rippleStart).clamp(0.0, 1.0);

  double get _iconX {
    final t = _settleProgress;
    final tail = ((t - 140 / 260) / (120 / 260)).clamp(0.0, 1.0);
    return _initialX * (1 - Curves.easeOutCubic.transform(t)) +
        (_playing ? 0 : 2 * math.sin(math.pi * tail));
  }

  double get _iconYScale {
    final t = _settleProgress;
    final first = (t / (140 / 260)).clamp(0.0, 1.0);
    final tail = ((t - 140 / 260) / (120 / 260)).clamp(0.0, 1.0);
    final squash = _playing
        ? (t < 140 / 260
              ? Curves.easeOut.transform(first)
              : 1 - Curves.easeOutCubic.transform(tail))
        : 0;
    return 1 + (_initialYScale - 1) * (1 - t) - .14 * squash;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = TrainerMotion.reduced(context);
    if (_reduced != reduced) {
      _reduced = reduced;
      if (reduced) {
        _press.stop();
        _ripple.stop();
        _rippleColor = null;
      }
      _animateTarget(_playing, motionChanged: true);
    }
    _ambient();
  }

  @override
  void didUpdateWidget(UgkPlayPauseButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_optimistic || oldWidget.isPlaying != widget.isPlaying) {
      _confirmation?.cancel();
      _optimistic = false;
      _animateTarget(widget.isPlaying);
    } else if (oldWidget.theme != widget.theme) {
      _animateColor(_discColor);
    }
  }

  void _ambient() {
    if (!_reduced && !_playing) {
      if (!_breath.isAnimating) {
        _breath.repeat(
          reverse: true,
          period: const Duration(milliseconds: 1200),
        );
      }
    } else {
      _breath.stop();
    }
  }

  void _animateTarget(bool playing, {bool motionChanged = false}) {
    final changed = _playing != playing;
    final initialX = _reduced ? 0.0 : _iconX;
    final initialYScale = _reduced ? 1.0 : _iconYScale;
    _playing = playing;
    if (changed || motionChanged) {
      _initialX = initialX;
      _initialYScale = initialYScale;
      _morph.animateTo(
        playing ? 1 : 0,
        duration: _reduced ? _reducedDuration : _morphDuration,
        curve: _reduced
            ? Curves.linear
            : playing
            ? Curves.easeOutBack
            : Curves.easeOutCubic,
      );
      if (_reduced) {
        _settle.stop();
      } else {
        _settleStart = _settle.value;
        _settle.animateTo(
          _settleStart + 1,
          duration: _morphDuration,
          curve: Curves.linear,
        );
      }
    }
    _animateColor(_discColor);
    if (changed || motionChanged) {
      _atmosphere.animateTo(
        playing ? 1 : 0,
        duration: _reduced
            ? _reducedDuration
            : const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    }
    _ambient();
  }

  void _animateColor(Color target) {
    if (_newColor == target || (_newColor == null && _baseColor == target)) {
      return;
    }
    // Freeze the previous composite, rather than returning to its old flat
    // background when an expanding colour wave is interrupted.
    if (_newColor case final color?) {
      _layers.add(_ColorLayer(color, _colorProgress, _reduced));
    }
    _newColor = target;
    _colorStart = _color.value;
    final owner = ++_colorOwner;
    _color
        .animateTo(
          _colorStart + 1,
          duration: _reduced ? _reducedDuration : _colorDuration,
          curve: _reduced ? Curves.linear : Curves.easeOutCubic,
        )
        .whenCompleteOrCancel(() {
          if (!mounted || owner != _colorOwner || _colorProgress < 1) return;
          setState(() {
            _baseColor = target;
            _newColor = null;
            _layers.clear();
          });
        });
  }

  void _pressDown() {
    _pointerCancelled = false;
    _pressed = true;
    if (!_reduced) {
      _press.animateTo(
        .92,
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
      );
    }
  }

  void _release({bool activate = false}) {
    _pressed = false;
    if (_reduced) return;
    if (activate) {
      _press.animateWith(
        SpringSimulation(
          const SpringDescription(mass: 1, stiffness: 350, damping: 10),
          _press.value,
          1,
          0,
        ),
      );
    } else {
      _press.animateTo(
        1,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _activate() {
    _release(activate: true);
    _confirmation?.cancel();
    setState(() {
      _optimistic = true;
      _animateTarget(!_playing);
      if (!_reduced) {
        _rippleStart = _ripple.value;
        _rippleColor = _discColor;
        _ripple.animateTo(
          _rippleStart + 1,
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOut,
        );
      }
    });
    _confirmation = Timer(_confirmationWindow, () {
      if (!mounted || !_optimistic) return;
      setState(() {
        _optimistic = false;
        _animateTarget(widget.isPlaying);
      });
    });
    unawaited(HapticFeedback.lightImpact());
    widget.onTap();
  }

  void _cancel() {
    _pointerCancelled = true;
    _release();
  }

  bool _inside(Offset position) =>
      (Offset.zero & Size.square(widget.ringSize)).contains(position);

  @override
  void dispose() {
    _confirmation?.cancel();
    for (final c in [
      _morph,
      _settle,
      _color,
      _ripple,
      _press,
      _atmosphere,
      _breath,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.isPlaying
        ? widget.strings.pause
        : widget.strings.resume;
    return RepaintBoundary(
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _activate();
              return null;
            },
          ),
          ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
            onInvoke: (_) {
              _activate();
              return null;
            },
          ),
        },
        child: Tooltip(
          message: label,
          child: Semantics(
            button: true,
            enabled: true,
            label: label,
            excludeSemantics: true,
            onTap: _activate,
            child: Listener(
              onPointerDown: (_) => _pressDown(),
              onPointerMove: (event) {
                if (!_inside(event.localPosition)) _cancel();
              },
              onPointerCancel: (_) => _cancel(),
              onPointerUp: (_) => scheduleMicrotask(() {
                if (mounted && _pressed) _release();
              }),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onTapCancel: _cancel,
                onTapUp: (details) {
                  if (!_pointerCancelled && _inside(details.localPosition)) {
                    _activate();
                  } else {
                    _cancel();
                  }
                },
                child: SizedBox.square(
                  dimension: widget.ringSize,
                  child: AnimatedBuilder(
                    animation: _animation,
                    builder: (_, _) => _face(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _face() {
    final th = widget.theme;
    final breath = _reduced
        ? 1.0
        : 1 +
              .03 *
                  Curves.easeInOutSine.transform(_breath.value) *
                  (1 - _atmosphere.value);
    final press = _reduced ? 1.0 : _press.value.clamp(.92, 1.04);
    final glyph = Color.lerp(
      th.onPaused,
      th.onAccent,
      _morph.value.clamp(0.0, 1.0),
    )!;
    return Transform.scale(
      key: const ValueKey('button-press'),
      scale: press,
      child: Transform.scale(
        key: const ValueKey('button-breath'),
        scale: breath,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            RepaintBoundary(
              child: Opacity(
                opacity: .5 + .5 * _atmosphere.value,
                child: CustomPaint(
                  key: const ValueKey('ring'),
                  size: Size.square(widget.ringSize),
                  painter: TrainerRingPainter(
                    widget.progress,
                    track:
                        widget.trackColor ??
                        (th.isDark ? th.surfaceHigh : th.track),
                    color: widget.progressColor ?? th.accent,
                    knob: widget.knobColor ?? th.ringKnob,
                    glow: !_reduced,
                    glowOpacity: _atmosphere.value,
                    glowBlur: 4,
                    thickness: .032,
                  ),
                ),
              ),
            ),
            if (!_reduced && _rippleColor != null && _rippleProgress < 1)
              IgnorePointer(
                child: OverflowBox(
                  maxWidth: widget.size * 1.35,
                  maxHeight: widget.size * 1.35,
                  child: CustomPaint(
                    key: const ValueKey('button-ripple'),
                    size: Size.square(widget.size * 1.35),
                    painter: _RipplePainter(
                      _rippleProgress,
                      _rippleColor!,
                      widget.size,
                    ),
                  ),
                ),
              ),
            DecoratedBox(
              decoration: ShapeDecoration(
                shape: const CircleBorder(),
                shadows: [
                  BoxShadow(
                    color: th.shadow,
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: SizedBox.square(
                dimension: widget.size,
                child: DecoratedBox(
                  key: _focused ? const ValueKey('play-pause-focus') : null,
                  position: DecorationPosition.foreground,
                  decoration: ShapeDecoration(
                    shape: CircleBorder(
                      side: BorderSide(
                        color: _focused ? th.accentText : th.border,
                        width: _focused ? 2.5 : 0,
                        strokeAlign: BorderSide.strokeAlignOutside,
                      ),
                    ),
                  ),
                  child: ClipOval(
                    child: CustomPaint(
                      key: const ValueKey('button-color'),
                      painter: _DiscPainter(
                        _baseColor,
                        List.of(_layers),
                        _newColor,
                        _colorProgress,
                        _reduced,
                        th.border,
                      ),
                      child: Center(
                        child: Transform.translate(
                          offset: Offset(_reduced ? 0 : _iconX, 0),
                          child: Transform.scale(
                            scaleY: _reduced ? 1 : _iconYScale,
                            child: CustomPaint(
                              key: const ValueKey('morph-icon'),
                              size: Size.square(widget.iconSize),
                              painter: _GlyphPainter(
                                _morph.value,
                                glyph,
                                _reduced,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
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

class _ColorLayer {
  const _ColorLayer(this.color, this.progress, this.crossFade);
  final Color color;
  final double progress;
  final bool crossFade;
}

class _DiscPainter extends CustomPainter {
  const _DiscPainter(
    this.baseColor,
    this.layers,
    this.newColor,
    this.progress,
    this.reduced,
    this.borderColor,
  );
  final Color baseColor;
  final List<_ColorLayer> layers;
  final Color? newColor;
  final double progress;
  final bool reduced;
  final Color borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // An opaque base remains behind every interrupted wave. Cross-fades only
    // blend state colours on that base, so settling a wave cannot change the
    // disc's opacity or expose the background. Morph Pulse timing and state
    // reconciliation are independent of this material paint.
    void disc(Color color, double amount, bool fade) {
      if (amount <= 0) return;
      canvas.save();
      if (!fade) {
        canvas.clipPath(
          Path()..addOval(
            Rect.fromCircle(
              center: rect.center,
              radius: size.width / 2 * amount,
            ),
          ),
        );
      }
      canvas.drawOval(
        rect,
        Paint()..color = color.withValues(alpha: fade ? amount : 1),
      );
      canvas.restore();
    }

    disc(baseColor, 1, false);
    for (final layer in layers) {
      disc(layer.color, layer.progress, layer.crossFade);
    }
    if (newColor case final color?) disc(color, progress, reduced);
    canvas.drawOval(
      rect.deflate(.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = borderColor,
    );
  }

  @override
  bool shouldRepaint(_DiscPainter old) =>
      old.baseColor != baseColor ||
      old.newColor != newColor ||
      old.progress != progress ||
      old.reduced != reduced ||
      old.borderColor != borderColor ||
      !listEquals(old.layers, layers);
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.morph, this.color, this.reduced);
  final double morph;
  final Color color;
  final bool reduced;
  double get playOpacity => 1 - morph.clamp(0.0, 1.0);
  double get pauseOpacity => morph.clamp(0.0, 1.0);

  static const _play = [
    [Offset(8, 5), Offset(13.5, 8.5), Offset(13.5, 15.5), Offset(8, 19)],
    [Offset(13.5, 8.5), Offset(19, 12), Offset(19, 12), Offset(13.5, 15.5)],
  ];
  static const _pause = [
    [Offset(6.5, 5), Offset(10.5, 5), Offset(10.5, 19), Offset(6.5, 19)],
    [Offset(13.5, 5), Offset(17.5, 5), Offset(17.5, 19), Offset(13.5, 19)],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    void glyph(double t, double opacity) {
      if (opacity <= 0) return;
      final paint = Paint()
        ..color = color.withValues(alpha: color.a * opacity)
        ..strokeWidth = 2.2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      for (var block = 0; block < 2; block++) {
        final points = List.generate(
          4,
          (i) => Offset.lerp(_play[block][i], _pause[block][i], t)!,
        );
        final path = Path()..addPolygon(points, true);
        canvas.drawPath(path, paint..style = PaintingStyle.fill);
        canvas.drawPath(path, paint..style = PaintingStyle.stroke);
      }
    }

    if (reduced) {
      glyph(0, playOpacity);
      glyph(1, pauseOpacity);
    } else {
      glyph(morph, 1);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.morph != morph || old.color != color || old.reduced != reduced;
}

class _RipplePainter extends CustomPainter {
  const _RipplePainter(this.progress, this.color, this.diameter);
  final double progress;
  final Color color;
  final double diameter;
  @override
  void paint(Canvas canvas, Size size) => canvas.drawCircle(
    size.center(Offset.zero),
    diameter / 2 * (1 + .35 * progress),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color.withValues(alpha: .35 * (1 - progress)),
  );
  @override
  bool shouldRepaint(_RipplePainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.diameter != diameter;
}
