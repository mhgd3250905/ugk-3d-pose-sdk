import 'package:flutter/material.dart';

import 'trainer_theme.dart';

/// Opaque media-stage background with a quiet line at the clip's foot plane.
/// The clip geometry stays owned by the player; this layer never covers media.
class TrainerStageFloor extends StatelessWidget {
  const TrainerStageFloor({
    super.key,
    required this.theme,
    required this.clipSize,
    this.clipLeft = 0,
    this.clipTop = 0,
  });

  final TrainerTheme theme;
  final double clipSize;
  final double clipLeft;
  final double clipTop;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _FloorPainter(
          background: theme.mediaStage,
          border: theme.border,
          clipSize: clipSize,
          clipLeft: clipLeft,
          clipTop: clipTop,
        ),
      ),
    ),
  );
}

class _FloorPainter extends CustomPainter {
  const _FloorPainter({
    required this.background,
    required this.border,
    required this.clipSize,
    required this.clipLeft,
    required this.clipTop,
  });

  final Color background;
  final Color border;
  final double clipSize;
  final double clipLeft;
  final double clipTop;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = background.withValues(alpha: 1),
    );
    if (clipSize <= 0) return;
    final feet = clipTop + clipSize * .9;
    if (feet < 0 || feet > size.height) return;
    canvas.drawLine(
      Offset(clipLeft.clamp(0, size.width), feet),
      Offset((clipLeft + clipSize).clamp(0, size.width), feet),
      Paint()
        ..color = border
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_FloorPainter old) =>
      old.background != background ||
      old.border != border ||
      old.clipSize != clipSize ||
      old.clipLeft != clipLeft ||
      old.clipTop != clipTop;
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
