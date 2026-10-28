/// Agent 版的只读虚拟文件系统（渐进式披露的第 2、3 层）：由 Pose-Hub 目录 + profile 白名单在内存里生成。
///
/// ```
/// action-library/SKILL.md                 动作库说明、维度与取值、查法
/// action-library/index/<维度>/<取值>.md    短表：id｜名称（中英）｜关键标签｜用途｜默认剂量
/// action-library/details/<动作id>.md       单个动作详情
/// action-library/compact.md               当前 App 的紧凑动作索引（同时内联进系统提示）
/// plan-training/SKILL.md                  排课原则与参数规则
/// action-coaching/SKILL.md                讲动作、纠错
/// user-memory/SKILL.md                    （仅记忆开关开时）
/// <profile.skills[i].name>/SKILL.md       App 专属 skill（及其 files）
/// ```
///
/// 只出现白名单内的动作；目录远程更新后 [SkillFiles.build] 用新目录重建（会话按目录实例缓存）。
library;

import '../catalog/catalog.dart';
import '../profile/coach_profile.dart';
import '../prompt/prompt_builder.dart';
import '../prompt/prompt_template.dart';
import '../prompt/prompts.g.dart';

/// 第 1 层里列出的一个 skill。
class SkillEntry {
  const SkillEntry(this.name, this.description, this.path);
  final String name;
  final String description;

  /// 入口文件（`<name>/SKILL.md`）。
  final String path;
}

class SkillFiles {
  SkillFiles._(this.files, this.skills);

  /// 路径 → 全文。
  final Map<String, String> files;
  final List<SkillEntry> skills;

  static const actionLibrary = 'action-library';
  static const ask = 'ask';
  static const planTraining = 'plan-training';
  static const actionCoaching = 'action-coaching';
  static const userMemory = 'user-memory';
  static const compactPath = '$actionLibrary/compact.md';

  /// 与虚拟文件完全相同的紧凑索引；只有 profile.scope 内的动作。
  String get compactIndex => files[compactPath]!;

  /// 明确的做法/要领问句才预载；匹配仅使用本 App 紧凑索引里的中文名称。
  /// 精确名称优先，泛称最多命中三个动作；未知、id、过度歧义仍按需 read。
  Map<String, String> preloadDetails(String userText) {
    if (RegExp(
      r'计划|方案|排课|安排|一套|展示|看看|看一下|有哪些|推荐|\b(?:plan|routine|workout|show)\b',
      caseSensitive: false,
    ).hasMatch(userText)) {
      return const {};
    }
    final howTo = RegExp(
      r'(?:怎么|如何)(?:正确)?(?:做|练|发力)|有什么要领|动作要点|正确姿势|做法|要领|注意事项|how\s+to\s+(?:do|perform)|how\s+(?:do|should)\s+i\s+(?:do|perform)',
      caseSensitive: false,
    ).firstMatch(userText);
    if (howTo == null) return const {};
    String normalized(String text) => text.toLowerCase().replaceAll(
      RegExp(r'[\s，。！？、,!.?:：()（）「」『』“”]+'),
      '',
    );
    String cleanTopic(String text) => normalized(
      text
          .trim()
          .replaceFirst(
            RegExp(
              r'^(?:(?:请问|请|麻烦|我想知道|我想学|想问|问一下|告诉我|教我|讲讲|讲一下|介绍一下|关于)\s*)+',
            ),
            '',
          )
          .replaceFirst(
            RegExp(r'(?:(?:这个动作|的|呢|吗|呀|啊|一下)\s*)+[？?。.!！\s]*$'),
            '',
          ),
    );
    var topic = cleanTopic(userText.substring(0, howTo.start));
    if (topic.isEmpty) topic = cleanTopic(userText.substring(howTo.end));
    if (topic.length < 2 || RegExp(r'^[a-z0-9_-]+$').hasMatch(topic)) {
      return const {};
    }
    final candidates = <({String id, String name})>[
      for (final line in compactIndex.split('\n').skip(3))
        if (line.split('｜') case final fields when fields.length == 12)
          (id: fields[0], name: normalized(fields[1])),
    ];
    final exact = candidates.where((entry) => entry.name == topic).toList();
    final matches = exact.isNotEmpty
        ? exact
        : candidates.where((entry) => entry.name.contains(topic)).toList();
    if (matches.isEmpty || matches.length > 3) return const {};
    return Map.unmodifiable({
      for (final entry in matches)
        if (read('$actionLibrary/details/${entry.id}.md')
            case final String detail)
          '$actionLibrary/details/${entry.id}.md': detail,
    });
  }

