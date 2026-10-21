/// 两个工具的定义：show_actions（看动作）与 show_plan（开练，参数 = TrainingPlan v1）。
/// 动作 id 白名单写进参数 schema 的 enum（同一 App 前缀固定，可被缓存）；门禁仍会独立判定。
/// 与评测 `eval/tools/build_prompt.py` 的 build_tools 产出同一 JSON（test/tools_test.dart 对照）。
library;

import '../catalog/catalog.dart';
import '../llm/llm_types.dart';
import '../plan/plan_validator.dart';
import '../profile/coach_profile.dart';

abstract final class CoachTools {
  static const showActions = 'show_actions';
  static const showPlan = 'show_plan';
  static const names = {showActions, showPlan};

  /// show_actions 最多几个动作。
  static const maxActions = 6;

  static List<String> whitelist(CoachProfile profile, Catalog catalog) => [
    for (final d in profile.scope(catalog)) d.id,
  ];

  /// [idEnum] = false 时动作 id 不写 enum（Agent 版：id 由模型读文件得到，门禁照样判定白名单）。
  static List<LlmTool> build(CoachProfile profile, Catalog catalog, {bool idEnum = true}) {
    final idSchema = idEnum
        ? <String, Object?>{'type': 'string', 'enum': whitelist(profile, catalog)}
        : <String, Object?>{'type': 'string', 'description': '动作 id，必须来自读到的动作库文件'};
    final lim = profile.limits;
    Map<String, Object?> intRange(int min, int max) => {'type': 'integer', 'minimum': min, 'maximum': max};
    final cautions = catalog.taxonomy.cautions;
    return [
      LlmTool(
        name: showActions,
        description: '给用户展示 1–6 个动作的演示卡（看动作怎么做，不开练、不带剂量）。',
        parameters: {
          'type': 'object',
          'properties': {
            'items': {
              'type': 'array',
              'minItems': 1,
              'maxItems': maxActions,
              'items': {
                'type': 'object',
                'properties': {
                  'actionId': idSchema,
                  'note': {'type': 'string', 'description': '可选，一句说明（不写组数次数）'},
                },
                'required': ['actionId'],
                'additionalProperties': false,
              },
            },
          },
          'required': ['items'],
          'additionalProperties': false,
        },
      ),
      LlmTool(
        name: showPlan,
        description: '给用户一份可直接开练的训练计划（TrainingPlan v1）。修改计划时提交完整新计划。',
        parameters: {
          'type': 'object',
          'properties': {
            'schemaVersion': {
              'type': 'integer',
              'enum': [1],
            },
            'title': {'type': 'string', 'description': '≤12 字'},
            'summary': {'type': 'string'},
            'goal': {'type': 'string', 'enum': planGoals.toList()},
            'scene': {'type': 'string', 'enum': profile.scenes.keys.toList()},
            'equipment': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'level': intRange(1, 3),
            'targetMinutes': intRange(lim.minutes.min, lim.minutes.max),
            'avoid': {
              'type': 'array',
              'items': cautions.isEmpty ? {'type': 'string'} : {'type': 'string', 'enum': cautions},
            },
            'blocks': {
              'type': 'array',
              'minItems': 1,
              'items': {
                'type': 'object',
                'properties': {
                  'id': {'type': 'string'},
                  'name': {'type': 'string'},
                  'type': {
                    'type': 'string',
                    'enum': ['warmup', 'main', 'circuit', 'cooldown'],
                  },
                  'rounds': intRange(lim.rounds.min, lim.rounds.max),
                  'restBetweenRoundsSeconds': intRange(
                    lim.restBetweenRoundsSeconds.min,
                    lim.restBetweenRoundsSeconds.max,
                  ),
                  'items': {
                    'type': 'array',
                    'minItems': 1,
                    'items': {
                      'type': 'object',
                      'properties': {
                        'exerciseId': idSchema,
                        'mode': {
                          'type': 'string',
                          'enum': ['reps', 'time'],
                        },
                        'sets': intRange(lim.sets.min, lim.sets.max),
                        'reps': intRange(lim.reps.min, lim.reps.max),
                        'workSeconds': intRange(lim.workSeconds.min, lim.workSeconds.max),
                        'perSide': {'type': 'boolean'},
                        'restSeconds': intRange(lim.restSeconds.min, lim.restSeconds.max),
                        'note': {'type': 'string'},
                      },
                      'required': ['exerciseId', 'mode', 'sets', 'perSide', 'restSeconds'],
                    },
                  },
                },
                'required': ['type', 'items'],
              },
            },
            'notes': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'safetyNotes': {
              'type': 'array',
              'items': {'type': 'string'},
            },
          },
          'required': ['schemaVersion', 'title', 'summary', 'goal', 'scene', 'level', 'targetMinutes', 'blocks'],
        },
      ),
    ];
  }
}
