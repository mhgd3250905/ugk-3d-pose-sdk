/// find_actions：硬过滤（场景、器械、避开部位/冲击/躺地）+ 打分排序（主动肌、目的、难度、别名分词），
/// 返回前 N 个，每个带一句代码生成的理由。
library;

import 'qa_action.dart';
import 'qa_lexicon.dart';

const muscleZh = <String, String>{
  'abs': '腹部', 'obliques': '侧腹', 'erectors': '下背', 'glute-max': '臀大肌', 'hip-abductors': '臀中肌',
  'quadriceps': '大腿前侧', 'hamstrings': '大腿后侧', 'adductors': '大腿内侧', 'calves': '小腿', 'chest': '胸',
  'triceps': '三头', 'biceps': '二头', 'deltoids': '肩', 'lats': '背阔', 'scapular': '上背', 'hip-flexors': '髋前侧',
  'rotator-cuff': '肩袖', 'serratus': '前锯肌', 'forearms': '前臂', 'tibialis': '小腿前侧', 'neck': '颈部',
  'upper-traps': '肩颈', 'hip-rotators': '髋外旋', 'peroneals': '小腿外侧',
};

const muscleEn = <String, String>{
  'abs': 'abs', 'obliques': 'obliques', 'erectors': 'lower back', 'glute-max': 'glutes', 'hip-abductors': 'side glutes',
  'quadriceps': 'quads', 'hamstrings': 'hamstrings', 'adductors': 'inner thighs', 'calves': 'calves', 'chest': 'chest',
  'triceps': 'triceps', 'biceps': 'biceps', 'deltoids': 'shoulders', 'lats': 'lats', 'scapular': 'upper back',
  'hip-flexors': 'hip flexors', 'rotator-cuff': 'rotator cuff', 'serratus': 'serratus', 'forearms': 'forearms',
  'tibialis': 'shins', 'neck': 'neck', 'upper-traps': 'neck & traps', 'hip-rotators': 'hip rotators', 'peroneals': 'outer calves',
};

const jointZh = {'knee': '膝盖', 'shoulder': '肩', 'lumbar': '腰', 'wrist': '手腕', 'neck': '颈', 'ankle': '脚踝', 'hip': '髋'};

/// 各场景默认就有的环境物（不算「器械」）。
const ambientEquipment = <String, Set<String>>{
  'home': {'mat', 'wall', 'chair', 'towel', 'doorframe', 'book', 'water-bottle', 'backpack', 'stairs'},
  'hotel': {'wall', 'chair', 'towel', 'doorframe', 'book', 'water-bottle', 'backpack', 'mat'},
  'office': {'chair', 'wall', 'doorframe', 'book', 'water-bottle', 'backpack'},
  'outdoor': {'wall', 'stairs', 'bench', 'pullup-bar'},
  'gym': {'*'},
};

const _softEquipment = {'mat', 'slider', 'block', 'bench', 'chair', 'towel', 'wall', 'parallettes', 'doorframe', 'stairs'};
const _majorMuscles = {'quadriceps', 'glute-max', 'hamstrings', 'chest', 'lats', 'abs', 'deltoids'};

/// 一次 find_actions 的完整条件（场景/器械已解析好）。
final class QaQuery {
  QaQuery({
    required this.scene,
    required this.equipment,
    this.muscles = const {},
    this.stretchMuscles = const {},
    this.types = const {},
    this.goals = const {},
    this.roles = const {},
    this.keywords = const [],
    this.avoidJoints = const {},
    this.noFloor = false,
    this.smallSpace = false,
    this.strict = false,
    this.maxImpact,
    this.maxDifficulty,
    this.targetDifficulty = 2,
    this.lowIntensity = false,
    this.preferEquipment = const {},
    this.exclude = const {},
    this.limit = 8,
  });

  final String scene;

  /// 用户额外可用的器械（不含场景环境物）。
  final Set<String> equipment;
  final Set<String> muscles;
  final Set<String> stretchMuscles;
  final Set<String> types;
  final Set<String> goals;
  final Set<String> roles;
  final List<String> keywords;
  final Set<String> avoidJoints;
  final bool noFloor;
  final bool smallSpace;

  /// 用户圈定过范围（答过地点/器械）：只能用 [equipment] 里的器械，不算环境物、不接受替代；
  /// 健身房不限场景和器械；办公室只到椅子 + 徒手、不躺地。
  final bool strict;
  final String? maxImpact;
  final int? maxDifficulty;
  final int targetDifficulty;
  final bool lowIntensity;

