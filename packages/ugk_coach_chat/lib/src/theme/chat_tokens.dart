import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_theme.dart';

abstract final class ChatComposerTokens {
  static const outerPadding = EdgeInsets.fromLTRB(16, 0, 16, 12);
  static const inputInnerPadding = EdgeInsets.symmetric(horizontal: 4);
  static const inputTextPadding = EdgeInsets.symmetric(vertical: 15);
  static const inputHeight = 54.0;
  static const inputRadius = 22.0;
  static const inputTextSize = 16.0;
  static const inputTextHeight = 1.5;
  static const edgeWidth = 1.0;
  static const actionWidth = 44.0;
  static const bookmarkSize = 21.0;
  static const sendSize = 34.0;
  static const sendIconSize = 18.0;
  static const sendStrokeWidth = 2.0;
  static const inputInsetWithoutLeading = 12.0;
  static const pressScale = .97;
  static const suggestionStripHeight = 52.0;
  static const suggestionStripPadding = EdgeInsets.fromLTRB(16, 4, 16, 4);
  static const suggestionGap = 8.0;
  static const suggestionFaceHeight = 32.0;
  static const suggestionRadius = 16.0;
  static const suggestionPadding = EdgeInsets.symmetric(horizontal: 12);
  static const suggestionTextSize = 14.0;
  static const suggestionTextHeight = 1.2;
  static const suggestionTextWeight = FontWeight.w400;
  static const suggestionIconSize = 14.0;
  static const suggestionIconGap = 6.0;
  static const suggestionEdgeWidth = .75;

  static ChatComposerStyle of(BuildContext context) =>
      ChatTheme.of(context).composer;
}

class ChatComposerStyle {
  const ChatComposerStyle(this.colors);
  final CoachChatPalette colors;
  LinearGradient get dockGradient => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      colors.skyBottom.withValues(alpha: 0),
      colors.skyBottom.withValues(alpha: .18),
      colors.skyBottom.withValues(alpha: .72),
      colors.skyBottom,
    ],
    stops: const [0, .35, .70, 1],
  );

  LinearGradient get inputGradient => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: colors.isDark
        ? [
            colors.token('inputGradientTop', const Color(0xFF1D2225)),
            colors.token('inputGradientBottom', const Color(0xFF171C1F)),
          ]
        : [
            colors.token('inputGradientTop', const Color(0xFFFFFFFF)),
            colors.token('inputGradientBottom', const Color(0xFFF7F9F7)),
          ],
  );

  Color get inputEdge => colors.token(
    'inputEdge',
    colors.isDark ? const Color(0xFF3A4246) : const Color(0xFFD2DCD5),
  );
  Color get hint => colors.token(
    'hint',
    colors.isDark ? const Color(0xFF899596) : const Color(0xFF818E86),
  );
  Color get bookmark => colors.token(
    'bookmark',
    colors.isDark ? const Color(0xFFB1BDBE) : const Color(0xFF63736B),
  );
  Color get inactiveSendFill => colors.token(
    'inactiveSendFill',
    colors.isDark ? const Color(0xFF262F33) : const Color(0xFFECF0ED),
  );
  Color get inactiveSendInk => colors.token(
    'inactiveSendInk',
    colors.isDark ? const Color(0xFF748285) : const Color(0xFF9BA9A1),
  );
  List<BoxShadow> get inputShadow => [
    BoxShadow(
      color: colors.token(
        'inputShadow',
        colors.isDark ? const Color(0x28000000) : const Color(0x0B203B2B),
      ),
      blurRadius: 6,
      offset: const Offset(0, 2),
    ),
  ];

  Color get suggestionFill => colors.token(
    'suggestionFill',
    colors.isDark ? const Color(0xFF181F22) : const Color(0xFFF0F4F1),
  );
  Color get suggestionEdge => colors.token(
    'suggestionEdge',
    colors.isDark ? const Color(0xFF303A3E) : const Color(0xFFDDE5DF),
  );
  Color get suggestionInk => colors.token(
    'suggestionInk',
    colors.isDark ? const Color(0xFFBAC5C5) : const Color(0xFF4C5E54),
  );
  Color get suggestionIcon => colors.token(
    'suggestionIcon',
    colors.isDark ? const Color(0xFF8FB7B2) : const Color(0xFF598477),
  );
}

