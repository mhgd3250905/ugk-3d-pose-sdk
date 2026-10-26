import 'package:flutter/widgets.dart';

/// A bounded paint reveal. The child keeps its layout and state while a hard
/// clip exposes it; no subtree alpha or intermediate render target is needed.
class PaintReveal extends AnimatedWidget {
  const PaintReveal({
    super.key,
    required Animation<double> progress,
    required this.child,
  }) : super(listenable: progress);

  PaintReveal.fixed({super.key, required double fraction, required this.child})
    : super(listenable: AlwaysStoppedAnimation(fraction));

  final Widget? child;
  Animation<double> get progress => listenable as Animation<double>;

  @override
  Widget build(BuildContext context) {
    final fraction = progress.value.clamp(0.0, 1.0);
    return IgnorePointer(
      ignoring: fraction == 0,
      child: ExcludeSemantics(
        excluding: fraction == 0,
        child: ClipRect(
          // Settled cutout art may intentionally protrude beyond its hero.
          // Keep the same subtree while releasing the transitional clip.
          clipBehavior: fraction == 1 ? Clip.none : Clip.hardEdge,
          clipper: _RevealClipper(fraction),
          child: child,
        ),
      ),
    );
  }
}

class _RevealClipper extends CustomClipper<Rect> {
  const _RevealClipper(this.fraction);
  final double fraction;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(
    0,
    size.height * (1 - fraction),
    size.width,
    size.height * fraction,
  );

  @override
  bool shouldReclip(_RevealClipper oldClipper) =>
      fraction != oldClipper.fraction;
}

/// Complementary horizontal slices let two media sources hand over inside the
/// same flying rectangle without painting both sources over the same pixels.
class MediaSliceClipper extends CustomClipper<Rect> {
  const MediaSliceClipper(this.start, this.end);
  final double start, end;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(
    size.width * start.clamp(0.0, 1.0),
    0,
    size.width * end.clamp(0.0, 1.0),
    size.height,
  );

  @override
  bool shouldReclip(MediaSliceClipper oldClipper) =>
      start != oldClipper.start || end != oldClipper.end;
}
