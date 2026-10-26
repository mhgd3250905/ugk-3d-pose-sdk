import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme.dart';

enum CoachGlyph { bookmark, chevronRight, play, stop }

enum CoachHaptic { none, selection, light, medium }

abstract final class CoachSpace {
  static const x1 = 4.0, x2 = 8.0, x3 = 12.0, x4 = 16.0, x6 = 24.0;
}

abstract final class CoachRadius {
  static const xs = 8.0, sm = 12.0, lg = 22.0, tail = 8.0;
}

abstract final class CoachMotion {
  static const fast = Duration(milliseconds: 180);
  static const medium = Duration(milliseconds: 280);
  static const appear = Duration(milliseconds: 360);
  static const replyStagger = Duration(milliseconds: 120);
  static const standard = Curves.easeOutCubic;
  static const enter = Cubic(0.2, 0.0, 0.0, 1.0);
  static const spring = Cubic(0.32, 1.28, 0.52, 1.0);
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

class CoachPressable extends StatelessWidget {
  const CoachPressable({
    super.key,
    required this.child,
    required this.onTap,
    this.semanticLabel,
    this.tooltip,
    this.scale = .97,
    this.haptic = CoachHaptic.none,
    this.expanded,
  });
  final Widget child;
  final VoidCallback? onTap;
  final String? semanticLabel, tooltip;
  final double scale;
  final CoachHaptic haptic;
  final bool? expanded;
  @override
  Widget build(BuildContext context) {
    final style = CoachUiTheme.of(context);
    final custom = style.builders.pressable;
    if (custom != null) return custom(context, this);
    Widget result = Semantics(
      button: true,
      enabled: onTap != null,
      label: semanticLabel,
      expanded: expanded,
      child: TextButton(
        onPressed: onTap == null
            ? null
            : () {
                switch (haptic) {
                  case CoachHaptic.none:
                    break;
                  case CoachHaptic.selection:
                    HapticFeedback.selectionClick();
                  case CoachHaptic.light:
                    HapticFeedback.lightImpact();
                  case CoachHaptic.medium:
                    HapticFeedback.mediumImpact();
                }
                onTap!();
              },
        style: TextButton.styleFrom(
          foregroundColor: style.colors.text,
          disabledForegroundColor: style.colors.faint,
          overlayColor: style.colors.surfaceRaised,
          splashFactory: NoSplash.splashFactory,
          padding: EdgeInsets.zero,
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: child,
      ),
    );
    if (tooltip != null) result = Tooltip(message: tooltip!, child: result);
    return result;
  }
}

class CoachControlFace extends StatelessWidget {
  const CoachControlFace({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 14),
    this.minHeight = 44,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double minHeight;
  @override
  Widget build(BuildContext context) {
    final style = CoachUiTheme.of(context);
    if (style.builders.controlFace case final builder?) {
      return builder(context, this);
    }
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: style.colors.surfaceRaised.withValues(alpha: 1),
          shape: StadiumBorder(side: BorderSide(color: style.colors.outline)),
          shadows: [
            BoxShadow(
              color: style.colors.shadow,
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class CoachTextAction extends StatelessWidget {
  const CoachTextAction({
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
  final CoachGlyph? icon;
  final bool iconFilled, boxed;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final style = CoachUiTheme.of(context);
    if (style.builders.textAction case final builder?) {
      return builder(context, this);
    }
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: color ?? style.colors.accentText,
        disabledForegroundColor: style.colors.faint,
        overlayColor: style.colors.surfaceRaised,
        splashFactory: NoSplash.splashFactory,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            CoachIcon(icon!, color: color ?? style.colors.accentText),
          Text(
            label,
            style: style.typography.callout.copyWith(
              color: onPressed == null
                  ? style.colors.faint
                  : color ?? style.colors.accentText,
            ),
          ),
        ],
      ),
    );
  }
}

class CoachCardSurface extends StatelessWidget {
  const CoachCardSurface({
    super.key,
    required this.child,
    this.radius = 22,
    this.padding,
    this.width,
  });
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final double? width;
  @override
  Widget build(BuildContext context) {
    final style = CoachUiTheme.of(context);
    if (style.builders.surface case final builder?) {
      return builder(context, this);
    }
    return SizedBox(
      width: width,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: style.colors.surface.withValues(alpha: 1),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: style.colors.outline),
          boxShadow: [
            BoxShadow(
              color: style.colors.shadow,
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
      ),
    );
  }
}

class CoachIcon extends StatelessWidget {
  const CoachIcon(
    this.glyph, {
    super.key,
    this.size = 18,
    this.color,
    this.filled = false,
    this.strokeWidth = 2,
  });
  final CoachGlyph glyph;
  final double size, strokeWidth;
  final Color? color;
  final bool filled;
  @override
  Widget build(BuildContext context) {
    final style = CoachUiTheme.of(context);
    if (style.builders.icon case final builder?) return builder(context, this);
    return Icon(
      switch (glyph) {
        CoachGlyph.bookmark => filled ? Icons.bookmark : Icons.bookmark_border,
        CoachGlyph.chevronRight => Icons.chevron_right,
        CoachGlyph.play => Icons.play_arrow,
        CoachGlyph.stop => Icons.stop,
      },
      size: size,
      color: color ?? style.colors.text,
    );
  }
}

class CoachStartButton extends StatelessWidget {
  const CoachStartButton({super.key, required this.onTap});
  final VoidCallback onTap;
  static const size = 48.0;
  static const reserve = size + CoachSpace.x2;
  @override
  Widget build(BuildContext context) {
    final style = CoachUiTheme.of(context);
    if (style.builders.startButton case final builder?) {
      return builder(context, this);
    }
    return CoachPressable(
      semanticLabel: style.strings.start,
      tooltip: style.strings.start,
      onTap: onTap,
      haptic: CoachHaptic.medium,
      child: SizedBox(
        width: size,
        height: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: style.colors.emphasis.withValues(alpha: 1),
            border: Border.all(color: style.colors.outline),
            boxShadow: [
              BoxShadow(
                color: style.colors.shadow,
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: CoachIcon(
            CoachGlyph.play,
            filled: true,
            color: style.colors.onEmphasis,
          ),
        ),
      ),
    );
  }
}

class CoachAppear extends StatefulWidget {
  const CoachAppear({
    super.key,
    required this.animate,
    required this.child,
    this.delay = Duration.zero,
    this.anchor = Alignment.bottomLeft,
    this.rise = 10,
    this.shift = 0,
    this.duration = CoachMotion.appear,
    this.scaleFrom = .98,
    this.curve = CoachMotion.standard,
  });
  final bool animate;
  final Duration delay, duration;
  final Widget child;
  final Alignment anchor;
  final double rise, shift, scaleFrom;
  final Curve curve;
  @override
  State<CoachAppear> createState() => _CoachAppearState();
}

class _CoachAppearState extends State<CoachAppear>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);
  Animation<double> _t = kAlwaysCompleteAnimation;
  bool _still = false, _begun = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_begun) return;
    _begun = true;
    _still = CoachMotion.reduced(context);
    if (!widget.animate) {
      _c.value = 1;
      return;
    }
    final run = _still ? const Duration(milliseconds: 200) : widget.duration;
    final total = widget.delay + run;
    if (total == Duration.zero) {
      _c.value = 1;
      return;
    }
    _c.duration = total;
    _t = CurvedAnimation(
      parent: _c,
      curve: Interval(
        widget.delay.inMicroseconds / total.inMicroseconds,
        1,
        curve: _still ? Curves.easeOut : widget.curve,
      ),
    );
    _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _t,
    child: widget.child,
    builder: (_, child) {
      final v = _t.value;
      if (identical(_t, kAlwaysCompleteAnimation) || _c.isCompleted) {
        return child!;
      }
      final o = v.clamp(0.0, 1.0);
      if (_still) return Opacity(opacity: o, child: child);
      return Opacity(
        opacity: o,
        child: Transform.translate(
          offset: Offset(widget.shift * (1 - v), widget.rise * (1 - v)),
          child: Transform.scale(
            scale: widget.scaleFrom + (1 - widget.scaleFrom) * v,
            alignment: widget.anchor,
            child: child,
          ),
        ),
      );
    },
  );
}
