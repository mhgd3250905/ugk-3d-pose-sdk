/// 工具版提示词（内核 v3）：系统消息 = `prompts/kernel_v3.md` 按 profile + 目录渲染；
/// 本轮条件放在用户消息开头（与 0.1 的 contextTemplate 相同），系统消息不随轮次变化，利于前缀缓存。
/// 与评测 `eval/tools/build_prompt.py --v3` 逐字节一致（test/tools_test.dart 金样对照）。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../catalog/catalog.dart';
import '../llm/llm_types.dart';
import '../plan/coach_context.dart';
import '../profile/coach_profile.dart';
import '../tools/coach_tools.dart';
import 'prompt_builder.dart';
import 'prompt_template.dart';
import 'prompts.g.dart';

/// 内核修订号。改 `prompts/kernel_v3.md` 的语义时手动加一（v3.x 记在 CHANGELOG）。
const kernelV3Revision = 4;

/// 提示词暗号默认值：写进系统消息并要求模型永不输出；回复或工具参数里出现即视为泄露，整轮丢弃改回落。
const defaultPromptCanary = 'UGK-CANARY-7F3K9Q';

final PromptSet defaultToolPromptSet = PromptSet.fromMarkdown(
  kernelV3Markdown,
  version: 'kernel-v$kernelV3Revision-$kernelV3MarkdownHash',
  contextTemplate: contextMarkdown,
  rewriteTemplate: rewriteMarkdown,
  names: const {
    '防破甲': 'guard',
    '回答方式': 'answer',
    '何时用哪个工具': 'tools',
    '参数规则': 'rules',
    '被打回时': 'resubmit',
    '多轮修改': 'multiturn',
    'App 配置': 'catalog',
    '用户上下文': 'context',
  },
);

class ToolPromptBuilder {
  ToolPromptBuilder({
    PromptSet? set,
    PromptOverrides overrides = const PromptOverrides(),
    this.canary = defaultPromptCanary,
  }) : set = (set ?? defaultToolPromptSet).apply(overrides),
       _overrides = overrides {
    _base = PromptBuilder(
      set: this.set,
      overrides: PromptOverrides(vars: {...overrides.vars, 'canary': canary}, version: overrides.version),
    );
  }

  final PromptSet set;
  final String canary;
  final PromptOverrides _overrides;
  late final PromptBuilder _base;

  PromptOverrides get overrides => _overrides;

  String version(CoachProfile p) => '${set.version}@${p.id}-${p.promptVersion}';

  /// 系统消息（按 profile + 目录实例缓存）。
  String system(CoachProfile profile, Catalog catalog) => _base.system(profile, catalog);

  String hash(CoachProfile profile, Catalog catalog) =>
      crypto.sha256.convert(utf8.encode(system(profile, catalog))).toString().substring(0, 12);

  /// 本轮用户消息：App 已知条件（括号）+ 用户原话。
  String userMessage(CoachProfile profile, Catalog catalog, CoachContext context, String userText) =>
      _base.contextMessage(profile, catalog, context, userText);

  List<LlmTool> tools(CoachProfile profile, Catalog catalog) => CoachTools.build(profile, catalog);
}
