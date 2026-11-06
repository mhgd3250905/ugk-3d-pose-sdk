import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../media/training_action_media.dart';
import '../media/training_media_policy.dart';
import '../pose_hub/pose_hub_action_browser.dart';
import '../ui/trainer_experience.dart';
import '../ui/trainer_player.dart';
import '../ui/trainer_poster.dart';
import '../ui/trainer_theme.dart';
import 'training_library_browser.dart';
import 'training_library_config.dart';
import 'training_library_filter.dart';
import 'training_library_icons.dart';
import 'training_library_style.dart';

/// SF's shared browser, using the product's canonical Coach allowlist and the
/// public frame-zero posters. Merely browsing never requests a video.
class TrainingLibraryPage extends StatelessWidget {
  const TrainingLibraryPage({
    super.key,
    required this.config,
    required this.mediaPolicy,
    this.theme,
    this.onStart,
    this.canStart,
    this.experience,
    this.embedded = false,
    this.initialFilter = const TrainingLibraryFilter(),
    this.initialMuscle,
  });
  final TrainingLibraryConfig config;
  final TrainingMediaPolicy mediaPolicy;
  final TrainerTheme? theme;
  final Future<void> Function(String actionId)? onStart;
  final bool Function(String actionId)? canStart;
  final TrainerExperienceConfig? experience;
  final bool embedded;

  /// Selection the page opens with, e.g. from a muscle or body-part detail
  /// (`TrainingLibraryFilter(bodyPart: '核心')`). Default: no filter.
  final TrainingLibraryFilter initialFilter;

  /// Shorthand for `initialFilter.copyWith(muscle: …)` with a catalogue
  /// muscle-group id such as `glute-max`; wins over [initialFilter.muscle].
  final String? initialMuscle;

  @override
  Widget build(BuildContext context) => TrainingLibraryBrowser(
    actions: mediaPolicy.catalog.semanticCompleteActions,
    initialFilter: initialMuscle == null
        ? initialFilter
        : initialFilter.copyWith(muscle: initialMuscle),
    theme: theme,
    config: config,
    embedded: embedded,
    actionArtwork: (_, action, theme) => TrainingLibraryActionArt(
      actionId: action.id,
      config: config,
      mediaPolicy: mediaPolicy,
      theme: theme,
    ),
    onOpenAction: (action) => unawaited(
      TrainingLibraryDetails.open(
        context,
        actionId: action.id,
        config: config,
        mediaPolicy: mediaPolicy,
        theme: theme,
        onStart: onStart,
        canStart: canStart,
        experience: experience,
      ),
    ),
  );
}

/// Public, scoped action artwork shared by lists, details and self-test entries.
/// [playing] is false by default, including off-line and first entry.
class TrainingLibraryActionArt extends StatelessWidget {
  const TrainingLibraryActionArt({
    super.key,
    required this.actionId,
    required this.config,
    required this.mediaPolicy,
    this.theme,
    this.playing = false,
    this.mirrored = false,
  });
  final String actionId;
  final TrainingLibraryConfig config;
  final TrainingMediaPolicy mediaPolicy;
  final TrainerTheme? theme;
  final bool playing, mirrored;

  @override
  Widget build(BuildContext context) {
    final resolved = _themeOf(context, theme);
    if (!config.allowedActionIds.contains(actionId) ||
        mediaPolicy.actionFor(actionId) == null) {
      return Center(
        child: Text(config.strings.unavailable, style: resolved.label),
      );
    }
    return TrainingActionMedia(
      key: ValueKey('library-public-art-$actionId'),
      actionId: actionId,
      policy: mediaPolicy,
      playing: playing,
      mirrored: mirrored,
      radius: resolved.radius,
      stage: resolved.mediaStage,
    );
  }
}

abstract final class TrainingLibraryDetails {
  /// Shared poster-first detail sheet. Host start callbacks retain their dose,
  /// safety and saving rules; without one, the SDK launches single practice.
  static Future<void> open(
    BuildContext context, {
    required String actionId,
    required TrainingLibraryConfig config,
    required TrainingMediaPolicy mediaPolicy,
    TrainerTheme? theme,
    Future<void> Function(String actionId)? onStart,
    bool Function(String actionId)? canStart,
    TrainerExperienceConfig? experience,
  }) async {
    final action = config
        .actions(mediaPolicy.catalog)
        .where((action) => action.id == actionId)
        .firstOrNull;
    if (action == null) return;
    final resolved = _themeOf(context, theme);
    final bundle = DefaultAssetBundle.of(context);
    final poster = mediaPolicy.posterAssetFor(actionId);
    if (poster != null) {
      await TrainingPosterImages.prepareAsset(
        context,
        poster,
        timeout:
            (experience ?? const TrainerExperienceConfig()).posterWarmupTimeout,
      );
      if (!context.mounted) return;
    }
    final start = await showModalBottomSheet<bool>(
      context: context,
      routeSettings: RouteSettings(name: 'training_library_detail/$actionId'),
      isScrollControlled: true,
      backgroundColor: resolved.surface,
      sheetAnimationStyle: TrainingLibraryStyle.sheetAnimation,
      shape: TrainingLibraryStyle.sheetShape,
      showDragHandle: true,
      builder: (_) => DefaultAssetBundle(
        bundle: bundle,
        child: TrainingLibraryDetail(
          action: action,
          config: config,
          mediaPolicy: mediaPolicy,
          theme: resolved,
          canStart: canStart?.call(actionId) ?? true,
        ),
      ),
    );
    if (start != true || !context.mounted) return;
    if (onStart != null) {
      await onStart(actionId);
      return;
    }
    await TrainerLauncher.open<void>(
      context,
      firstPosterAsset: mediaPolicy.posterAssetFor(actionId),
      planActionIds: [actionId],
      mediaPolicy: mediaPolicy,
      experience: experience,
      theme: resolved,
      builder: (_) => PoseHubSinglePracticePage(
        action: action,
        mediaBaseUri: mediaPolicy.repository.mediaBaseUri,
        theme: resolved,
        startMode: TrainerStartMode.training,
      ),
    );
  }
}

