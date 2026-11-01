import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/chat_theme.dart';

/// The endless space behind the chat and the player: a two-stop sky
/// (deep blue-black on dark, paper white on light), one very faint cool
/// light in a corner, and a few dozen motes of dust drifting upward.
///
/// Quiet by design: 48 points, only the nearest few with a tiny halo,
/// repainted at most ~30 times a second on its own layer; the ticker stops
/// when [animate] is off, under reduced motion, in the background, and
/// when a page covers the chat (TickerMode), e.g. during a workout.
class CosmosBackground extends StatefulWidget {
  const CosmosBackground({
    super.key,
    this.animate = true,
    this.showStars = true,
    this.child,
  });
  final bool animate;

  /// Explicit internal off removes the layer; the default preserves the
  /// existing static stars when the user's animation preference is off.
  final bool showStars;
  final Widget? child;

  @override
  State<CosmosBackground> createState() => _CosmosBackgroundState();
}

class _CosmosBackgroundState extends State<CosmosBackground>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker = createTicker(_tick);
  final _time = ValueNotifier<double>(0);
  double _base = 0;
  Duration _lastFrame = Duration.zero;
  bool _foreground = true;
  bool _reduceMotion = false;
  static final _stars = _Star.field(48, seed: 20261019);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(CosmosBackground old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    final want =
        widget.showStars && widget.animate && _foreground && !_reduceMotion;
    if (want && !_ticker.isActive) {
      _base = _time.value;
      _lastFrame = Duration.zero;
      _ticker.start();
    } else if (!want && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
    if (elapsed - _lastFrame < const Duration(milliseconds: 33)) return;
    _lastFrame = elapsed;
    _time.value = _base + elapsed.inMicroseconds / 1e6;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = ChatTheme.of(context).colors.palette;
    return Stack(
      fit: StackFit.expand,
      children: [
        SkyFill(palette: p),
        if (widget.showStars)
          RepaintBoundary(
            child: CustomPaint(
              painter: _StarPainter(_stars, _time, p.dust, p.isDark),
              isComplex: false,
              willChange: true,
            ),
          ),
        ?widget.child,
      ],
    );
  }
}

/// The sky alone (no dust): also painted while a card grows into a page.
class SkyFill extends StatelessWidget {
  const SkyFill({super.key, required this.palette});
  final CoachChatPalette palette;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [palette.skyTop, palette.skyBottom],
      ),
    ),
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(.9, -.95),
          radius: 1.1,
          colors: [palette.skyGlow, palette.skyGlow.withValues(alpha: 0)],
        ),
      ),
    ),
  );
}

class _Star {
  const _Star(
    this.x,
    this.y,
    this.r,
    this.alpha,
    this.vx,
    this.vy,
    this.freq,
    this.phase,
  );
  final double x, y, r, alpha, vx, vy, freq, phase;

  /// Fixed seed: the same sky every launch. Nearer (bigger) motes drift a
  /// little faster for a hint of depth.
  static List<_Star> field(int n, {required int seed}) {
    final rnd = math.Random(seed);
    return List.generate(n, (i) {
      final depth = math.pow(rnd.nextDouble(), 2.6).toDouble(); // most are far
      final r = .3 + depth * 1.0;
      return _Star(
        rnd.nextDouble(),
        rnd.nextDouble(),
        r,
        .10 + depth * .38 + rnd.nextDouble() * .08,
        (.0006 + depth * .0016) * (rnd.nextBool() ? 1 : -.6),
        -(.0011 + depth * .003),
        .06 + rnd.nextDouble() * .25,
        rnd.nextDouble() * math.pi * 2,
      );
    });
  }
}

class _StarPainter extends CustomPainter {
  _StarPainter(this.stars, this.time, this.color, this.dark)
    : super(repaint: time);
  final List<_Star> stars;
  final ValueListenable<double> time;
  final Color color;
  final bool dark;

  final _dot = Paint()..isAntiAlias = true;
  final _glow = Paint()
    ..isAntiAlias = true
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    // Motes on paper read darker than stars on night: keep them fainter.
    final k = dark ? 1.0 : .55;
    for (final s in stars) {
      final x = ((s.x + s.vx * t) % 1 + 1) % 1 * size.width;
      final y = ((s.y + s.vy * t) % 1 + 1) % 1 * size.height;
      final tw = .75 + .25 * math.sin(t * s.freq * math.pi * 2 + s.phase);
      final a = (s.alpha * tw * k).clamp(0.0, 1.0);
      if (dark && s.r > 1.05) {
        _glow.color = color.withValues(alpha: a * .35);
        canvas.drawCircle(Offset(x, y), s.r * 2.2, _glow);
      }
      _dot.color = color.withValues(alpha: a);
      canvas.drawCircle(Offset(x, y), s.r, _dot);
    }
  }

  @override
  bool shouldRepaint(_StarPainter old) =>
      old.stars != stars || old.color != color || old.dark != dark;
}
