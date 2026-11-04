import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart'
    show
        PoseHubCatalogUpdateConfig,
        TrainerExperienceConfig,
        TrainingMediaPolicy,
        TrainingLibraryConfig;

import '../theme/chat_theme.dart';
import 'chat_strings.dart';

/// The original agent remains the default for existing host configurations.
enum CoachChatAgentMode { legacy, qaV2 }

/// A dose projection applied to an explicitly selected catalogue action.
/// The projector changes the actual catalogue dose/range/rhythm together;
/// [unitLabel] only formats that already projected dose.
class CoachChatDoseOverride {
  const CoachChatDoseOverride({required this.apply, this.unitLabel});
  final coach.Drill Function(coach.Drill drill) apply;
  final String? unitLabel;
}

/// The product configuration of one shared chat module.
///
/// [executionTiming] is the synchronous pure callback of the player's actual
/// SessionBuilder. The module never estimates preparation or lead overhead.
class CoachAppProfile {
  const CoachAppProfile({
    required this.appId,
    required coach.CoachActionScopeManifest scopeManifest,
    required this.coachProfile,
    required this.conversationPolicy,
    required this.executionTiming,
    this.revision = '1',
    this.strings = const CoachChatStrings(),
    this.visual = const CoachChatVisuals(),
    this.doseOverrides = const {},
    this.trainingExperience,
    this.mediaPolicy,
    this.library,
    this.agentMode = CoachChatAgentMode.legacy,
    this.aiTags = const {},
    this.catalogUpdate,
    // Keep the public named parameter while retaining the legacy fallback.
    // ignore: prefer_initializing_formals
  }) : _scopeManifest = scopeManifest;

  final String appId, revision;
  final coach.CoachActionScopeManifest _scopeManifest;

  /// The optional shared library supplies the same scope used by Coach tools
  /// and plan admission. Existing hosts retain their original manifest.
  coach.CoachActionScopeManifest get scopeManifest =>
      library?.scopeManifest ?? _scopeManifest;
  final coach.CoachProfile coachProfile;
  final coach.CoachScopeConversationPolicy conversationPolicy;
  final coach.PlanExecutionTimingCallback executionTiming;
  final CoachChatStrings strings;
  final CoachChatVisuals visual;
  final Map<String, CoachChatDoseOverride> doseOverrides;

  /// Optional shared training presentation settings. Null uses the SDK's
  /// poster-first launcher defaults. Host plans, safety and persistence remain
  /// in the host adapters.
  final TrainerExperienceConfig? trainingExperience;

  /// Opt-in public action media. Null retains the host's existing media path.
  final TrainingMediaPolicy? mediaPolicy;

  /// Shared action library presentation and its canonical action whitelist.
  /// Null preserves the host's existing library and Coach scope.
  final TrainingLibraryConfig? library;

  /// Opt in to the SDK's question-and-answer agent without a host-owned page.
  final CoachChatAgentMode agentMode;

  /// Optional Pose-Hub AI tags keyed by action ID, loaded by the host App.
  /// The SDK ships no tag dataset. Missing tags use catalogue fields.
  final Map<String, Map<String, Object?>> aiTags;

  /// Build-time action-library channel (dev/beta/stable). Null keeps the
  /// bundled catalogue only; hosts run `PoseHubCatalogUpdater` with it.
  final PoseHubCatalogUpdateConfig? catalogUpdate;
  Set<String> get allowedActionIds => scopeManifest.allowedActionIds;

  coach.Catalog planningCatalog(coach.Catalog source) {
    if (appId.trim().isEmpty ||
        revision.trim().isEmpty ||
        appId != coachProfile.id ||
        appId != scopeManifest.appId) {
      throw ArgumentError(
        'The chat profile and manifest must use the same appId',
      );
    }
    if (strings.safetyQuestions.length != strings.safetyAdvice.length ||
        strings.safetyQuestions.isEmpty) {
      throw ArgumentError(
        'Safety questions and advice must have equal lengths',
      );
    }
    for (final id in doseOverrides.keys) {
      if (!allowedActionIds.contains(id) || source[id] == null) {
        throw ArgumentError.value(id, 'doseOverrides', 'Action is not allowed');
      }
    }
    if (doseOverrides.isEmpty) return source;
    return coach.Catalog.fromJson({
      ...source.toJson(),
      'drills': [
        for (final drill in source.drills)
          if (doseOverrides[drill.id] case final override?)
            _project(override, drill).toJson()
          else
            drill.toJson(),
      ],
    });
  }

  coach.Drill _project(CoachChatDoseOverride override, coach.Drill source) {
    final result = override.apply(source);
    if (result.id != source.id) {
      throw ArgumentError('A dose override cannot change the action ID');
    }
    return result;
  }
}
