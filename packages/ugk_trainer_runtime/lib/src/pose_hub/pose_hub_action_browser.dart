import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../engine/session.dart';
import '../library/training_library_browser.dart';
import '../library/training_library_config.dart';
import '../result/session_result.dart';
import '../rhythm/rhythm.dart';
import '../ui/trainer_player.dart';
import '../ui/trainer_strings.dart';
import '../ui/trainer_theme.dart';
import 'pose_hub_media_preparation.dart';
import 'pose_hub_pack_image.dart';

export '../library/training_library_browser.dart'
    show PoseHubActionFacets, poseHubEquipmentLabels;

@Deprecated(
  'The user library only exposes complete actions with user-facing facets.',
)
enum PoseHubActionFilter { all, semanticComplete, pending }

/// Compatibility adapter to the public, asset-independent library browser.
class PoseHubActionBrowser extends StatelessWidget {
  const PoseHubActionBrowser({
    super.key,
    required this.catalog,
    required this.mediaBaseUri,
    this.theme,
    this.onPracticeFinished,
    this.mediaPreparer,
    this.voice,
    this.onStartTraining,
    this.onCompleted,
    this.onOpenPractice,
    this.libraryConfig,
    this.onOpenAction,
    this.actionArtwork,
    this.embedded = false,
  });

  /// Optional shared-library configuration; absent preserves the SF browser.
  final TrainingLibraryConfig? libraryConfig;
  final ValueChanged<PoseHubPackAction>? onOpenAction;
  final Widget Function(
    BuildContext context,
    PoseHubPackAction action,
    TrainerTheme theme,
  )?
  actionArtwork;
  final bool embedded;
  final PoseHubAppTestCatalog catalog;
  final Uri mediaBaseUri;
  final TrainerTheme? theme;
  final ValueChanged<PoseHubPracticeResult>? onPracticeFinished;
  final PoseHubMediaPreparer? mediaPreparer;
  final TrainerVoice? voice;
  final VoidCallback? onStartTraining;
  final Future<void> Function(SessionResult result)? onCompleted;

  /// Lets the host open the fully configured single-practice page.
  ///
  /// Null preserves the built-in MaterialPageRoute. When supplied, this is
  /// called instead of pushing a route; the host owns navigation. The page
  /// exposes the selected action, resolved theme and all existing practice
  /// inputs, which can be reused when adding host start/exit or media hooks.
  final ValueChanged<PoseHubSinglePracticePage>? onOpenPractice;
  @override
  Widget build(BuildContext context) {
    final resolved = _themeOf(context, theme);
    return TrainingLibraryBrowser(
      actions: catalog.semanticCompleteActions,
      config: libraryConfig,
      theme: resolved,
      embedded: embedded,
      actionArtwork:
          actionArtwork ??
          (_, action, theme) =>
              PoseHubStandingImage(action: action, theme: theme),
      onOpenAction: (action) {
        if (onOpenAction case final open?) {
          open(action);
          return;
        }
        final page = PoseHubSinglePracticePage(
          action: action,
          mediaBaseUri: mediaBaseUri,
          theme: resolved,
          onFinished: onPracticeFinished,
          mediaPreparer: mediaPreparer,
          voice: voice,
          startMode: TrainerStartMode.preview,
          onStartTraining: onStartTraining,
          onCompleted: onCompleted,
        );
        if (onOpenPractice case final open?) {
          open(page);
        } else {
          Navigator.of(
            context,
          ).push<void>(MaterialPageRoute(builder: (_) => page));
        }
      },
    );
  }
}

@immutable
class PoseHubPracticeResult {
  const PoseHubPracticeResult({
    required this.actionId,
    required this.activeDuration,
    required this.trainingDefinitionComplete,
  });
  final String actionId;
  final Duration activeDuration;
  final bool trainingDefinitionComplete;
}

