// Quiet studio lighting and floor behind training media. TrainerPlayer
// supplies the opaque mediaStage base; this exported painter stays
// translucent for hosts that place it above existing content.
// Static, one CustomPainter, no live blur.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'trainer_theme.dart';

/// Paints translucent lighting and floor for a clip of [clipSize] whose
/// top-left corner is at ([clipLeft], [clipTop]). The player places it
/// behind media over an opaque [TrainerTheme.mediaStage] base so alpha
/// video reveals the studio without tinting the figure. Ignores pointers.
class TrainerStageFloor extends StatelessWidget {
  const TrainerStageFloor({
    super.key,
    required this.theme,
    required this.clipSize,
    this.clipLeft = 0,
    this.clipTop = 0,
    this.fadeClipEdge = true,
  });
  final TrainerTheme theme;
  final double clipSize;
  final double clipLeft;

  /// Top of the clip; 0 when it sits at the very top of the stage.
  final double clipTop;

  /// Blend the clip's lower edge into the stage (hides any seam when a
  /// host clip's backdrop is a shade off [TrainerTheme.mediaStage]).
  final bool fadeClipEdge;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _FloorPainter(
          stage: theme.mediaStage,
          accent: theme.accent,
          dark: theme.isDark,
          clipSize: clipSize,
          clipLeft: clipLeft,
          clipTop: clipTop,
          fadeClipEdge: fadeClipEdge,
        ),
      ),
    ),
  );
}

class _FloorPainter extends CustomPainter {
  _FloorPainter({
    required this.stage,
    required this.accent,
    required this.dark,
    required this.clipSize,
    required this.clipLeft,
    required this.clipTop,
    required this.fadeClipEdge,
  });
  final Color stage;
  final Color accent;
  final bool dark;
  final double clipSize;
  final double clipLeft;
  final double clipTop;
  final bool fadeClipEdge;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final w = size.width, h = size.height, v = clipSize;
    final cx = clipLeft + v / 2;
    // The clips' feet stand at ~0.9 of the frame; the horizon sits above.
    final y0 = clipTop;
    final feet = y0 + v * .9;
    final horizon = y0 + v * .78;
    final ink = dark ? Colors.white : const Color(0xFF1B2420);

