import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/agent_prompt.dart';

void main() {
  test(
    'homogeneous primitive enums retain their complete value constraint',
    () {
      final original = <String, Object?>{
        'type': 'object',
        'properties': {
          'text': {
            'type': 'string',
            'enum': ['plan', 'recommend'],
          },
          'level': {
            'type': 'integer',
            'enum': [1, 2, 3],
          },
          'ratio': {
            'type': 'number',
            'enum': [1, 2.5],
          },
          'reuse': {
            'type': 'boolean',
            'enum': [true, false],
          },
        },
        'required': ['text', 'level'],
        'additionalProperties': false,
      };
      final before = jsonEncode(original);
      expect(compactEnumSchema(original), {
        'type': 'object',
        'properties': {
          'text': {
            'enum': ['plan', 'recommend'],
          },
          'level': {
            'enum': [1, 2, 3],
          },
          'ratio': {
            'enum': [1, 2.5],
          },
          'reuse': {
            'enum': [true, false],
          },
        },
        'required': ['text', 'level'],
        'additionalProperties': false,
      });
      expect(
        jsonEncode(original),
        before,
        reason: 'Input schemas remain intact',
      );
    },
  );

  test('mixed enums and nonredundant type constraints remain unchanged', () {
    final schemas = <Map<String, Object?>>[
      {
        'type': 'string',
        'enum': ['text', 2],
      },
      {
        'type': 'string',
        'enum': ['text', null],
      },
      {
        'type': 'integer',
        'enum': [1, 2.5],
      },
      {
        'type': 'boolean',
        'enum': [true, 0],
      },
      {'type': 'string', 'enum': <String>[]},
      {
        'type': ['string', 'null'],
        'enum': ['text', null],
      },
      {
        'type': 'object',
        'enum': [
          {'x': 1},
        ],
      },
      {
        'type': 'array',
        'enum': [
          [1, 2],
        ],
      },
    ];
    for (final schema in schemas) {
      expect(compactEnumSchema(schema), schema);
    }
  });

  test(
    'nested constraints, descriptions and required fields survive compaction',
    () {
      final description =
          'Do not ask known conditions again; retain provenance.';
      final input = <String, Object?>{
        'type': 'object',
        'description': description,
        'properties': {
          'conditions': {
            'type': 'array',
            'description': 'Validated choices only',
            'minItems': 1,
            'uniqueItems': true,
            'items': {
              'type': 'object',
              'properties': {
                'source': {
                  'type': 'string',
                  'enum': ['user', 'default'],
                  'description': 'A user quote is required for source=user',
                },
                'quote': {'type': 'string', 'minLength': 1, 'maxLength': 30},
              },
              'required': ['source'],
              'additionalProperties': false,
            },
          },
        },
        'required': ['conditions'],
        'additionalProperties': false,
      };
      final result = compactEnumSchema(input);
      final properties = result['properties'] as Map;
      final conditions = properties['conditions'] as Map;
      final item = conditions['items'] as Map;
      expect(result['description'], description);
      expect(result['required'], ['conditions']);
      expect(result['additionalProperties'], isFalse);
      expect(conditions['minItems'], 1);
      expect(conditions['uniqueItems'], isTrue);
      expect(item['required'], ['source']);
      expect(item['additionalProperties'], isFalse);
      expect((item['properties'] as Map)['source'], {
        'enum': ['user', 'default'],
        'description': 'A user quote is required for source=user',
      });
      expect((item['properties'] as Map)['quote'], {
        'type': 'string',
        'minLength': 1,
        'maxLength': 30,
      });
    },
  );

  test(
    'enum literals that resemble schema objects keep their exact values',
    () {
      final literal = <String, Object?>{
        'type': 'string',
        'enum': ['literal-data'],
      };
      final input = <String, Object?>{
        'type': 'object',
        'enum': [literal],
      };
      expect(compactEnumSchema(input), input);
    },
  );
}
