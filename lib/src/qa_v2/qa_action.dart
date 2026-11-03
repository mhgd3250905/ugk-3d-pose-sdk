/// AI 问答推荐 Agent v2 的动作视图：优先用 Pose-Hub `catalog/ai-tags`
/// （`pose-hub-ai-tags@1`）的结构化标签，按 id 对不上时回退到现有目录字段。
library;

import '../catalog/catalog.dart';
import '../util/json.dart';

/// 关节负担档位：none < low < moderate。
int stressLevel(String? v) => switch (v) {
  'moderate' => 2,
  'low' => 1,
  _ => 0,
};

/// 一个动作在 v2 里用到的全部字段（来源 [source]：`ai-tags` 或 `catalog`）。
final class QaAction {
  QaAction({
    required this.drill,
    required this.source,
    required this.scenes,
    required this.requiredEquipment,
    required this.substitutes,
    required this.floorRequired,
    required this.impact,
    required this.trainingType,
    required this.movementPattern,
    required this.primaryMuscles,
    required this.secondaryMuscles,
    required this.stretchedMuscles,
    required this.difficulty,
    required this.intensity,
    required this.jointStress,
    required this.sessionRole,
    required this.goals,
    required this.alternatives,
    required this.regressions,
    required this.progressions,
    required this.prerequisites,
    required this.summaryZh,
    required this.summaryEn,
    this.space = 'in-place',
  });

  final Drill drill;
  final String source;
  final Set<String> scenes;
  final Set<String> requiredEquipment;

  /// 器械 → 可替代器械（如 mat → towel）。
  final Map<String, Set<String>> substitutes;
  final bool floorRequired;

  /// none / low / high。
  final String impact;
  final Set<String> trainingType;
  final List<String> movementPattern;
  final List<String> primaryMuscles;
  final List<String> secondaryMuscles;
  final List<String> stretchedMuscles;

  /// 1–5。
  final int difficulty;
  final String intensity;
  final Map<String, String> jointStress;
  final Set<String> sessionRole;
  final Set<String> goals;
  final List<String> alternatives;
  final List<String> regressions;
  final List<String> progressions;
  final Set<String> prerequisites;
  final String summaryZh;
  final String summaryEn;

  /// in-place / mat / walking。
  final String space;

  String get id => drill.id;
  String name(String lang) => drill.name.values[lang] ?? drill.name.values['zh'] ?? drill.id;

  bool get isStretchOnly =>
      trainingType.isNotEmpty &&
      trainingType.every((t) => t == 'static-stretch' || t == 'dynamic-stretch' || t == 'mobility' || t == 'breathing');

  /// 有 ai-tags 时用标签；否则从目录字段推。
  factory QaAction.from(Drill d, Map<String, Object?>? tags) {
    if (tags != null && tags['format'] == 'pose-hub-ai-tags@1') return QaAction._fromTags(d, tags);
    return QaAction._fromCatalog(d);
  }

  factory QaAction._fromTags(Drill d, Map<String, Object?> t) {
    final subs = <String, Set<String>>{};
    for (final s in asList(t['substitutes'])) {
      final m = asMap(s);
      final f = asString(m['for']);
      if (f != null) subs[f] = asStringList(m['use']).toSet();
    }
    final summary = asMap(t['aiSummary']);
    return QaAction(
      drill: d,
      source: 'ai-tags',
      scenes: asStringList(t['scenes']).toSet(),
      requiredEquipment: asStringList(t['requiredEquipment']).toSet(),
      substitutes: subs,
      floorRequired: asBool(t['floorRequired']) ?? false,
      impact: asString(t['impact']) ?? 'none',
      trainingType: asStringList(t['trainingType']).toSet(),
      movementPattern: asStringList(t['movementPattern']),
      primaryMuscles: asStringList(t['primaryMuscles']),
      secondaryMuscles: asStringList(t['secondaryMuscles']),
      stretchedMuscles: asStringList(t['stretchedMuscles']),
      difficulty: asInt(t['difficulty']) ?? 2,
      intensity: asString(t['intensity']) ?? 'low',
      jointStress: {for (final e in asMap(t['jointStress']).entries) e.key: '${e.value}'},
      sessionRole: asStringList(t['sessionRole']).toSet(),
      goals: asStringList(t['goals']).toSet(),
      alternatives: asStringList(t['alternatives']),
      regressions: asStringList(t['regressions']),
      progressions: asStringList(t['progressions']),
      prerequisites: asStringList(t['prerequisites']).toSet(),
      summaryZh: asString(summary['zh']) ?? d.purpose,
      summaryEn: asString(summary['en']) ?? '',
      space: asString(t['space']) ?? 'in-place',
    );
  }

  factory QaAction._fromCatalog(Drill d) {
    const floor = {'supine', 'prone', 'quadruped', 'kneeling', 'side_lying'};
    final type = switch (d.category) {
      'strength' => {'strength'},
      'core' => {'strength', 'stability-control'},
      'cardio' => {'cardio'},
      'mobility' => {'mobility'},
      'stretch' => {'static-stretch'},
      _ => <String>{},
    };
    final role = switch (d.category) {
      'mobility' => {'warmup'},
      'stretch' => {'cooldown'},
      _ => {'main'},
    };
    final stress = <String, String>{};
    for (final c in d.cautions) {
      if (c.contains('膝')) stress['knee'] = 'moderate';
      if (c.contains('腰')) stress['lumbar'] = 'moderate';
      if (c.contains('肩')) stress['shoulder'] = 'moderate';
      if (c.contains('腕')) stress['wrist'] = 'moderate';
      if (c.contains('颈')) stress['neck'] = 'moderate';
    }
    final stretch = d.category == 'stretch';
    return QaAction(
      drill: d,
      source: 'catalog',
      scenes: {...d.scenes, if (d.scenes.contains('home')) 'hotel'},
      requiredEquipment: d.equipment.toSet(),
      substitutes: const {},
      floorRequired: floor.contains(d.position),
      impact: d.category == 'cardio' ? 'low' : 'none',
      trainingType: type,
      movementPattern: const [],
      primaryMuscles: stretch ? const [] : d.muscleGroups,
      secondaryMuscles: const [],
      stretchedMuscles: stretch ? d.muscleGroups : const [],
      difficulty: (d.level * 1.5).round().clamp(1, 5),
      intensity: 'low',
      jointStress: stress,
      sessionRole: role,
      goals: const {},
      alternatives: [if (d.alternative != null) d.alternative!],
      regressions: const [],
      progressions: const [],
      prerequisites: const {},
      summaryZh: d.purpose,
      summaryEn: '',
    );
  }
}

/// 目录 + 标签合并后的索引，并统计标签覆盖率。
final class QaActionIndex {
  QaActionIndex(Catalog catalog, {Map<String, Map<String, Object?>> aiTags = const {}, Iterable<String>? allowIds})
    : catalog = catalog,
      _byId = {
        for (final d in catalog.drills)
          if (allowIds == null || allowIds.contains(d.id)) d.id: QaAction.from(d, aiTags[d.id]),
      };

  final Catalog catalog;
  final Map<String, QaAction> _byId;

  Iterable<QaAction> get all => _byId.values;
  QaAction? operator [](String id) => _byId[id];
  int get length => _byId.length;
  int get taggedCount => _byId.values.where((a) => a.source == 'ai-tags').length;
  List<String> get untaggedIds => [for (final a in _byId.values) if (a.source != 'ai-tags') a.id];
}
