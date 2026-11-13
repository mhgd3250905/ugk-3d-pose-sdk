import 'package:flutter/material.dart';

import 'trainer_theme.dart';

/// Player V1's dock. The player supplies the existing controls and owns their
/// callbacks and session state.
class TrainerPlayerV1Dock extends StatelessWidget {
  const TrainerPlayerV1Dock({
    super.key,
    required this.theme,
    required this.minHeight,
    required this.bottomInset,
    required this.countdown,
    required this.previous,
    required this.primary,
    required this.next,
    this.optionalControls,
    this.restFeedback,
  });

  final TrainerTheme theme;
  final double minHeight;
  final double bottomInset;
  final Widget countdown;
  final Widget previous;
  final Widget primary;
  final Widget next;
  final Widget? optionalControls;
  final Widget? restFeedback;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(minHeight: minHeight),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: theme.card.withValues(alpha: 1),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 8, 24, 16 + bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            ExcludeSemantics(
              child: SizedBox(
                key: const ValueKey('player-v1-dock-handle'),
                width: 40,
                height: 4,
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    color: theme.border,
                    shape: const StadiumBorder(),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (restFeedback case final feedback?) ...[
                      feedback,
                      const SizedBox(height: 12),
                      Divider(height: 1, thickness: 1, color: theme.border),
                      const SizedBox(height: 12),
                    ],
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 52),
                      child: Align(
                        alignment: Alignment.center,
                        heightFactor: 1,
                        child: countdown,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Center(
                      child: SizedBox(
                        width: 240,
                        child: OverflowBar(
                          alignment: MainAxisAlignment.spaceBetween,
                          overflowSpacing: 8,
                          children: [previous, primary, next],
                        ),
                      ),
                    ),
                    ?optionalControls,
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Standard rest feedback content for [TrainerPlayerV1Dock]. A host supplies
/// labels and actions through its existing rest feedback builder.
enum TrainerRestFeedbackChoice { comfortable, tight, pain }

/// A host supplies option labels, callbacks and the current selection.
class TrainerRestFeedbackPanel extends StatelessWidget {
  const TrainerRestFeedbackPanel({
    super.key,
    required this.theme,
    required this.title,
    required this.description,
    this.selected,
    this.comfortableLabel,
    this.onComfortable,
    this.tightLabel,
    this.onTight,
    this.painLabel,
    this.onPain,
  });

  final TrainerTheme theme;
  final String title;
  final String description;
  final TrainerRestFeedbackChoice? selected;
  final String? comfortableLabel;
  final VoidCallback? onComfortable;
  final String? tightLabel;
  final VoidCallback? onTight;
  final String? painLabel;
  final VoidCallback? onPain;

  @override
  Widget build(BuildContext context) {
    final options = [
      if (comfortableLabel case final label?)
        _option(
          TrainerRestFeedbackChoice.comfortable,
          label,
          theme.goodBg,
          theme.good,
          onComfortable,
        ),
      if (tightLabel case final label?)
        _option(
          TrainerRestFeedbackChoice.tight,
          label,
          theme.cautionBg,
          theme.caution,
          onTight,
        ),
      if (painLabel case final label?)
        _option(
          TrainerRestFeedbackChoice.pain,
          label,
          theme.dangerBg,
          theme.danger,
          onPain,
        ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.title.copyWith(
            fontSize: 17,
            height: 1.2,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          description,
          textAlign: TextAlign.center,
          style: theme.label.copyWith(
            color: theme.sub,
            fontSize: 12,
            height: 1.25,
          ),
        ),
        if (options.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              for (var i = 0; i < options.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: options[i]),
              ],
            ],
          ),
        ],
      ],
    );
  }

  Widget _option(
    TrainerRestFeedbackChoice choice,
    String label,
    Color background,
    Color foreground,
    VoidCallback? onPressed,
  ) => TrainerV1FeedbackButton(
    key: ValueKey('player-v1-rest-${choice.name}'),
    theme: theme,
    label: label,
    background: background,
    color: foreground,
    selected: selected == choice,
    onPressed: onPressed,
  );
}

/// Shared appearance for V1 rest and completion feedback.
class TrainerV1FeedbackButton extends StatelessWidget {
  const TrainerV1FeedbackButton({
    super.key,
    required this.theme,
    required this.label,
    required this.color,
    required this.background,
    required this.onPressed,
    this.selected = false,
  });

  final TrainerTheme theme;
  final String label;
  final Color color;
  final Color background;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final foreground = selected
        ? theme.isDark
              ? const Color(0xFF111214)
              : Colors.white
        : color;
    final duration = TrainerMotion.reduced(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    return Semantics(
      selected: selected,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 46),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(23)),
          ),
          side: BorderSide(
            color: color.withValues(alpha: theme.isDark ? .3 : .2),
          ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
          backgroundColor: selected ? color : background,
          disabledBackgroundColor: selected ? color : background,
          foregroundColor: foreground,
          disabledForegroundColor: foreground,
          animationDuration: duration,
          textStyle: theme.body.copyWith(
            fontSize: 15,
            height: 1.2,
            fontWeight: FontWeight.w600,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedSwitcher(
              duration: duration,
              child: selected
                  ? const Padding(
                      padding: EdgeInsetsDirectional.only(end: 4),
                      child: Icon(Icons.check_rounded, size: 14),
                    )
                  : const SizedBox.shrink(),
            ),
            Flexible(child: Text(label, textAlign: TextAlign.center)),
          ],
        ),
      ),
    );
  }
}
