/// 拼装一次调用的消息：系统（内核 + profile + 目录表）+ 裁剪后的历史 + 本轮（App 已知条件 + 用户原话）。
///
/// 系统消息与 ai-coach-eval `tools/build_prompt.py` 逐字节一致（test/prompt_test.dart 金样对照），
/// 评测结论可直接用于 SDK。系统消息只依赖 profile、目录与提示词版本、不含本轮条件，
/// 同一 App 的连续调用共享前缀，可命中服务端前缀缓存（DeepSeek 命中价约为原价一折）。
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

  /// 系统消息 sha256 前 12 位：同一版本号下内容是否真的一样（目录版本不同哈希也不同）。
  final String hash;
  final String system;
}

class PromptBuilder {
  PromptBuilder({PromptSet? set, this.overrides = const PromptOverrides(), this.history = const HistoryPolicy()})
    : set = (set ?? defaultPromptSet).apply(overrides);

  final PromptSet set;
  final PromptOverrides overrides;
  final HistoryPolicy history;

  Object? _cacheKey;
  String _cache = '';

  String version(CoachProfile p) => '${set.version}@${p.id}-${p.promptVersion}';

  /// 模板可用的变量（与 build_prompt.py 同名）。
  Map<String, String> variables(CoachProfile profile, Catalog catalog) {
    final drills = profile.scope(catalog);
    final tax = catalog.taxonomy;
    final v = profile.vars;
    return {
      'appName': profile.appName,
      'defaultMinutes': v['defaultMinutes'] ?? '15',
      'defaultLevel': v['defaultLevel'] ?? '1',
      'defaultSceneLabel': _sceneLabels[profile.defaultScene] ?? '居家',
      'cautions': tax.cautions.join('、'),
      'sceneRules': sceneRulesText(profile, tax, drills),
      'sceneIds': profile.scenes.keys.join(' / '),
      'sceneEnum': profile.scenes.keys.join('|'),
      'goalEnum': profile.goals.join('|'),
      'focus': [for (final x in profile.focus.split('\n')) if (x.trim().isNotEmpty) '- $x'].join('\n'),
      'rules': [for (final r in profile.rules) '- $r'].join('\n'),
      'drillCount': '${drills.length}',
      'table': [for (final d in drills) catalogRow(d)].join('\n'),
      'catalogVersion': catalog.version,
      ...v,
      ...overrides.vars,
    };
  }

  /// 系统消息（按 profile + 目录实例缓存）。
  String system(CoachProfile profile, Catalog catalog) {
    final key = (profile, catalog);
    if (key == _cacheKey) return _cache;
    final vars = variables(profile, catalog);
    final text = [for (final s in set.sections) PromptTemplate(s.template).render(vars, where: '段 ${s.name}')].join();
    _cacheKey = key;
    _cache = text;
    return text;
  }

  static const _sceneLabels = {'home': '居家', 'office': '办公室', 'gym': '健身房'};
  static const _catShort = {'strength': '力量', 'core': '核心', 'cardio': '有氧', 'mobility': '活动', 'stretch': '拉伸'};
  static const _muscleShort = {
    'deltoids': '三角肌', 'rotator-cuff': '肩袖', 'triceps': '肱三头', 'biceps': '肱二头', 'forearms': '前臂',
    'serratus': '前锯肌', 'scapular': '中下斜方', 'chest': '胸', 'lats': '背阔', 'abs': '腹直', 'obliques': '腹斜',
    'erectors': '竖脊', 'hip-flexors': '髋屈', 'glute-max': '臀大', 'hip-abductors': '臀中', 'adductors': '内收',
    'quadriceps': '股四', 'hamstrings': '腘绳', 'calves': '小腿', 'tibialis': '胫前',
  };
  static const _posShort = {
    'standing': '站', 'seated': '坐', 'supine': '仰卧*', 'prone': '俯*', 'quadruped': '四足*', 'kneeling': '跪*',
    'side_lying': '侧卧*', 'support': '器械撑', 'hanging': '悬垂',
  };
  static const _sceneShort = {'home': '家', 'office': '办', 'gym': '馆'};

  /// 目录表一行：`id|名称|类型|肌群|器械|体位|单侧|难度|场所|默认|范围|注意|用途`。
  static String catalogRow(Drill d) {
    final dd = d.defaultDose;
    final r = autoRange(d);
    final reps = dd.mode == DoseMode.reps;
    final dose = reps ? '${dd.sets}×${dd.reps}次 休${dd.restSeconds}' : '${dd.sets}×${dd.seconds}秒 休${dd.restSeconds}';
    final rng = reps
        ? '组${r.sets!.min}-${r.sets!.max} 次${r.reps!.min}-${r.reps!.max}'
        : '组${r.sets!.min}-${r.sets!.max} 秒${r.seconds!.min}-${r.seconds!.max}';
    return [
      d.id,
      d.name.of(),
      _catShort[d.category] ?? d.category,
      d.muscleGroups.map((g) => _muscleShort[g] ?? g).join(','),
      d.equipment.isEmpty ? '-' : d.equipment.join(','),
      _posShort[d.position] ?? d.position,
      d.unilateral ? '单' : '',
      '${d.level}',
      d.scenes.map((s) => _sceneShort[s] ?? s).join(','),
      dose,
      rng,
      d.cautions.isEmpty ? '-' : d.cautions.join(','),
      d.purpose,
    ].join('|');
  }

