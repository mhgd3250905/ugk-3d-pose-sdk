/// 极简模板：`{{name}}` 替换。缺变量直接报错（提示词错了要在开发时就发现，而不是悄悄发给模型）。
library;

class PromptRenderException implements Exception {
  const PromptRenderException(this.message);
  final String message;
  @override
  String toString() => 'PromptRenderException: $message';
}

class PromptTemplate {
  const PromptTemplate(this.source);
  final String source;

  static final _var = RegExp(r'\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}');

  Set<String> get variables => {for (final m in _var.allMatches(source)) m.group(1)!};

  String render(Map<String, String> vars, {String where = 'prompt'}) {
    final missing = variables.where((v) => !vars.containsKey(v)).toList();
    if (missing.isNotEmpty) throw PromptRenderException('$where 缺变量：${missing.join(', ')}');
    return source.replaceAllMapped(_var, (m) => vars[m.group(1)!]!);
  }
}

/// 系统提示词的一段（原样拼接，段尾自带换行）。App 可按 [name] 替换或追加。
class PromptSection {
  const PromptSection(this.name, this.template);
  final String name;
  final String template;
}

/// 一套提示词。[version] 随每次调用记录（改任何一段就升，内置版本带内容哈希）。
class PromptSet {
  const PromptSet({required this.version, required this.sections, required this.contextTemplate, required this.rewriteTemplate});

  /// 按一级标题（`# `）把 markdown 切成段。标题前的部分叫 `intro`；
  /// 其余段名取 [names] 里的映射（标题前缀 → 段名），没有映射就用标题原文。
  factory PromptSet.fromMarkdown(
    String markdown, {
    required String version,
    required String contextTemplate,
    required String rewriteTemplate,
    Map<String, String> names = const {},
  }) {
    final sections = <PromptSection>[];
    final lines = markdown.split('\n');
    var name = 'intro';
    final buf = StringBuffer();
    void flush() {
      if (buf.isNotEmpty) sections.add(PromptSection(name, buf.toString()));
      buf.clear();
    }

    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      if (l.startsWith('# ')) {
        flush();
        final title = l.substring(2).trim();
        name = names.entries.where((e) => title.startsWith(e.key)).map((e) => e.value).firstOrNull ?? title;
      }
      buf.write(l);
      if (i < lines.length - 1) buf.write('\n');
    }
    flush();
    return PromptSet(version: version, sections: sections, contextTemplate: contextTemplate, rewriteTemplate: rewriteTemplate);
  }

  final String version;

  /// 系统消息各段，原样拼接（静态在前、目录在后，利于前缀缓存命中）。
  final List<PromptSection> sections;

  /// 每轮用户消息。变量：`known`（App 已知条件）、`user_text`。没有已知条件时只发原话。
  final String contextTemplate;

  /// 校验失败时追加的用户消息。变量：`issues`。
  final String rewriteTemplate;

  Iterable<String> get sectionNames => sections.map((s) => s.name);

  /// 应用 App 覆盖：替换同名段、追加新段（插在 [PromptOverrides.appendBefore] 段之前，默认目录段之前）。
  PromptSet apply(PromptOverrides o) {
    if (o.isEmpty) return this;
    final unknown = o.replace.keys.where((k) => !sections.any((s) => s.name == k));
    if (unknown.isNotEmpty) throw PromptRenderException('覆盖了不存在的段：${unknown.join(', ')}');
    String ensureBreak(String t) => t.endsWith('\n\n') ? t : (t.endsWith('\n') ? '$t\n' : '$t\n\n');
    final out = <PromptSection>[];
    var appended = false;
    for (final s in sections) {
      if (!appended && s.name == o.appendBefore) {
        out.addAll([for (final a in o.append) PromptSection(a.name, ensureBreak(a.template))]);
        appended = true;
      }
      out.add(o.replace.containsKey(s.name) ? PromptSection(s.name, ensureBreak(o.replace[s.name]!)) : s);
    }
    if (!appended) out.addAll(o.append);
    return PromptSet(
      version: '$version+${o.version}',
      sections: out,
      contextTemplate: o.contextTemplate ?? contextTemplate,
      rewriteTemplate: o.rewriteTemplate ?? rewriteTemplate,
    );
  }
}

/// App 对提示词的定制。
class PromptOverrides {
  const PromptOverrides({
    this.version = 'app',
    this.replace = const {},
    this.append = const [],
    this.appendBefore = 'catalog',
    this.vars = const {},
    this.contextTemplate,
    this.rewriteTemplate,
  });

  /// 进入 promptVersion，如 `hiplab-2`。
  final String version;

  /// 段名 → 新模板。
  final Map<String, String> replace;
  final List<PromptSection> append;

  /// 追加段插在哪一段之前（找不到则放最后）。
  final String appendBefore;

  /// 额外 / 覆盖的模板变量。
  final Map<String, String> vars;
  final String? contextTemplate;
  final String? rewriteTemplate;

  bool get isEmpty =>
      replace.isEmpty && append.isEmpty && vars.isEmpty && contextTemplate == null && rewriteTemplate == null;
}
