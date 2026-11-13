import 'package:flutter/material.dart';

import '../result/session_result.dart' show DiscomfortAction;
import 'trainer_player.dart' show DiscomfortDecision;
import 'trainer_player_motion.dart';
import 'trainer_strings.dart';
import 'trainer_theme.dart';

Future<DiscomfortDecision?> showTrainerV1DiscomfortSheet({
  required BuildContext context,
  required TrainerTheme theme,
  required TrainerStrings strings,
}) => _showPlayerSheet<DiscomfortDecision>(
  context: context,
  theme: theme,
  title: strings.discomfortTitle,
  body: strings.discomfortBody,
  actions: (context) => [
    _sheetButton(
      theme: theme,
      key: const ValueKey('discomfort-skip'),
      label: strings.discomfortSkip,
      background: theme.ctrl,
      onPressed: () => Navigator.pop(
        context,
        const DiscomfortDecision(DiscomfortAction.skip),
      ),
    ),
    _sheetButton(
      theme: theme,
      key: const ValueKey('discomfort-end'),
      label: strings.discomfortEnd,
      background: theme.dangerBg,
      foreground: theme.danger,
      onPressed: () => Navigator.pop(
        context,
        const DiscomfortDecision(DiscomfortAction.end),
      ),
    ),
    _sheetButton(
      theme: theme,
      key: const ValueKey('discomfort-continueEasier'),
      label: strings.discomfortContinue,
      foreground: theme.accentText,
      onPressed: () => Navigator.pop(
        context,
        const DiscomfortDecision(DiscomfortAction.continueEasier),
      ),
    ),
  ],
);

Future<bool?> showTrainerV1ExitSheet({
  required BuildContext context,
  required TrainerTheme theme,
  required TrainerStrings strings,
  required int completed,
  required int total,
  required VoidCallback onConfirm,
}) => _showPlayerSheet<bool>(
  context: context,
  theme: theme,
  title: strings.closeSheetTitle,
  body: strings.closeSheetProgress(completed, total),
  actions: (context) => [
    _sheetButton(
      theme: theme,
      key: const ValueKey('close-cancel'),
      label: strings.closeCancel,
      background: theme.accent,
      foreground: theme.onAccent,
      onPressed: () => Navigator.pop(context, false),
    ),
    _sheetButton(
      theme: theme,
      key: const ValueKey('close-confirm'),
      label: strings.closeConfirm,
      border: theme.border,
      onPressed: () {
        onConfirm();
        if (context.mounted) Navigator.pop(context, true);
      },
    ),
  ],
);

Future<T?> _showPlayerSheet<T>({
  required BuildContext context,
  required TrainerTheme theme,
  required String title,
  required String body,
  required List<Widget> Function(BuildContext) actions,
}) {
  final reduced = TrainerMotion.reduced(context);
  final height = MediaQuery.sizeOf(context).height / 2;
  const shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
  );
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    enableDrag: !reduced,
    showDragHandle: false,
    barrierColor: Colors.black.withValues(alpha: .30),
    backgroundColor: Colors.transparent,
    elevation: 0,
    sheetAnimationStyle: reduced
        ? const AnimationStyle(
            duration: PlayerMotion.reducedFade,
            reverseDuration: PlayerMotion.reducedFade,
            curve: _AnchoredSheetCurve(),
            reverseCurve: _AnchoredSheetCurve(),
          )
        : const AnimationStyle(
            duration: PlayerMotion.slow,
            reverseDuration: PlayerMotion.medium,
            curve: PlayerMotion.enter,
            reverseCurve: FlippedCurve(PlayerMotion.exit),
          ),
    builder: (context) {
      final buttons = actions(context);
      final sheet = SizedBox(
        key: const ValueKey('player-v1-sheet'),
        width: double.infinity,
        height: height,
        child: Material(
          color: theme.card.withValues(alpha: 1),
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: theme.title.copyWith(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    body,
                    style: theme.body.copyWith(fontSize: 13, color: theme.sub),
                  ),
                  const SizedBox(height: 20),
                  for (var i = 0; i < buttons.length; i++) ...[
                    if (i > 0) const SizedBox(height: 12),
                    buttons[i],
                  ],
                ],
              ),
            ),
          ),
        ),
      );
      if (!reduced) return sheet;
      return FadeTransition(
        opacity: ModalRoute.of(context)!.animation!,
        child: sheet,
      );
    },
  );
}

Widget _sheetButton({
  required TrainerTheme theme,
  required Key key,
  required String label,
  required VoidCallback onPressed,
  Color? background,
  Color? foreground,
  Color? border,
}) => TextButton(
  key: key,
  onPressed: onPressed,
  style: TextButton.styleFrom(
    foregroundColor: foreground ?? theme.text,
    backgroundColor: background,
    side: border == null ? null : BorderSide(color: border),
    minimumSize: const Size(0, 52),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.standard,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    textStyle: theme.body.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
  ),
  child: Text(label, textAlign: TextAlign.center),
);

/// Keep the route at its final offset while its content fades. At t=0 both
/// the route and its sheet are fully transparent.
class _AnchoredSheetCurve extends Curve {
  const _AnchoredSheetCurve();

  @override
  double transformInternal(double t) => 1;
}