  /// 用户点名的器械：用到的加分。
  final Set<String> preferEquipment;
  final Set<String> exclude;
  final int limit;

  Map<String, Object?> toJson() => {
    'scene': scene,
    if (equipment.isNotEmpty) 'equipment': equipment.toList(),
    if (muscles.isNotEmpty) 'muscles': muscles.toList(),
    if (stretchMuscles.isNotEmpty) 'stretchMuscles': stretchMuscles.toList(),
    if (types.isNotEmpty) 'types': types.toList(),
    if (goals.isNotEmpty) 'goals': goals.toList(),
    if (roles.isNotEmpty) 'roles': roles.toList(),
    if (keywords.isNotEmpty) 'keywords': keywords,
    if (avoidJoints.isNotEmpty) 'avoidJoints': avoidJoints.toList(),
    if (noFloor) 'noFloor': true,
    if (maxImpact != null) 'maxImpact': maxImpact,
    if (maxDifficulty != null) 'maxDifficulty': maxDifficulty,
  };
}

final class QaHit {
  QaHit(this.action, this.score, this.reasons);
  final QaAction action;
  final double score;
  final List<String> reasons;
  String get reason => reasons.join('，');
}

final class QaFinder {
  QaFinder(this.index);
  final QaActionIndex index;

  /// 硬过滤：场景、器械、躺地、冲击、避开部位、难度上限。
  bool passes(QaAction a, QaQuery q) {
    if (q.exclude.contains(a.id)) return false;
    if (q.strict) {
      if (q.scene != 'gym') {
        if (!a.scenes.contains(q.scene == 'hotel' ? 'home' : q.scene)) return false;
        final have = q.scene == 'office' ? const {'chair'} : q.equipment;
        if (!a.requiredEquipment.every(have.contains)) return false;
      }
    } else if (!a.scenes.contains(q.scene)) {
      return false;
    }
    final ambient = ambientEquipment[q.scene] ?? const {};
    if (!q.strict && !ambient.contains('*')) {
      final have = {...ambient, ...q.equipment};
      for (final e in a.requiredEquipment) {
        if (have.contains(e)) continue;
        // 只接受「环境物」类替代（垫子→毛巾）；负重器械（哑铃→水瓶）不算有。
        final subs = _softEquipment.contains(e) ? (a.substitutes[e] ?? const {}) : const <String>{};
        if (subs.any(have.contains)) continue;
        return false;
      }
    }
    if ((q.noFloor || q.scene == 'office') && a.floorRequired) return false;
    if (q.smallSpace && a.space == 'walking') return false;
    if (q.maxImpact != null && _impact(a.impact) > _impact(q.maxImpact!)) return false;
    for (final j in q.avoidJoints) {
      if (stressLevel(a.jointStress[j]) >= 2) return false;
    }
    if (q.maxDifficulty != null && a.difficulty > q.maxDifficulty!) return false;
    return true;
  }

  static int _impact(String v) => switch (v) {
    'high' => 2,
    'low' => 1,
    _ => 0,
  };

  List<QaHit> find(QaQuery q, {String lang = 'zh'}) {
    final first = _find(q, lang);
    if (first.length >= 4 || q.types.isEmpty) return first;
    // 太少：放宽「目的」（例如静音燃脂库里有氧动作少 → 补低冲击的大肌群动作），硬过滤不放宽。
    final relaxed = _find(
      QaQuery(
        scene: q.scene, equipment: q.equipment, muscles: q.muscles, stretchMuscles: q.stretchMuscles,
        goals: q.goals, roles: q.roles, keywords: q.keywords, avoidJoints: q.avoidJoints, noFloor: q.noFloor, smallSpace: q.smallSpace, strict: q.strict,
        maxImpact: q.maxImpact, maxDifficulty: q.maxDifficulty, targetDifficulty: q.targetDifficulty,
        lowIntensity: q.lowIntensity, preferEquipment: q.preferEquipment,
        exclude: {...q.exclude, for (final h in first) h.action.id}, limit: q.limit - first.length,
      ),
      lang,
    );
    return [...first, ...relaxed];
  }