  /// 从已按 profile 渲染的同一份技能模板提取快路径，不复制另一套规则。
  String get fastPaths => [
    for (final name in const [actionLibrary, planTraining, actionCoaching])
      _fastPath(files['$name/SKILL.md']!),
  ].join('\n\n');

  static String _fastPath(String text) {
    const start = '<!-- fast-path:start -->';
    const end = '<!-- fast-path:end -->';
    final from = text.indexOf(start);
    final to = text.indexOf(end, from + start.length);
    if (from < 0 || to < 0) throw StateError('内置技能缺少 fast-path 标记');
    return text.substring(from + start.length, to).trim();
  }

  /// 规范化路径：去掉首尾 `/`、`./`。
  static String normalize(String path) {
    var p = path.trim().replaceAll('\\', '/');
    while (p.startsWith('./')) {
      p = p.substring(2);
    }
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  String? read(String path) => files[normalize(path)];

  /// 列目录：直接子项，子目录带 `/`。目录不存在返回 null。
  List<String>? ls(String dir) {
    final d = normalize(dir);
    final prefix = d.isEmpty ? '' : '$d/';
    final out = <String>{};
    for (final p in files.keys) {
      if (!p.startsWith(prefix)) continue;
      final rest = p.substring(prefix.length);
      final i = rest.indexOf('/');
      out.add(i < 0 ? rest : rest.substring(0, i + 1));
    }
    if (out.isEmpty) return null;
    return out.toList()..sort();
  }

  static SkillFiles build(
    CoachProfile profile,
    Catalog catalog, {
    bool memory = true,
  }) {
    final drills = profile.scope(catalog);
    final files = <String, String>{};
    final skills = <SkillEntry>[];
    final vars = _vars(profile, catalog, drills);

    void addBuiltin(String name) {
      final src = builtinSkillMarkdown[name]!;
      final text = PromptTemplate(
        src,
      ).render(vars, where: 'skills/$name/SKILL.md');
      files['$name/SKILL.md'] = text;
      skills.add(
        SkillEntry(
          name,
          _frontMatter(text, 'description') ?? name,
          '$name/SKILL.md',
        ),
      );
    }

    addBuiltin(ask);
    addBuiltin(actionLibrary);
    addBuiltin(planTraining);
    addBuiltin(actionCoaching);
    if (memory) addBuiltin(userMemory);
    for (final s in profile.skills) {
      if (files.containsKey('${s.name}/SKILL.md')) continue; // 不覆盖内置
      files['${s.name}/SKILL.md'] = s.content;
      for (final e in s.files.entries) {
        files['${s.name}/${normalize(e.key)}'] = e.value;
      }
      skills.add(SkillEntry(s.name, s.description, '${s.name}/SKILL.md'));
    }

    final tax = catalog.taxonomy;
    files[compactPath] = [
      '# 本 App 紧凑动作索引（${drills.length} 个；${catalog.version}）',
      '列：id｜中文名｜部位｜器械｜难度｜注意部位｜类型｜体位｜场所｜默认剂量｜perSide｜禁忌',
      '默认剂量=mode:sets×reps或workSeconds@restSeconds；perSide=1表示true、0表示false，剂量为每侧；-表示无。器械、类型、体位、场所均为原始id。',
      for (final d in drills) compactRow(d, tax),
    ].join('\n');
    final dims = dimensions(catalog);
    final index = <String, Map<String, List<Drill>>>{};
    final scopeIds = {for (final d in drills) d.id};
    for (final d in drills) {
      for (final dim in dims) {
        for (final v in dim.valuesOf(d)) {
          (index.putIfAbsent(dim.id, () => {})[v] ??= []).add(d);
        }
      }
      files['$actionLibrary/details/${d.id}.md'] = detail(
        d,
        tax,
        catalog,
        scope: scopeIds,
      );
    }
    for (final dim in dims) {
      final byValue = index[dim.id] ?? const {};
      for (final e in byValue.entries) {
        final label = dim.label(e.key);
        files['$actionLibrary/index/${dim.id}/${e.key}.md'] = [
          '# ${dim.zh} ${dim.id}=${e.key}：$label（${e.value.length} 个）',
          'id｜名称｜关键标签｜用途｜默认剂量',
          for (final d in e.value) row(d, tax),
        ].join('\n');
      }
    }
    // 维度表写回 action-library/SKILL.md（只列有动作的取值）。
    final lib = files['$actionLibrary/SKILL.md']!;
    files['$actionLibrary/SKILL.md'] = lib.replaceFirst(
      '{{dimensions}}',
      _dimensionTable(dims, index),
    );
    return SkillFiles._(Map.unmodifiable(files), List.unmodifiable(skills));
  }

  static Map<String, String> _vars(
    CoachProfile profile,
    Catalog catalog,
    List<Drill> drills,
  ) {
    final tax = catalog.taxonomy;
    final l = profile.limits;
    return {
      'drillCount': '${drills.length}',
      'catalogVersion': catalog.version,
      'dimensions': '{{dimensions}}', // build() 里替换
      'sceneRules': sceneRules(profile, tax, drills),
      'sceneIds': profile.scenes.keys.join(' / '),
      'goals': profile.goals.join(' / '),
      'cautions': tax.cautions.join('、'),
      'limits':
          'sets ${l.sets}，reps ${l.reps}，workSeconds ${l.workSeconds}，restSeconds ${l.restSeconds}，'
          'rounds ${l.rounds}，restBetweenRoundsSeconds ${l.restBetweenRoundsSeconds}，targetMinutes ${l.minutes}，'
          '整份计划最多 ${l.maxItems} 个动作条目',
    };
  }

  static String sceneRules(
    CoachProfile profile,
    Taxonomy tax,
    List<Drill> drills,
  ) {
    final lines = <String>[];
    for (final e in profile.scenes.entries) {
      final r = e.value;
      final String eq;
      if (r.allEquipment) {
        eq = '默认全部器械都有';
      } else if (r.assumedEquipment.isNotEmpty) {
        eq = '默认有 ${r.assumedEquipment.join('、')}';
      } else {
        eq = '默认没有器械';
      }
      final acc = (r.acceptDrillScenes.isEmpty ? {e.key} : r.acceptDrillScenes)
          .join(' / ');
      final floor = r.forbidFloor
          ? '；不能用着地体位（position 为 ${tax.floorPositions.join('/')}）'
          : '';
      final positions = r.forbidPositions.isEmpty
          ? ''
          : '；禁用体位 ${r.forbidPositions.join('/')}';
      lines.add(
        '  - ${e.key}（${r.label ?? e.key}）：动作场所须含 $acc 之一；$eq$floor$positions。',
      );
    }
    final missing = [
      for (final s in const ['home', 'office', 'gym'])
        if (!profile.scenes.containsKey(s)) s,
    ];
    if (missing.isNotEmpty) {
      lines.add(
        '  - 本 App 不支持场所：${missing.join('、')}。用户在这些场所时说明本 App 不覆盖，不要硬排。',
      );
    }
    return lines.join('\n');
  }

  static String _dimensionTable(
    List<Dimension> dims,
    Map<String, Map<String, List<Drill>>> index,
  ) {
    final out = <String>[];
    for (final dim in dims) {
      final values = index[dim.id];
      if (values == null || values.isEmpty) continue;
      final keys = values.keys.toList()
        ..sort((a, b) => dim.order(a).compareTo(dim.order(b)));
      out.add('- ${dim.id}（${dim.zh} / ${dim.en}）${dim.note}：');
      out.add(
        '  ${[for (final k in keys) '$k=${dim.label(k)}(${values[k]!.length})'].join('，')}',
      );
    }
    return out.join('\n');
  }

  static String? _frontMatter(String text, String key) {
    if (!text.startsWith('---')) return null;
    final end = text.indexOf('\n---', 3);
    if (end < 0) return null;
    for (final line in text.substring(3, end).split('\n')) {
      final i = line.indexOf(':');
      if (i > 0 && line.substring(0, i).trim() == key) {
        return line.substring(i + 1).trim();
      }
    }
    return null;
  }

  static String _dose(Dose d) => d.mode == DoseMode.reps
      ? '${d.sets}×${d.reps}次 休${d.restSeconds}秒'
      : '${d.sets}×${d.seconds}秒 休${d.restSeconds}秒';

  static String _names(Drill d) {
    final zh = d.name.of('zh'), en = d.name.of('en');
    return en.isEmpty || en == zh ? zh : '$zh $en';
  }

  /// 只保留筛选与直接排课需要的字段；长用途、要领、英文名按需读详情。
  static String compactRow(Drill d, Taxonomy tax) {
    String cell(String text) =>
        text.replaceAll(RegExp(r'[\r\n]+'), ' ').replaceAll('｜', '/');
    String values(Iterable<String> items) =>
        items.isEmpty ? '-' : items.map(cell).join(',');
    final dose = d.defaultDose;
    return [
      d.id,
      cell(d.name.of('zh')),
      values(d.muscleGroups.map((g) => tax.muscleGroups[g] ?? g)),
      values(d.equipment),
      '${d.level}',
      values(d.cautions),
      d.category,
      d.position,
      values(d.scenes),
      '${dose.mode.name}:${dose.sets}×${dose.mode == DoseMode.reps ? dose.reps : dose.seconds}@${dose.restSeconds}',
      d.unilateral ? '1' : '0',
      values(d.contraindications),
    ].join('｜');
  }

  /// 索引表一行。
  static String row(Drill d, Taxonomy tax) {
    final tags = [
      tax.categoryLabel(d.category),
      ...d.muscleGroups.map((g) => tax.muscleGroups[g] ?? g),
      d.equipment.isEmpty ? '徒手' : d.equipment.join(','),
      tax.positionLabel(d.position),
      if (d.unilateral) '单侧',
      'L${d.level}',
      d.scenes.join(','),
      if (d.cautions.isNotEmpty) '注意:${d.cautions.join(',')}',
    ];
    return [
      d.id,
      _names(d),
      tags.join(' '),
      d.purpose,
      _dose(d.defaultDose),
    ].join('｜');
  }

  /// 动作详情。给 [scope] 时，范围外的替代动作整行省略（与详情、索引同一白名单）。
  static String detail(
    Drill d,
    Taxonomy tax,
    Catalog catalog, {
    Set<String>? scope,
  }) {
    final r = PromptBuilder.autoRange(d);
    final reps = d.defaultDose.mode == DoseMode.reps;
    final range = [
      'sets ${r.sets}',
      if (reps) 'reps ${r.reps}' else 'workSeconds ${r.seconds}',
      if (r.restSeconds != null) 'restSeconds ${r.restSeconds}',
    ].join('，');
    final cues = d.cues['zh'] ?? d.cues.values.firstOrNull ?? const [];
    final altId =
        d.alternative != null &&
            (scope == null || scope.contains(d.alternative))
        ? d.alternative
        : null;
    final alt = altId == null ? null : catalog[altId];
    return [
      '# ${d.id}｜${_names(d)}',
      '用途：${d.purpose.isEmpty ? '-' : d.purpose}',
      '类型：${d.category}（${tax.categoryLabel(d.category)}）；肌群：${d.muscleGroups.map((g) => '$g（${tax.muscleGroups[g] ?? g}）').join('、')}',
      '器械：${d.equipment.isEmpty ? '徒手' : d.equipment.join('、')}；体位：${d.position}（${tax.positionLabel(d.position)}）；单侧：${d.unilateral ? '是（perSide=true，剂量指每侧）' : '否'}；难度：${d.level}；场所：${d.scenes.join('、')}',
      '默认剂量：${_dose(d.defaultDose)}（mode=${d.defaultDose.mode.name}）；范围：$range',
      if (cues.isNotEmpty) '要领：${cues.join('；')}',
      '注意部位：${d.cautions.isEmpty ? '无' : d.cautions.join('、')}',
      if (d.contraindications.isNotEmpty) '禁忌：${d.contraindications.join('；')}',
      if (altId != null) '替代：$altId${alt == null ? '' : '（${alt.name.of()}）'}',
    ].join('\n');
  }

  /// 动作库的标签维度。
  static List<Dimension> dimensions(Catalog catalog) {
    final tax = catalog.taxonomy;
    final rawTax = catalog.raw['taxonomy'];
    String? en(String dim, String id) {
      if (rawTax is! Map) return null;
      final m = rawTax[dim];
      if (m is! Map) return null;
      final v = m[id];
      return v is Map && v['en'] is String ? v['en'] as String : null;
    }

    String both(String zh, String? e) => e == null || e.isEmpty ? zh : '$zh $e';
    return [
      Dimension(
        'scene',
        '场所',
        'Scene',
        (d) => d.scenes,
        (v) => both(tax.scenes[v] ?? v, en('scenes', v) ?? _sceneEn[v]),
        order: _orderOf(tax.scenes.keys),
      ),
      Dimension(
        'equipment',
        '器械',
        'Equipment',
        (d) => d.equipment.isEmpty ? const ['none'] : d.equipment,
        (v) => v == 'none'
            ? '徒手 Bodyweight'
            : both(tax.equipmentLabel(v), en('equipment', v)),
        note: '，none = 徒手',
        order: _orderOf(['none', ...tax.equipment.keys]),
      ),
      Dimension(
        'muscle',
        '肌群',
        'Muscle group',
        (d) => d.muscleGroups,
        (v) => both(tax.muscleGroups[v] ?? v, en('muscleGroups', v)),
        order: _orderOf(tax.muscleGroups.keys),
      ),
      Dimension(
        'category',
        '类型',
        'Category',
        (d) => [d.category],
        (v) => both(tax.categoryLabel(v), en('categories', v)),
        order: _orderOf(tax.categories.keys),
      ),
      Dimension(
        'level',
        '难度',
        'Level',
        (d) => ['${d.level}'],
        (v) => _levels[v] ?? v,
        order: _orderOf(_levels.keys),
      ),
      Dimension(
        'caution',
        '注意部位',
        'Caution',
        (d) => [for (final c in d.cautions) cautionId(c)],
        (v) => both(_cautionZh[v] ?? v, _cautionEn[v]),
        note: '，列出需要留意该部位的动作，用户要保护时从候选里排除',
        order: _orderOf([for (final c in tax.cautions) cautionId(c)]),
      ),
      Dimension(
        'position',
        '体位',
        'Position',
        (d) => [d.position],
        (v) => both(tax.positionLabel(v), en('positions', v)),
        order: _orderOf(tax.positions.keys),
      ),
      Dimension(
        'unilateral',
        '单侧',
        'Unilateral',
        (d) => [d.unilateral ? 'yes' : 'no'],
        (v) => v == 'yes' ? '单侧（左右各做）Unilateral' : '双侧 Bilateral',
        order: _orderOf(const ['yes', 'no']),
      ),
    ];
  }

  /// 注意部位（目录里是中文）→ 索引文件名用的标准 id；未知的原样返回。
  static String cautionId(String c) => _cautionIds[c] ?? c;

  static const _cautionIds = {
    '膝': 'knee',
    '腰': 'lower-back',
    '肩': 'shoulder',
    '手腕': 'wrist',
    '颈': 'neck',
    '髋': 'hip',
    '大腿内侧': 'inner-thigh',
  };
  static final _cautionZh = {
    for (final e in _cautionIds.entries) e.value: e.key,
  };
  static const _cautionEn = {
    'knee': 'Knee',
    'lower-back': 'Lower back',
    'shoulder': 'Shoulder',
    'wrist': 'Wrist',
    'neck': 'Neck',
    'hip': 'Hip',
    'inner-thigh': 'Inner thigh',
  };
  static const _sceneEn = {'home': 'Home', 'office': 'Office', 'gym': 'Gym'};
  static const _levels = {
    '1': '入门 Beginner',
    '2': '基础 Basic',
    '3': '进阶 Advanced',
  };

  static int Function(String) _orderOf(Iterable<String> keys) {
    final m = <String, int>{};
    for (final k in keys) {
      m.putIfAbsent(k, () => m.length);
    }
    return (v) => m[v] ?? 1 << 20;
  }
}

/// 一个标签维度：索引目录 `index/<id>/`。
class Dimension {
  const Dimension(
    this.id,
    this.zh,
    this.en,
    this.valuesOf,
    this.label, {
    this.note = '',
    required this.order,
  });
  final String id;
  final String zh;
  final String en;
  final Iterable<String> Function(Drill) valuesOf;
  final String Function(String) label;
  final String note;
  final int Function(String) order;
}
