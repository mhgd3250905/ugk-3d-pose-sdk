import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();
  const expected = <String, Object?>{
    'type': 'object',
    'properties': {
      'title': {
        'type': 'string',
        'description': '标题只写名称，不写时长、动作数、组数；卡片时长由代码从数据显示。',
      },
      'blocks': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'kind': {
              'enum': ['warmup', 'main', 'cooldown'],
            },
            'items': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'id': {'type': 'string'},
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
