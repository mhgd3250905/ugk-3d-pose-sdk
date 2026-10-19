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

/// 系统提示词的一段。按顺序拼接；App 可按 [name] 替换或追加。
class PromptSection {
  const PromptSection(this.name, this.template);
  final String name;
  final String template;
}

/// 一套提示词。[version] 随每次调用记录（改任何一段就升）。
class PromptSet {
  const PromptSet({required this.version, required this.sections, required this.contextTemplate, required this.rewriteTemplate});

  final String version;

  /// 系统消息（静态在前、少变在后，利于前缀缓存命中）。
  final List<PromptSection> sections;

  /// 每轮用户消息：本轮条件 + 用户原话。
  final String contextTemplate;

  /// 校验失败时追加的用户消息。变量：`issues`。
  final String rewriteTemplate;

  PromptSet copyWith({
    String? version,
    List<PromptSection>? sections,
    String? contextTemplate,
    String? rewriteTemplate,
  }) => PromptSet(
    version: version ?? this.version,
    sections: sections ?? this.sections,
    contextTemplate: contextTemplate ?? this.contextTemplate,
    rewriteTemplate: rewriteTemplate ?? this.rewriteTemplate,
  );

  /// 应用 App 覆盖：替换同名段、追加新段、改模板；版本号附上覆盖的版本。
  PromptSet apply(PromptOverrides o) {
    if (o.isEmpty) return this;
    final sections = [
      for (final s in this.sections) o.replace.containsKey(s.name) ? PromptSection(s.name, o.replace[s.name]!) : s,
      ...o.append,
    ];
    final unknown = o.replace.keys.where((k) => !this.sections.any((s) => s.name == k));
    if (unknown.isNotEmpty) throw PromptRenderException('覆盖了不存在的段：${unknown.join(', ')}');
    return PromptSet(
      version: '$version+${o.version}',
      sections: sections,
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
    this.vars = const {},
    this.contextTemplate,
    this.rewriteTemplate,
  });

  /// 进入 promptVersion，如 `hiplab-2`。
  final String version;
  final Map<String, String> replace;
  final List<PromptSection> append;
  final Map<String, String> vars;
  final String? contextTemplate;
  final String? rewriteTemplate;

  bool get isEmpty =>
      replace.isEmpty && append.isEmpty && vars.isEmpty && contextTemplate == null && rewriteTemplate == null;
}
