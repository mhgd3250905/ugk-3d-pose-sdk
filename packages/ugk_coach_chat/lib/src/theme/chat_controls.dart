import 'package:flutter/material.dart';

import 'chat_theme.dart';
import 'chat_tokens.dart';

/// Whether the nearest [ChatPressable] is held down.
class ChatPressedScope extends InheritedWidget {
  const ChatPressedScope({
    super.key,
    required this.pressed,
    required super.child,
  });
  final bool pressed;
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatPressedScope>()?.pressed ??
      false;
  @override
  bool updateShouldNotify(ChatPressedScope old) => old.pressed != pressed;
}

class ChatPressable extends StatefulWidget {
  const ChatPressable({
    super.key,
    required this.child,
    required this.onTap,
    this.semanticLabel,
    this.tooltip,
    this.scale = ChatMotion.pressScale,
    this.haptic = ChatHaptic.none,
    this.toggled,
    this.selected,
    this.semanticHint,
    this.expanded,
  });
  final Widget child;
  final VoidCallback? onTap;

  /// Disclosure control: exposes expanded / collapsed (TalkBack state).
  final bool? expanded;
  final String? semanticLabel;

  /// Switch-like control: exposes the toggled state (TalkBack "on/off")
  /// instead of a plain button.
  final bool? toggled;

  /// Choice-like control: exposes the selected state.
  final bool? selected;

  /// Extra spoken explanation (e.g. a settings row's subtitle), read after
  /// the label; the excluded visual text is not announced twice.
  final String? semanticHint;
  final String? tooltip;
  final double scale;

  /// Played on a completed tap (not on press-down, not on cancel).
  final ChatHaptic haptic;

  @override
  State<ChatPressable> createState() => _ChatPressableState();
}

class _ChatPressableState extends State<ChatPressable> {
  bool _down = false;
  bool _showFocus = false;

  void _tap() {
    widget.haptic.play();
    widget.onTap?.call();
  }

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    Widget child = GestureDetector(
      behavior: HitTestBehavior.opaque,
      // The outer semantics node owns activation, including when the visual
      // child is excluded to keep an explicit button label from repeating.
      excludeFromSemantics: true,
      onTapDown: enabled ? (_) => _set(true) : null,
      onTapUp: enabled ? (_) => _set(false) : null,
      onTapCancel: enabled ? () => _set(false) : null,
      onTap: enabled ? _tap : null,
      child: AnimatedScale(
        scale: _down && !still ? widget.scale : 1,
        duration: _down ? ChatMotion.press : ChatMotion.release,
        curve: _down ? Curves.easeOut : Curves.easeOutCubic,
        child: ChatPressedScope(
          pressed: _down,
          child: widget.semanticLabel == null
              ? widget.child
              : ExcludeSemantics(child: widget.child),
        ),
      ),
    );
    child = FocusableActionDetector(
      enabled: enabled,
      mouseCursor: enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onShowFocusHighlight: (value) {
        if (_showFocus != value) setState(() => _showFocus = value);
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            if (enabled) _tap();
            return null;
          },
        ),
        ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
          onInvoke: (_) {
            if (enabled) _tap();
            return null;
          },
        ),
      },
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(ChatRadius.sm),
          border: _showFocus
              ? Border.all(
                  color: ChatTheme.of(context).colors.accentText,
                  width: 2,
                )
              : null,
        ),
        child: child,
      ),
    );
    child = Semantics(
      // Keep surrounding message text out of this button's accessible name.
      // Wrap focus as well, so focus and activation belong to one node.
      container: true,
      button: widget.toggled == null,
      toggled: widget.toggled,
      selected: widget.selected,
      expanded: widget.expanded,
      enabled: enabled,
      label: widget.semanticLabel,
      hint: widget.semanticHint,
      onTap: enabled ? _tap : null,
      child: child,
    );
    if (widget.tooltip != null) {
      child = Tooltip(
        message: widget.tooltip!,
        excludeFromSemantics: widget.semanticLabel != null,
        child: child,
      );
    }
    return child;
  }
}

/// An opaque control face. Press feedback changes its solid tone; the
/// surrounding pressable owns scale, semantics and activation.
class ChatSolidControlFace extends StatelessWidget {
  const ChatSolidControlFace({
    super.key,
    required this.child,
    this.radius,
    this.padding = const EdgeInsets.symmetric(horizontal: 14),
    this.minHeight = 40,
    this.circle = false,
  });
  final Widget child;
  final double? radius;
  final EdgeInsetsGeometry padding;
  final double minHeight;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final down = ChatPressedScope.of(context);
    final side = ChatTheme.of(context).colors.cardEdge;
    final ShapeBorder shape = circle
        ? CircleBorder(side: side)
        : radius == null
        ? StadiumBorder(side: side)
        : RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius!),
            side: side,
          );
    return Container(
      key: const ValueKey('sf-solid-control-face'),
      constraints: BoxConstraints(
        minHeight: minHeight,
        minWidth: circle ? minHeight : 0,
      ),
      padding: padding,
      alignment: circle ? Alignment.center : null,
      decoration: ShapeDecoration(
        shape: shape,
        color: down
            ? ChatTheme.of(context).colors.surface
            : ChatTheme.of(context).colors.surfaceHigh,
      ),
      child: child,
    );
  }
}

/// Tertiary action: icon + text, no container; 44 pt tall hit area.
class ChatTextAction extends StatelessWidget {
  const ChatTextAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.iconFilled = false,
    this.color,
    this.boxed = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final ChatGlyph? icon;
  final bool iconFilled;
  final Color? color;

  /// Adds a solid capsule in the dark theme while the action is tappable.
  final bool boxed;

  @override
  Widget build(BuildContext context) {
    final fg = onPressed == null
        ? ChatTheme.of(context).colors.faint
        : (color ?? ChatTheme.of(context).colors.muted);
    final pill =
        boxed && ChatTheme.of(context).colors.isDark && onPressed != null;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          ChatIcon(icon!, size: 18, filled: iconFilled, color: fg),
          const SizedBox(width: 6),
        ],
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            height: 1.2,
            color: fg,
          ),
        ),
      ],
    );
    return ChatPressable(
      semanticLabel: label,
      onTap: onPressed,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: ChatSpace.x1),
          child: pill
              ? Center(
                  widthFactor: 1,
                  child: ChatSolidControlFace(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: row,
                  ),
                )
              : row,
        ),
      ),
    );
  }
}
