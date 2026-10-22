// Liquid glass for the player (sdk-stage-r5), after SmartFit@63c8720
// lib/ui/theme/glass.dart. Dependency-free: one backdrop filter per surface
// (blur + saturation/brightness boost composed into one ImageFilter), a
// cool tint, a crisp 1 px specular rim bright on top and fading down, an
// inner top sheen, a faint inner bottom shade, and a contact + ambient
// shadow painted only outside the shape so the glass stays clear.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'trainer_theme.dart';

/// The glass material. [TrainerTheme.glass] gives the preset for its
/// brightness unless the app passes its own.
@immutable
class TrainerGlassStyle {
  const TrainerGlassStyle({
    required this.tint,
    required this.rimLight,
    required this.rimShade,
    required this.specular,
    required this.hairline,
    required this.controlRim,
    required this.controlFillTop,
    required this.controlFill,
    required this.overMediaTint,
    this.blur = 1.2,
    this.rimWidth = 1.0,
    this.saturation = 1.0,
    this.brightness = 0.0,
    this.innerShade = const Color(0x00000000),
    this.contactShadow = const Color(0x00000000),
    this.ambientShadow = const Color(0x00000000),
  });

  /// Body tint.
  final Color tint;

  /// Specular rim: [rimLight] on the top edge fading to [rimShade] at the
  /// sides (the bottom edge catches a little light again).
  final Color rimLight;
  final Color rimShade;

  /// Inner sheen just under the top edge.
  final Color specular;

  /// Calm edge on passive glass.
  final Color hairline;

  /// Idle control rim and fill.
  final Color controlRim;
  final Color controlFillTop;
  final Color controlFill;

  /// Extra tint for pills floating on a clip / camera / 3D, so white
  /// numerals and labels stay legible at arm's length.
  final Color overMediaTint;

  /// Backdrop blur sigma.
  final double blur;
  final double rimWidth;

  /// Backdrop colour boost (1 = none) and lift (0 = none, in 0..1 of white)
  /// applied with the blur in the same filter, so what's behind reads
  /// through brighter and richer.
  final double saturation;
  final double brightness;

  /// Faint shade along the inside of the bottom edge (thickness).
  final Color innerShade;

  /// Outer shadow: a tight contact shadow and a soft ambient one, painted
  /// only outside the shape so the glass itself stays clear.
  final Color contactShadow;
  final Color ambientShadow;

  static const dark = TrainerGlassStyle(
    tint: Color(0x0AFFFFFF),
    rimLight: Color(0x80FFFFFF),
    rimShade: Color(0x12FFFFFF),
    specular: Color(0x1AFFFFFF),
    hairline: Color(0x14FFFFFF),
    controlRim: Color(0x33FFFFFF),
    controlFillTop: Color(0x21FFFFFF),
    controlFill: Color(0x12FFFFFF),
    overMediaTint: Color(0x66000000),
    blur: 6,
    saturation: 1.3,
    brightness: .02,
    innerShade: Color(0x2E000000),
    contactShadow: Color(0x73000000),
    ambientShadow: Color(0x59000000),
  );

  static const light = TrainerGlassStyle(
    tint: Color(0x47F6FAFF),
    rimLight: Color(0xFFFFFFFF),
    rimShade: Color(0x80FFFFFF),
    specular: Color(0x8CFFFFFF),
    hairline: Color(0x1A1D2B3A),
    controlRim: Color(0x1F1D2B3A),
    controlFillTop: Color(0x80FFFFFF),
    controlFill: Color(0x4DFFFFFF),
    overMediaTint: Color(0x59000000),
    blur: 10,
    saturation: 1.6,
    brightness: .05,
    innerShade: Color(0x0F27405A),
    contactShadow: Color(0x1F1B2A3A),
    ambientShadow: Color(0x241B3A4A),
  );

  /// Blur + colour boost in one image filter.
  ui.ImageFilter get backdrop {
    final blurF = ui.ImageFilter.blur(
      sigmaX: blur,
      sigmaY: blur,
      tileMode: TileMode.mirror,
    );
    if (saturation == 1 && brightness == 0) return blurF;
    final s = saturation, l = brightness * 255;
    const r = .2126, g = .7152, b = .0722;
    final m = <double>[
      r * (1 - s) + s, g * (1 - s), b * (1 - s), 0, l, //
      r * (1 - s), g * (1 - s) + s, b * (1 - s), 0, l, //
      r * (1 - s), g * (1 - s), b * (1 - s) + s, 0, l, //
      0, 0, 0, 1, 0,
    ];
    return ui.ImageFilter.compose(
      outer: ui.ColorFilter.matrix(m),
      inner: blurF,
    );
  }
}

