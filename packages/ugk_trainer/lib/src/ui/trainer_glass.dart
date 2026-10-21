// Clear liquid glass for the player, after SmartFit@63c8720
// lib/ui/theme/glass.dart (SfGlassSurface, SfGlass.standardMaterial,
// SfControlInk, SfGlassField). SmartFit draws it with a shader package;
// this is a compact, dependency-free port: near-zero blur, a 2–6 % tint,
// a Fresnel rim (bright upper-left, faint lower-right), a soft specular
// and — in dark mode — a calm white hairline (40 % on idle controls).
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
  });

  /// Body tint (≈2 % dark, ≈6 % light).
  final Color tint;

  /// Fresnel rim at the light (upper-left) and away from it.
  final Color rimLight;
  final Color rimShade;

  /// Soft highlight in the upper-left of the body.
  final Color specular;

  /// Calm edge on passive glass (white hairline dark, faint ink light).
  final Color hairline;

  /// Idle control rim (≥3:1 on the dark sky) and fill.
  final Color controlRim;
  final Color controlFillTop;
  final Color controlFill;

  /// Extra tint for pills floating on a clip / camera / 3D, so white
  /// numerals and labels stay legible at arm's length.
  final Color overMediaTint;

  /// Backdrop blur sigma: near zero, only to soften what it bends.
  final double blur;
  final double rimWidth;

  static const dark = TrainerGlassStyle(
    tint: Color(0x05FFFFFF),
    rimLight: Color(0x8CFFFFFF),
    rimShade: Color(0x14FFFFFF),
    specular: Color(0x1FFFFFFF),
    hairline: Color(0x1FFFFFFF),
    controlRim: Color(0x66FFFFFF),
    controlFillTop: Color(0x24FFFFFF),
    controlFill: Color(0x17FFFFFF),
    overMediaTint: Color(0x73000000),
  );

  static const light = TrainerGlassStyle(
    tint: Color(0x0FFFFFFF),
    rimLight: Color(0xF2FFFFFF),
    rimShade: Color(0x1A1D2B25),
    specular: Color(0x66FFFFFF),
    hairline: Color(0x141D2B25),
    controlRim: Color(0x1F1D2B25),
    controlFillTop: Color(0x8CFFFFFF),
    controlFill: Color(0x59FFFFFF),
    overMediaTint: Color(0x66000000),
    blur: 1.5,
  );
}

/// One glass platter behind [child]: a circle / capsule when [radius] is
/// null, otherwise a rounded superellipse. It only paints; the child keeps
/// its own semantics and taps. Never nest one inside another.
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

  /// A tappable control: visibly glassy when idle (fill + 40 % rim, dark).
  final bool control;

  /// Floats on media: darker tint for contrast; light text on top.
  final bool overMedia;
  final bool pressed;

  ShapeBorder _shape([BorderSide side = BorderSide.none]) => radius == null
      ? StadiumBorder(side: side)
      : RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(radius!),
          side: side,
        );

  @override
  Widget build(BuildContext context) {
    // On media the dark material is used in both themes (light text).
    final g = overMedia ? TrainerGlassStyle.dark : theme.glass;
    final dark = theme.isDark || overMedia;
    Widget body = CustomPaint(
      painter: _GlassPainter(
        shape: _shape(),
        style: g,
        mediaTint: theme.glass.overMediaTint,
        dark: dark,
        control: control,
        overMedia: overMedia,
        pressed: pressed,
        textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      ),
      child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
    );
    if (g.blur > 0) {
      body = Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: ClipPath(
              clipper: ShapeBorderClipper(shape: _shape()),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: g.blur, sigmaY: g.blur),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          body,
        ],
      );
    }
    return SizedBox(width: width, height: height, child: body);
  }
}

class _GlassPainter extends CustomPainter {
  _GlassPainter({
    required this.shape,
    required this.style,
    required this.mediaTint,
    required this.dark,
    required this.control,
    required this.overMedia,
    required this.pressed,
    required this.textDirection,
  });
  final ShapeBorder shape;
  final TrainerGlassStyle style;
  final Color mediaTint;
  final bool dark;
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
            stops: const [0, .5],
            colors: [top, style.controlFill],
          ).createShader(rect),
      );
    }
    // Specular: a soft lens highlight towards the light.
    canvas.save();
    canvas.clipPath(path);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-.6, -1.1),
          radius: 1.1,
          colors: [style.specular, style.specular.withValues(alpha: 0)],
        ).createShader(rect),
    );
    canvas.restore();
    // Fresnel rim: bright where the light hits, nearly gone opposite.
    final w = style.rimWidth;
    final inner = shape.getOuterPath(
      rect.deflate(w / 2),
      textDirection: textDirection,
    );
    canvas.drawPath(
      inner,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            style.rimLight,
            style.rimShade,
            style.rimLight.withValues(alpha: style.rimLight.a * .35),
          ],
          stops: const [0, .55, 1],
        ).createShader(rect),
    );
    // Dark: calm hairline (controls: the 40 % rim, so idle reads as a button).
    final edge = control ? style.controlRim : style.hairline;
    if (edge != null && edge.a > 0) {
      canvas.drawPath(
        inner,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = control ? 1.0 : .8
          ..color = pressed ? Color.lerp(edge, Colors.white, .35)! : edge,
      );
    }
  }

  @override
  bool shouldRepaint(_GlassPainter old) =>
      old.style != style ||
      old.mediaTint != mediaTint ||
      old.dark != dark ||
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
