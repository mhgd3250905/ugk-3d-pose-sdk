import 'package:flutter/material.dart';

import 'models.dart';
import 'primitives.dart';
import 'theme.dart';

/// An admitted recommendation's IDs and explanation, resolved through the
/// host's trusted, currently localized catalogue. This presentation widget
/// owns no agent, network client, navigation or training state.
///
/// Use `ValidatedActions.items.map((item) => item.id)` and the delivery's text
/// (or their persisted equivalents) as [actionIds] and [note]. [library] uses
/// the same standing/first-frame assets as the host's action browser.
class CoachRecommendCard extends StatelessWidget {
  CoachRecommendCard({
    super.key,
    required List<String> actionIds,
    required this.note,
    required this.library,
    required this.onOpenAction,
    this.onPlanFromActions,
  }) : actionIds = List.unmodifiable(actionIds);

  final List<String> actionIds;
  final String note;
  final CoachExerciseLibrary library;
  final ValueChanged<String> onOpenAction;
  final ValueChanged<List<String>>? onPlanFromActions;

  @override
  Widget build(BuildContext context) {
    final style = CoachUiTheme.of(context);
    return CoachCardSurface(
      padding: const EdgeInsets.all(CoachSpace.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (note.isNotEmpty) ...[
            Text(
              note,
              style: style.typography.body.copyWith(color: style.colors.text),
            ),
            const SizedBox(height: CoachSpace.x4),
          ],
          LayoutBuilder(
            builder: (context, constraints) {
              final single = actionIds.length == 1;
              final columns = constraints.maxWidth < 260 ? 1 : 2;
              final tileWidth = single
                  ? constraints.maxWidth
                  : (constraints.maxWidth - CoachSpace.x3 * (columns - 1)) /
                        columns;
              return Wrap(
                spacing: CoachSpace.x3,
                runSpacing: CoachSpace.x3,
                children: [
                  for (final id in actionIds)
                    SizedBox(
                      key: ValueKey('recommend-action-$id'),
                      width: tileWidth,
                      child: _Action(
                        id: id,
                        exercise: library.tryGet(id),
                        horizontal: single,
                        onOpen: () => onOpenAction(id),
                      ),
                    ),
                ],
              );
            },
          ),
          if (onPlanFromActions != null && actionIds.isNotEmpty) ...[
            const SizedBox(height: CoachSpace.x4),
            CoachPressable(
              key: const ValueKey('recommend-plan-button'),
              onTap: () => onPlanFromActions!(actionIds),
              semanticLabel: style.strings.planFromActions,
              haptic: CoachHaptic.light,
              child: CoachControlFace(
                child: Center(
                  child: Text(
                    style.strings.planFromActions,
                    style: style.typography.callout.copyWith(
                      color: style.colors.accentText,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.id,
    required this.exercise,
    required this.horizontal,
    required this.onOpen,
  });

  final String id;
  final CoachExercise? exercise;
  final bool horizontal;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final style = CoachUiTheme.of(context);
    final e = exercise;
    final name = e?.name ?? style.strings.actionUnavailable;
    final text = Padding(
      padding: const EdgeInsets.all(CoachSpace.x3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: style.typography.callout.copyWith(color: style.colors.text),
          ),
          if (e?.levelLabel.isNotEmpty == true ||
              e?.equipmentLabel.isNotEmpty == true) ...[
            const SizedBox(height: CoachSpace.x1),
            Text(
              [
                if (e!.levelLabel.isNotEmpty) e.levelLabel,
                if (e.equipmentLabel.isNotEmpty) e.equipmentLabel,
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: style.typography.caption.copyWith(
                color: style.colors.muted,
              ),
            ),
          ],
        ],
      ),
    );
    final image = _Thumbnail(exercise: e);
    return CoachPressable(
      onTap: e == null ? null : onOpen,
      semanticLabel: name,
      haptic: CoachHaptic.selection,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: style.colors.surfaceRaised,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: style.colors.outline),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: horizontal
              ? Row(
                  children: [
                    SizedBox(width: 96, height: 112, child: image),
                    Expanded(child: text),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AspectRatio(aspectRatio: 1, child: image),
                    text,
                  ],
                ),
        ),
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.exercise});
  final CoachExercise? exercise;

  @override
  Widget build(BuildContext context) {
    final style = CoachUiTheme.of(context);
    final e = exercise;
    final asset = e?.stillCutout ?? e?.poster;
    final cutout = e?.stillCutout != null;
    Widget placeholder() => Center(
      child: Icon(
        Icons.fitness_center_outlined,
        size: 28,
        color: style.colors.faint,
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            style.colors.stage.mediaStage,
            Color.alphaBlend(
              style.colors.accent.withValues(alpha: .08),
              style.colors.surface,
            ),
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(CoachSpace.x2),
        child: e == null || asset == null || asset.isEmpty
            ? placeholder()
            : Builder(
                builder: (context) {
                  final request = CoachMediaRequest(
                    exercise: e,
                    asset: asset,
                    cutout: cutout,
                    still: true,
                    landing: false,
                    fit: BoxFit.contain,
                    alignment: Alignment.center,
                    semanticLabel: e.name,
                  );
                  return style.builders.media?.call(context, request) ??
                      Image.asset(
                        asset,
                        fit: request.fit,
                        alignment: request.alignment,
                        gaplessPlayback: true,
                        semanticLabel: request.semanticLabel,
                        frameBuilder: (_, child, frame, wasSync) =>
                            wasSync || frame != null
                            ? child
                            : const SizedBox.expand(),
                        errorBuilder: (_, _, _) => placeholder(),
                      );
                },
              ),
      ),
    );
  }
}
