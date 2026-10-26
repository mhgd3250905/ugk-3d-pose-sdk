import 'package:flutter/material.dart';
import 'models.dart';
import 'theme.dart';
import 'primitives.dart';

typedef CoachOptionBuilder =
    Widget Function(
      String messageId,
      int index,
      String label,
      bool chosen,
      bool dimmed,
      bool enabled,
      VoidCallback onTap,
    );

/// Bubble shape: round corners, a small one on the speaker's side.
BorderRadius bubbleRadius({required bool user}) => BorderRadius.only(
  topLeft: const Radius.circular(CoachRadius.lg),
  topRight: const Radius.circular(CoachRadius.lg),
  bottomLeft: Radius.circular(user ? CoachRadius.lg : CoachRadius.tail),
  bottomRight: Radius.circular(user ? CoachRadius.tail : CoachRadius.lg),
);

/// A plain text bubble is content, not a control: flat at z = 0 — a solid
/// fill, no glass, no shadow, no rim. The user's line is mint-tinted, the
/// assistant's teal-tinted; only interactive parts (cards, chips, the
/// input bar) are raised liquid glass.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.user, required this.child, this.padding});
  final bool user;
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: user
          ? CoachUiTheme.of(context).colors.userBubble
          : CoachUiTheme.of(context).colors.assistantBubble,
      borderRadius: bubbleRadius(user: user),
    ),
    child: Padding(
      padding:
          padding ??
          const EdgeInsets.fromLTRB(CoachSpace.x4, 10, CoachSpace.x4, 11),
      child: child,
    ),
  );
}

class CoachMessageBubble extends StatelessWidget {
  const CoachMessageBubble({
    super.key,
    required this.message,
    required this.optionsActive,
    required this.onOption,
    this.optionBuilder,
  });

  final CoachBubbleData message;
  final bool optionsActive;
  final void Function(int index) onOption;
  final CoachOptionBuilder? optionBuilder;

  @override
  Widget build(BuildContext context) {
    final user = message.isUser;
    final maxW = MediaQuery.sizeOf(context).width * (user ? .78 : .86);
    final bubble = _Bubble(
      user: user,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (message.caption case final caption?) ...[
            Text(
              caption,
              style: CoachUiTheme.of(context).typography.caption.copyWith(
                color: CoachUiTheme.of(context).colors.muted,
                letterSpacing: .6,
                fontFeatures: CoachUiTypography.tabular,
              ),
            ),
            const SizedBox(height: 2),
          ],
          if (message.text.isNotEmpty)
            Text(message.text, style: CoachUiTheme.of(context).typography.body),
          if (message.options.isNotEmpty) ...[
            const SizedBox(height: CoachSpace.x3),
            Wrap(
              spacing: CoachSpace.x2,
              runSpacing: CoachSpace.x2,
              children: [
                for (var i = 0; i < message.options.length; i++)
                  optionBuilder?.call(
                        message.id,
                        i,
                        message.options[i],
                        message.chosen == i,
                        message.chosen != null && message.chosen != i,
                        optionsActive,
                        () => onOption(i),
                      ) ??
                      CoachOptionPill(
                        key: ValueKey('option-${message.id}-$i'),
                        label: message.options[i],
                        chosen: message.chosen == i,
                        dimmed: message.chosen != null && message.chosen != i,
                        enabled: optionsActive,
                        onTap: () => onOption(i),
                      ),
              ],
            ),
            const SizedBox(height: 3),
          ],
        ],
      ),
    );
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW),
        child: bubble,
      ),
    );
  }
}

/// A choice inside an assistant bubble. Chosen: accent tint + accent text
/// (the selected segment); once answered the others go faint.
class CoachOptionPill extends StatelessWidget {
  const CoachOptionPill({
    super.key,
    required this.label,
    required this.onTap,
    this.chosen = false,
    this.dimmed = false,
    this.enabled = true,
  });

