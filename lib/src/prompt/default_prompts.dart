/// 内置提示词：`prompts/kernel.md`（与 ai-coach-eval 评测用的同一份）、`context.md`、`rewrite.md`。
/// 改 md 后运行 `dart run tool/embed_prompts.dart`。
library;

import 'prompt_template.dart';
import 'prompts.g.dart';

/// 内核修订号（与 ai-coach-eval 的 kernel v1 / v2 对应）。改 `prompts/kernel.md` 的语义时手动加一。
/// v2（ai-coach-eval c60023f）：plan 先于 text、思考简短、text ≤80 字、equipment 含默认器械。
/// v3：器械未确认时使用徒手，不再按场所假设用户拥有器械。
const kernelRevision = 3;

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
  version: 'kernel-v$kernelRevision-$kernelMarkdownHash.c${contextMarkdownHash.substring(0, 4)}.r${rewriteMarkdownHash.substring(0, 4)}',
  contextTemplate: contextMarkdown,
  rewriteTemplate: rewriteMarkdown,
  names: kernelSectionNames,
);
