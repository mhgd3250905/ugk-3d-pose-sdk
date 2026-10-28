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
      padding: const EdgeInsets.all(CoachSpace.x3),
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
              final tileWidth = (constraints.maxWidth - CoachSpace.x3) / 2;
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
    required this.onOpen,
  });

  final String id;
  final CoachExercise? exercise;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final style = CoachUiTheme.of(context);
    final e = exercise;
    final name = e?.name ?? style.strings.actionUnavailable;
    final scaler = MediaQuery.textScalerOf(context);
    final titleStyle = style.typography.callout.copyWith(
      color: style.colors.text,
      fontSize: 15,
      fontWeight: FontWeight.w600,
      height: 1.35,
    );
    final tagStyle = style.typography.caption.copyWith(
      color: style.colors.muted,
      fontSize: 12,
      height: 1.35,
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          key: ValueKey('recommend-title-slot-$id'),
          height: scaler.scale(15) * 1.35 * 2,
          child: Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          ),
        ),
        const SizedBox(height: CoachSpace.x1),
        SizedBox(
          key: ValueKey('recommend-tags-$id'),
          height: scaler.scale(12) * 1.35,
          child: Text(
            [
              if (e?.levelLabel.isNotEmpty == true) e!.levelLabel,
              if (e?.equipmentLabel.isNotEmpty == true) e!.equipmentLabel,
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tagStyle,
          ),
        ),
      ],
    );
    final image = _Thumbnail(exercise: e);
    return CoachPressable(
      onTap: e == null ? null : onOpen,
      semanticLabel: name,
      haptic: CoachHaptic.selection,
      child: DecoratedBox(
        key: ValueKey('recommend-surface-$id'),
        decoration: BoxDecoration(
          color: style.colors.cardSurface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: style.colors.cardBorder),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(CoachSpace.x3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                AspectRatio(
                  key: ValueKey('recommend-image-area-$id'),
                  aspectRatio: 1,
                  child: image,
                ),
                const SizedBox(height: CoachSpace.x3),
                text,
              ],
            ),
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
    return e == null || asset == null || asset.isEmpty
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
          );
  }
}
