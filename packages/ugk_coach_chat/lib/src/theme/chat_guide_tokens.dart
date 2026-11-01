import 'package:flutter/material.dart';

import 'chat_tokens.dart';
import 'chat_theme.dart';

/// Approved training-guide layout; colour roles follow the current App theme.
abstract final class ChatGuideTokens {
  static Color previewControlFill(BuildContext context) {
    final colors = ChatTheme.of(context).colors;
    return colors.token(
      'guidePreviewControlFill',
      colors.isDark
          ? Colors.black.withValues(alpha: .55)
          : Colors.white.withValues(alpha: .92),
    );
  }

  static Color previewControlInk(BuildContext context) {
    final colors = ChatTheme.of(context).colors;
    return colors.token(
      'guidePreviewControlInk',
      colors.isDark ? Colors.white : colors.accent,
    );
  }

  static List<BoxShadow>? previewControlShadow(BuildContext context) {
    final colors = ChatTheme.of(context).colors;
    return colors.isDark
        ? null
        : [
            BoxShadow(
              color: colors.token(
                'guidePreviewControlShadow',
                Colors.black.withValues(alpha: .12),
              ),
              offset: const Offset(0, 2),
              blurRadius: 8,
            ),
          ];
  }

  static const pageInset = 20.0;
  static const bottomSpace = 96.0;
  static const cardGap = 14.0;
  static const cardRadius = 20.0;
  static const mediaRatio = 4 / 3;
  static const bodyPadding = EdgeInsets.fromLTRB(16, 14, 16, 16);
  static const sectionPadding = EdgeInsets.only(top: 28, bottom: 10);
  static const tagHeight = 26.0;
  static const tagRadius = 13.0;
  static const tagPadding = EdgeInsets.symmetric(horizontal: 10);
  static const tagGap = 6.0;
  static const numberSize = 24.0;
  static const numberRadius = 12.0;
  static const nameGap = 10.0;
  static const muscleGap = 6.0;
  static const dividerGap = 12.0;
  static const instructionGap = 12.0;
  static const stepSize = 18.0;
  static const stepGap = 8.0;
  static const buttonHeight = 52.0;
  static const buttonRadius = 26.0;
  static const buttonBottom = 12.0;
  static const footerFade = 24.0;

  static Color cardFill(BuildContext context) =>
      ChatTheme.of(context).colors.isDark
      ? Theme.of(context).colorScheme.surfaceContainer
      : Theme.of(context).colorScheme.surface;

  static Color doseFill(BuildContext context) => ChatTheme.of(context)
      .colors
      .accent
      .withValues(alpha: ChatTheme.of(context).colors.isDark ? .18 : .10);

  static List<BoxShadow> cardShadow(BuildContext context) =>
      ChatTheme.of(context).colors.isDark
      ? const []
      : [
          BoxShadow(
            color: Colors.black.withValues(alpha: .06),
            offset: const Offset(0, 1),
            blurRadius: 3,
          ),
        ];

  static TextStyle title(BuildContext context) => ChatType.of(
    context,
  ).title.copyWith(fontSize: 24, fontWeight: FontWeight.w700);
  static TextStyle tag(BuildContext context) => ChatType.of(
    context,
  ).label.copyWith(fontSize: 12, fontWeight: FontWeight.w500, height: 1.2);
  static TextStyle section(BuildContext context) => ChatType.of(context).label
      .copyWith(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: .5);
  static TextStyle number(BuildContext context) =>
      ChatType.of(context).label.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        height: 1,
        color: ChatTheme.of(context).colors.accent,
      );
  static TextStyle name(BuildContext context) => ChatType.of(
    context,
  ).headline.copyWith(fontSize: 17, fontWeight: FontWeight.w600);
  static TextStyle dose(BuildContext context) =>
      ChatType.of(context).label.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        height: 1.2,
        color: ChatTheme.of(context).colors.accent,
      );
  static TextStyle muscles(BuildContext context) =>
      ChatType.of(context).label.copyWith(fontSize: 13);
  static TextStyle caption(BuildContext context) => ChatType.of(
    context,
  ).label.copyWith(fontSize: 12, fontWeight: FontWeight.w600);
  static TextStyle step(BuildContext context) =>
      ChatType.of(context).body.copyWith(fontSize: 14, height: 1.5);
  static TextStyle stepNumber(BuildContext context) => ChatType.of(
    context,
  ).label.copyWith(fontSize: 11, fontWeight: FontWeight.w600, height: 1);
  static TextStyle button(BuildContext context) =>
      ChatType.of(context).body.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.2,
        color: ChatTheme.of(context).colors.onAccent,
      );
}
