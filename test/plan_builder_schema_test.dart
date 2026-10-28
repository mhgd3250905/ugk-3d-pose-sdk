import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();
  const expected = <String, Object?>{
    'type': 'object',
    'properties': {
      'plan_id': {'type': 'string'},
      'operation': {
        'enum': ['edit', 'replace_all'],
      },
      'title': {'type': 'string'},
      'blocks': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'kind': {
              'enum': ['warmup', 'main', 'cooldown'],
            },
            'rounds': {'type': 'integer'},
            'items': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'id': {'type': 'string'},
                  'sets': {'type': 'integer'},
                  'reps': {'type': 'integer'},
                  'seconds': {'type': 'integer'},
                },
                'required': ['id'],
                'additionalProperties': false,
              },
            },
          },
          'required': ['kind', 'items'],
          'additionalProperties': false,
        },
      },
    },
    'required': ['title', 'blocks'],
    'additionalProperties': false,
  };

  for (final id in ['smartfit', 'hiplab', 'flarelab']) {
    test('$id draft_plan schema has only the specified structural inputs', () {
      final tool = AgentTools.build(
        loadProfile(id),
        catalog,
        memory: false,
      ).singleWhere((tool) => tool.name == AgentTools.draftPlan);
      expect(tool.parameters, expected);
      final wire = jsonDecode(jsonEncode(tool.toJson())) as Map;
      expect((wire['function'] as Map)['parameters'], expected);
      for (final drill in catalog.drills) {
        expect(jsonEncode(tool.parameters), isNot(contains(drill.id)));
      }
    });
  }
}
