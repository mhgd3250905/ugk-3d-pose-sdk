import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'trainer_stage.dart';
import 'trainer_theme.dart';

/// Result-only material scope. Live training and media never enter this stage.
/// Each library surface loads its own renderer lazily; hosts need no setup.
class TrainerResultStage extends StatelessWidget {
  const TrainerResultStage({
    super.key,
    required this.theme,
    required this.child,
  });

  final TrainerTheme theme;
  final Widget child;

  /// Only the outer result surfaces use optics; their descendants keep paint.
  static bool contains(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_ResultMaterialScope>()
          ?.enabled ??
      false;

  @override
  Widget build(BuildContext context) => GlassTheme(
    data: GlassThemeData(
      brightness: theme.isDark ? Brightness.dark : Brightness.light,
    ),
    child: _ResultMaterialScope(
      enabled: true,
      child: LayoutBuilder(
        builder: (context, box) {
          final size = box.biggest;
          final v = math.min(size.width, size.height * .5);
          return Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              ColoredBox(
                color: theme.mediaStage,
                child: TrainerStageFloor(
                  theme: theme,
                  clipSize: v,
                  clipLeft: (size.width - v) / 2,
                  clipTop: (size.height - v) / 2,
                  fadeClipEdge: false,
                ),
              ),
              ScrollConfiguration(
                // Android stretch isolates the backdrop in a compositing layer.
                // Keep ordinary scrolling without the stretch decoration.
                behavior: const MaterialScrollBehavior().copyWith(
                  overscroll: false,
                ),
                child: child,
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _ResultMaterialScope extends InheritedWidget {
  const _ResultMaterialScope({required this.enabled, required super.child});

  final bool enabled;

  @override
  bool updateShouldNotify(_ResultMaterialScope oldWidget) =>
      enabled != oldWidget.enabled;
}

/// Optical material for an existing result panel, preserving its layout.
/// Impeller uses the premium renderer. Web/Skia retain the library's lighter
/// frosted path; that fallback is not evidence of native optical rendering.
class TrainerResultSurface extends StatelessWidget {
  const TrainerResultSurface({
    super.key,
    required this.theme,
    required this.child,
    this.radius,
    this.padding,
    this.width,
    this.height,
  });

  final TrainerTheme theme;
  final Widget child;
  final double? radius;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final variant = theme.isDark
        ? GlassThemeVariant.dark
        : GlassThemeVariant.light;
    final defaults = variant.settings!.applyTo(const LiquidGlassSettings());
    final highContrast = MediaQuery.highContrastOf(context);
    final settings = defaults.copyWith(
      bodyMode: GlassBodyMode.clear,
      thickness: 30,
      blur: highContrast ? 0 : 2,
      lightIntensity: .18,
      glassColor: highContrast ? theme.surface : defaults.glassColor,
    );

    return GlassContainer(
      useOwnLayer: true,
      quality: highContrast ? GlassQuality.minimal : GlassQuality.premium,
      settings: settings,
      shape: radius == null
          ? const LiquidRoundedRectangle(borderRadius: double.infinity)
          : LiquidRoundedSuperellipse(borderRadius: radius!),
      padding: padding,
      width: width,
      height: height,
      child: _ResultMaterialScope(enabled: false, child: child),
    );
  }
}
