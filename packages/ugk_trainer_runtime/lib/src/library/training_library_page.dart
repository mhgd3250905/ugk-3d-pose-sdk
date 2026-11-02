import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../media/training_action_media.dart';
import '../media/training_media_policy.dart';
import '../pose_hub/pose_hub_action_browser.dart';
import '../ui/trainer_experience.dart';
import '../ui/trainer_player.dart';
import '../ui/trainer_theme.dart';
import 'training_library_config.dart';

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
  });
  final TrainingLibraryConfig config;
  final TrainingMediaPolicy mediaPolicy;
  final TrainerTheme? theme;
  final Future<void> Function(String actionId)? onStart;
  final bool Function(String actionId)? canStart;
  final TrainerExperienceConfig? experience;
  final bool embedded;

  @override
  Widget build(BuildContext context) => PoseHubActionBrowser(
    catalog: mediaPolicy.catalog,
    mediaBaseUri: mediaPolicy.repository.mediaBaseUri,
    theme: theme,
    libraryConfig: config,
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
    final start = await showModalBottomSheet<bool>(
      context: context,
      routeSettings: RouteSettings(name: 'training_library_detail/$actionId'),
      isScrollControlled: true,
      backgroundColor: resolved.surface,
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
    final equipment = PoseHubActionFacets.equipment(action);
    final cues = (action.raw['cues'] as Map?)?['zh'] as List? ?? const [];
    final cautions = [
      ...(action.raw['cautions'] as List?)?.whereType<String>() ?? const [],
      ...(action.raw['contraindications'] as List?)?.whereType<String>() ??
          const [],
    ];
    final muscles =
        action.raw['muscleGroupsZh'] as String? ??
        ((action.raw['muscleGroups'] as List?)
                ?.whereType<String>()
                .map((id) => _muscleLabels[id] ?? id)
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
            Semantics(
              button: true,
              label:
                  '${_playing ? strings.pause : strings.play}${action.nameZh}',
              child: GestureDetector(
                key: const ValueKey('library-detail-play'),
                onTap: () => setState(() => _playing = !_playing),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      TrainingLibraryActionArt(
                        actionId: action.id,
                        config: widget.config,
                        mediaPolicy: widget.mediaPolicy,
                        theme: theme,
                        playing: _playing,
                      ),
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: theme.surfaceHigh,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _playing
                                      ? CupertinoIcons.pause_fill
                                      : CupertinoIcons.play_fill,
                                  size: 18,
                                  color: theme.text,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _playing ? strings.pause : strings.play,
                                  style: theme.callout,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              action.nameZh,
              style: theme.title.copyWith(
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              [
                PoseHubActionFacets.type(action),
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
            _line(theme, CupertinoIcons.person, strings.muscles, muscles),
            const SizedBox(height: 12),
            _line(
              theme,
              CupertinoIcons.text_bubble,
              strings.cues,
              cues.whereType<String>().join('；'),
            ),
            if (cautions.isNotEmpty) ...[
              const SizedBox(height: 12),
              _line(
                theme,
                CupertinoIcons.bandage,
                strings.cautions,
                '${cautions.join('、')}；${strings.cautionSuffix}',
                color: theme.caution,
              ),
            ],
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
        ),
      ),
    );
  }

  Widget _line(
    TrainerTheme theme,
    IconData icon,
    String label,
    String text, {
    Color? color,
  }) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Icon(icon, size: 18, color: color ?? theme.faint),
      ),
      const SizedBox(width: 8),
      SizedBox(
        width: 36,
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
    supplied ??
    (Theme.of(context).brightness == Brightness.dark
        ? TrainerTheme.dark
        : TrainerTheme.light);

const _muscleLabels = <String, String>{
  'chest': '胸部',
  'lats': '背阔肌',
  'erectors': '竖脊肌',
  'scapular': '肩胛肌群',
  'deltoids': '三角肌',
  'rotator-cuff': '肩袖',
  'serratus': '前锯肌',
  'biceps': '肱二头肌',
  'triceps': '肱三头肌',
  'forearms': '前臂',
  'abs': '腹肌',
  'obliques': '腹斜肌',
  'glute-max': '臀大肌',
  'hip-abductors': '髋外展肌',
  'hamstrings': '腘绳肌',
  'quadriceps': '股四头肌',
  'hip-flexors': '髋屈肌',
  'adductors': '内收肌',
  'calves': '小腿',
  'tibialis': '胫骨前肌',
};
