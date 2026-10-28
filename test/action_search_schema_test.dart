import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_tags.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$pack/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$pack/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();

  for (final id in ['smartfit', 'hiplab', 'flarelab']) {
    test('$id search schema uses only its actual catalogue tags', () {
      final profile = loadProfile(id);
      final tool = AgentTools.build(
        profile,
        catalog,
        memory: false,
      ).singleWhere((tool) => tool.name == AgentTools.searchActions);
      final properties = tool.parameters['properties']! as Map<String, Object?>;
      final tags = properties['tags']! as Map<String, Object?>;
      final items = tags['items']! as Map<String, Object?>;
      final allowed = (items['enum']! as List).cast<String>();

      expect(allowed, ActionTags(profile, catalog).tags);
      expect(allowed, isNotEmpty);
      expect(allowed, isNot(contains('purpose.warmup')));
      expect(allowed, isNot(contains('body.not_in_catalog')));
      expect(tags['type'], 'array');
      expect(tags['uniqueItems'], isTrue);
      // Every permitted enum member is a string, so a separate primitive type
      // adds no constraint to this schema.
      expect(items.containsKey('type'), isFalse);
      expect(allowed.every((value) => value.isNotEmpty), isTrue);
      expect(properties['keywords'], {'type': 'string'});
      expect(properties['limit'], {
        'type': 'integer',
        'minimum': 1,
        'maximum': 20,
      });
      expect(tool.parameters['required'], ['tags']);
      expect(tool.parameters['additionalProperties'], isFalse);
    });
  }

  test(
    'get_action schema accepts one to ten IDs without catalogue injection',
    () {
      final tool = AgentTools.build(
        loadProfile('smartfit'),
        catalog,
        memory: false,
      ).singleWhere((tool) => tool.name == AgentTools.getAction);
      expect(tool.parameters, {
        'type': 'object',
        'properties': {
          'ids': {
            'type': 'array',
            'items': {'type': 'string'},
            'minItems': 1,
            'maxItems': 10,
            'uniqueItems': true,
          },
        },
        'required': ['ids'],
        'additionalProperties': false,
      });
    },
  );
}