  List<QaHit> _find(QaQuery q, String lang) {
    final scored = <QaHit>[];
    for (final a in index.all) {
      if (!passes(a, q)) continue;
      final h = _score(a, q, lang);
      if (h != null) scored.add(h);
    }
    scored.sort((x, y) => y.score.compareTo(x.score));
    // 去重：同组变体（abs-A/abs-B）、同模式同主肌 依次扣分，保证前 N 有变化。
    final picked = <QaHit>[];
    final pool = [...scored];
    while (picked.length < q.limit && pool.isNotEmpty) {
      QaHit? best;
      var bestScore = double.negativeInfinity;
      for (final h in pool.take(40)) {
        var s = h.score;
        for (final p in picked) {
          if (_family(p.action.id) == _family(h.action.id)) s -= 2.5;
          if (p.action.movementPattern.isNotEmpty &&
              p.action.movementPattern.first == (h.action.movementPattern.firstOrNull ?? '') &&
              p.action.primaryMuscles.firstOrNull == h.action.primaryMuscles.firstOrNull) {
            s -= 1.2;
          }
        }
        if (s > bestScore) {
          bestScore = s;
          best = h;
        }
      }
      pool.remove(best);
      picked.add(best!);
    }
    return picked;
  }

  static String _family(String id) {
    final m = RegExp(r'^(.*)-[A-E]$').firstMatch(id);
    return m?.group(1) ?? id;
  }

  QaHit? _score(QaAction a, QaQuery q, String lang) {
    final names = lang == 'en' ? muscleEn : muscleZh;
    var s = 0.0;
    final why = <String>[];
    final hasFocus = q.muscles.isNotEmpty || q.stretchMuscles.isNotEmpty || q.types.isNotEmpty || q.keywords.isNotEmpty;
    final stretchWanted = q.types.any((t) => t.contains('stretch') || t == 'mobility');

    // 主动肌
    final primHit = [for (final m in a.primaryMuscles) if (q.muscles.contains(m)) m];
    final secHit = [for (final m in a.secondaryMuscles) if (q.muscles.contains(m)) m];
    if (primHit.isNotEmpty) {
      s += 3 + primHit.length;
      why.add(lang == 'en' ? 'targets ${primHit.map((m) => names[m] ?? m).join('/')}' : '主练${primHit.map((m) => names[m] ?? m).join('、')}');
    } else if (secHit.isNotEmpty) {
      s += 1;
    }
    // 被拉伸的肌肉
    final stretchTargets = {...q.stretchMuscles, if (stretchWanted) ...q.muscles};
    final strHit = [for (final m in a.stretchedMuscles) if (stretchTargets.contains(m)) m];
    if (strHit.isNotEmpty) {
      s += 3 + strHit.length;
      why.add(lang == 'en' ? 'loosens ${strHit.map((m) => names[m] ?? m).join('/')}' : '拉开${strHit.map((m) => names[m] ?? m).join('、')}');
    }
    // 目的
    final typeHit = a.trainingType.intersection(q.types);
    if (typeHit.isNotEmpty) {
      s += 2;
      if (typeHit.contains('cardio')) why.add(lang == 'en' ? 'raises heart rate' : '心率能上来');
    } else if (q.types.isNotEmpty) {
      s -= 2;
    }
    // 点名了部位却一处都没练到：重罚（有氧燃脂例外，不罚）。
    if ((q.muscles.isNotEmpty || q.stretchMuscles.isNotEmpty) && primHit.isEmpty && strHit.isEmpty) {
      s -= typeHit.contains('cardio') ? 0 : (secHit.isNotEmpty ? 2 : 3.5);
    }
    if (a.goals.intersection(q.goals).isNotEmpty) s += 1.5;
    if (q.roles.isNotEmpty) s += a.sessionRole.intersection(q.roles).isNotEmpty ? 1.5 : -1;
    // 关键词（名称分词）
    for (final k in q.keywords) {
      final n = a.name('zh');
      if (n.contains(k)) {
        s += 4;
      } else if (_bigramOverlap(k, '$n${a.summaryZh}') >= 0.5) {
        s += 1.5;
      }
    }
    if (hasFocus && s <= 0.5) return null;
    // 器械：用户点名的加分
    final usesPreferred = a.requiredEquipment.intersection(q.preferEquipment);
    if (usesPreferred.isNotEmpty) {
      s += 2.5;
      why.add(lang == 'en' ? 'uses your ${usesPreferred.join('/')}' : '用上你的${usesPreferred.map(_equipZh).join('、')}');
    }
    // 难度：默认入门（目标 2），超出扣分。
    final over = a.difficulty - q.targetDifficulty;
    if (over > 0) s -= over * 0.9;
    if (a.difficulty <= q.targetDifficulty && q.targetDifficulty <= 2) {
      why.add(lang == 'en' ? 'beginner-friendly' : '入门难度');
    }
    if (q.lowIntensity && a.intensity != 'low') s -= 1.5;
    // 无焦点（随便练练）：主训练优先、全身动作优先。
    if (!hasFocus) {
      if (a.sessionRole.contains('main')) s += 1.5;
      if (a.trainingType.contains('strength') || a.trainingType.contains('cardio')) s += 1;
    }
    // 没点名部位（全身/燃脂/随便）：大肌群复合动作优先。
    if (q.muscles.isEmpty && q.stretchMuscles.isEmpty && a.primaryMuscles.any(_majorMuscles.contains)) {
      s += 1 + (a.primaryMuscles.where(_majorMuscles.contains).length > 1 ? 1 : 0);
    }
    // 约束带来的理由
    for (final j in q.avoidJoints) {
      if (stressLevel(a.jointStress[j]) == 0) {
        s += 1;
        why.add(lang == 'en' ? 'easy on the $j' : '${jointZh[j] ?? j}几乎不受力');
      } else {
        s -= 0.5;
        why.add(lang == 'en' ? 'light $j load' : '${jointZh[j] ?? j}负担低');
      }
    }
    if (q.noFloor && !a.floorRequired) why.add(lang == 'en' ? 'no floor needed' : '不用躺地');
    if (q.maxImpact != null && a.impact == 'none') why.add(lang == 'en' ? 'silent' : '无跳跃不扰邻');
    if (a.source == 'catalog') s -= 0.3;
    return QaHit(a, s, why.take(3).toList());
  }

