/// 圈定范围 + 按标签排序。只认结构化标签（场景、器械 id、躺地、冲击、关节负担、难度、肌肉 id），
/// 不读任何语言的文字：用户的话由模型按 SOP 填成 [QaQuery] 的字段。
library;

import '../profile/coach_profile.dart';
import 'qa_action.dart';
import 'qa_admission.dart';

/// 各场景默认就有的环境物（不算「器械」）；没圈定范围时可用。
const ambientEquipment = <String, Set<String>>{
  'home': {'mat', 'wall', 'chair', 'towel', 'doorframe', 'book', 'water-bottle', 'backpack', 'stairs'},
  'hotel': {'wall', 'chair', 'towel', 'doorframe', 'book', 'water-bottle', 'backpack', 'mat'},
  'office': {'chair', 'wall', 'doorframe', 'book', 'water-bottle', 'backpack'},
  'outdoor': {'wall', 'stairs', 'bench', 'pullup-bar'},
  'gym': {'*'},
};

/// 圈定范围后，居家仍默认可用的环境物（不用问、不算器械）。
const homeAlwaysAvailable = {'wall'};

/// 办公室圈定范围：只到椅子 + 徒手。
const officeEquipment = {'chair'};

const _softEquipment = {'mat', 'slider', 'block', 'bench', 'chair', 'towel', 'wall', 'parallettes', 'doorframe', 'stairs'};
const _majorMuscles = {'quadriceps', 'glute-max', 'hamstrings', 'chest', 'lats', 'abs', 'deltoids'};

