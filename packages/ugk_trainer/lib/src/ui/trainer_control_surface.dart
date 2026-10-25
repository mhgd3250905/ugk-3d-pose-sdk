import 'package:flutter/widgets.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'trainer_theme.dart';

/// Optical library surfaces using the accessory/control recipes recorded in
/// the Liquid Glass skill's UGK Water R4 case.
class TrainerControlSurface extends StatelessWidget {
  const TrainerControlSurface({
    super.key,
    required this.theme,
    required this.child,
    this.radius,
    this.padding,
    this.width,
    this.height,
    this.control = false,
  });

  final TrainerTheme theme;
  final Widget child;
  final double? radius;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;
  final bool control;

  @override
  Widget build(BuildContext context) {
    final variant = theme.isDark
        ? GlassThemeVariant.dark
        : GlassThemeVariant.light;
    final defaults = variant.settings!.applyTo(const LiquidGlassSettings());
    final highContrast = MediaQuery.highContrastOf(context);
    final nested =
        context
            .dependOnInheritedWidgetOfExactType<InheritedLiquidGlass>()
            ?.avoidsRefraction ??
        false;
    return GlassTheme(
      data: GlassThemeData(brightness: theme.brightness),
      child: RepaintBoundary(
        child: GlassContainer(
          // Independent surfaces own their optical layer. Inside an existing
          // glass platter, use its vibrancy path instead of nesting
          // another refracting surface (for example the header's close button).
          useOwnLayer: !nested,
          quality: highContrast ? GlassQuality.minimal : GlassQuality.premium,
          settings: nested
              ? null
              : defaults.copyWith(
                  bodyMode: GlassBodyMode.clear,
                  // Preserve the case's exact role-specific optical recipes and
                  // brightness-aware tint; no opaque backer or extra content fill.
                  thickness: control ? 24 : 30,
                  blur: highContrast ? 0 : (control ? 3 : 2),
                  lightIntensity: control ? .2 : .18,
                  glassColor: highContrast
                      ? theme.surface
                      : defaults.glassColor,
                ),
          shape: radius == null
              ? const LiquidRoundedRectangle(borderRadius: double.infinity)
              : LiquidRoundedSuperellipse(borderRadius: radius!),
          padding: padding,
          width: width,
          height: height,
          child: child,
        ),
      ),
    );
  }
}
