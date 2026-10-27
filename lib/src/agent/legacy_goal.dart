/// Resolves old plan-card goals from profile-owned structured rules.
library;

import 'dart:convert';

import '../profile/coach_profile.dart';
import '../util/json.dart';
import 'legacy_goal_defaults.g.dart';

final List<Map<String, Object?>> _defaultRules = [
  for (final rule in jsonDecode(legacyGoalDefaultsJson) as List) asMap(rule),
];

String resolveLegacyGoal(
  CoachProfile profile,
  Iterable<String> goals,
  Iterable<String> blockKinds,
) {
  final allGoals = goals.toSet();
  final bodyGoals = allGoals.where((code) => code.startsWith('body.')).toSet();
  final blocks = blockKinds.toSet();
  final rules = profile.legacyGoalMap.isEmpty
      ? _defaultRules
      : profile.legacyGoalMap;
  for (final rule in rules) {
    final anyOf = asStringList(rule['anyOf']);
    final fallback = asBool(rule['fallback']) ?? false;
    if (!fallback && !anyOf.any(allGoals.contains)) continue;

    if (rule.containsKey('onlyBlocks')) {
      final allowed = asStringList(rule['onlyBlocks']).toSet();
      if (blocks.isEmpty || !blocks.every(allowed.contains)) continue;
    }
    if (rule.containsKey('bodyOnlyOf')) {
      final allowed = asStringList(rule['bodyOnlyOf']).toSet();
      if (bodyGoals.isEmpty || !bodyGoals.every(allowed.contains)) continue;
    }
    if (rule.containsKey('minBodyRegions')) {
      final minimum = asInt(rule['minBodyRegions']);
      final regions = asMap(rule['bodyRegions']);
      if (minimum == null ||
          regions.values
                  .where((codes) => asStringList(codes).any(bodyGoals.contains))
                  .length <
              minimum) {
        continue;
      }
    }
    final goal = asString(rule['goal']);
    if (goal != null && goal.isNotEmpty) return goal;
  }
  throw StateError('Profile ${profile.id} has no matching legacyGoalMap rule.');
}
