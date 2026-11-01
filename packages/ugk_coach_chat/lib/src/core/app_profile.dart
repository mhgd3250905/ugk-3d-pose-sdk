import 'package:ugk_coach/ugk_coach.dart' as coach;

import '../theme/chat_theme.dart';
import 'chat_strings.dart';

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
    required this.scopeManifest,
    required this.coachProfile,
    required this.conversationPolicy,
    required this.executionTiming,
    this.revision = '1',
    this.strings = const CoachChatStrings(),
    this.visual = const CoachChatVisuals(),
    this.doseOverrides = const {},
  });

  final String appId, revision;
  final coach.CoachActionScopeManifest scopeManifest;
  final coach.CoachProfile coachProfile;
  final coach.CoachScopeConversationPolicy conversationPolicy;
  final coach.PlanExecutionTimingCallback executionTiming;
  final CoachChatStrings strings;
  final CoachChatVisuals visual;
  final Map<String, CoachChatDoseOverride> doseOverrides;
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