/// Kept for source compatibility; the removed detail UI now opens training.
@Deprecated(
  'Use PoseHubSinglePracticePage; details now open the shared trainer.',
)
class PoseHubActionDetail extends StatelessWidget {
  const PoseHubActionDetail({
    super.key,
    required this.action,
    required this.mediaBaseUri,
    this.theme,
    this.onPracticeFinished,
    this.mediaPreparer,
  });
  final PoseHubPackAction action;
  final Uri mediaBaseUri;
  final TrainerTheme? theme;
  final ValueChanged<PoseHubPracticeResult>? onPracticeFinished;
  final PoseHubMediaPreparer? mediaPreparer;
  @override
  Widget build(BuildContext context) => PoseHubSinglePracticePage(
    action: action,
    mediaBaseUri: mediaBaseUri,
    theme: theme,
    onFinished: onPracticeFinished,
    mediaPreparer: mediaPreparer,
  );
}

/// Compatibility entry backed by the same one-action training player.
/// Dose comes from complete catalogue semantics, never from video duration.
class PoseHubSinglePracticePage extends StatelessWidget {
  const PoseHubSinglePracticePage({
    super.key,
    required this.action,
    required this.mediaBaseUri,
    this.theme,
    this.onFinished,
    this.mediaPreparer,
    this.voice,
    this.startMode = TrainerStartMode.training,
    this.onStartTraining,
    this.onCompleted,
    this.startGate,
    this.beforeExitPop,
    this.onExitStarted,
    this.mediaBuilder,
  });
  final PoseHubPackAction action;
  final Uri mediaBaseUri;
  final TrainerTheme? theme;
  final ValueChanged<PoseHubPracticeResult>? onFinished;
  final PoseHubMediaPreparer? mediaPreparer;
  final TrainerVoice? voice;
  final TrainerStartMode startMode;
  final VoidCallback? onStartTraining;
  final Future<void> Function(SessionResult result)? onCompleted;

  /// Delays an initially training session, with [TrainerPlayer.startGate]
  /// semantics. Until it settles, the clock, ticks, audio and keep-alive do
  /// not start, and media requests are paused. Errors release the gate;
  /// leaving first prevents startup and saving. Preview ignores the gate.
  /// Null preserves immediate startup.
  final Future<void>? startGate;

  /// Awaits host exit work after saving and receipt completion, before pop.
  ///
  /// Forwarded to [TrainerPlayer.beforeExitPop], including its one-second
  /// timeout and error handling. Save failure and preview exit do not call
  /// it. Closing before [startGate] settles awaits it without saving.
  final Future<void> Function()? beforeExitPop;

  /// Announces a confirmed exit synchronously, before saving begins.
  ///
  /// Forwarded to [TrainerPlayer.onExitStarted]; called once until replay.
  /// The host may begin exit motion here and await it in [beforeExitPop].
  /// Preview exit does not call it. Null retains the existing exit flow.
  final VoidCallback? onExitStarted;

  /// Replaces the media stage using [TrainerPlayer.mediaBuilder] semantics.
  ///
  /// Called on the first build, so the host can return a preloaded poster
  /// immediately. Honor [TrainerMediaRequest.paused] to avoid playback while
  /// gated or paused. Null keeps the existing Pose-Hub media and cover.
  /// This builder owns the full media stage, not an overlay on SDK video.
  final TrainerMediaBuilder? mediaBuilder;