/// 一次检索的完整条件（全是结构化 id）。
final class QaQuery {
  QaQuery({
    required this.scene,
    required this.equipment,
    this.muscles = const {},
    this.stretchMuscles = const {},
    this.types = const {},
    this.goals = const {},
    this.roles = const {},
    this.patterns = const {},
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

  /// 用户可用的器械（不含场景环境物）。
  final Set<String> equipment;
  final Set<String> muscles;
  final Set<String> stretchMuscles;
  final Set<String> types;
  final Set<String> goals;
  final Set<String> roles;
  final Set<String> patterns;
  final Set<String> avoidJoints;
  final bool noFloor;
  final bool smallSpace;

  /// 范围已圈定：居家只用 [equipment] + 墙；办公室只到椅子 + 徒手、不躺地；健身房不限场景和器械。
  final bool strict;
  final String? maxImpact;
  final int? maxDifficulty;
  final int targetDifficulty;
  final bool lowIntensity;
  final Set<String> preferEquipment;
  final Set<String> exclude;
  final int limit;

  QaQuery copyWith({
    Set<String>? muscles,
    Set<String>? stretchMuscles,
    Set<String>? types,
    Set<String>? goals,
    Set<String>? roles,
    Set<String>? patterns,
    String? maxImpact,
    int? maxDifficulty,
    int? targetDifficulty,
    Set<String>? exclude,
    int? limit,
  }) => QaQuery(
    scene: scene,
    equipment: equipment,
    muscles: muscles ?? this.muscles,
    stretchMuscles: stretchMuscles ?? this.stretchMuscles,
    types: types ?? this.types,
    goals: goals ?? this.goals,
    roles: roles ?? this.roles,
    patterns: patterns ?? this.patterns,
    avoidJoints: avoidJoints,
    noFloor: noFloor,
    smallSpace: smallSpace,
    strict: strict,
    maxImpact: maxImpact ?? this.maxImpact,
    maxDifficulty: maxDifficulty ?? this.maxDifficulty,
    targetDifficulty: targetDifficulty ?? this.targetDifficulty,
    lowIntensity: lowIntensity,
    preferEquipment: preferEquipment,
    exclude: exclude ?? this.exclude,
    limit: limit ?? this.limit,
  );

  QaQuery withExclude(Set<String> ids) => copyWith(exclude: {...exclude, ...ids});
  QaQuery withLimit(int n) => copyWith(limit: n);

  /// 只保留范围（场景、器械、限制），去掉「练什么」：用来判断一个动作是否越界。
  QaQuery get scopeOnly => QaQuery(
    scene: scene,
    equipment: equipment,
    avoidJoints: avoidJoints,
    noFloor: noFloor,
    smallSpace: smallSpace,
    strict: strict,
    maxImpact: maxImpact,
    maxDifficulty: maxDifficulty,
  );

  Map<String, Object?> toJson() => {
    'scene': scene,
    'strict': strict,
    'equipment': equipment.toList(),
    if (muscles.isNotEmpty) 'muscles': muscles.toList(),
    if (stretchMuscles.isNotEmpty) 'stretchMuscles': stretchMuscles.toList(),
    if (types.isNotEmpty) 'types': types.toList(),
    if (goals.isNotEmpty) 'goals': goals.toList(),
    if (roles.isNotEmpty) 'roles': roles.toList(),
    if (patterns.isNotEmpty) 'patterns': patterns.toList(),
    if (avoidJoints.isNotEmpty) 'avoidJoints': avoidJoints.toList(),
    if (noFloor) 'noFloor': true,
    if (smallSpace) 'smallSpace': true,
    if (maxImpact != null) 'maxImpact': maxImpact,
    if (maxDifficulty != null) 'maxDifficulty': maxDifficulty,
  };
}

final class QaHit {
  QaHit(this.action, this.score);
  final QaAction action;
  final double score;
}

/// 换动作的方式。
enum QaSwapMode { any, easier, harder }

final class QaFinder {
  QaFinder(this.index, {required CoachProfile profile})
    : admission = QaAdmission(profile, index.equipmentCatalog());
  final QaActionIndex index;

  /// 与 refit / 交付 / 恢复共用的 core 准入；[passes] 先过它，再过 QA 标签收窄。
  final QaAdmission admission;

  /// 硬过滤：场景、器械、躺地、冲击、避开部位、难度上限。
  bool passes(QaAction a, QaQuery q) {
    if (q.exclude.contains(a.id)) return false;
    // 不推荐 / 停用的动作不进搜索、推荐、新计划和换动作候选。
    if (!a.drill.suggestible) return false;
    // 计划会按动作自身要求声明器械（见 QaPlanBuilder.equipmentFor），
    // 这里用同一声明、同一场景映射、同一避开部位走 core 门禁。
    if (admission.problem(
          a.id,
          scene: q.scene,
          equipment: a.requiredEquipment,
          avoid: q.avoidJoints,
        ) !=
        null) {
      return false;
    }
    if (q.strict) {
      if (q.scene != 'gym') {
        if (!a.scenes.contains(q.scene == 'hotel' ? 'home' : q.scene)) return false;
        final have = q.scene == 'office' ? officeEquipment : {...q.equipment, ...homeAlwaysAvailable};
        if (!a.requiredEquipment.every(have.contains)) return false;
      }
    } else {
      if (!a.scenes.contains(q.scene)) return false;
      final ambient = ambientEquipment[q.scene] ?? const {};
      if (!ambient.contains('*')) {
        final have = {...ambient, ...q.equipment};
        for (final e in a.requiredEquipment) {
          if (have.contains(e)) continue;
          // 只接受「环境物」类替代（垫子→毛巾）；负重器械不拿环境物顶。
          final subs = _softEquipment.contains(e) ? (a.substitutes[e] ?? const {}) : const <String>{};
          if (subs.any(have.contains)) continue;
          return false;
        }
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

  /// 范围内全部动作（不排序）。
  List<QaAction> inScope(QaQuery q) => [for (final a in index.all) if (passes(a, q.scopeOnly)) a];

  List<QaHit> find(QaQuery q) {
    final first = _find(q);
    if (first.length >= 4 || q.types.isEmpty) return first;
    // 太少：放宽「目的」，硬过滤不放宽。
    final relaxed = _find(q.copyWith(types: const {}, exclude: {...q.exclude, for (final h in first) h.action.id}, limit: q.limit - first.length));
    return [...first, ...relaxed];
  }

  List<QaHit> _find(QaQuery q) {
    final scored = <QaHit>[];
    for (final a in index.all) {
      if (!passes(a, q)) continue;
      final s = _score(a, q);
      if (s != null) scored.add(QaHit(a, s));
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

  double? _score(QaAction a, QaQuery q) {
    var s = 0.0;
    final hasFocus = q.muscles.isNotEmpty || q.stretchMuscles.isNotEmpty || q.types.isNotEmpty || q.patterns.isNotEmpty;
    final stretchWanted = q.types.any((t) => t.contains('stretch') || t == 'mobility');
    final primHit = a.primaryMuscles.where(q.muscles.contains).length;
    final secHit = a.secondaryMuscles.where(q.muscles.contains).length;
    if (primHit > 0) {
      s += 3 + primHit;
    } else if (secHit > 0) {
      s += 1;
    }
    final stretchTargets = {...q.stretchMuscles, if (stretchWanted) ...q.muscles};
    final strHit = a.stretchedMuscles.where(stretchTargets.contains).length;
    if (strHit > 0) s += 3 + strHit;
    final typeHit = a.trainingType.intersection(q.types);
    if (typeHit.isNotEmpty) {
      s += 2;
    } else if (q.types.isNotEmpty) {
      s -= 2;
    }
    // 点名了部位却一处都没练到：重罚（有氧燃脂例外）。
    if ((q.muscles.isNotEmpty || q.stretchMuscles.isNotEmpty) && primHit == 0 && strHit == 0) {
      s -= typeHit.contains('cardio') ? 0 : (secHit > 0 ? 2 : 3.5);
    }
    if (q.patterns.isNotEmpty && a.movementPattern.any(q.patterns.contains)) s += 3;
    if (a.goals.intersection(q.goals).isNotEmpty) s += 1.5;
    if (q.roles.isNotEmpty) s += a.sessionRole.intersection(q.roles).isNotEmpty ? 1.5 : -1;
    if (hasFocus && s <= 0.5) return null;
    if (a.requiredEquipment.intersection(q.preferEquipment).isNotEmpty) s += 2.5;
    final over = a.difficulty - q.targetDifficulty;
    if (over > 0) s -= over * 0.9;
    if (q.lowIntensity && a.intensity != 'low') s -= 1.5;
    if (!hasFocus) {
      if (a.sessionRole.contains('main')) s += 1.5;
      if (a.trainingType.contains('strength') || a.trainingType.contains('cardio')) s += 1;
    }
    if (q.muscles.isEmpty && q.stretchMuscles.isEmpty && a.primaryMuscles.any(_majorMuscles.contains)) {
      s += 1 + (a.primaryMuscles.where(_majorMuscles.contains).length > 1 ? 1 : 0);
    }
    for (final j in q.avoidJoints) {
      s += stressLevel(a.jointStress[j]) == 0 ? 1 : -0.5;
    }
    if (a.source == 'catalog') s -= 0.3;
    return s;
  }

  /// 能顶替 [a] 的候选（都在范围 [q] 内）：练同一处（主动肌或被拉伸肌有交集），
  /// 环节相同（主训练 / 热身 / 收操）；[focus] 非空时还要练到原动作在 focus 里练到的那部分。
  /// 热身/收操没有同一处的，放宽到「同环节且照顾 [sessionRegion]」。
  /// easier 只要更简单的，harder 只要更难的；标签 regressions / progressions / alternatives 排前面。
  List<QaAction> swapCandidates(
    QaAction a,
    QaQuery q, {
    QaSwapMode mode = QaSwapMode.any,
    Set<String> focus = const {},
    Set<String> sessionRegion = const {},
    String? role,
    int limit = 6,
  }) {
    bool difficultyOk(QaAction b) => switch (mode) {
      QaSwapMode.easier => b.difficulty < a.difficulty,
      QaSwapMode.harder => b.difficulty > a.difficulty,
      QaSwapMode.any => b.difficulty <= a.difficulty + 1,
    };
    bool roleOk(QaAction b) => role == null || role == 'main' ? !b.isStretchOnly || a.isStretchOnly : b.sessionRole.contains(role);
    final scope = q.scopeOnly.copyWith(exclude: {...q.exclude, a.id});
    final preferred = switch (mode) {
      QaSwapMode.easier => a.regressions,
      QaSwapMode.harder => a.progressions,
      QaSwapMode.any => a.alternatives,
    };
    final out = <QaAction>[];
    void addIf(QaAction b, bool Function(QaAction) area) {
      if (out.any((x) => x.id == b.id) || !passes(b, scope) || !difficultyOk(b) || !roleOk(b) || !area(b)) return;
      out.add(b);
    }

    bool same(QaAction b) => sameArea(a, b) && keepsFocus(a, b, focus);
    for (final id in preferred) {
      final b = index[id];
      if (b != null) addIf(b, same);
    }
    final ranked = find(q.copyWith(
      muscles: {...a.primaryMuscles},
      stretchMuscles: {...a.stretchedMuscles},
      types: a.trainingType,
      roles: role == null ? a.sessionRole : {role},
      patterns: const {},
      targetDifficulty: mode == QaSwapMode.easier ? 1 : a.difficulty,
      exclude: {...q.exclude, a.id},
      limit: 30,
    ));
    for (final h in ranked) {
      addIf(h.action, same);
    }
    if (out.isEmpty && (role == 'warmup' || role == 'cooldown') && sessionRegion.isNotEmpty) {
      bool fits(QaAction b) => [...b.primaryMuscles, ...b.secondaryMuscles, ...b.stretchedMuscles].any(sessionRegion.contains);
      final warm = role == 'warmup';
      for (final h in find(q.copyWith(
        muscles: warm ? sessionRegion : const {},
        stretchMuscles: warm ? const {} : sessionRegion,
        types: warm ? const {'mobility', 'dynamic-stretch'} : const {'static-stretch'},
        roles: {role!},
        exclude: {...q.exclude, a.id},
        limit: 20,
      ))) {
        addIf(h.action, fits);
      }
    }
    return out.take(limit).toList();
  }

  /// 用户点名的部位里原动作练到的那部分，新动作也要练到。
  static bool keepsFocus(QaAction a, QaAction b, Set<String> focus) {
    final need = {...a.primaryMuscles, ...a.secondaryMuscles, ...a.stretchedMuscles}.intersection(focus);
    if (need.isEmpty) return true;
    return [...b.primaryMuscles, ...b.secondaryMuscles, ...b.stretchedMuscles].any(need.contains);
  }

  /// 替换/退阶必须练同一处：主动肌或被拉伸肌有交集。
  static bool sameArea(QaAction a, QaAction b) =>
      a.primaryMuscles.any(b.primaryMuscles.contains) || a.stretchedMuscles.any(b.stretchedMuscles.contains);
}