abstract final class ChatFeaturePanelTokens {
  static const padding = EdgeInsets.fromLTRB(16, 16, 16, 16);
  static const minTileWidth = 80.0;
  static const maxColumns = 4;
  static const rowGap = 16.0;
  static const tileSize = 56.0;
  static const tileRadius = 16.0;
  static const iconSize = 24.0;
  static const labelGap = 8.0;
  static const maxHeightFraction = .45;
  static ChatFeaturePanelStyle of(BuildContext context) =>
      ChatTheme.of(context).panel;
}

class ChatFeaturePanelStyle {
  const ChatFeaturePanelStyle(this.colors);
  final CoachChatPalette colors;
  Color get background => colors.skyBottom;
  Color get tileFill => colors.surfaceHigh;
  Color get tileEdge => colors.line;
}

abstract final class ChatType {
  static ChatTextTokens of(BuildContext context) => ChatTheme.of(context).type;
  static const labelMetrics = TextStyle(
    fontSize: 13,
    height: 1.4,
    fontWeight: FontWeight.w400,
  );
  static const tabular = [FontFeature.tabularFigures()];
}

class ChatTextTokens {
  const ChatTextTokens(this.colors, this.fontFamily);
  final CoachChatPalette colors;
  final String? fontFamily;

  /// 完成页 title.
  TextStyle get display => TextStyle(
    fontFamily: fontFamily,
    fontSize: 30,
    height: 1.2,
    fontWeight: FontWeight.w800,
    letterSpacing: -.3,
    color: colors.text,
  );

  /// The chat's greeting: large type floating in the sky, no bubble.
  TextStyle get greeting => TextStyle(
    fontFamily: fontFamily,
    fontSize: 28,
    height: 1.3,
    fontWeight: FontWeight.w700,
    letterSpacing: -.2,
    color: colors.text,
  );

  /// Card / page / exercise titles.
  TextStyle get title => TextStyle(
    fontFamily: fontFamily,
    fontSize: 20,
    height: 1.3,
    fontWeight: FontWeight.w700,
    letterSpacing: -.1,
    color: colors.text,
  );

  /// Section heads, sheet titles.
  TextStyle get headline => TextStyle(
    fontFamily: fontFamily,
    fontSize: 17,
    height: 1.35,
    fontWeight: FontWeight.w600,
    color: colors.text,
  );

  /// Conversation and running text.
  TextStyle get body => TextStyle(
    fontFamily: fontFamily,
    fontSize: 16,
    height: 1.6,
    fontWeight: FontWeight.w400,
    color: colors.text,
  );

  /// List rows, chips, buttons inside cards.
  TextStyle get callout => TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    height: 1.4,
    fontWeight: FontWeight.w500,
    color: colors.text,
  );

  /// Meta lines (时长 · 动作数 · 器械), doses.
  TextStyle get label => TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    height: 1.4,
    fontWeight: FontWeight.w400,
    color: colors.muted,
  );

  /// Time marks, hints, footnotes.
  TextStyle get caption => TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    height: 1.4,
    fontWeight: FontWeight.w400,
    color: colors.faint,
  );

  /// Numbers that tick (counter, progress).
  static const tabular = [FontFeature.tabularFigures()];

  /// A large number that changes (countdown, stats): tabular, tight, set
  /// solid (HipLab's ring numeral: tracking −1.2 % of the size).
  TextStyle numeral(double size, {Color? color}) => TextStyle(
    fontFamily: fontFamily,
    fontSize: size,
    height: 1,
    fontWeight: FontWeight.w700,
    letterSpacing: -size * .012,
    color: color ?? colors.text,
    fontFeatures: tabular,
  );
}