    // The player supplies the opaque base; retain this exported surface's
    // translucent composition for existing overlay callers. Lighting
    // changes spatially, not every frame.
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(cx, y0 + v * .42),
          math.max(w, h) * .65,
          [
            Colors.white.withValues(alpha: dark ? .045 : .42),
            Colors.white.withValues(alpha: dark ? .015 : .12),
            Colors.white.withValues(alpha: 0),
          ],
          const [0, .48, 1],
        ),
    );

    if (fadeClipEdge && v > 0) {
      final top = y0 + v * .9;
      canvas.drawRect(
        Rect.fromLTWH(clipLeft, top, v, y0 + v - top),
        Paint()
          ..shader = ui.Gradient.linear(Offset(0, top), Offset(0, y0 + v), [
            stage.withValues(alpha: 0),
            stage,
          ]),
      );
      if (y0 > 0) {
        // A centred clip: soften its top edge into the stage as well.
        final end = y0 + v * .05;
        canvas.drawRect(
          Rect.fromLTWH(clipLeft, y0, v, end - y0),
          Paint()
            ..shader = ui.Gradient.linear(Offset(0, y0), Offset(0, end), [
              stage,
              stage.withValues(alpha: 0),
            ]),
        );
      }
    }

    // Receding floor grid from the feet towards the viewer, faded radially
    // around the figure so it never reaches the controls' edges.
    final reach = math.max(w, h - feet) * .95;
    final grid = Paint()
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke
      ..shader = ui.Gradient.radial(
        Offset(cx, feet + v * .06),
        reach,
        [
          ink.withValues(alpha: dark ? .055 : .048),
          ink.withValues(alpha: dark ? .022 : .018),
          ink.withValues(alpha: 0),
        ],
        const [0, .45, 1],
      );
    final depth = math.max(1.0, h - horizon);
    for (var k = -9; k <= 9; k++) {
      // Rays meet at the vanishing point on the horizon.
      final bx = cx + k * v * .34;
      final t0 = (feet - horizon) / depth;
      final x0 = cx + (bx - cx) * t0;
      canvas.drawLine(Offset(x0, feet), Offset(bx, h), grid);
    }
    for (var i = 1; i < 14; i++) {
      final y = horizon + depth * .16 * i * i / 4;
      if (y < feet + 2) continue;
      if (y > h) break;
      canvas.drawLine(Offset(0, y), Offset(w, y), grid);
    }

    // Pool of light (dark) / contact shadow (light) under the figure.
    void ellipse(double ry, List<Color> colors, List<double> stops) {
      canvas
        ..save()
        ..translate(cx, feet)
        ..scale(1, ry);
      canvas.drawCircle(
        Offset.zero,
        v * .5,
        Paint()
          ..shader = ui.Gradient.radial(Offset.zero, v * .5, colors, stops),
      );
      canvas.restore();
    }

    ellipse(
      .22,
      dark
          ? [
              accent.withValues(alpha: .12),
              Colors.white.withValues(alpha: .035),
              Colors.white.withValues(alpha: 0),
            ]
          : [
              const Color(0xFF1B2420).withValues(alpha: .09),
              accent.withValues(alpha: .025),
              accent.withValues(alpha: 0),
            ],
      const [0, .45, 1],
    );

    // Depth fog: the stage darkens (dark) / greys (light) towards the
    // edges and the bottom, so the floating glass reads in front of it.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(cx, y0 + v * .62),
          math.max(w, h) * .95,
          [
            Colors.black.withValues(alpha: 0),
            Colors.black.withValues(alpha: 0),
            Colors.black.withValues(alpha: dark ? .22 : .035),
          ],
          const [0, .45, 1],
        ),
    );
    // Static environmental light gives clear controls a surface to reveal.
    // Keep the centre neutral so transparent training media retains its colour.
    void blob(double x, double y, double r, Color c, double a) {
      final o = Offset(w * x, h * y);
      final rad = math.max(w, 320.0) * r;
      canvas.drawCircle(
        o,
        rad,
        Paint()
          ..shader = ui.Gradient.radial(
            o,
            rad,
            [
              c.withValues(alpha: a),
              c.withValues(alpha: a * .4),
              c.withValues(alpha: 0),
            ],
            const [0, .5, 1],
          ),
      );
    }

    blob(-.10, .05, 1.0, const Color(0xFF62C6B1), dark ? .13 : .26);
    blob(1.12, .12, .95, const Color(0xFF91B5D6), dark ? .10 : .20);
    blob(.08, .96, .88, accent, dark ? .11 : .13);
    blob(1.05, .92, .8, const Color(0xFFD2BDAE), dark ? .045 : .18);
  }

  @override
  bool shouldRepaint(_FloorPainter old) =>
      old.stage != stage ||
      old.accent != accent ||
      old.dark != dark ||
      old.clipSize != clipSize ||
      old.clipLeft != clipLeft ||
      old.clipTop != clipTop ||
      old.fadeClipEdge != fadeClipEdge;
}

/// A soft contact shadow under a floating panel, so it reads as hovering
/// above the stage floor (no shadow under the glass itself, which would
/// muddy clear glass).
class TrainerHover extends StatelessWidget {
  const TrainerHover({
    super.key,
    required this.theme,
    required this.child,
    this.lift = 10,
    this.inset = .14,
  });
  final TrainerTheme theme;
  final Widget child;

  /// How far below the panel the shadow falls.
  final double lift;

  /// Horizontal inset of the shadow, as a fraction of the width.
  final double inset;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    fit: StackFit.passthrough,
    children: [
      Positioned.fill(
        child: IgnorePointer(
          child: LayoutBuilder(
            builder: (_, box) => Align(
              alignment: Alignment.bottomCenter,
              child: Transform.translate(
                offset: Offset(0, lift),
                child: Container(
                  width: box.maxWidth * (1 - 2 * inset),
                  height: 10,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: theme.isDark
                            ? const Color(0x26000000)
                            : const Color(0x0A1B2420),
                        blurRadius: 14,
                        spreadRadius: 0,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      child,
    ],
  );
}
