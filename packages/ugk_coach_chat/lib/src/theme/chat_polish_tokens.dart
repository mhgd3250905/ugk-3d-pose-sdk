import 'package:flutter/material.dart';

import 'chat_tokens.dart';
import 'chat_theme.dart';

/// Approved first-batch UI values. Keep product-specific values in the theme.
abstract final class ChatCardTokens {
  static const radius = 20.0;
  static const edgeWidth = 1.0;
  static const inset = 12.0;
  static const padding = EdgeInsets.all(inset);
  static const gridGap = 12.0;
  static const imageAspectRatio = 1.0;
  static const titleLines = 2;
}

abstract final class ChatPlanPolishTokens {
  static const toggleHeight = 32.0;
  static const togglePadding = EdgeInsets.symmetric(horizontal: 12);
  static const toggleRadius = 16.0;
  static const toggleInset = 12.0;
  static const expansion = ChatMotion.medium;
  static const rowFade = ChatMotion.fast;
  static const revealScroll = Duration(milliseconds: 240);
  static const detailActionGap = 24.0;
}

abstract final class ChatDockPolishTokens {
  static const fadeAboveInput = 72.0;
  static const menuDuration = Duration(milliseconds: 240);
  static const menuRise = ChatSpace.x2;
  static ChatDockStyle of(BuildContext context) => ChatTheme.of(context).dock;
}
