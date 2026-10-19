/// 拼装一次调用的消息：系统（内核 + profile + 目录表 + 输出格式）+ 裁剪后的历史 + 本轮条件与原话。
///
/// 系统消息只依赖 profile、目录版本与提示词版本，不含本轮条件，
/// 因此同一 App 的连续调用共享前缀，可命中服务端前缀缓存（DeepSeek 缓存价约为原价一折）。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../assistant/conversation.dart';
import '../catalog/catalog.dart';
import '../llm/llm_types.dart';
import '../plan/coach_context.dart';
import '../plan/plan_issue.dart';
import '../profile/coach_profile.dart';
import 'default_prompts.dart';
import 'prompt_template.dart';

class BuiltPrompt {
  const BuiltPrompt({required this.messages, required this.version, required this.hash, required this.system});
  final List<LlmMessage> messages;

  /// `<PromptSet.version>@<profile.id>-<profile.promptVersion>`
  final String version;

  /// 系统消息 sha256 前 12 位：同一版本号下内容是否真的一样。
  final String hash;
  final String system;
}

class PromptBuilder {
  PromptBuilder({PromptSet set = defaultPromptSet, this.overrides = const PromptOverrides(), this.history = const HistoryPolicy()})
    : set = set.apply(overrides);

  final PromptSet set;
  final PromptOverrides overrides;
  final HistoryPolicy history;

  String _systemCacheKey = '';
  String _systemCache = '';

  String version(CoachProfile p) => '${set.version}@${p.id}-${p.promptVersion}';

  /// 系统消息（按 profile+目录版本缓存）。
  String system(CoachProfile profile, Catalog catalog) {
    final key = '${profile.id}|${profile.promptVersion}|${catalog.version}|${identityHashCode(catalog)}';
    if (key == _systemCacheKey) return _systemCache;
    final scope = profile.scope(catalog);
    final l = profile.limits;
    final vars = <String, String>{
      'app_name': profile.appName,
      'profile_focus': profile.focus,
      'profile_rules': [for (final (i, r) in profile.rules.indexed) '${i + 11}. $r'].join('\n'),
      'limit_sets': '${l.sets}',
      'limit_reps': '${l.reps}',
      'limit_work': '${l.workSeconds}',
      'limit_rest': '${l.restSeconds}',
      'limit_rounds': '${l.rounds}',
      'goals': profile.goals.join('|'),
      'catalog_version': catalog.version,
      'catalog_count': '${scope.length}',
      'catalog_table': catalogTable(scope, catalog.taxonomy),
      ...profile.vars,
      ...overrides.vars,
    };
    final text = [
      for (final s in set.sections) PromptTemplate(s.template).render(vars, where: '段 ${s.name}').trim(),
    ].join('\n\n');
    _systemCacheKey = key;
    _systemCache = text;
    return text;
  }

  /// 目录表：一行一个动作，`|` 分隔，尽量省 token。
  static String catalogTable(List<Drill> drills, Taxonomy t) {
    String range(Drill d) {
      final r = d.doseRange;
      final parts = [
        if (r.sets != null) '组${r.sets}',
        if (r.reps != null) '次${r.reps}',
        if (r.seconds != null) '秒${r.seconds}',
        if (r.restSeconds != null) '休${r.restSeconds}',
      ];
      return parts.isEmpty ? '-' : parts.join(' ');
    }

    return [
      for (final d in drills)
        [
          d.id,
          d.name.of(),
          d.purpose.isEmpty ? '-' : _purpose(d),
          d.category,
          d.equipment.isEmpty ? '-' : d.equipment.join(','),
          d.position,
          d.unilateral ? '是' : '否',
          'L${d.level}',
          d.cautions.isEmpty ? '-' : d.cautions.join(','),
          d.scenes.join(','),
          '${d.defaultDose.mode.name} ${d.defaultDose.short} 休${d.defaultDose.restSeconds}',
          range(d),
        ].join('|'),
    ].join('\n');
  }

  /// 作用列去掉重复的动作名前缀（「徒手深蹲，练大腿前侧」→「练大腿前侧」）。
  static String _purpose(Drill d) {
    final n = d.name.of();
    var p = d.purpose;
    if (p.startsWith(n)) p = p.substring(n.length).replaceFirst(RegExp(r'^[，,、\s]+'), '');
    return p.isEmpty ? '-' : p;
  }

  String contextMessage(CoachProfile profile, Catalog catalog, CoachContext c, String userText) {
    final scene = c.scene;
    final rule = scene == null ? null : profile.sceneRule(scene);
    final have = c.availableEquipment(profile);
    String eqLabel(Iterable<String> ids) => ids.isEmpty ? '徒手' : ids.map(catalog.taxonomy.equipmentLabel).join('、');
    final vars = <String, String>{
      'scene': scene == null ? '未知（默认${profile.sceneRule(profile.defaultScene).label ?? profile.defaultScene}，可追问）' : '${rule!.label ?? scene}($scene)',
      'equipment': scene == null && c.equipment.isEmpty
          ? '按场所默认'
          : have == null
          ? '全部'
          : eqLabel(have.toList()..sort()),
      'avoid': c.avoid.isEmpty ? '无' : c.avoid.join('、'),
      'level': c.level == null ? '未知（默认 L1）' : 'L${c.level}',
      'minutes': c.minutes == null ? '未指定' : '${c.minutes} 分钟',
      'goal': c.goal ?? '未指定',
      'notes': c.notes.isEmpty ? '' : c.notes.map((n) => '· $n').join('\n'),
      'user_text': userText.trim(),
      ...profile.vars,
      ...overrides.vars,
    };
    return PromptTemplate(set.contextTemplate).render(vars, where: 'contextTemplate').replaceAll(RegExp(r'\n{2,}'), '\n');
  }

  BuiltPrompt build({
    required CoachProfile profile,
    required Catalog catalog,
    required CoachContext context,
    required String userText,
    CoachConversation? conversation,
  }) {
    final sys = system(profile, catalog);
    final messages = [
      LlmMessage.system(sys),
      if (conversation != null) ...history.select(conversation),
      LlmMessage.user(contextMessage(profile, catalog, context, userText)),
    ];
    return BuiltPrompt(
      messages: messages,
      version: version(profile),
      hash: crypto.sha256.convert(utf8.encode(sys)).toString().substring(0, 12),
      system: sys,
    );
  }

  /// 重写轮：在原消息后追加模型上次的输出和问题清单。
  List<LlmMessage> rewrite(List<LlmMessage> previous, String lastOutput, List<PlanIssue> issues) => [
    ...previous,
    LlmMessage.assistant(lastOutput),
    LlmMessage.user(PromptTemplate(set.rewriteTemplate).render({
      'issues': [for (final i in issues.where((i) => i.isError)) '- ${i.feedbackLine}'].join('\n'),
    }, where: 'rewriteTemplate')),
  ];
}
