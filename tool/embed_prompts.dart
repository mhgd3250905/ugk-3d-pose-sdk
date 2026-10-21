// 把 prompts/*.md 嵌进 lib/src/prompt/prompts.g.dart（Flutter / Web 都不用读文件）。
// 改了 prompts/ 下的文件后运行：dart run tool/embed_prompts.dart
// test/prompt_test.dart 会检查生成文件与 md 一致，忘了运行会失败。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

void main() {
  final kernel = File('prompts/kernel.md').readAsStringSync();
  final context = File('prompts/context.md').readAsStringSync();
  final rewrite = File('prompts/rewrite.md').readAsStringSync();
  final kernelV3 = File('prompts/kernel_v3.md').readAsStringSync();
  final agent = File('prompts/agent_kernel.md').readAsStringSync();
  // skills/<name>/SKILL.md → 内置 skill（按名称排序，生成文件稳定）。
  final skillDirs = Directory('skills').listSync().whereType<Directory>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final skills = {
    for (final d in skillDirs)
      if (File('${d.path}/SKILL.md').existsSync())
        d.uri.pathSegments.where((x) => x.isNotEmpty).last: File('${d.path}/SKILL.md').readAsStringSync(),
  };
  String hash(String s) => sha256.convert(utf8.encode(s)).toString().substring(0, 8);
  for (final (n, s) in [
    ('prompts/kernel.md', kernel),
    ('prompts/context.md', context),
    ('prompts/rewrite.md', rewrite),
    ('prompts/kernel_v3.md', kernelV3),
    ('prompts/agent_kernel.md', agent),
    for (final e in skills.entries) ('skills/${e.key}/SKILL.md', e.value),
  ]) {
    if (s.contains("'''")) throw StateError("$n 不能含 '''");
  }
  final out = StringBuffer()
    ..writeln('// 由 tool/embed_prompts.dart 从 prompts/*.md 生成，不要手改。')
    ..writeln('// ignore_for_file: lines_longer_than_80_chars')
    ..writeln()
    ..writeln("const kernelMarkdownHash = '${hash(kernel)}';")
    ..writeln("const contextMarkdownHash = '${hash(context)}';")
    ..writeln("const rewriteMarkdownHash = '${hash(rewrite)}';")
    ..writeln("const kernelV3MarkdownHash = '${hash(kernelV3)}';")
    ..writeln()
    ..writeln("const kernelMarkdown = r'''$kernel''';")
    ..writeln()
    ..writeln("const contextMarkdown = r'''$context''';")
    ..writeln()
    ..writeln("const rewriteMarkdown = r'''$rewrite''';")
    ..writeln()
    ..writeln('/// 工具版内核（0.2）：show_actions / show_plan。')
    ..writeln("const kernelV3Markdown = r'''$kernelV3''';")
    ..writeln()
    ..writeln("const agentKernelMarkdownHash = '${hash(agent)}';")
    ..writeln("const builtinSkillsHash = '${hash(skills.values.join())}';")
    ..writeln()
    ..writeln('/// Agent 版第 1 层系统提示词（0.3）。')
    ..writeln("const agentKernelMarkdown = r'''$agent''';")
    ..writeln()
    ..writeln('/// 内置 skill：`skills/<name>/SKILL.md`（名称 → 全文）。')
    ..writeln('const builtinSkillMarkdown = <String, String>{');
  for (final e in skills.entries) {
    out.writeln("  '${e.key}': r'''${e.value}''',");
  }
  out.writeln('};');
  File('lib/src/prompt/prompts.g.dart').writeAsStringSync(out.toString());
  stdout.writeln('写入 lib/src/prompt/prompts.g.dart（kernel ${hash(kernel)}）');
}
