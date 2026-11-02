import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Extracted from SF 52d30ae lib/ui/theme/sf_icons.dart.
/// SmartFit's icon set: HipLab's glyphs (mhgd3250905/HipLab
/// lib/hip/ui/hip_icons.dart, same author) plus the few SmartFit needs
/// (skipPrevious, bookmark, arrowUp, more, grid, sliders, swap, clock,
/// sparkle), drawn on the same grid so the app has one icon language.
///
/// One visual system: a 24-unit grid with a 2-unit safe margin, 1.75-unit
/// strokes with round caps and joins, corner radii from the same small set
/// (1.5 / 3 / 4.5), and every glyph drawn in two states: outline (default)
/// and filled ([TrainingLibraryIcon.filled]) — e.g. the selected bottom tab. Solid
/// glyphs (play, pause, skip, bolt) are filled in both states. Play
/// triangles are rounded and shifted for optical centring.
enum TrainingLibraryGlyph { play, pause, figure, subtitles, bandage }

/// Draws a [TrainingLibraryGlyph]. Size and colour default to the ambient [IconTheme],
/// so it drops in wherever an `Icon` was (buttons, list tiles).
class TrainingLibraryIcon extends StatelessWidget {
  const TrainingLibraryIcon(
    this.glyph, {
    super.key,
    this.size,
    this.color,
    this.filled = false,
    this.strokeWidth,
    this.semanticLabel,
  });

  final TrainingLibraryGlyph glyph;
  final double? size;
  final Color? color;
  final bool filled;

  /// Stroke in grid units (default 1.75 of 24).
  final double? strokeWidth;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final s = size ?? theme.size ?? 24;
    var c = color ?? theme.color ?? const Color(0xff000000);
    final opacity = theme.opacity;
    if (color == null && opacity != null && opacity < 1) {
      c = c.withValues(alpha: c.a * opacity);
    }
    final icon = SizedBox.square(
      dimension: s,
      child: CustomPaint(
        painter: TrainingLibraryIconPainter(
          glyph,
          color: c,
          filled: filled,
          strokeWidth: strokeWidth ?? 1.75,
        ),
      ),
    );
    return semanticLabel == null
        ? ExcludeSemantics(child: icon)
        : Semantics(
            label: semanticLabel,
            child: ExcludeSemantics(child: icon),
          );
  }
}

class TrainingLibraryIconPainter extends CustomPainter {
  TrainingLibraryIconPainter(
    this.glyph, {
    required this.color,
    this.filled = false,
    this.strokeWidth = 1.75,
  });
  final TrainingLibraryGlyph glyph;
  final Color color;
  final bool filled;
  final double strokeWidth;

