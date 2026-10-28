// Player-scoped solid surfaces, semantic colours and typography.
import 'package:flutter/material.dart';

@immutable
class TrainerTheme {
  const TrainerTheme({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceHigh,
    required this.border,
    required this.shadow,
    required this.track,
    required this.ringKnob,
    required this.accent,
    required this.accentSubtle,
    required this.accentText,
    required this.onAccent,
    required this.text,
    required this.muted,
    required this.faint,
    required this.caution,
    required this.danger,
    required this.mediaStage,
    this.fontFamily,
    this.radius = 22,
    Color? pausedColor,
    Color? onPaused,
    Color? cardSurface,
    Color? cardBorder,
    this.primaryForeground = const Color(0xFFFFFFFF),
  }) : pausedColor = pausedColor ?? accent,
       onPaused = onPaused ?? onAccent,
       cardSurface = cardSurface ?? surface,
       cardBorder = cardBorder ?? border;

  final Brightness brightness;

  /// The three opaque elevation levels: page, panel and raised control.
  final Color background;
  final Color surface;
  final Color surfaceHigh;

  /// One-pixel surface separation and the fixed, soft contact shadow.
  final Color border;
  final Color shadow;
  final Color track;
  final Color ringKnob;

  /// Primary action, its quiet progress state, and readable foregrounds.
  final Color accent;
  final Color accentSubtle;
  final Color accentText;
  final Color onAccent;
  final Color pausedColor;
  final Color onPaused;

  /// Action cards and training UX surfaces use one continuous background.
  final Color cardSurface;
  final Color cardBorder;
  final Color primaryForeground;
  final Color text;
  final Color muted;
  final Color faint;
  final Color caution;
  final Color danger;

  /// Opaque background behind native or transparent training media.
  final Color mediaStage;
  final String? fontFamily;
  final double radius;

  bool get isDark => brightness == Brightness.dark;

  /// Every visual token can be overridden within the player scope.
  TrainerTheme copyWith({
    Brightness? brightness,
    Color? background,
    Color? surface,
    Color? surfaceHigh,
    Color? border,
    Color? shadow,
    Color? track,
    Color? ringKnob,
    Color? accent,
    Color? accentSubtle,
    Color? accentText,
    Color? onAccent,
    Color? pausedColor,
    Color? onPaused,
    Color? cardSurface,
    Color? cardBorder,
    Color? primaryForeground,
    Color? text,
    Color? muted,
    Color? faint,
    Color? caution,
    Color? danger,
    Color? mediaStage,
    String? fontFamily,
    double? radius,
  }) => TrainerTheme(
    brightness: brightness ?? this.brightness,
    background: background ?? this.background,
    surface: surface ?? this.surface,
    surfaceHigh: surfaceHigh ?? this.surfaceHigh,
    border: border ?? this.border,
    shadow: shadow ?? this.shadow,
    track: track ?? this.track,
    ringKnob: ringKnob ?? this.ringKnob,
    accent: accent ?? this.accent,
    accentSubtle: accentSubtle ?? this.accentSubtle,
    accentText: accentText ?? this.accentText,
    onAccent: onAccent ?? this.onAccent,
    pausedColor: pausedColor ?? this.pausedColor,
    onPaused: onPaused ?? this.onPaused,
    cardSurface: cardSurface ?? this.cardSurface,
    cardBorder: cardBorder ?? this.cardBorder,
    primaryForeground: primaryForeground ?? this.primaryForeground,
    text: text ?? this.text,
    muted: muted ?? this.muted,
    faint: faint ?? this.faint,
    caution: caution ?? this.caution,
    danger: danger ?? this.danger,
    mediaStage: mediaStage ?? this.mediaStage,
    fontFamily: fontFamily ?? this.fontFamily,
    radius: radius ?? this.radius,
  );

  static const dark = TrainerTheme(
    cardSurface: Color(0xFF1A2324),
    cardBorder: Color.from(alpha: .08, red: 1, green: 1, blue: 1),
    brightness: Brightness.dark,
    background: Color(0xFF0C1117),
    surface: Color(0xFF151D25),
    surfaceHigh: Color(0xFF202A33),
    border: Color(0xFF303B45),
    shadow: Color(0x1A000000),
    track: Color(0xFF303D46),
    ringKnob: Color(0xFFF3F6F7),
    accent: Color(0xFF64DAB5),
    accentSubtle: Color(0xFF346F5E),
    accentText: Color(0xFF7BE2C1),
    onAccent: Color(0xFF072E23),
    text: Color(0xFFF3F6F7),
    muted: Color(0xFFA8B3BB),
    faint: Color(0xFF76848E),
    caution: Color(0xFFF3A443),
    danger: Color(0xFFEF6A6A),
    mediaStage: Color(0xFF0C1117),
  );

  static const light = TrainerTheme(
    cardSurface: Color(0xFFFFFFFF),
    cardBorder: Color(0xFFE3E8E6),
    brightness: Brightness.light,
    background: Color(0xFFF2F4F5),
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFE8EEF1),
    border: Color(0xFFD6DEE2),
    shadow: Color(0x0C17262C),
    track: Color(0xFFD3DFDA),
    ringKnob: Color(0xFFFFFFFF),
    accent: Color(0xFF12A97F),
    accentSubtle: Color(0xFFA8D9CB),
    accentText: Color(0xFF08614B),
    onAccent: Color(0xFF052B21),
    text: Color(0xFF17262C),
    muted: Color(0xFF51616C),
    faint: Color(0xFF72858B),
    caution: Color(0xFFB8650F),
    danger: Color(0xFFD43F3F),
    mediaStage: Color(0xFFF2F4F5),
  );

  TextStyle _t(double size, double height, FontWeight w, Color c) => TextStyle(
    fontFamily: fontFamily,
    fontSize: size,
    height: height,
    fontWeight: w,
    color: c,
  );

  TextStyle get display => _t(30, 1.2, FontWeight.w600, text);
  TextStyle get title => _t(20, 1.3, FontWeight.w600, text);
  TextStyle get body => _t(16, 1.6, FontWeight.w400, text);
  TextStyle get callout => _t(15, 1.4, FontWeight.w500, text);
  TextStyle get label => _t(13, 1.4, FontWeight.w400, muted);

  static const tabular = [FontFeature.tabularFigures()];

  TextStyle numeral(double size, {Color? color}) => TextStyle(
    fontFamily: fontFamily,
    fontSize: size,
    height: 1,
    fontWeight: FontWeight.w500,
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
