import 'package:flutter/material.dart';
import 'theme.dart';

/// Approved SmartFit generation-card geometry and motion, unchanged.
class CoachTaskBubbleTokens {
  static const cardPadding = EdgeInsets.fromLTRB(16, 14, 16, 16);
  static const padding = cardPadding;
  static const cardRadius = 20.0;
  static const cardEdgeWidth = .5;
  static const glowRadius = 160.0;
  static const animationSize = 44.0;
  static const animationGap = 12.0;
  static const arcStroke = 1.5;
  static const arcWidth = arcStroke;
  static const arcSweep = 300.0;
  static const arcHeadSize = 1.5;
  static const rotation = Duration(milliseconds: 1400);
  static const coreSize = 10.0;
  static const haloSize = 20.0;
  static const breath = Duration(milliseconds: 1200);
  static const breathInitialScale = .8;
  static const breathInitialOpacity = .6;
  static const coreCollapse = Duration(milliseconds: 180);
  static const silhouetteHold = Duration(milliseconds: 900);
  static const silhouetteFade = Duration(milliseconds: 250);
  static const imageHold = silhouetteHold;
  static const imageTransition = silhouetteFade;
  static const imageInitialScale = .94;
  static const statusExit = Duration(milliseconds: 160);
  static const statusDelay = Duration(milliseconds: 60);
  static const statusTransition = Duration(milliseconds: 220);
  static const statusOffset = 6.0;
  static const statusGap = 3.0;
  static const shimmer = Duration(milliseconds: 1600);
  static const progressTransition = Duration(milliseconds: 400);
  static const progressBand = Duration(milliseconds: 1200);
  static const progressBandFraction = .4;
  static const progressTopGap = 14.0;
  static const progressHeight = 3.0;
  static const progressRadius = 1.5;
  static const progressGap = 4.0;
  static const progressSegments = 4;
  static const thumbnailInset = 6.0;
  static const chipsTopGap = 12.0;
  static const chipGap = 6.0;
  static const chipHeight = 24.0;
  static const chipPadding = EdgeInsets.symmetric(horizontal: 9);
  static const chipRadius = 12.0;
  static const chipTransition = Duration(milliseconds: 200);
  static const chipDelay = Duration(milliseconds: 60);
  static const chipInitialScale = .9;
  static const cancelTouchSize = 44.0;
  static const completionVisual = Duration(milliseconds: 240);
  static const completionHold = Duration(milliseconds: 350);
  static const completionTransition = Duration(milliseconds: 300);
  static const completionFade = Duration(milliseconds: 200);
  static const completionDetail = Duration(milliseconds: 120);
  static const checkSize = 20.0;
  static const checkInitialScale = .6;
  static const maxWidth = 400.0;

  // Prototype curves, copied verbatim from its CSS variables. Flutter's
  // Curves.easeInOutSine/easeOutBack are different cubics, so do not swap.
  static const sine = Cubic(.37, 0, .63, 1);
  static const back = Cubic(.34, 1.56, .64, 1);
  static const checkTransition = Duration(milliseconds: 260);
  static const checkFade = Duration(milliseconds: 120);
  static const checkStroke = 2.4;

  /// First silhouette waits for the core collapse, then fades in.
  static const silhouetteRevealDelay = coreCollapse;

  /// The shimmer gradient is 2.5x the sentence width and travels from
  /// background-position 100% to -150% (left to right).
  static const shimmerSpan = 2.5;

  /// The cancel target overhangs the card's right padding by 10 px.
  static const cancelOutset = 10.0;

  final CoachUiStyle style;
  final double letterSpacing;
  const CoachTaskBubbleTokens(this.style, {this.letterSpacing = 0});
  CoachUiColors get colors => style.colors;

  Color get cardEdge => colors.taskCardBorder;
  List<BoxShadow> get cardShadow => colors.isDark
      ? const []
      : [
          BoxShadow(
            color: colors.taskShadowNear,
            offset: const Offset(0, 1),
            blurRadius: 2,
          ),
          BoxShadow(
            color: colors.taskShadowFar,
            offset: const Offset(0, 6),
            blurRadius: 20,
          ),
        ];
  Color get glow => colors.taskGlow;
  Color get orbFill => colors.taskOrbFill;
  Color get progressTrack => colors.taskProgressTrack;
  Color get chipEdge => colors.taskChipBorder;
  // SfType uses bare styles, inheriting Scaffold's bodyMedium spacing instead
  // of Material role geometry. Copying titleSmall/labelMedium/bodySmall would
  // silently introduce .1/.5/.4 spacing in a resolved Material 3 theme.
  TextStyle get title => TextStyle(
    fontFamily: style.typography.callout.fontFamily,
    fontFamilyFallback: style.typography.callout.fontFamilyFallback,
    fontSize: 15,
    height: 1.35,
    fontWeight: FontWeight.w600,
    letterSpacing: letterSpacing,
    color: colors.taskText,
  );
  TextStyle get status => TextStyle(
    fontFamily: style.typography.body.fontFamily,
    fontFamilyFallback: style.typography.body.fontFamilyFallback,
    fontSize: 13,
    height: 18 / 13,
    fontWeight: FontWeight.w500,
    letterSpacing: letterSpacing,
    color: colors.taskMuted,
  );
  // The source TextButton theme supplies a bare style with no letter spacing.
  TextStyle get cancel => TextStyle(
    fontFamily: style.typography.label.fontFamily,
    fontFamilyFallback: style.typography.label.fontFamilyFallback,
    fontSize: 13,
    height: 1.4,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    color: colors.taskMuted,
  );
  TextStyle chipText(bool user) => TextStyle(
    fontFamily: style.typography.caption.fontFamily,
    fontFamilyFallback: style.typography.caption.fontFamilyFallback,
    fontSize: 12,
    height: 1.4,
    fontWeight: FontWeight.w500,
    letterSpacing: letterSpacing,
    color: user ? colors.taskAccent : colors.taskMuted,
  );
  Color chipFill(bool user) =>
      user ? colors.taskChipSurface : Colors.transparent;
  Color get highlight => colors.taskText;
  static const shimmerStops = [0.0, .35, .5, .65, 1.0];
}
