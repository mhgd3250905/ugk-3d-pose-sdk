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
    required this.firstPosterAsset,
    this.posterAssets,
    this.theme,
  });

  final CoachAppProfile profile;
  final Widget Function(BuildContext context, CoachChatTrainingRequest request)
  pageBuilder;
  final String? Function(BuildContext context, CoachChatTrainingRequest request)
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
  ) => TrainerLauncher.open<SessionResult>(
    context,
    builder: (context) => pageBuilder(context, request),
    firstPosterAsset: firstPosterAsset(context, request),
    posterAssets: posterAssets?.call(context, request) ?? const [],
    experience: profile.trainingExperience,
    theme: theme?.call(context, request),
    onStarting: request.onStarting,
    holdTransition: request.holdTransition,
    settings: const RouteSettings(name: 'player'),
  );
}
