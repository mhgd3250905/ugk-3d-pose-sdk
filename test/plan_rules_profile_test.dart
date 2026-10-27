import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  const expected = {
    'warmupFromMinutes': 9,
    'cooldownFromMinutes': 9,
    'exemptWarmupForPureStretch': true,
    'focusRatio': 0.5,
    'maxSameMuscleInRow': 3,
    'antagonisticPairs': <Object>[],
  };

  for (final id in ['smartfit', 'hiplab', 'flarelab']) {
    test('$id declares its plan rules and they survive a JSON roundtrip', () {
      final profile = loadProfile(id);
      expect(profile.planRules.toJson(), expected);
      final restored = CoachProfile.fromJson(
        jsonDecode(jsonEncode(profile.toJson())),
      );
      expect(restored.planRules.toJson(), expected);
      expect(restored.toJson(), profile.toJson());
    });
  }

  test('old custom profiles have complete default rules', () {
    const direct = CoachProfile(id: 'old', appName: 'old');
    final decoded = CoachProfile.fromJson({'id': 'old'});
    expect(direct.planRules.toJson(), expected);
    expect(decoded.planRules.toJson(), expected);
    final source = jsonDecode(
      File('profiles/plan-rules-default.json').readAsStringSync(),
    );
    expect(direct.planRules.toJson(), source);
  });

  test('custom thresholds, stretch policy and antagonist groups roundtrip', () {
    final custom = CoachProfile.fromJson({
      'id': 'custom',
      'planRules': {
        'warmupFromMinutes': 5,
        'cooldownFromMinutes': 12,
        'exemptWarmupForPureStretch': false,
        'focusRatio': 0.75,
        'maxSameMuscleInRow': 2,
        'antagonisticPairs': [
          {
            'first': ['body.abs', 'body.obliques'],
            'second': ['body.erectors'],
          },
        ],
      },
    });
    final rules = custom.planRules;
    expect(rules.warmupFromMinutes, 5);
    expect(rules.cooldownFromMinutes, 12);
    expect(rules.exemptWarmupForPureStretch, isFalse);
    expect(rules.focusRatio, 0.75);
    expect(rules.maxSameMuscleInRow, 2);
    expect(rules.antagonisticPairs.single.first, ['body.abs', 'body.obliques']);
    expect(rules.antagonisticPairs.single.second, ['body.erectors']);
    final restored = CoachProfile.fromJson(
      jsonDecode(jsonEncode(custom.toJson())),
    );
    expect(restored.planRules.toJson(), rules.toJson());
  });

  test('invalid explicit rules fail rather than weakening checks silently', () {
    final invalid = <Map<String, Object?>>[
      {'focusRatio': -0.01},
      {'focusRatio': 1.01},
      {'focusRatio': '0.5'},
      {'warmupFromMinutes': -1},
      {'cooldownFromMinutes': -1},
      {'maxSameMuscleInRow': 0},
      {'maxSameMuscleInRow': -1},
      {'exemptWarmupForPureStretch': 'yes'},
      {'antagonisticPairs': 'invalid'},
      {
        'antagonisticPairs': [null],
      },
      {
        'antagonisticPairs': [
          {
            'first': ['body.abs'],
            'second': <String>[],
          },
        ],
      },
      {
        'antagonisticPairs': [
          {
            'first': ['body.abs', 1],
            'second': ['body.erectors'],
          },
        ],
      },
    ];
    for (final rules in invalid) {
      expect(
        () => CoachProfile.fromJson({'id': 'x', 'planRules': rules}),
        throwsFormatException,
        reason: 'invalid: $rules',
      );
    }
    expect(
      () => CoachProfile.fromJson({'id': 'x', 'planRules': 'invalid'}),
      throwsFormatException,
    );
    expect(PlanRules.fromJson({}).toJson(), expected);
  });
}