  static double _bigramOverlap(String k, String text) {
    if (k.length < 2) return text.contains(k) ? 1 : 0;
    var hit = 0;
    for (var i = 0; i < k.length - 1; i++) {
      if (text.contains(k.substring(i, i + 2))) hit++;
    }
    return hit / (k.length - 1);
  }

  static String _equipZh(String e) =>
      const {'dumbbell': '哑铃', 'band': '弹力带', 'kettlebell': '壶铃', 'pullup-bar': '单杠', 'mini-band': '迷你带'}[e] ?? e;

  /// 退阶：标签 regressions → 同主肌、更低难度、通过过滤的动作。
  QaHit? easierThan(QaAction a, QaQuery q, {String lang = 'zh', Set<String> focus = const {}}) {
    bool keeps(QaAction b) => _sameArea(a, b) && _keepsFocus(a, b, focus);
    for (final id in a.regressions) {
      final r = index[id];
      if (r != null && passes(r, q) && keeps(r)) {
        return QaHit(r, 0, [lang == 'en' ? 'easier version of ${a.name(lang)}' : '是「${a.name(lang)}」的退阶版']);
      }
    }
    final sub = QaQuery(
      scene: q.scene,
      equipment: q.equipment,
      strict: q.strict,
      muscles: {...a.primaryMuscles},
      stretchMuscles: {...a.stretchedMuscles},
      types: a.trainingType,
      avoidJoints: q.avoidJoints,
      noFloor: q.noFloor,
      maxImpact: q.maxImpact,
      maxDifficulty: (a.difficulty - 1).clamp(1, 5),
      targetDifficulty: 1,
      exclude: q.exclude,
      limit: 1,
    );
    final hit = find(sub.withLimit(8), lang: lang).where((h) => keeps(h.action)).firstOrNull;
    if (hit == null) return null;
    return QaHit(hit.action, 0, [lang == 'en' ? 'same muscles, lower difficulty' : '同样练${_mainMuscle(a, lang)}，难度更低']);
  }

  QaHit? harderThan(QaAction a, QaQuery q, {String lang = 'zh'}) {
    for (final id in a.progressions) {
      final r = index[id];
      if (r != null && passes(r, q)) {
        return QaHit(r, 0, [lang == 'en' ? 'harder version of ${a.name(lang)}' : '是「${a.name(lang)}」的进阶版']);
      }
    }
    return null;
  }

