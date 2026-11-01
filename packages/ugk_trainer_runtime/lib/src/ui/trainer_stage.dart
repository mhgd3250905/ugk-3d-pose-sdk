import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'trainer_theme.dart';

/// Projection anchors in the square media frame, expressed as fractions of
/// its size. These are display coordinates, not world-space measurements.
///
/// The default is a visual estimate, not a calibrated camera projection.
/// A host with calibrated coordinates may supply a particular clip's geometry.
@immutable
class TrainerFloorGeometry {
  const TrainerFloorGeometry({
    this.horizon = .60,
    this.ground = .81,
    this.vanishingX = .5,
  }) : assert(horizon < ground),
       assert(vanishingX >= 0 && vanishingX <= 1);

  /// Height of the horizon in the source frame, relative to its top edge.
  final double horizon;

  /// Height of the contact line in the source frame, relative to its top edge.
  final double ground;

  /// Horizontal position of the vanishing point in the source frame.
  final double vanishingX;
}

/// Opaque media-stage background with a quiet perspective grid.
/// The clip geometry stays owned by the player; this layer never covers media.
class TrainerStageFloor extends StatelessWidget {
  const TrainerStageFloor({
    super.key,
    required this.theme,
    required this.clipSize,
    this.clipLeft = 0,
    this.clipTop = 0,
    this.geometry = const TrainerFloorGeometry(),
  });

  final TrainerTheme theme;
  final double clipSize;
  final double clipLeft;
  final double clipTop;
  final TrainerFloorGeometry geometry;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _FloorPainter(
          background: theme.mediaStage,
          dark: theme.isDark,
          clipSize: clipSize,
          clipLeft: clipLeft,
          clipTop: clipTop,
          geometry: geometry,
        ),
      ),
    ),
  );
}

class _FloorPainter extends CustomPainter {
  const _FloorPainter({
    required this.background,
    required this.dark,
    required this.clipSize,
    required this.clipLeft,
    required this.clipTop,
    required this.geometry,
  });

  final Color background;
  final bool dark;
  final double clipSize;
  final double clipLeft;
  final double clipTop;
  final TrainerFloorGeometry geometry;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = background.withValues(alpha: 1),
    );
    if (clipSize <= 0) return;
    final horizon = clipTop + clipSize * geometry.horizon;
    final ground = clipTop + clipSize * geometry.ground;
    final cx = clipLeft + clipSize * geometry.vanishingX;
    if (!horizon.isFinite ||
        !ground.isFinite ||
        !cx.isFinite ||
        horizon >= size.height ||
        ground <= horizon) {
      return;
    }

    // Keep the grid in the media's coordinates, but fade it in below the
    // horizon so the converging rays do not create a conspicuous bright tip.
    final ink = dark ? Colors.white : const Color(0xFF26383A);
    final opacity = dark ? .105 : .17;
    final depth = size.height - horizon;
    final fadeIn = ((ground - horizon) / depth).clamp(.08, .45);
    for (var k = -8; k <= 8; k++) {
      final bottomX = cx + k * clipSize * .32;
      final rayOpacity = opacity * (1 - k.abs() / 12);
      final ray = Paint()
        ..strokeWidth = 1
        ..shader = ui.Gradient.linear(
          Offset(0, horizon),
          Offset(0, size.height),
          [
            ink.withValues(alpha: 0),
            ink.withValues(alpha: rayOpacity),
            ink.withValues(alpha: rayOpacity * .65),
            ink.withValues(alpha: 0),
          ],
          [0, fadeIn, .7, 1],
        );
      canvas.drawLine(Offset(cx, horizon), Offset(bottomX, size.height), ray);
    }
    // Quadratic spacing gives denser lines in the distance and widening
    // intervals toward the viewer; i=3 is precisely the contact line.
    for (var i = 1; i <= 24; i++) {
      final y = horizon + (ground - horizon) * i * i / 9;
      if (y > size.height) break;
      if (y < 0) continue;
      final nearFade = ((y - horizon) / (ground - horizon)).clamp(0.0, 1.0);
      final farFade = ((size.height - y) / depth).clamp(0.0, 1.0);
      final lineOpacity = opacity * nearFade * (farFade * 2).clamp(0.0, 1.0);
      final row = Paint()
        ..strokeWidth = 1
        ..shader = ui.Gradient.linear(
          Offset(0, y),
          Offset(size.width, y),
          [
            ink.withValues(alpha: 0),
            ink.withValues(alpha: lineOpacity),
            ink.withValues(alpha: lineOpacity),
            ink.withValues(alpha: 0),
          ],
          const [0, .2, .8, 1],
        );
      canvas.drawLine(Offset(0, y), Offset(size.width, y), row);
    }
  }

  @override
  bool shouldRepaint(_FloorPainter old) =>
      old.background != background ||
      old.dark != dark ||
      old.clipSize != clipSize ||
      old.clipLeft != clipLeft ||
      old.clipTop != clipTop ||
      old.geometry.horizon != geometry.horizon ||
      old.geometry.ground != geometry.ground ||
      old.geometry.vanishingX != geometry.vanishingX;
}

/// Completed-session composition: a solid page background and ordinary
/// scrolling content. It has no inherited material or rendering scope.
class TrainerResultStage extends StatelessWidget {
  const TrainerResultStage({
    super.key,
    required this.theme,
    required this.child,
  });

  final TrainerTheme theme;
  final Widget child;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: theme.background.withValues(alpha: 1),
    child: ScrollConfiguration(
      behavior: const MaterialScrollBehavior().copyWith(overscroll: false),
      child: child,
    ),
  );
}