  /// 动作的 doseRange；目录没给就按 Pose-Hub build_catalog.py 的默认规则推出来。
  static DoseRange autoRange(Drill d) {
    final dd = d.defaultDose;
    final r = d.doseRange;
    int clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);
    // Python round()：四舍六入五取偶，与 build_catalog.py 保持一致。
    int pyRound(double x) {
      final f = x.floorToDouble();
      final diff = x - f;
      if (diff > 0.5) return f.toInt() + 1;
      if (diff < 0.5) return f.toInt();
      return f.toInt().isEven ? f.toInt() : f.toInt() + 1;
    }
    final sets = r.sets ?? IntRange(1, clamp(dd.sets + 1, 1, 6));
    if (dd.mode == DoseMode.reps) {
      final n = dd.reps ?? 10;
      return DoseRange(
        sets: sets,
        reps: r.reps ?? IntRange(clamp(pyRound(n * 0.5), 1, 30), clamp(n + 2 > pyRound(n * 1.5) ? n + 2 : pyRound(n * 1.5), 1, 30)),
        restSeconds: r.restSeconds,
      );
    }
    final s = dd.seconds ?? 30;
    return DoseRange(
      sets: sets,
      seconds: r.seconds ?? IntRange(clamp(pyRound(s * 0.5), 10, 120), clamp(s * 2, 10, 120)),
      restSeconds: r.restSeconds,
    );
  }

  static String sceneRulesText(CoachProfile profile, Taxonomy tax, List<Drill> drills) {
    final lines = <String>[];
    for (final e in profile.scenes.entries) {
      final sid = e.key, r = e.value;
      final label = r.label ?? sid;
      const eq = '器械未确认时只用徒手';
      final acc = (r.acceptDrillScenes.isEmpty ? [sid] : r.acceptDrillScenes).map((s) => _sceneShort[s] ?? s).join('、');
      final extra = r.forbidFloor ? '；不能用着地体位（体位带 * 的：仰卧/俯/四足/跪/侧卧）' : '';
      lines.add('   - $sid（$label）：只用「场所」列含「$acc」的动作；$eq$extra。');
    }
    final missing = [for (final s in const ['home', 'office', 'gym']) if (!profile.scenes.containsKey(s)) s];
    if (missing.isNotEmpty) {
      lines.add('   - 本 App 不支持场所：${missing.map((s) => _sceneLabels[s]).join('、')}。用户在这些场所时，说明本 App 不覆盖，不要硬排。');
    }
    final used = {for (final d in drills) ...d.equipment};
    final legend = [for (final e in tax.equipment.entries) if (used.contains(e.key)) '${e.key}=${e.value}'].join('、');
    lines.add('   - 器械 id：$legend。');
    return lines.join('\n');
  }

  /// App 已知的本轮条件，一行；什么都不知道时返回空串（只发用户原话，与评测一致）。
  String knownConditions(CoachProfile profile, Catalog catalog, CoachContext c) {
    final tax = catalog.taxonomy;
    final parts = <String>[
      if (c.scene != null) '场所 ${profile.sceneRule(c.scene!).label ?? _sceneLabels[c.scene] ?? c.scene}（${c.scene}）',
      if (c.equipment != null)
        c.equipment!.isEmpty ? '没有器械（徒手）' : '可用器械 ${c.equipment!.map((q) => '$q（${tax.equipmentLabel(q)}）').join('、')}',
      if (c.avoid.isNotEmpty) '要保护 ${c.avoid.join('、')}',
      if (c.level != null) '水平 ${c.level}',
      if (c.minutes != null) '时长 ${c.minutes} 分钟',
      if (c.goal != null) '目标 ${c.goal}',
      ...c.notes,
    ];
    return parts.join('；');
  }

  String contextMessage(CoachProfile profile, Catalog catalog, CoachContext c, String userText) {
    final known = knownConditions(profile, catalog, c);
    if (known.isEmpty) return userText.trim();
    return PromptTemplate(set.contextTemplate)
        .render({...overrides.vars, 'known': known, 'user_text': userText.trim()}, where: 'contextTemplate');
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

  /// 上次输出疑似被截断时追加的一行（与评测 format_feedback 一致）。
  static const truncationHint = '（上次输出被截断了：少想一点，直接输出紧凑的 JSON，不要换行缩进。）';

  static bool _looksTruncated(PlanIssue i) =>
      i.isError && i.code == IssueCodes.notJson && (i.message.contains('没有闭合') || i.message.contains('没有 JSON'));

  /// 重写轮：在原消息后追加模型上次的输出和错误清单（`- E_DOSE 消息`，与评测 format_feedback 一致；
  /// 疑似截断时再加一行「少想一点、输出紧凑 JSON」）。
  List<LlmMessage> rewrite(List<LlmMessage> previous, String lastOutput, List<PlanIssue> issues) => [
    ...previous,
    LlmMessage.assistant(lastOutput),
    LlmMessage.user(PromptTemplate(set.rewriteTemplate).render({
      ...overrides.vars,
      'issues': [
        for (final i in issues.where((i) => i.isError)) '- ${i.category} ${i.message}',
        if (issues.any(_looksTruncated)) truncationHint,
      ].join('\n'),
    }, where: 'rewriteTemplate')),
  ];
}
