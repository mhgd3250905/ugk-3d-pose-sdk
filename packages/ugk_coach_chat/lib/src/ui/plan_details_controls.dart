import 'package:flutter/material.dart';

import '../theme/chat_controls.dart';
import '../theme/chat_theme.dart';
import '../theme/chat_tokens.dart';
import 'chat_localization.dart';

class ChatDetailsTopBar extends StatelessWidget implements PreferredSizeWidget {
  const ChatDetailsTopBar({
    super.key,
    required this.title,
    this.caption,
    this.trailing,
    this.onBack,
  });
  final String title;
  final String? caption;
  final Widget? trailing;

  /// Defaults to popping the route.
  final VoidCallback? onBack;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final canPop = onBack != null || (ModalRoute.of(context)?.canPop ?? false);
    return ColoredBox(
      color: ChatTheme.of(context).colors.surfaceLow,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 64,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              ChatSpace.x3,
              0,
              ChatSpace.x4,
              0,
            ),
            child: Row(
              children: [
                if (canPop) ...[
                  ChatDetailsCircleButton(
                    key: const ValueKey('back'),
                    icon: ChatGlyph.back,
                    size: 40,
                    tooltip: chatCopy(context, '返回', 'Back'),
                    fill: Colors.transparent,
                    onPressed: onBack ?? () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: ChatSpace.x1),
                ] else
                  const SizedBox(width: ChatSpace.x2),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ChatType.of(
                          context,
                        ).title.copyWith(fontWeight: FontWeight.w800),
                      ),
                      if (caption != null)
                        Text(
                          caption!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ChatType.of(context).caption.copyWith(
                            color: ChatTheme.of(context).colors.muted,
                          ),
                        ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ChatDetailsCircleButton extends StatelessWidget {
  const ChatDetailsCircleButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.size = 44,
    this.tooltip,
    this.fill,
    this.iconColor,
    this.filled = true,
    this.haptic = ChatHaptic.none,
  });
  final ChatGlyph icon;
  final VoidCallback? onPressed;
  final double size;
  final String? tooltip;
  final Color? fill;
  final Color? iconColor;
  final bool filled;
  final ChatHaptic haptic;

  @override
  Widget build(BuildContext context) {
    final bg = fill ?? ChatTheme.of(context).colors.surfaceHigh;
    return ChatPressable(
      semanticLabel: tooltip,
      tooltip: tooltip,
      onTap: onPressed,
      haptic: haptic,
      scale: .92,
      child: Builder(
        builder: (context) {
          final down = ChatPressedScope.of(context);
          return AnimatedContainer(
            duration: down ? ChatMotion.press : ChatMotion.release,
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: down
                  ? Color.lerp(
                      bg,
                      ChatTheme.of(context).colors.isDark
                          ? Colors.white
                          : Colors.black,
                      .06,
                    )
                  : bg,
              shape: BoxShape.circle,
              border: ChatTheme.of(context).colors.isDark
                  ? (fill == null && onPressed != null
                        ? Border.fromBorderSide(
                            ChatTheme.of(context).colors.cardEdge,
                          )
                        : null)
                  : fill != null
                  ? null
                  : Border.all(color: ChatTheme.of(context).colors.line),
            ),
            alignment: Alignment.center,
            child: AnimatedSwitcher(
              duration: ChatMotion.fast,
              transitionBuilder: (child, a) => FadeTransition(
                opacity: a,
                child: ScaleTransition(
                  scale: Tween(begin: .7, end: 1.0).animate(a),
                  child: child,
                ),
              ),
              child: ChatIcon(
                icon,
                key: ValueKey(icon),
                size: size * (size > 50 ? .42 : .45),
                color: onPressed == null
                    ? ChatTheme.of(context).colors.faint
                    : (iconColor ?? ChatTheme.of(context).colors.text),
                filled: filled,
                strokeWidth: size > 50 ? 1.75 : 2,
              ),
            ),
          );
        },
      ),
    );
  }
}