/// One glass platter behind [child]: a circle / capsule when [radius] is
/// null, otherwise a rounded superellipse. It only paints; the child keeps
/// its own semantics and taps. One backdrop filter per surface; never nest
/// one inside another.
class TrainerGlass extends StatelessWidget {
  const TrainerGlass({
    super.key,
    required this.theme,
    required this.child,
    this.radius,
    this.padding,
    this.width,
    this.height,
    this.control = false,
    this.overMedia = false,
    this.pressed = false,
  });
  final TrainerTheme theme;
  final Widget child;
  final double? radius;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;

  /// A tappable control: visibly glassy when idle.
  final bool control;

  /// Floats on media: darker tint for contrast; light text on top.
  final bool overMedia;
  final bool pressed;

  ShapeBorder _shape() => radius == null
      ? const StadiumBorder()
      : RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius!));

  @override
  Widget build(BuildContext context) {
    // On media the dark material is used in both themes (light text).
    final g = overMedia ? TrainerGlassStyle.dark : theme.glass;
    final dir = Directionality.maybeOf(context) ?? TextDirection.ltr;
    final shape = _shape();
    final body = CustomPaint(
      painter: _GlassPainter(
        shape: shape,
        style: g,
        mediaTint: theme.glass.overMediaTint,
        control: control,
        overMedia: overMedia,
        pressed: pressed,
        textDirection: dir,
      ),
      child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
    );
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        fit: StackFit.passthrough,
        clipBehavior: Clip.none,
        children: [
          if (theme.glass.contactShadow.a > 0 || g.contactShadow.a > 0)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _ShadowPainter(
                    shape: shape,
                    // Pills on media keep the page's shadow weight.
                    style: overMedia ? theme.glass : g,
                    textDirection: dir,
                  ),
                ),
              ),
            ),
          if (g.blur > 0)
            Positioned.fill(
              child: ClipPath(
                clipper: ShapeBorderClipper(shape: shape),
                child: BackdropFilter(
                  filter: g.backdrop,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          body,
        ],
      ),
    );
  }
}

/// Contact + ambient shadow outside the shape only.
class _ShadowPainter extends CustomPainter {
  _ShadowPainter({
    required this.shape,
    required this.style,
    required this.textDirection,
  });
  final ShapeBorder shape;
  final TrainerGlassStyle style;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final path = shape.getOuterPath(rect, textDirection: textDirection);
    final small = size.shortestSide < 60;
    canvas.save();
    canvas.clipPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(rect.inflate(60)),
        path,
      ),
    );
    void shadow(Color c, double dy, double sigma) {
      if (c.a == 0) return;
      canvas.drawPath(
        path.shift(Offset(0, dy)),
        Paint()
          ..color = c
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma),
      );
    }

    shadow(style.ambientShadow, small ? 4 : 10, small ? 6 : 14);
    shadow(style.contactShadow, small ? 1 : 1.5, small ? 1.5 : 2.5);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ShadowPainter old) =>
      old.style != style || old.shape != shape;
}

class _GlassPainter extends CustomPainter {
  _GlassPainter({
    required this.shape,
    required this.style,
    required this.mediaTint,
    required this.control,
    required this.overMedia,
    required this.pressed,
    required this.textDirection,
  });
  final ShapeBorder shape;
  final TrainerGlassStyle style;
  final Color mediaTint;
  final bool control;
  final bool overMedia;
  final bool pressed;
  final TextDirection textDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final path = shape.getOuterPath(rect, textDirection: textDirection);
    // Body: tint (+ media tint) and, on controls, the idle fill.
    canvas.drawPath(path, Paint()..color = style.tint);
    if (overMedia) canvas.drawPath(path, Paint()..color = mediaTint);
    if (control) {
      final top = pressed
          ? Color.lerp(style.controlFillTop, Colors.white, .12)!
          : style.controlFillTop;
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0, .55],
            colors: [top, style.controlFill],
          ).createShader(rect),
      );
    }
    // Inner sheen under the top edge, and a faint shade along the bottom
    // for thickness — both within a fixed depth so pills and cards match.
    final h = size.height;
    final sheenDepth = math.min(h * .5, 22.0);
    final shadeDepth = math.min(h * .4, 16.0);
    canvas.save();
    canvas.clipPath(path);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, sheenDepth),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [style.specular, style.specular.withValues(alpha: 0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, sheenDepth)),
    );
    if (style.innerShade.a > 0) {
      final r = Rect.fromLTWH(0, h - shadeDepth, size.width, shadeDepth);
      canvas.drawRect(
        r,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [style.innerShade.withValues(alpha: 0), style.innerShade],
          ).createShader(r),
      );
    }
    canvas.restore();
    // Edge definition (an ink hairline on light / white on dark), then the
    // crisp specular rim: bright along the top, fading down the sides, a
    // faint return on the bottom edge.
    final w = style.rimWidth;
    final inner = shape.getOuterPath(
      rect.deflate(w / 2),
      textDirection: textDirection,
    );
    final edge = control ? style.controlRim : style.hairline;
    if (edge.a > 0) {
      canvas.drawPath(
        inner,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w
          ..color = pressed ? Color.lerp(edge, Colors.white, .35)! : edge,
      );
    }
    final top = math.min(1.0, 14 / math.max(h, 1));
    canvas.drawPath(
      inner,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            style.rimLight,
            Color.lerp(style.rimLight, style.rimShade, .6)!,
            style.rimShade.withValues(alpha: style.rimShade.a * .35),
            style.rimShade.withValues(alpha: style.rimShade.a * .8),
          ],
          stops: [0, top.clamp(.08, .5), .7, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GlassPainter old) =>
      old.style != style ||
      old.mediaTint != mediaTint ||
      old.control != control ||
      old.overMedia != overMedia ||
      old.pressed != pressed ||
      old.shape != shape;
}