  late Paint _stroke;
  late Paint _fill;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / 24;
    canvas.save();
    canvas.translate((size.width - 24 * k) / 2, (size.height - 24 * k) / 2);
    canvas.scale(k);
    // Never thinner than ~1.1 device-independent px at tiny sizes.
    final sw = math.max(strokeWidth, 1.1 / k);
    _stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = sw
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color
      ..isAntiAlias = true;
    _fill = Paint()
      ..style = PaintingStyle.fill
      ..color = color
      ..isAntiAlias = true;
    _draw(canvas);
    canvas.restore();
  }

  void _draw(Canvas c) {
    switch (glyph) {
      case TrainingLibraryGlyph.play:
        // Rounded triangle; its box sits 1.4 right of centre so the visual
        // mass (≈ the centroid) lands on the centre line.
        final p = roundedPolygon(const [
          Offset(8, 5.4),
          Offset(8, 18.6),
          Offset(18.9, 12),
        ], 2.4);
        c.drawPath(p, _fill);
        c.drawPath(p, _stroke);
      case TrainingLibraryGlyph.pause:
        for (final x in [6.6, 13.4]) {
          final r = RRect.fromRectAndRadius(
            Rect.fromLTWH(x, 5.2, 4, 13.6),
            const Radius.circular(1.6),
          );
          c.drawRRect(r, _fill);
        }
      case TrainingLibraryGlyph.figure:
        c.drawCircle(const Offset(12, 4.9), 2.2, filled ? _fill : _stroke);
        c.drawPath(
          Path()
            ..moveTo(5, 9)
            ..cubicTo(8, 10, 9.8, 10.2, 12, 10.2)
            ..cubicTo(14.2, 10.2, 16, 10, 19, 9),
          _stroke,
        );
        c.drawLine(const Offset(12, 10.2), const Offset(12, 14.6), _stroke);
        c.drawPath(
          _poly(const [
            Offset(8.8, 20.6),
            Offset(12, 14.6),
            Offset(15.2, 20.6),
          ]),
          _stroke,
        );
      case TrainingLibraryGlyph.subtitles:
        final box = RRect.fromRectAndRadius(
          const Rect.fromLTWH(3.5, 5.5, 17, 13),
          const Radius.circular(3.5),
        );
        final lines = [
          (const Offset(7, 11.4), const Offset(12.4, 11.4)),
          (const Offset(14.6, 11.4), const Offset(17, 11.4)),
          (const Offset(7, 14.8), const Offset(9.4, 14.8)),
          (const Offset(11.6, 14.8), const Offset(17, 14.8)),
        ];
        if (filled) {
          final holes = Path();
          for (final (a, b) in lines) {
            holes.addPath(_strokeHole([a, b]), Offset.zero);
          }
          _paintHoled(c, Path()..addRRect(box.inflate(.6)), holes);
        } else {
          c.drawRRect(box, _stroke);
          for (final (a, b) in lines) {
            c.drawLine(a, b, _stroke);
          }
        }
      case TrainingLibraryGlyph.bandage:
        c.save();
        c.translate(12, 12);
        c.rotate(-math.pi / 4);
        final band = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: 19, height: 8),
          const Radius.circular(4),
        );
        if (filled) {
          _paintHoled(
            c,
            Path()..addRRect(band),
            Path()..addRRect(
              RRect.fromRectAndRadius(
                Rect.fromCenter(center: Offset.zero, width: 5.6, height: 5),
                const Radius.circular(1.5),
              ),
            ),
          );
        } else {
          c.drawRRect(band, _stroke);
          c.drawLine(const Offset(-3, -4), const Offset(-3, 4), _stroke);
          c.drawLine(const Offset(3, -4), const Offset(3, 4), _stroke);
          c.drawCircle(const Offset(0, -1.4), .7, _fill);
          c.drawCircle(const Offset(0, 1.4), .7, _fill);
        }
        c.restore();
    }
  }

  /// Omit the holes before drawing ink, so the actual background stays visible.
  void _paintHoled(Canvas canvas, Path ink, Path holes, {bool stroke = false}) {
    canvas.save();
    _clipHoles(
      canvas,
      holes,
      bounds: ink.getBounds().inflate(_stroke.strokeWidth + 1),
    );
    canvas.drawPath(ink, _fill);
    if (stroke) canvas.drawPath(ink, _stroke);
    canvas.restore();
  }

  void _clipHoles(Canvas canvas, Path holes, {Rect? bounds}) {
    canvas.clipPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(bounds ?? const Rect.fromLTWH(-2, -2, 28, 28)),
        holes,
      ),
    );
  }

  /// Round-capped straight segments, expressed as one filled path for clipping.
  Path _strokeHole(List<Offset> points) {
    final path = Path();
    final radius = _stroke.strokeWidth / 2;
    for (final point in points) {
      path.addOval(Rect.fromCircle(center: point, radius: radius));
    }
    for (var i = 1; i < points.length; i++) {
      final a = points[i - 1];
      final b = points[i];
      final delta = b - a;
      if (delta.distance == 0) continue;
      final normal = Offset(-delta.dy, delta.dx) * (radius / delta.distance);
      path.addPolygon([a + normal, a - normal, b - normal, b + normal], true);
    }
    return path;
  }

  static Path _poly(List<Offset> pts) => Path()..addPolygon(pts, false);

  @override
  bool shouldRepaint(TrainingLibraryIconPainter old) =>
      old.glyph != glyph ||
      old.color != color ||
      old.filled != filled ||
      old.strokeWidth != strokeWidth;
}

/// A closed polygon whose corners are rounded: each corner is replaced by a
/// quadratic curve starting [d] units before the vertex and ending [d] after
/// it (clamped to half of the shorter adjacent edge).
Path roundedPolygon(List<Offset> pts, double d) {
  final n = pts.length;
  final path = Path();
  for (var i = 0; i < n; i++) {
    final prev = pts[(i - 1 + n) % n];
    final cur = pts[i];
    final next = pts[(i + 1) % n];
    final inLen = (cur - prev).distance;
    final outLen = (next - cur).distance;
    final r = math.min(d, math.min(inLen, outLen) / 2);
    final a = cur - (cur - prev) / inLen * r;
    final b = cur + (next - cur) / outLen * r;
    if (i == 0) {
      path.moveTo(a.dx, a.dy);
    } else {
      path.lineTo(a.dx, a.dy);
    }
    path.quadraticBezierTo(cur.dx, cur.dy, b.dx, b.dy);
  }
  return path..close();
}
