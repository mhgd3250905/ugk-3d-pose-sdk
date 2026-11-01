import 'package:flutter/material.dart';

import 'chat_polish_tokens.dart';
import 'chat_theme.dart';
import 'chat_tokens.dart';
import 'chat_controls.dart';

/// The one card surface for this UI batch. Media draws on its transparent child.
class ChatPolishCard extends StatelessWidget {
  const ChatPolishCard({
    super.key,
    required this.child,
    this.padding = ChatCardTokens.padding,
    this.width,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double? width;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(ChatCardTokens.radius),
    child: Container(
      width: width,
      padding: padding,
      decoration: BoxDecoration(color: ChatTheme.of(context).cardFill),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ChatCardTokens.radius),
        border: Border.all(
          color: ChatTheme.of(context).cardEdge,
          width: ChatCardTokens.edgeWidth,
        ),
      ),
      child: child,
    ),
  );
}

/// Both plan states use the same face; the SDK owns its placement.
class ChatPlanToggleButton extends StatelessWidget {
  const ChatPlanToggleButton({
    super.key,
    required this.expanded,
    required this.onPressed,
    this.semanticLabel,
    this.tooltip,
    this.haptic = ChatHaptic.selection,
  });

  final bool expanded;
  final VoidCallback? onPressed;
  final String? semanticLabel;
  final String? tooltip;
  final ChatHaptic haptic;

  @override
  Widget build(BuildContext context) => ChatPressable(
    semanticLabel: semanticLabel ?? (expanded ? '收起详情' : '展开详情'),
    tooltip: tooltip,
    expanded: expanded,
    onTap: onPressed,
    haptic: haptic,
    child: Align(
      widthFactor: 1,
      heightFactor: 1,
      child: SizedBox(
        height: ChatPlanPolishTokens.toggleHeight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: ChatTheme.of(context).colors.surfaceHigh,
            borderRadius: BorderRadius.circular(
              ChatPlanPolishTokens.toggleRadius,
            ),
          ),
          child: Padding(
            padding: ChatPlanPolishTokens.togglePadding,
            child: Center(
              widthFactor: 1,
              child: Text(
                expanded ? '收起' : '展开',
                style: ChatType.of(context).label.copyWith(fontSize: 13),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
