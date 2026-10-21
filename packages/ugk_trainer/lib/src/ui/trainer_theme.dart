// Colour / type / spacing tokens of the player, after SmartFit@e8981ee
// lib/ui/theme/tokens.dart (SfPalette dark / light, SfType, SfSpace,
// SfRadius, SfMotion). The app passes its own [TrainerTheme]; the presets
// are SmartFit's values.
import 'package:flutter/material.dart';

import 'trainer_glass.dart';

@immutable
class TrainerTheme {
  const TrainerTheme({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceHigh,
    required this.track,
    required this.accent,
    required this.accentText,
    required this.onAccent,
    required this.text,
    required this.muted,
    required this.faint,
    required this.caution,
    required this.danger,
    required this.mediaStage,
    required this.scrim,
    this.fontFamily,
    this.radius = 22,
    this.glassStyle,
  });

  final Brightness brightness;

  /// Behind the whole player.
  final Color background;

  /// Panels (下一个, stats).
  final Color surface;

  /// Circle buttons.
  final Color surfaceHigh;

  /// Ring / progress tracks.
  final Color track;

  /// The one accent: the working ring and the pause disc.
  final Color accent;
  final Color accentText;
  final Color onAccent;
  final Color text;
  final Color muted;
  final Color faint;

  /// Safety only (不舒服, 换侧).
  final Color caution;
  final Color danger;

  /// Behind a drill clip.
  final Color mediaStage;

  /// Labels floating on media (已暂停, 不舒服).
  final Color scrim;
  final String? fontFamily;

  /// Media / panel corner radius.
  final double radius;

  /// The app's own glass material; null: SmartFit's clear glass preset.
  final TrainerGlassStyle? glassStyle;

  /// Clear liquid glass for controls and HUD pills (SmartFit, 2026-10-21).
  TrainerGlassStyle get glass =>
      glassStyle ?? (isDark ? TrainerGlassStyle.dark : TrainerGlassStyle.light);

  bool get isDark => brightness == Brightness.dark;

  /// A copy with some tokens replaced (host apps pass their own theme).
  TrainerTheme copyWith({
    Color? background,
    Color? surface,
    Color? surfaceHigh,
    Color? accent,
    Color? accentText,
    Color? onAccent,
    Color? text,
    Color? muted,
    String? fontFamily,
    double? radius,
    TrainerGlassStyle? glassStyle,
  }) => TrainerTheme(
    brightness: brightness,
    background: background ?? this.background,
    surface: surface ?? this.surface,
    surfaceHigh: surfaceHigh ?? this.surfaceHigh,
    track: track,
    accent: accent ?? this.accent,
    accentText: accentText ?? this.accentText,
    onAccent: onAccent ?? this.onAccent,
    text: text ?? this.text,
    muted: muted ?? this.muted,
    faint: faint,
    caution: caution,
    danger: danger,
    mediaStage: mediaStage,
    scrim: scrim,
    fontFamily: fontFamily ?? this.fontFamily,
    radius: radius ?? this.radius,
    glassStyle: glassStyle ?? this.glassStyle,
  );

  static const dark = TrainerTheme(
    brightness: Brightness.dark,
    background: Color(0xFF0E0F11), // neutral sky (SmartFit round 4)
    surface: Color(0xFF15171C),
    surfaceHigh: Color(0xFF1F2228),
    track: Color(0x1FFFFFFF),
    accent: Color(0xFF3CCFA4),
    accentText: Color(0xFF3CCFA4),
    onAccent: Color(0xFF07261D),
    text: Color(0xFFF2F3F5),
    muted: Color(0xFF8D9199),
    faint: Color(0xFF5C6068),
    caution: Color(0xFFF3A443),
    danger: Color(0xFFEF6A6A),
    mediaStage: Color(0xFF101013),
    scrim: Color(0xA6000000),
  );

  static const light = TrainerTheme(
    brightness: Brightness.light,
    background: Color(0xFFF4F5F3),
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFEEF0EE),
    track: Color(0x14000000),
    accent: Color(0xFF14A37B),
    accentText: Color(0xFF0D6E53),
    onAccent: Color(0xFFFFFFFF),
    text: Color(0xFF121614),
    muted: Color(0xFF5D6661),
    faint: Color(0xFF9AA29E),
    caution: Color(0xFFB8650F),
    danger: Color(0xFFD43F3F),
    mediaStage: Color(0xFFEFEFEF),
    scrim: Color(0x8C000000),
  );

  TextStyle _t(double size, double height, FontWeight w, Color c) => TextStyle(
    fontFamily: fontFamily,
    fontSize: size,
    height: height,
    fontWeight: w,
    color: c,
  );

  TextStyle get display => _t(30, 1.2, FontWeight.w800, text);
  TextStyle get title => _t(20, 1.3, FontWeight.w700, text);
  TextStyle get body => _t(16, 1.6, FontWeight.w400, text);
  TextStyle get callout => _t(15, 1.4, FontWeight.w500, text);
  TextStyle get label => _t(13, 1.4, FontWeight.w400, muted);

  static const tabular = [FontFeature.tabularFigures()];

  TextStyle numeral(double size, {Color? color}) => TextStyle(
    fontFamily: fontFamily,
    fontSize: size,
    height: 1,
    fontWeight: FontWeight.w700,
    letterSpacing: -size * .012,
    color: color ?? text,
    fontFeatures: tabular,
  );
}

/// Spacing and motion steps (SmartFit SfSpace / SfMotion).
abstract final class TrainerSpace {
  static const x1 = 4.0;
  static const x2 = 8.0;
  static const x3 = 12.0;
  static const x4 = 16.0;
  static const x5 = 20.0;
  static const x6 = 24.0;
  static const x8 = 32.0;
  static const gutter = 20.0;
}

abstract final class TrainerMotion {
  static const fast = Duration(milliseconds: 180);
  static const medium = Duration(milliseconds: 280);
  static const slow = Duration(milliseconds: 420);
  static const roll = Duration(milliseconds: 260);
  static const breath = Duration(milliseconds: 1000);
  static const Curve standard = Curves.easeOutCubic;

  /// Calm phase changes (SmartFit r10): unhurried, one curve, the old
  /// content leaves before the new arrives — nothing overlaps mid-flight.
  static const calm = Duration(milliseconds: 500);
  static const Curve calmCurve = Curves.fastOutSlowIn;

  /// Stagger between neighbours entering together.
  static const stagger = Duration(milliseconds: 60);

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}