/// A round glass button (≥40 px; the primary is a solid emerald disc).
/// Presses scale to .96 (transform only) and fire [onPressed].
class TrainerGlassButton extends StatefulWidget {
  const TrainerGlassButton({
    super.key,
    required this.theme,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 48,
    this.primary = false,
    this.overMedia = false,
    this.iconColor,
  });
  final TrainerTheme theme;
  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;

  /// The emerald disc (one per screen).
  final bool primary;
  final bool overMedia;
  final Color? iconColor;

  @override
  State<TrainerGlassButton> createState() => _TrainerGlassButtonState();
}

class _TrainerGlassButtonState extends State<TrainerGlassButton> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final th = widget.theme;
    final s = widget.size;
    final still = TrainerMotion.reduced(context);
    final color =
        widget.iconColor ??
        (widget.primary
            ? th.onAccent
            : widget.overMedia
            ? Colors.white
            : th.text);
    final face = IconTheme.merge(
      data: IconThemeData(color: color, size: s * .46),
      child: Center(child: widget.icon),
    );
    final Widget disc = widget.primary
        ? DecoratedBox(
            decoration: ShapeDecoration(
              shape: const CircleBorder(
                side: BorderSide(color: Color(0x33FFFFFF), width: 1),
              ),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color.lerp(th.accent, Colors.white, .14)!, th.accent],
              ),
            ),
            child: face,
          )
        : TrainerGlass(
            theme: th,
            control: true,
            overMedia: widget.overMedia,
            pressed: _down,
            child: face,
          );
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        enabled: widget.onPressed != null,
        label: widget.tooltip,
        excludeSemantics: true,
        onTap: widget.onPressed,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _set(true),
          onTapUp: (_) => _set(false),
          onTapCancel: () => _set(false),
          onTap: widget.onPressed,
          child: AnimatedScale(
            scale: _down && !still ? .96 : 1,
            duration: _down
                ? const Duration(milliseconds: 100)
                : const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: SizedBox.square(dimension: s, child: disc),
          ),
        ),
      ),
    );
  }
}

/// A soft field behind the player so clear glass has something to bend.
/// Dark: neutral (two near-invisible white lifts). Light: a faint jade
/// pool bottom-left and a cool mist on the right. Static, gradients only.
class TrainerGlassField extends StatelessWidget {
  const TrainerGlassField({super.key, required this.theme});
  final TrainerTheme theme;

  @override
  Widget build(BuildContext context) {
    Widget pool(Alignment c, double r, Color color, double a) => DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: c,
          radius: r,
          colors: [
            color.withValues(alpha: a),
            color.withValues(alpha: 0),
          ],
        ),
      ),
    );
    return IgnorePointer(
      child: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: theme.isDark
              ? [
                  pool(const Alignment(0, 1.1), 1.1, Colors.white, .045),
                  pool(const Alignment(-.8, -.9), .9, Colors.white, .025),
                ]
              : [
                  pool(const Alignment(-1.1, 1.05), 1.0, theme.accent, .12),
                  pool(
                    const Alignment(1.15, .55),
                    .9,
                    const Color(0xFF9DB8D6),
                    .22,
                  ),
                ],
        ),
      ),
    );
  }
}