  @override
  Widget build(BuildContext context) {
    if (!action.trainingDefinitionComplete) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('此动作暂未开放训练')),
      );
    }
    final dose = action.raw['defaultDose']! as Map;
    final cues = action.raw['cues'] as Map?;
    final zh = cues?['zh'] as List?;
    final cueList =
        zh?.whereType<String>().toList(growable: false) ?? const <String>[];
    final cautionAreas =
        (action.raw['cautions'] as List?)?.whereType<String>().toList() ??
        const <String>[];
    final precautions = [
      if (cautionAreas.isNotEmpty) '注意部位：${cautionAreas.join('、')}',
      ...(action.raw['contraindications'] as List?)?.whereType<String>() ??
          const <String>[],
    ];
    final item = PlanItem(
      exerciseId: action.id,
      mode: dose['mode'] == 'reps' ? DoseMode.reps : DoseMode.time,
      sets: dose['sets']! as int,
      reps: dose['reps'] as int?,
      workSeconds: dose['seconds'] as int?,
      perSide: action.raw['unilateral'] == true,
      restSeconds: dose['restSeconds']! as int,
    );
    // Alternating pair (v3 `training.repUnit: left+right`): the authored
    // one-side phases, played right+left inside every count. perSide stays
    // true for the 每侧 N 次 dose text; the engine does not split the set.
    final training = action.raw['training'];
    final pair = training is Map
        ? Rhythm.fromJson(
            Map<String, dynamic>.from(training),
            startingSide: action.raw['startingSide'] as String?,
          )
        : null;
    final rhythms = {
      action.id: pair != null && pair.alternatePair && pair.counted
          ? pair
          : Rhythm.forDose(
              item.mode,
              category: action.raw['category'] as String?,
              holdSeconds: (dose['holdSeconds'] as num?)?.toDouble(),
            ),
    };
    final scenes = (action.raw['scenes'] as List).whereType<String>();
    var plan = TrainingPlan(
      id: 'practice-${action.id}',
      source: 'template',
      title: action.nameZh,
      goal: action.raw['purpose'] as String? ?? '',
      scene: scenes.first,
      equipment: PoseHubActionFacets.equipment(action),
      level: action.raw['level'] as int? ?? 1,
      targetMinutes: 1,
      blocks: [
        PlanBlock(
          id: 'single',
          name: action.nameZh,
          type: BlockType.main,
          items: [item],
        ),
      ],
    );
    final seconds = SessionBuilder(
      rhythms: rhythms,
      prepSeconds: 0,
    ).phases(plan).fold<double>(0, (sum, phase) => sum + phase.seconds);
    plan = plan.copyWith(targetMinutes: (seconds / 60).ceil().clamp(1, 10000));
    return TrainerPlayer(
      key: ValueKey('posehub-practice-${action.id}'),
      plan: plan,
      rhythms: rhythms,
      strings: TrainerStrings.zh(),
      theme: _themeOf(context, theme),
      startMode: startMode,
      onStartTraining: onStartTraining,
      onCompleted: onCompleted,
      startGate: startGate,
      beforeExitPop: beforeExitPop,
      onExitStarted: onExitStarted,
      mediaBuilder: mediaBuilder,
      drillOf: (id) => id == action.id
          ? TrainerDrill(
              id: id,
              name: action.nameZh,
              cues: cueList,
              precautions: precautions,
              targetMuscles: action.raw['muscleGroupsZh'] as String?,
              equipment: _actionEquipment(action),
              thumbnailAsset:
                  'packages/ugk_trainer/assets/pose_hub/app-pack-r2-v1/standing/$id.webp',
            )
          : null,
      poseHubActionOf: (id) => id == action.id ? action : null,
      poseHubMediaBaseUri: mediaBaseUri,
      poseHubMediaPreparer: mediaPreparer,
      voice: voice,
      prepSeconds: startMode == TrainerStartMode.preview ? 10 : 0,
      onFinished: (result) async => onFinished?.call(
        PoseHubPracticeResult(
          actionId: action.id,
          activeDuration: Duration(
            microseconds: (result.activeSeconds * 1e6).round(),
          ),
          trainingDefinitionComplete: true,
        ),
      ),
    );
  }
}

String _actionEquipment(PoseHubPackAction action) {
  final equipment = PoseHubActionFacets.equipment(action);
  if (equipment.isEmpty) return '徒手';
  return equipment.map((id) => poseHubEquipmentLabels[id] ?? '其他器械').join('、');
}

TrainerTheme _themeOf(BuildContext context, TrainerTheme? supplied) =>
    supplied ??
    (Theme.of(context).brightness == Brightness.dark
        ? TrainerTheme.dark
        : TrainerTheme.light);