  /// 替换：标签 alternatives → 同主肌同角色的最佳检索结果。
  QaHit? replacementFor(QaAction a, QaQuery q, {String lang = 'zh', Set<String> focus = const {}}) {
    bool keeps(QaAction b) => _sameArea(a, b) && _keepsFocus(a, b, focus);
    for (final id in a.alternatives) {
      final r = index[id];
      if (r != null && passes(r, q) && r.difficulty <= a.difficulty + 1 && keeps(r)) {
        return QaHit(r, 0, [lang == 'en' ? 'same job as ${a.name(lang)}' : '和「${a.name(lang)}」练的是同一处']);
      }
    }
    final sub = QaQuery(
      scene: q.scene,
      equipment: q.equipment,
      strict: q.strict,
      muscles: {...a.primaryMuscles},
      stretchMuscles: {...a.stretchedMuscles},
      types: a.trainingType,
      roles: a.sessionRole,
      avoidJoints: q.avoidJoints,
      noFloor: q.noFloor,
      maxImpact: q.maxImpact,
      maxDifficulty: a.difficulty + 1,
      targetDifficulty: a.difficulty,
      exclude: q.exclude,
      limit: 8,
    );
    final hit = find(sub, lang: lang).where((h) => keeps(h.action)).firstOrNull;
    if (hit == null) return null;
    return QaHit(hit.action, 0, [lang == 'en' ? 'works the same area' : '同样练${_mainMuscle(a, lang)}']);
  }

  /// 用户点名的部位（如练背）里原动作练到的那部分，新动作也要练到。
  static bool _keepsFocus(QaAction a, QaAction b, Set<String> focus) {
    final need = {...a.primaryMuscles, ...a.secondaryMuscles, ...a.stretchedMuscles}.intersection(focus);
    if (need.isEmpty) return true;
    return [...b.primaryMuscles, ...b.secondaryMuscles, ...b.stretchedMuscles].any(need.contains);
  }

  /// 替换/退阶必须练同一处：主动肌或被拉伸肌有交集。
  static bool _sameArea(QaAction a, QaAction b) =>
      a.primaryMuscles.any(b.primaryMuscles.contains) || a.stretchedMuscles.any(b.stretchedMuscles.contains);

  static String _mainMuscle(QaAction a, String lang) {
    final m = a.primaryMuscles.firstOrNull ?? a.stretchedMuscles.firstOrNull;
    if (m == null) return lang == 'en' ? 'this area' : '这个部位';
    return (lang == 'en' ? muscleEn : muscleZh)[m] ?? m;
  }
}

/// 把用户原话解析出的意图转成检索条件。
QaQuery queryFromIntent(
  QaIntent i, {
  required String scene,
  required Set<String> equipment,
  Set<String> exclude = const {},
  int limit = 8,
  bool strict = false,
}) => QaQuery(
  strict: strict,
  scene: scene,
  equipment: equipment,
  muscles: i.muscles,
  stretchMuscles: i.stretchMuscles,
  types: i.types,
  goals: i.goals,
  roles: i.roles,
  keywords: i.keywords,
  avoidJoints: i.avoidJoints,
  noFloor: i.noFloor,
  smallSpace: i.smallSpace,
  maxImpact: i.maxImpact,
  maxDifficulty: i.maxDifficulty ?? (i.easy ? 2 : null),
  targetDifficulty: i.easy ? 1 : 2,
  lowIntensity: i.lowIntensity,
  preferEquipment: i.equipment.difference(const {'mat', 'chair'}),
  exclude: exclude,
  limit: limit,
);

extension QaQueryCopy on QaQuery {
  QaQuery withExclude(Set<String> ids) => QaQuery(
    scene: scene,
    equipment: equipment,
    muscles: muscles,
    stretchMuscles: stretchMuscles,
    types: types,
    goals: goals,
    roles: roles,
    keywords: keywords,
    avoidJoints: avoidJoints,
    noFloor: noFloor,
    smallSpace: smallSpace,
    strict: strict,
    maxImpact: maxImpact,
    maxDifficulty: maxDifficulty,
    targetDifficulty: targetDifficulty,
    lowIntensity: lowIntensity,
    preferEquipment: preferEquipment,
    exclude: {...exclude, ...ids},
    limit: limit,
  );

  QaQuery withLimit(int n) => QaQuery(
    scene: scene,
    equipment: equipment,
    muscles: muscles,
    stretchMuscles: stretchMuscles,
    types: types,
    goals: goals,
    roles: roles,
    keywords: keywords,
    avoidJoints: avoidJoints,
    noFloor: noFloor,
    smallSpace: smallSpace,
    strict: strict,
    maxImpact: maxImpact,
    maxDifficulty: maxDifficulty,
    targetDifficulty: targetDifficulty,
    lowIntensity: lowIntensity,
    preferEquipment: preferEquipment,
    exclude: exclude,
    limit: n,
  );
}
