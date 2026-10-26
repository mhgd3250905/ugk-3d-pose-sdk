import 'package:flutter/material.dart';

import 'trainer_theme.dart';

/// Three opaque levels: page background, panel and raised control.
enum TrainerSurfaceLevel { background, panel, control }

/// An opaque surface with a quiet one-pixel outline and fixed contact shadow.
/// Its decoration never samples content behind it or changes child layout.
class TrainerSurface extends StatelessWidget {
  const TrainerSurface({
    super.key,
    required this.theme,
    required this.child,
    this.level = TrainerSurfaceLevel.panel,
    this.radius,
    this.padding,
    this.width,
    this.height,
  });

  final TrainerTheme theme;
  final Widget child;
  final TrainerSurfaceLevel level;
  final double? radius;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: DecoratedBox(
      decoration: ShapeDecoration(
        color: (switch (level) {
          TrainerSurfaceLevel.background => theme.background,
          TrainerSurfaceLevel.panel => theme.surface,
          TrainerSurfaceLevel.control => theme.surfaceHigh,
        }).withValues(alpha: 1),
        shape: radius == null
            ? StadiumBorder(side: BorderSide(color: theme.border))
            : RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(radius!),
                side: BorderSide(color: theme.border),
              ),
        shadows: level == TrainerSurfaceLevel.background
            ? null
            : [
                BoxShadow(
                  color: theme.shadow,
                  offset: const Offset(0, 2),
                  blurRadius: 4,
                ),
              ],
      ),
      child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
    ),
  );
}

/// A solid circular control retaining pointer, keyboard and screen-reader
/// activation. Press feedback only scales its existing visual bounds.
class TrainerIconButton extends StatefulWidget {
  const TrainerIconButton({
    super.key,
    required this.theme,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 48,
    this.primary = false,
    this.iconColor,
  });

  final TrainerTheme theme;
  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final bool primary;
  final Color? iconColor;

  @override
  State<TrainerIconButton> createState() => _TrainerIconButtonState();
}

class _TrainerIconButtonState extends State<TrainerIconButton> {
  bool _down = false;
  bool _focused = false;

  void _set(bool value) {
    if (_down != value) setState(() => _down = value);
  }

  void _activate() => widget.onPressed?.call();

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final enabled = widget.onPressed != null;
    final foreground =
        widget.iconColor ??
        (enabled
            ? (widget.primary ? theme.onAccent : theme.text)
            : theme.faint);
    final face = IconTheme.merge(
      data: IconThemeData(color: foreground, size: widget.size * .46),
      child: Center(child: widget.icon),
    );
    final disc = widget.primary
        ? DecoratedBox(
            decoration: ShapeDecoration(
              color: (enabled ? theme.accent : theme.surfaceHigh).withValues(
                alpha: 1,
              ),
              shape: CircleBorder(side: BorderSide(color: theme.border)),
              shadows: [
                BoxShadow(
                  color: theme.shadow,
                  offset: const Offset(0, 2),
                  blurRadius: 4,
                ),
              ],
            ),
            child: face,
          )
        : TrainerSurface(
            theme: theme,
            level: TrainerSurfaceLevel.control,
            child: face,
          );
    return FocusableActionDetector(
      enabled: enabled,
      mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onShowFocusHighlight: (value) {
        if (_focused != value) setState(() => _focused = value);
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _activate();
            return null;
          },
        ),
        ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
          onInvoke: (_) {
            _activate();
            return null;
          },
        ),
      },
      child: Tooltip(
        message: widget.tooltip,
        decoration: ShapeDecoration(
          color: theme.surfaceHigh.withValues(alpha: 1),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: BorderSide(color: theme.border),
          ),
          shadows: [
            BoxShadow(
              color: theme.shadow,
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        textStyle: theme.label.copyWith(color: theme.text),
        child: Semantics(
          button: true,
          enabled: enabled,
          label: widget.tooltip,
          excludeSemantics: true,
          onTap: widget.onPressed,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: enabled ? (_) => _set(true) : null,
            onTapUp: enabled ? (_) => _set(false) : null,
            onTapCancel: enabled ? () => _set(false) : null,
            onTap: widget.onPressed,
            child: AnimatedScale(
              scale: _down && !TrainerMotion.reduced(context) ? .96 : 1,
              duration: _down
                  ? const Duration(milliseconds: 100)
                  : const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              child: SizedBox.square(
                dimension: widget.size,
                child: _focused
                    ? DecoratedBox(
                        key: const ValueKey('surface-button-focus'),
                        position: DecorationPosition.foreground,
                        decoration: ShapeDecoration(
                          shape: CircleBorder(
                            side: BorderSide(
                              color: theme.accentText,
                              width: 2.5,
                              strokeAlign: BorderSide.strokeAlignOutside,
                            ),
                          ),
                        ),
                        child: disc,
                      )
                    : disc,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
