/// Agent 版第 1 层：系统提示词（身份、防破甲、回答风格、skill 列表、工具说明、App 侧重、记忆摘要）与工具定义。
/// 首轮只含技能索引；动作目录和技能正文在任务开始后按需披露。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../catalog/catalog.dart';
import '../llm/llm_types.dart';
import '../plan/coach_context.dart';
import '../profile/coach_profile.dart';
import '../prompt/prompt_template.dart';
import '../prompt/prompts.g.dart';
import '../prompt/tool_prompt.dart';
import '../tools/coach_tools.dart';
import 'action_tags.dart';
import 'session_params.dart';
import 'session_state.dart';
import 'skill_files.dart';
import 'user_memory.dart';

/// Agent 内核修订号。改 `prompts/agent_kernel.md` 或 `skills/` 语义时手动加一。
const agentKernelRevision = 9;

abstract final class AgentTools {
  static const read = 'read';
  static const ls = 'ls';
  static const setParams = 'set_params';
  static const startTask = 'start_task';
  static const check = 'check';
  static const searchActions = 'search_actions';
  static const getAction = 'get_action';
  static const draftPlan = 'draft_plan';
  static const checkPlan = 'check_plan';
  static const showActions = CoachTools.showActions;
  static const showPlan = CoachTools.showPlan;
  static const remember = 'remember';
  static const forget = 'forget';
  static const askUser = 'ask_user';

  static const finals = {showActions, showPlan, askUser};

