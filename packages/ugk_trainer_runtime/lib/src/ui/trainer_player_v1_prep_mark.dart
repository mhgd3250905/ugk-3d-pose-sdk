import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'trainer_player_motion.dart';
import 'trainer_theme.dart';

/// The center of the stage during the last three preparation seconds and the
/// start cue. The player still owns phase timing and the bottom clock.
class TrainerV1PrepMark extends StatefulWidget {
  const TrainerV1PrepMark({
    super.key,
    required this.label,
    required this.starting,
    required this.theme,
  });

  final String label;
  final bool starting;
  final TrainerTheme theme;

  @override
  State<TrainerV1PrepMark> createState() => _TrainerV1PrepMarkState();
}

class _TrainerV1PrepMarkState extends State<TrainerV1PrepMark>
    with SingleTickerProviderStateMixin {
  static const _intro = Duration(milliseconds: 320);
  static const _digitDuration = Duration(seconds: 1);
  static const _digitExit = Duration(milliseconds: 760);
  static const _startHold = Duration(milliseconds: 400);
  static const _outro = Duration(milliseconds: 200);

  late final _clock = AnimationController(
    vsync: this,
    animationBehavior: AnimationBehavior.preserve,
  );
  late final _spring = SpringSimulation(PlayerMotion.spring, 1.6, 1, 0);
  late final _springEnd = _spring.x(
    _intro.inMicroseconds / Duration.microsecondsPerSecond,
  );
  bool? _reduced;

  Duration get _fadeIn => _reduced! ? PlayerMotion.reducedFade : _intro;
  Duration get _fadeOut => _reduced! ? PlayerMotion.reducedFade : _outro;
  Duration get _exitAt => widget.starting
      ? _fadeIn + _startHold
      : _reduced!
      ? _digitDuration - _fadeOut
      : _digitExit;
  Duration get _duration =>
      widget.starting ? _exitAt + _fadeOut : _digitDuration;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = TrainerMotion.reduced(context);
    if (_reduced == reduced) return;
    final elapsed = (_clock.duration?.inMicroseconds ?? 0) * _clock.value;
    _reduced = reduced;
    _startAt(elapsed);
  }

  @override
  void didUpdateWidget(TrainerV1PrepMark oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.label != widget.label ||
        oldWidget.starting != widget.starting) {
      _startAt(0);
    }
  }

  void _startAt(double elapsed) {
    _clock.duration = _duration;
    _clock.forward(from: (elapsed / _duration.inMicroseconds).clamp(0.0, 1.0));
  }

  double _ramp(double elapsed, Duration delay, Duration duration) =>
      ((elapsed - delay.inMicroseconds) / duration.inMicroseconds).clamp(
        0.0,
        1.0,
      );

  @override
  Widget build(BuildContext context) {
    final reduced = _reduced!;
    final theme = widget.theme;
    final style = DefaultTextStyle.of(context).style.merge(
      theme
          .numeral(widget.starting ? 72 : 160)
          .copyWith(color: Colors.white, fontWeight: FontWeight.w900),
    );
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: AnimatedBuilder(
              animation: _clock,
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _PrepMarkShadow(
                    label: widget.label,
                    style: style,
                    textDirection: Directionality.of(context),
                    textScaler: MediaQuery.textScalerOf(context),
                    shadow: Shadow(
                      color: theme.accent.withValues(alpha: .35),
                      offset: const Offset(0, 8),
                      blurRadius: 24,
                    ),
                  ),
                  child: ShaderMask(
                    blendMode: BlendMode.srcIn,
                    shaderCallback: (rect) => LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [theme.accent, theme.accentDeep],
                    ).createShader(rect),
                    child: Text(
                      widget.label,
                      key: ValueKey(
                        widget.starting
                            ? 'player-v1-start-label'
                            : 'player-v1-prep-digit',
                      ),
                      style: style,
                      maxLines: 1,
                    ),
                  ),
                ),
              ),
              builder: (_, child) {
                final elapsed = (_clock.value * _duration.inMicroseconds)
                    .roundToDouble();
                final entered = _ramp(elapsed, Duration.zero, _fadeIn);
                final exit = _ramp(elapsed, _exitAt, _fadeOut);
                final faded = reduced
                    ? exit
                    : PlayerMotion.exit.transform(exit);
                final opacity = entered * (1 - faded);
                // Normalize the sampled spring so the entry lands at 1.0
                // precisely when the 320 ms fade completes.
                final seconds = elapsed / Duration.microsecondsPerSecond;
                final scale = entered == 1 || reduced
                    ? 1.0
                    : 1 +
                          .6 *
                              (_spring.x(seconds) - _springEnd) /
                              (1.6 - _springEnd);
                final glyph = Opacity(
                  key: const ValueKey('player-v1-prep-opacity'),
                  opacity: opacity,
                  child: reduced
                      ? child
                      : Transform.scale(
                          key: const ValueKey('player-v1-prep-scale'),
                          scale: scale * (1 - .15 * faded),
                          child: child,
                        ),
                );
                if (widget.starting) return glyph;
                return SizedBox.square(
                  dimension: 220,
                  child: Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.none,
                    children: [
                      Opacity(
                        opacity: entered * (reduced ? 1 - faded : 1),
                        child: const SizedBox.square(
                          key: ValueKey('player-v1-prep-halo'),
                          dimension: 200,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  Color.from(
                                    alpha: .85,
                                    red: 1,
                                    green: 1,
                                    blue: 1,
                                  ),
                                  Color(0x00FFFFFF),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (!reduced)
                        SizedBox.expand(
                          child: CustomPaint(
                            key: const ValueKey('player-v1-prep-ring'),
                            painter: TrainerV1PrepRingPainter(
                              _clock.value,
                              theme.accent,
                            ),
                          ),
                        ),
                      glyph,
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }
}

/// Paints a four-pixel sweep inside the mark bounds.
class TrainerV1PrepRingPainter extends CustomPainter {
  const TrainerV1PrepRingPainter(this.progress, this.color);

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress == 0) return;
    const stroke = 4.0;
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - stroke) / 2;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    if (progress == 1) {
      canvas.drawCircle(center, radius, paint);
    } else {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(TrainerV1PrepRingPainter old) =>
      progress != old.progress || color != old.color;
}

/// Keep the glow outside the ShaderMask so it retains its accent color.
class _PrepMarkShadow extends CustomPainter {
  const _PrepMarkShadow({
    required this.label,
    required this.style,
    required this.textDirection,
    required this.textScaler,
    required this.shadow,
  });

  final String label;
  final TextStyle style;
  final TextDirection textDirection;
  final TextScaler textScaler;
  final Shadow shadow;

  @override
  void paint(Canvas canvas, Size size) {
    final text = TextPainter(
      text: TextSpan(
        text: label,
        style: style.copyWith(foreground: shadow.toPaint()),
      ),
      textDirection: textDirection,
      textScaler: textScaler,
      maxLines: 1,
    )..layout(maxWidth: size.width);
    text.paint(canvas, shadow.offset);
    text.dispose();
  }

  @override
  bool shouldRepaint(_PrepMarkShadow old) =>
      old.label != label ||
      old.style != style ||
      old.textDirection != textDirection ||
      old.textScaler != textScaler ||
      old.shadow != shadow;
}
