import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';

import 'trainer_stage.dart';
import 'trainer_theme.dart';

/// Internal result-only optics. Never wrap a live training/media subtree in
/// this view: Skia captures its static background once, Impeller samples it.
/// The package lazily loads its shaders; hosts need no initialization call.
class TrainerResultStage extends StatefulWidget {
  const TrainerResultStage({
    super.key,
    required this.theme,
    required this.child,
  });

  final TrainerTheme theme;
  final Widget child;

  @override
  State<TrainerResultStage> createState() => _TrainerResultStageState();
}

class _TrainerResultStageState extends State<TrainerResultStage> {
  final _capture = LiquidGlassViewController();
  Size? _size;
  TrainerTheme? _theme;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final size = box.biggest;
      if (_size != size || _theme != widget.theme) {
        _size = size;
        _theme = widget.theme;
        // Refresh the cached Skia background on resize/theme changes only.
        // The result content keeps the same State and scroll position.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_capture.captureOnce());
        });
      }
      final v = math.min(size.width, size.height * .5);
      return LiquidGlassView(
        controller: _capture,
        realTimeCapture: false,
        batch: false,
        backgroundWidget: ColoredBox(
          color: widget.theme.mediaStage,
          child: TrainerStageFloor(
            theme: widget.theme,
            clipSize: v,
            clipLeft: (size.width - v) / 2,
            clipTop: size.height * .08,
            fadeClipEdge: false,
          ),
        ),
        child: ScrollConfiguration(
          // Android stretch puts backdrop filters in an isolated layer.
          // Disable that decoration only; normal scrolling is unchanged.
          behavior: const MaterialScrollBehavior().copyWith(overscroll: false),
          child: widget.child,
        ),
      );
    },
  );
}

/// A single clear result sheet, with ordinary content inside (no glass nesting).
class TrainerResultSurface extends StatelessWidget {
  const TrainerResultSurface({
    super.key,
    required this.theme,
    required this.child,
    this.padding = const EdgeInsets.all(24),
  });

  final TrainerTheme theme;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: padding, child: child);
    if (MediaQuery.highContrastOf(context)) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: theme.surface,
          borderRadius: BorderRadius.circular(32),
          border: Border.all(color: theme.muted),
        ),
        child: content,
      );
    }
    return LiquidGlassLens(
      style: LiquidGlassStyle(
        shape: const LiquidGlassShape.continuousRoundedRectangle(
          cornerRadius: 32,
        ),
        specular: LiquidGlassLight.specular(
          thickness: 3,
          intensity: theme.isDark ? .55 : .8,
        ),
        refractionIndex: 1.02,
        refractionWidth: 24,
        shadow: LiquidGlassShadow(
          cornerRadius: 32,
          blur: 6,
          opacity: theme.isDark ? .18 : .09,
          offset: const Offset(0, 3),
          insideGlass: false,
        ),
        color: theme.isDark ? const Color(0x161B252C) : const Color(0x26FFFFFF),
      ),
      child: content,
    );
  }
}