  static List<LlmTool> build(
    CoachProfile profile,
    Catalog catalog, {
    required bool memory,
    bool includeCheckPlan = true,
    CoachSessionState? sessionState,
    String language = 'zh',
  }) {
    final kinds = [for (final k in MemoryKind.values) k.name];
    final tags = ActionTags(profile, catalog);
    final en = language.toLowerCase().startsWith('en');
    final equipmentCodes = SessionParams(
      tags,
    ).equipmentCodes(sessionState ?? CoachSessionState());
    Map<String, Object?> parameter(
      Map<String, Object?> value, {
      bool derived = false,
      bool direction = false,
    }) => {
      'type': 'object',
      'properties': {
        'value': value,
        'source': {
          'type': 'string',
          'enum': [
            for (final source in SessionParams.sources)
              if (derived || source != 'derived') source,
          ],
        },
        'quote': {'type': 'string', 'maxLength': 30},
        if (direction)
          'direction': {
            'type': 'string',
            'enum': ['shorter', 'longer'],
          },
      },
      'required': ['value', 'source'],
      'additionalProperties': false,
    };
    Map<String, Object?> codes(List<String> values) => {
      'type': 'array',
      'items': {'type': 'string', 'enum': values},
      'uniqueItems': true,
    };
    final tools = [
      const LlmTool(
        name: startTask,
        description: '开始推荐或计划并自动完成理解节点；完成推荐后转计划默认复用。',
        parameters: {
          'type': 'object',
          'properties': {
            'type': {
              'type': 'string',
              'enum': ['recommend', 'plan'],
            },
            'reuse': {'type': 'boolean'},
          },
          'required': ['type'],
          'additionalProperties': false,
        },
      ),
      const LlmTool(
        name: check,
        description: '可选复查节点；已完成则返回当前状态。动作节点可提供已搜索的 picks。',
        parameters: {
          'type': 'object',
          'properties': {
            'node': {
              'type': 'string',
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
        },
      ),
      const LlmTool(
        name: read,
        description:
            '读技能文件系统里的一个文件（如 action-library/SKILL.md、action-library/index/scene/home.md）。',
        parameters: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
          },
          'required': ['path'],
          'additionalProperties': false,
        },
      ),
      LlmTool(
        name: searchActions,
        description:
            '先 start_task；purpose/body/pose/level 同类或、跨类且；按场景、器材、伤痛过滤。默认不加 level，仅用户说明水平或 limits 需要时加。',
        parameters: {
          'type': 'object',
          'properties': {
            'tags': codes(tags.tags),
            'keywords': {'type': 'string'},
            'limit': {'type': 'integer', 'minimum': 1, 'maximum': 20},
          },
          'required': ['tags'],
          'additionalProperties': false,
        },
      ),
      const LlmTool(
        name: getAction,
        description: '批量查看动作要领与禁忌；大多数情况不需要调用。',
        parameters: {
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
        },
      ),
      const LlmTool(
        name: draftPlan,
        description:
            '自动完成动作、规划和核对；通过后直接 show_plan。修改沿用任务，整体换用 replace_all，局部用 edit。',
        parameters: {
          'type': 'object',
          'properties': {
            'plan_id': {'type': 'string'},
            'operation': {
              'type': 'string',
              'enum': ['edit', 'replace_all'],
            },
            'title': {'type': 'string'},
            'blocks': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'kind': {
                    'type': 'string',
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
        },
      ),
      LlmTool(
        name: setParams,
        description:
            '记条件并自动打卡；user 引用原话，preselect 用习惯，default 明示默认。低来源覆盖高来源时 kept；推测场景用 derived+quote，相对时长带 direction；host 由宿主写入。',
        parameters: {
          'type': 'object',
          'properties': {
            'fields': {
              'type': 'object',
              'minProperties': 1,
              'additionalProperties': false,
              'properties': {
                'scene': parameter({
                  'type': 'string',
                  'enum': SessionParams(tags).sceneCodes,
                }, derived: true),
                'goal': parameter(codes(tags.goalCodes)),
                'equipment': parameter(codes(equipmentCodes)),
                'equipment_exclude': {
                  ...parameter(codes(equipmentCodes)),
                  'properties': {
                    'value': {
                      'type': 'array',
                      'items': {'type': 'string'},
                      'uniqueItems': true,
                    },
                    'source': {
                      'type': 'string',
                      'enum': ['user'],
                    },
                    'quote': {'type': 'string', 'maxLength': 30},
                  },
                  'required': ['value', 'source', 'quote'],
                },
                'minutes': parameter(
                  {'type': 'integer', 'minimum': 1},
                  derived: true,
                  direction: true,
                ),
                'level': parameter({
                  'type': 'integer',
                  'enum': [1, 2, 3],
                }),
                'limits': parameter(codes(tags.limitCodes)),
              },
            },
          },
          'required': ['fields'],
          'additionalProperties': false,
        },
      ),
      if (includeCheckPlan)
        const LlmTool(
          name: checkPlan,
          description: '可选复核最新计划；draft_plan 已自动核对，通过后直接 show_plan。',
          parameters: {
            'type': 'object',
            'properties': {
              'plan_id': {'type': 'string'},
            },
            'required': ['plan_id'],
            'additionalProperties': false,
          },
        ),
      LlmTool(
        name: showActions,
        description: '交付动作卡并自动打卡；每项须命中目标部位，数量按候选池。note 用一两句说明思路，超长截断。',
        parameters: {
          'type': 'object',
          'properties': {
            'ids': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'note': {
              'type': 'string',
              'minLength': 1,
              'description': en ? 'At most 2 sentences and 45 words' : '最多120字',
            },
          },
          'required': ['ids', 'note'],
          'additionalProperties': false,
        },
      ),
      LlmTool(
        name: showPlan,
        description: '交付已通过核对的最新计划卡；note 用一两句说明安排思路。',
        parameters: {
          'type': 'object',
          'properties': {
            'plan_id': {'type': 'string'},
            'note': {
              'type': 'string',
              'minLength': 1,
              'description': en ? 'At most 2 sentences and 45 words' : '最多120字',
            },
          },
          'required': ['plan_id', 'note'],
          'additionalProperties': false,
        },
      ),
      LlmTool(
        name: askUser,
        description: '由模型决定是否需要澄清。调用后暂停，用户回答后继续；不要重问已有条件。',
        parameters: {
          'type': 'object',
          'properties': {
            'question': {
              'type': 'string',
              'minLength': 1,
              'description': '简短口语，一次补齐缺项',
            },
            'mode': {
              'type': 'string',
              'enum': ['text', 'choice', 'form'],
            },
            'options': {
              'type': 'array',
              'items': {
                'type': 'string',
                'minLength': 1,
                if (en) 'description': 'At most 12 words' else 'maxLength': 12,
              },
              'minItems': 2,
              'maxItems': 6,
              'uniqueItems': true,
              'description': '仅 choice 模式提供，2–6 个短选项',
            },
            'multiple': {
              'type': 'boolean',
              'default': false,
              'description': '仅 choice 模式提供，是否多选',
            },
            'fields': {
              'type': 'array',
              'minItems': 1,
              'maxItems': 3,
              'description': '仅旧版 form：scene/equipment/minutes 分组，器械选项来自当前动作库',
              'items': {
                'type': 'object',
                'properties': {
                  'key': {
                    'type': 'string',
                    'enum': ['scene', 'equipment', 'minutes'],
                  },
                  'label': {
                    'type': 'string',
                    if (en) 'description': 'At most 6 words',
                  },
                  'options': {
                    'type': 'array',
                    'minItems': 2,
                    'maxItems': 64,
                    'items': {
                      'type': 'string',
                      if (en)
                        'description': 'At most 24 words'
                      else
                        'maxLength': 24,
                    },
                  },
                  'multiple': {'type': 'boolean'},
                },
                'required': ['key', 'label', 'options', 'multiple'],
                'additionalProperties': false,
              },
            },
            'skipLabel': {
              'type': 'string',
              'enum': [en ? 'Show suggestions' : '直接出方案'],
            },
          },
          'required': ['question', 'mode'],
          'additionalProperties': false,
        },
      ),
      if (memory) ...[
        LlmTool(
          name: remember,
          description: '记住用户主动提供的一条训练相关信息（先读 user-memory/SKILL.md）。',
          parameters: {
            'type': 'object',
            'properties': {
              'kind': {'type': 'string', 'enum': kinds},
              'text': {'type': 'string', 'description': '一句短话，用用户的说法'},
            },
            'required': ['kind', 'text'],
            'additionalProperties': false,
          },
        ),
        LlmTool(
          name: forget,
          description: '忘掉一条或一类记忆：给 text 删匹配的条目；只给 kind 删整类。',
          parameters: {
            'type': 'object',
            'properties': {
              'kind': {'type': 'string', 'enum': kinds},
              'text': {'type': 'string'},
            },
            'additionalProperties': false,
          },
        ),
      ],
    ];
    return [
      for (final tool in tools)
        LlmTool(
          name: tool.name,
          description: tool.description,
          parameters: compactEnumSchema(tool.parameters),
        ),
    ];
  }
}

/// An enum of homogeneous primitives already enforces its primitive type.
/// Removing only that redundant keyword preserves every accepted value and
/// every description, including provenance and safety constraints.
Map<String, Object?> compactEnumSchema(Map<String, Object?> schema) {
  Object? visit(Object? value) {
    if (value is List) return [for (final item in value) visit(item)];
    if (value is! Map) return value;
    final choices = value['enum'];
    final type = value['type'];
    final redundant =
        choices is List &&
        choices.isNotEmpty &&
        choices.every(
          (v) =>
              type == 'string' && v is String ||
              type == 'integer' && v is int ||
              type == 'boolean' && v is bool ||
              type == 'number' && v is num,
        );
    return <String, Object?>{
      for (final entry in value.entries)
        if (!(entry.key == 'type' && redundant))
          entry.key as String:
              const {'enum', 'const', 'default', 'examples'}.contains(entry.key)
              ? entry.value
              : visit(entry.value),
    };
  }

  return visit(schema)! as Map<String, Object?>;
}

class AgentPromptBuilder {
  AgentPromptBuilder({
    String? kernel,
    this.canary = defaultPromptCanary,
    ToolPromptBuilder? context,
  }) : kernel = kernel ?? agentKernelMarkdown,
       _context = context ?? ToolPromptBuilder(canary: canary);

  /// 第 1 层模板（默认 `prompts/agent_kernel.md`）。
  final String kernel;
  final String canary;
  final ToolPromptBuilder _context;

  String version(CoachProfile p) =>
      'agent-v$agentKernelRevision-$agentKernelMarkdownHash-$builtinSkillsHash@${p.id}-${p.promptVersion}';

  String system(
    CoachProfile profile,
    SkillFiles files, {
    required bool memory,
    String memorySummary = '',
    String userText = '',
    int questionsAsked = 0,
    String trainingParameters = '',
    String locale = 'zh',
  }) {
    final v = profile.vars;
    final labels = {'home': '居家', 'office': '办公室', 'gym': '健身房'};
    return PromptTemplate(kernel).render({
      'appName': profile.appName,
      'locale': locale,
      'canary': canary,
      'defaultMinutes': v['defaultMinutes'] ?? '15',
      'defaultLevel': v['defaultLevel'] ?? '1',
      'defaultSceneLabel':
          profile.sceneRule(profile.defaultScene).label ??
          labels[profile.defaultScene] ??
          '居家',
      'skills': [
        for (final s in files.skills)
          '- ${s.name} — ${s.description.replaceAll('\r', ' ').replaceAll('\n', ' ')} — ${s.path}',
      ].join('\n'),
      'fastPaths': '',
      'actionIndex': '',
      'questionProgress': '',
      'trainingParameters': '',
      'preloadedDetails': '',
      'memoryTools': memory ? '- 记忆工具先读 user-memory/SKILL.md；成功后才确认。\n' : '',
      'focus': [
        for (final x in profile.focus.split('\n'))
          if (x.trim().isNotEmpty) '- $x',
      ].take(1).join('\n'),
      'rules': [for (final r in profile.rules) '- $r'].join('\n'),
      'memory': memory && memorySummary.trim().isNotEmpty
          ? '\n# 用户记忆\n$memorySummary\n'
          : '',
    }, where: 'agent_kernel');
  }

  String hash(String system) =>
      crypto.sha256.convert(utf8.encode(system)).toString().substring(0, 12);

  /// 本轮用户消息：App 已知条件（括号）+ 用户原话（与 0.2 相同）。
  String userMessage(
    CoachProfile profile,
    Catalog catalog,
    CoachContext context,
    String userText,
  ) => _context.userMessage(profile, catalog, context, userText);
}