/// 4-pt spacing grid.
abstract final class ChatSpace {
  static const x1 = 4.0;
  static const x2 = 8.0;
  static const x3 = 12.0;
  static const x4 = 16.0;
  static const x5 = 20.0;
  static const x6 = 24.0;
  static const x8 = 32.0;

  /// Page gutter.
  static const gutter = 20.0;
}

/// Radii: a small set used everywhere. Nested corners step down by the
/// padding between them (card 22 → inner stage 14 at 8 pt inset).
abstract final class ChatRadius {
  static const xs = 8.0; // tiny thumbnails, tags
  static const sm = 12.0; // list thumbnails
  static const md = 16.0; // inner tiles, chips' container rows
  static const lg = 22.0; // cards, bubbles, media
  static const xl = 28.0; // sheets, drawer

  /// Bubble corner on the speaker's side.
  static const tail = 8.0;
}

/// Motion tokens (HipLab's vocabulary): short, no bounce, one large move
/// per transition.
abstract final class ChatMotion {
  static const fast = Duration(milliseconds: 180);
  static const medium = Duration(milliseconds: 280);
  static const slow = Duration(milliseconds: 420);

  /// Press feedback (scale + slightly deeper fill) and its release.
  static const press = Duration(milliseconds: 100);
  static const release = Duration(milliseconds: 180);
  static const pressScale = .97;

  /// A message arriving: fade + 12 px rise.
  static const appear = Duration(milliseconds: 360);

  /// Container transform (plan card → player): the one large move.
  static const expand = Duration(milliseconds: 500);
  static const expandReverse = Duration(milliseconds: 420);

  /// Push / pop of a plain page, its reverse a touch quicker.
  static const page = Duration(milliseconds: 400);
  static const pageReverse = Duration(milliseconds: 340);

  /// Sheets rise on the page timing.
  static const sheet = AnimationStyle(
    duration: page,
    reverseDuration: pageReverse,
  );

  /// Items arriving together, one after another.
  static const stagger = Duration(milliseconds: 40);

  /// Messages of one reply (words first, then the card).
  static const replyStagger = Duration(milliseconds: 120);

  /// A digit rolling over (countdown, rep counter).
  static const roll = Duration(milliseconds: 260);

  /// The last-seconds breath of the countdown (once per second).
  static const breath = Duration(milliseconds: 1000);

  /// Segmented thumb slide.
  static const segment = Duration(milliseconds: 380);

  /// Finish: the check drawing itself, the one ring going out, counting up.
  static const check = Duration(milliseconds: 520);
  static const ripple = Duration(milliseconds: 900);
  static const countUp = Duration(milliseconds: 700);

  static const Curve standard = Curves.easeOutCubic;

  /// Pages arriving: a gentle first frame, half way at ~20 %.
  static const Curve enter = Cubic(0.2, 0.0, 0.0, 1.0);

  /// A page leaving (pop), as the distance travelled.
  static const Curve exit = Curves.fastOutSlowIn;

  /// Container bounds, both ways.
  static const Curve container = Curves.fastOutSlowIn;

  /// A soft spring (≈4 % overshoot): the segmented thumb only.
  static const Curve spring = Cubic(0.32, 1.28, 0.52, 1.0);

  /// Whether the platform asks for reduced motion.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// Touch feedback, graded (docs/design-audit-2026-10-19.md §2.9): a
/// selection tick for choices, a light tap for primary buttons, a medium
/// one for starting / finishing a workout. Haptics stay on under reduced
/// motion (they are not motion).
enum ChatHaptic {
  none,
  selection,
  light,
  medium;

  void play() {
    switch (this) {
      case ChatHaptic.none:
        return;
      case ChatHaptic.selection:
        HapticFeedback.selectionClick();
      case ChatHaptic.light:
        HapticFeedback.lightImpact();
      case ChatHaptic.medium:
        HapticFeedback.mediumImpact();
    }
  }
}
