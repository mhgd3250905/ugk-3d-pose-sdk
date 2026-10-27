import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/legacy_goal.dart';
import 'package:ugk_coach/src/agent/legacy_goal_defaults.g.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final source =
      jsonDecode(File('profiles/legacy-goal-default.json').readAsStringSync())
          as Map<String, dynamic>;
  final rules = jsonDecode(legacyGoalDefaultsJson) as List<dynamic>;

  test('compiled defaults match source JSON and all current profiles', () {
    expect(rules, source['legacyGoalMap']);
    for (final name in ['smartfit', 'hiplab', 'flarelab']) {
      final profile = loadProfile(name);
      expect(profile.legacyGoalMap, rules);
      expect(
        CoachProfile.fromJson(
          jsonDecode(jsonEncode(profile.toJson())),
        ).toJson(),
        profile.toJson(),
      );
    }
  });

  for (final name in ['smartfit', 'hiplab', 'flarelab']) {
    test('$name resolves priority, regions, single body and fallback', () {
      final profile = loadProfile(name);
      String resolve(List<String> goals) =>
          resolveLegacyGoal(profile, goals, ['main']);
      expect(
        resolve(['purpose.stretch', 'purpose.strength', 'body.core']),
        'relax',
      );
      expect(
        resolve(['purpose.mobility', 'purpose.strength', 'body.core']),
        'mobility',
      );
      expect(resolve(['body.core']), 'core');
      expect(resolve(['body.abs', 'body.obliques']), 'core');
      expect(resolve(['body.deltoids', 'body.quadriceps']), 'fullbody');
      expect(resolve(['body.core', 'body.quadriceps']), 'fullbody');
      expect(resolve(['body.deltoids']), 'strength');
      expect(resolve(['purpose.strength']), 'strength');
      expect(resolve(['purpose.cardio']), 'fullbody');
      expect(resolve([]), 'fullbody');
    });
  }

  test('old custom profile uses offline defaults; explicit rules override', () {
    const old = CoachProfile(id: 'old', appName: 'old');
    expect(resolveLegacyGoal(old, ['body.core'], ['main']), 'core');
    expect(resolveLegacyGoal(old, ['purpose.cardio'], ['main']), 'fullbody');
    const override = CoachProfile(
      id: 'custom',
      appName: 'custom',
      legacyGoalMap: [
        {
          'anyOf': ['body.core'],
          'goal': 'strength',
        },
        {'anyOf': <String>[], 'goal': 'mobility', 'fallback': true},
      ],
    );
    expect(resolveLegacyGoal(override, ['body.core'], ['main']), 'strength');
    expect(resolveLegacyGoal(override, [], ['main']), 'mobility');
  });

  test(
    'optional purpose and body codes obey configured block and region rules',
    () {
      final custom = (jsonDecode(jsonEncode(rules)) as List)
          .cast<Map<String, dynamic>>();
      custom[2]['anyOf'] = ['purpose.warmup'];
      custom[3]['anyOf'] = ['purpose.cooldown'];
      custom.insert(6, {
        'anyOf': ['body.fullbody'],
        'goal': 'fullbody',
      });
      final profile = CoachProfile(
        id: 'future',
        appName: 'future',
        legacyGoalMap: custom,
      );
      expect(
        resolveLegacyGoal(profile, ['purpose.warmup'], ['warmup']),
        'warmup',
      );
      expect(
        resolveLegacyGoal(profile, ['purpose.warmup'], ['warmup', 'main']),
        'fullbody',
      );
      expect(resolveLegacyGoal(profile, ['purpose.warmup'], []), 'fullbody');
      expect(
        resolveLegacyGoal(profile, ['purpose.cooldown'], ['cooldown']),
        'cooldown',
      );
      expect(
        resolveLegacyGoal(profile, ['purpose.cooldown'], ['main', 'cooldown']),
        'fullbody',
      );
      expect(
        resolveLegacyGoal(profile, ['body.fullbody'], ['main']),
        'fullbody',
      );
      expect(
        resolveLegacyGoal(
          profile,
          ['purpose.stretch', 'purpose.warmup'],
          ['warmup'],
        ),
        'relax',
      );
    },
  );

  test('model draft schema does not accept legacy_goal', () {
    final tool = AgentTools.build(
      loadProfile('smartfit'),
      loadCatalog(),
      memory: false,
    ).singleWhere((tool) => tool.name == AgentTools.draftPlan);
    final properties = tool.parameters['properties'] as Map;
    expect(properties, isNot(contains('legacy_goal')));
    expect(tool.parameters['additionalProperties'], isFalse);
  });
}
