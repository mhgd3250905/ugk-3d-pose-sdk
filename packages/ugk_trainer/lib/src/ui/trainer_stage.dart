import 'dart:math' as math;
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

    // Keep the perspective stationary in the clip's coordinate system; the
    // row at `ground` anchors the source's contact plane. The radial shader
    // makes the grid disappear towards the stage edges and controls.
    final radius = math.max(size.width, size.height - ground) * .9;
    final ink = dark ? Colors.white : const Color(0xFF26383A);
    final grid = Paint()
      ..strokeWidth = 1
      ..shader = ui.Gradient.radial(
        Offset(cx, ground + clipSize * .05),
        math.max(1, radius),
        [
          ink.withValues(alpha: dark ? .09 : .065),
          ink.withValues(alpha: dark ? .045 : .03),
          ink.withValues(alpha: 0),
        ],
        const [0, .5, 1],
      );
    for (var k = -8; k <= 8; k++) {
      final bottomX = cx + k * clipSize * .32;
      canvas.drawLine(Offset(cx, horizon), Offset(bottomX, size.height), grid);
    }
    // Quadratic spacing gives denser lines in the distance and widening
    // intervals toward the viewer; i=3 is precisely the contact line.
    for (var i = 1; i <= 24; i++) {
      final y = horizon + (ground - horizon) * i * i / 9;
      if (y > size.height) break;
      if (y < 0) continue;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
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
