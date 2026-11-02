import 'package:flutter/widgets.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

import 'app_profile.dart';
import 'chat_bindings.dart';

/// Connects a host's player and media metadata to the shared training launcher.
/// Assign [call] to [CoachChatHostActions.onStartTraining]. Ordinary host
/// training entries can call [TrainerLauncher.open] with the same profile.
///
/// This adapter runs the request's bookkeeping only after the first poster is
/// decoded. It retains the host's existing safety, player and save callbacks.
class CoachChatTrainingAdapter {
  const CoachChatTrainingAdapter({
    required this.profile,
    required this.pageBuilder,
    this.firstPosterAsset,
    this.posterAssets,
    this.theme,
  });

  final CoachAppProfile profile;
  final Widget Function(BuildContext context, CoachChatTrainingRequest request)
  pageBuilder;

  /// Legacy media callbacks are used only when the profile has no media policy.
  final String? Function(
    BuildContext context,
    CoachChatTrainingRequest request,
  )?
  firstPosterAsset;
  final Iterable<String> Function(
    BuildContext context,
    CoachChatTrainingRequest request,
  )?
  posterAssets;
  final TrainerTheme? Function(
    BuildContext context,
    CoachChatTrainingRequest request,
  )?
  theme;

  Future<SessionResult?> call(
    BuildContext context,
    CoachChatTrainingRequest request,
  ) {
    final policy = profile.mediaPolicy;
    final ids = request.plan.plan.exerciseIds;
    return TrainerLauncher.open<SessionResult>(
      context,
      builder: (context) => pageBuilder(context, request),
      firstPosterAsset: policy == null
          ? firstPosterAsset?.call(context, request)
          : ids.isEmpty
          ? null
          : policy.posterAssetFor(ids.first),
      posterAssets: policy == null
          ? posterAssets?.call(context, request) ?? const []
          : [for (final id in ids) ?policy.posterAssetFor(id)],
      experience: profile.trainingExperience,
      mediaPolicy: policy,
      planActionIds: ids,
      theme: theme?.call(context, request),
      onStarting: request.onStarting,
      holdTransition: request.holdTransition,
      settings: const RouteSettings(name: 'player'),
    );
  }
}
