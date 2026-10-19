/// 内置提示词：`prompts/kernel.md`（与 ai-coach-eval 评测用的同一份）、`context.md`、`rewrite.md`。
/// 改 md 后运行 `dart run tool/embed_prompts.dart`。
library;

import 'prompt_template.dart';
import 'prompts.g.dart';

/// 段名：intro / rules / composition / focus / output / catalog。
const kernelSectionNames = {
  '硬规则': 'rules',
  '编排原则': 'composition',
  '本 App 侧重': 'focus',
  '输出格式': 'output',
  '动作目录': 'catalog',
};

final PromptSet defaultPromptSet = PromptSet.fromMarkdown(
  kernelMarkdown,
  version: 'kernel-$kernelMarkdownHash.c${contextMarkdownHash.substring(0, 4)}.r${rewriteMarkdownHash.substring(0, 4)}',
  contextTemplate: contextMarkdown,
  rewriteTemplate: rewriteMarkdown,
  names: kernelSectionNames,
);
