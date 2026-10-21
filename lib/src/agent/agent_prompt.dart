/// Agent 版第 1 层：系统提示词（身份、防破甲、回答风格、skill 列表、工具说明、App 侧重、记忆摘要）与工具定义。
/// 不放动作表，工具 schema 也不放动作 id enum；动作靠模型 read 虚拟文件系统获得。
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
import 'skill_files.dart';
import 'user_memory.dart';

/// Agent 内核修订号。改 `prompts/agent_kernel.md` 或 `skills/` 语义时手动加一。
const agentKernelRevision = 1;

abstract final class AgentTools {
  static const read = 'read';
  static const ls = 'ls';
  static const checkPlan = 'check_plan';
  static const showActions = CoachTools.showActions;
  static const showPlan = CoachTools.showPlan;
  static const remember = 'remember';
  static const forget = 'forget';

  static const finals = {showActions, showPlan};

  static List<LlmTool> build(CoachProfile profile, Catalog catalog, {required bool memory}) {
    final shows = CoachTools.build(profile, catalog, idEnum: false);
    final plan = shows.firstWhere((t) => t.name == showPlan);
    final kinds = [for (final k in MemoryKind.values) k.name];
    return [
      const LlmTool(
        name: read,
        description: '读技能文件系统里的一个文件（如 action-library/SKILL.md、action-library/index/scene/home.md）。',
        parameters: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
          },
          'required': ['path'],
          'additionalProperties': false,
        },
      ),
      const LlmTool(
        name: ls,
        description: '列出技能文件系统某个目录下的文件和子目录（空字符串 = 根目录）。',
        parameters: {
          'type': 'object',
          'properties': {
            'dir': {'type': 'string'},
          },
          'required': ['dir'],
          'additionalProperties': false,
        },
      ),
      LlmTool(
        name: checkPlan,
        description: '交付前自检一份计划（参数与 show_plan 相同）：返回错误清单、估算时长与 targetMinutes 的差。不会展示给用户。',
        parameters: plan.parameters,
      ),
      ...shows,
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
  }
}

class AgentPromptBuilder {
  AgentPromptBuilder({String? kernel, this.canary = defaultPromptCanary, ToolPromptBuilder? context})
    : kernel = kernel ?? agentKernelMarkdown,
      _context = context ?? ToolPromptBuilder(canary: canary);

  /// 第 1 层模板（默认 `prompts/agent_kernel.md`）。
  final String kernel;
  final String canary;
  final ToolPromptBuilder _context;

  String version(CoachProfile p) =>
      'agent-v$agentKernelRevision-$agentKernelMarkdownHash-$builtinSkillsHash@${p.id}-${p.promptVersion}';

  String system(CoachProfile profile, SkillFiles files, {required bool memory, String memorySummary = ''}) {
    final v = profile.vars;
    final labels = {'home': '居家', 'office': '办公室', 'gym': '健身房'};
    return PromptTemplate(kernel).render({
      'appName': profile.appName,
      'canary': canary,
      'defaultMinutes': v['defaultMinutes'] ?? '15',
      'defaultLevel': v['defaultLevel'] ?? '1',
      'defaultSceneLabel': profile.sceneRule(profile.defaultScene).label ?? labels[profile.defaultScene] ?? '居家',
      'skills': [for (final s in files.skills) '- ${s.name} — ${s.description} — ${s.path}'].join('\n'),
      'memoryTools': memory
          ? '- remember / forget：记住或忘掉用户主动提供的训练信息（先读 user-memory/SKILL.md）。\n'
                '- 用户主动陈述稳定的训练信息（水平/经验、家中器械、惯常场所、长期目标、不适/保护部位等）时，必须先用 read 读 user-memory/SKILL.md，再按类别逐条调用 remember；不要把 App 括号中的已知条件或模型推断当作用户新提供的事实，也不要从一次训练请求推断长期习惯或记住「今天」的临时条件。\n'
                '- 例如「我是新手，家里有哑铃」要分别 remember(kind=level, text=新手) 和 remember(kind=equipment, text=家里有哑铃)。只有记忆工具返回 ok=true 后才能确认「记下了」，禁止只口头确认而不调用工具。\n'
                '- 用户只陈述条件、未要求找动作/排计划，且对话中没有待完成的训练请求时：完成记忆后只用一句文字确认已记下、以后排课会参考；本轮不调用 show_actions / show_plan，不擅自按默认值排课。若用户同时明确要求训练，先记下稳定事实，再继续该训练任务。\n'
          : '',
      'focus': [
        for (final x in profile.focus.split('\n'))
          if (x.trim().isNotEmpty) '- $x',
      ].join('\n'),
      'rules': [for (final r in profile.rules) '- $r'].join('\n'),
      'memory': memory && memorySummary.trim().isNotEmpty
          ? '\n# 用户记忆（用户之前主动告诉你的，供参考；与本轮冲突以本轮为准）\n$memorySummary\n'
          : '',
    }, where: 'agent_kernel');
  }

  String hash(String system) => crypto.sha256.convert(utf8.encode(system)).toString().substring(0, 12);

  /// 本轮用户消息：App 已知条件（括号）+ 用户原话（与 0.2 相同）。
  String userMessage(CoachProfile profile, Catalog catalog, CoachContext context, String userText) =>
      _context.userMessage(profile, catalog, context, userText);
}