  final String label;
  final VoidCallback onTap;
  final bool chosen;
  final bool dimmed;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final fg = chosen
        ? CoachUiTheme.of(context).colors.accentText
        : dimmed
        ? CoachUiTheme.of(context).colors.faint
        : CoachUiTheme.of(context).colors.text;
    final bg = chosen
        ? CoachUiTheme.of(context).colors.accentSoft
        : CoachUiTheme.of(context).colors.isDark
        ? CoachUiTheme.of(context).colors.thumb
        : CoachUiTheme.of(context).colors.surface;
    // Dark (round 5): an open choice reads as a button — glass fill + rim.
    final idle =
        CoachUiTheme.of(context).colors.isDark && enabled && !chosen && !dimmed;
    return CoachPressable(
      semanticLabel: label,
      onTap: enabled ? onTap : null,
      haptic: CoachHaptic.selection,
      child: idle
          ? CoachControlFace(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 14,
                  height: 1.35,
                  fontWeight: FontWeight.w500,
                ),
              ),
            )
          : AnimatedContainer(
              duration: CoachMotion.medium,
              constraints: const BoxConstraints(minHeight: 36),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: ShapeDecoration(
                color: bg,
                shape: const StadiumBorder(),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 14,
                  height: 1.35,
                  fontWeight: chosen ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
    );
  }
}

/// The opening line without a bubble (§2.1): a greeting in large type
/// floating in the sky, the invitation under it in muted body text. It is
/// still a message: later ones push it up.
class CoachGreetingBlock extends StatelessWidget {
  const CoachGreetingBlock({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final i = text.indexOf('\n');
    final head = i < 0 ? text : text.substring(0, i);
    final rest = i < 0 ? '' : text.substring(i + 1);
    return Padding(
      key: const ValueKey('greeting'),
      padding: const EdgeInsets.fromLTRB(
        CoachSpace.x2,
        CoachSpace.x6,
        CoachSpace.x2,
        CoachSpace.x1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(head, style: CoachUiTheme.of(context).typography.greeting),
          if (rest.isNotEmpty) ...[
            const SizedBox(height: CoachSpace.x1),
            Text(
              rest,
              style: CoachUiTheme.of(context).typography.body.copyWith(
                color: CoachUiTheme.of(context).colors.muted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A localized time label between sittings.
class CoachTimeMark extends StatelessWidget {
  const CoachTimeMark(this.at, {super.key, required this.now});
  final DateTime at;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final label = CoachUiTheme.of(context).strings.timeLabel(at, now);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: CoachSpace.x3),
      child: Center(
        child: Text(
          label,
          style: CoachUiTheme.of(
            context,
          ).typography.caption.copyWith(letterSpacing: .4),
        ),
      ),
    );
  }
}

/// Three soft dots while the assistant "thinks".
class CoachTypingBubble extends StatefulWidget {
  const CoachTypingBubble({super.key, this.onCancel, this.progressLabel});
  final VoidCallback? onCancel;
  final String? progressLabel;
  @override
  State<CoachTypingBubble> createState() => _CoachTypingBubbleState();
}

class _CoachTypingBubbleState extends State<CoachTypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) {
      _c.stop();
      _c.value = .5;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: _Bubble(
      user: false,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 17),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _c,
            builder: (_, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  SizedBox.square(
                    dimension: 6,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: CoachUiTheme.of(context).colors.muted.withValues(
                          alpha:
                              CoachUiTheme.of(context).colors.muted.a *
                              (.3 + .7 * _pulse((_c.value - i * .18) % 1)),
                        ),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (widget.onCancel != null) ...[
            const SizedBox(height: CoachSpace.x3),
            Text(
              widget.progressLabel ??
                  CoachUiTheme.of(context).strings.preparing,
              style: CoachUiTheme.of(context).typography.body,
            ),
            const SizedBox(height: CoachSpace.x1),
            Text(
              CoachUiTheme.of(context).strings.progressHint,
              style: CoachUiTheme.of(context).typography.caption,
            ),
            CoachTextAction(
              key: const ValueKey('chat-cancel'),
              label: CoachUiTheme.of(context).strings.cancel,
              icon: CoachGlyph.stop,
              onPressed: widget.onCancel,
            ),
          ],
        ],
      ),
    ),
  );

  static double _pulse(double t) => t < .5 ? t * 2 : (1 - t) * 2;
}
