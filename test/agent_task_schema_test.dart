import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/agent_prompt.dart';
import 'package:ugk_coach/src/profile/coach_profile.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();

  group('task tool schemas', () {
    for (final id in ['smartfit', 'hiplab', 'flarelab']) {
      test('$id exposes only the fixed task types and node inputs', () {
        final tools = AgentTools.build(loadProfile(id), catalog, memory: false);
        final start = tools.singleWhere((tool) => tool.name == 'start_task');
        final check = tools.singleWhere((tool) => tool.name == 'check');

        expect(start.parameters, {
          'type': 'object',
          'properties': {
            'type': {
              'enum': ['recommend', 'plan'],
              'description':
                  'recommend=给几个动作让用户挑选或尝试；plan=有时长和结构、可以跟练的一整套训练（用户给了时长，或说练一下/来一套/安排/计划）；两者都合理时由模型判断。',
            },
            'reuse': {'type': 'boolean'},
          },
          'required': ['type'],
          'additionalProperties': false,
        });
        expect(check.parameters, {
          'type': 'object',
          'properties': {
            'node': {
              'enum': [
                'understand',
                'parameters',
                'actions',
                'planning',
                'review',
              ],
            },
            'picks': {
              'type': 'array',
              'items': {'type': 'string'},
              'uniqueItems': true,
            },
          },
          'required': ['node'],
          'additionalProperties': false,
        });
      });
    }
  });

  group('profile action thresholds', () {
    for (final id in ['smartfit', 'hiplab', 'flarelab']) {
      test('$id declares three actions and survives JSON roundtrip', () {
        final input =
            jsonDecode(File('profiles/$id.json').readAsStringSync())
                as Map<String, dynamic>;
        expect(input['minActions'], 3);
        final profile = CoachProfile.fromJson(input);
        expect(profile.minActions, 3);
        final encoded = jsonDecode(jsonEncode(profile.toJson()));
        final restored = CoachProfile.fromJson(encoded);
        expect(restored.minActions, 3);
        expect(restored.toJson(), profile.toJson());
      });
    }

    test('a configured threshold is preserved through JSON', () {
      final original = loadProfile('smartfit').toJson()..['minActions'] = 5;
      final profile = CoachProfile.fromJson(original);
      final restored = CoachProfile.fromJson(
        jsonDecode(jsonEncode(profile.toJson())),
      );
      expect(restored.minActions, 5);
      expect(restored.toJson(), profile.toJson());
    });
  });
}