/// SF detail content: one square poster, tap-to-play, descriptive metadata and
/// separate cue/caution rows. The UI never starts downloads on mount.
class TrainingLibraryDetail extends StatefulWidget {
  const TrainingLibraryDetail({
    super.key,
    required this.action,
    required this.config,
    required this.mediaPolicy,
    this.theme,
    this.canStart = true,
  });
  final PoseHubPackAction action;
  final TrainingLibraryConfig config;
  final TrainingMediaPolicy mediaPolicy;
  final TrainerTheme? theme;
  final bool canStart;
  @override
  State<TrainingLibraryDetail> createState() => _TrainingLibraryDetailState();
}

class _TrainingLibraryDetailState extends State<TrainingLibraryDetail> {
  bool _playing = false;

  @override
  Widget build(BuildContext context) {
    final action = widget.action;
    final theme = _themeOf(context, widget.theme);
    final strings = widget.config.strings;
    final display = widget.config.displayText?.call(action.id);
    final name = display?.name ?? action.nameZh;
    final equipment = PoseHubActionFacets.equipment(action);
    final cues =
        display?.cues ??
        (action.raw['cues'] as Map?)?['zh'] as List? ??
        const [];
    final cautions =
        display?.cautions ??
        [
          ...(action.raw['cautions'] as List?)?.whereType<String>() ?? const [],
          ...(action.raw['contraindications'] as List?)?.whereType<String>() ??
              const [],
        ];
    final muscles =
        display?.muscles ??
        action.raw['muscleGroupsZh'] as String? ??
        ((action.raw['muscleGroups'] as List?)
                ?.whereType<String>()
                .map((id) => poseHubMuscleLabels[id] ?? id)
                .join('、') ??
            '');
    return SafeArea(
      child: SingleChildScrollView(
        key: ValueKey('library-detail-${action.id}'),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              key: const ValueKey('library-detail-play'),
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _playing = !_playing),
              child: Semantics(
                button: true,
                label:
                    '${_playing ? strings.pause : strings.play}${display?.name == null ? '' : ' '}$name',
                child: TrainingLibraryActionArt(
                  actionId: action.id,
                  config: widget.config,
                  mediaPolicy: widget.mediaPolicy,
                  theme: theme,
                  playing: _playing,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(name, style: TrainingLibraryStyle.detailTitle(theme)),
            const SizedBox(height: 4),
            Text(
              display?.metadata ??
                  [
                    _categoryLabel(action.raw['category'] as String?),
                    switch (action.raw['level']) {
                      1 => '入门',
                      2 => '基础',
                      _ => '进阶',
                    },
                    equipment.isEmpty
                        ? '徒手'
                        : equipment
                              .map((id) => poseHubEquipmentLabels[id] ?? '其他器械')
                              .join('/'),
                    if (action.raw['unilateral'] == true) '左右各做',
                  ].join(' · '),
              style: theme.label,
            ),
            const SizedBox(height: 16),
            _line(
              theme,
              TrainingLibraryGlyph.figure,
              strings.muscles,
              muscles,
              labelWidth: display == null ? 36 : 60,
            ),
            const SizedBox(height: 12),
            _line(
              theme,
              TrainingLibraryGlyph.subtitles,
              strings.cues,
              cues.whereType<String>().join(display?.cues == null ? '；' : '; '),
              labelWidth: display == null ? 36 : 60,
            ),
            if (cautions.isNotEmpty) ...[
              const SizedBox(height: 12),
              _line(
                theme,
                TrainingLibraryGlyph.bandage,
                strings.cautions,
                '${cautions.join(display?.cautions == null ? '、' : ', ')}${strings.cautionSuffix}',
                color: theme.caution,
                labelWidth: display == null ? 36 : 60,
              ),
            ],
            if (widget.config.showStartAction) ...[
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('library-detail-start'),
                  onPressed: widget.canStart
                      ? () => Navigator.of(context).pop(true)
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.accent,
                    foregroundColor: theme.onAccent,
                  ),
                  child: Text(strings.start),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _line(
    TrainerTheme theme,
    TrainingLibraryGlyph icon,
    String label,
    String text, {
    Color? color,
    double labelWidth = 36,
  }) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: TrainingLibraryIcon(icon, size: 18, color: color ?? theme.faint),
      ),
      const SizedBox(width: 8),
      SizedBox(
        width: labelWidth,
        child: Text(
          label,
          style: theme.label.copyWith(color: color ?? theme.muted, height: 1.6),
        ),
      ),
      Expanded(
        child: Text(
          text,
          style: theme.body.copyWith(fontSize: 15, height: 1.55, color: color),
        ),
      ),
    ],
  );
}

TrainerTheme _themeOf(BuildContext context, TrainerTheme? supplied) =>
    TrainingLibraryStyle.themeOf(context, supplied);

String _categoryLabel(String? category) => switch (category) {
  'strength' => '力量',
  'core' => '核心',
  'cardio' => '有氧',
  'mobility' => '灵活',
  'stretch' => '拉伸',
  _ => '灵活',
};
