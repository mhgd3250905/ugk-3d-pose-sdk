/// TrainingPlan v1（与 SmartFit `docs/plan-schema.md` 同一 JSON）：模板计划、AI 计划、已存计划共用。
/// 只含动作 id 与剂量；素材由 id 经 [AssetResolver] 带出。
library;

import '../catalog/catalog.dart';

const planSchemaVersion = 1;

enum BlockType {
  warmup('热身', 0),
  main('主训练', 1),
  circuit('循环', 1),
  cooldown('放松', 2);

  const BlockType(this.zh, this.order);
  final String zh;

  /// 块顺序：热身(0) ≤ 主训练/循环(1) ≤ 放松(2)。
  final int order;
  static BlockType? tryParse(Object? s) => values.where((v) => v.name == s).firstOrNull;
}

class PlanItem {
  const PlanItem({
    required this.exerciseId,
    required this.mode,
    required this.sets,
    this.reps,
    this.workSeconds,
    required this.perSide,
    required this.restSeconds,
    this.note,
    this.replacedFrom,
  });

  final String exerciseId;
  final DoseMode mode;
  final int sets;

  /// mode=reps 必填；单侧指每侧。
  final int? reps;

  /// mode=time 必填；单侧指每侧。
  final int? workSeconds;

  /// 必须等于动作的 unilateral。
  final bool perSide;

  /// 每组之后休息。
  final int restSeconds;
  final String? note;
  final String? replacedFrom;

  PlanItem copyWith({int? sets, int? reps, int? workSeconds, bool? perSide, int? restSeconds, String? exerciseId}) =>
      PlanItem(
        exerciseId: exerciseId ?? this.exerciseId,
        mode: mode,
        sets: sets ?? this.sets,
        reps: reps ?? this.reps,
        workSeconds: workSeconds ?? this.workSeconds,
        perSide: perSide ?? this.perSide,
        restSeconds: restSeconds ?? this.restSeconds,
        note: note,
        replacedFrom: replacedFrom,
      );

  Map<String, Object?> toJson() => {
    'exerciseId': exerciseId,
    'mode': mode.name,
    'sets': sets,
    'reps': ?reps,
    'workSeconds': ?workSeconds,
    'perSide': perSide,
    'restSeconds': restSeconds,
    'note': ?note,
    'replacedFrom': ?replacedFrom,
  };
}

class PlanBlock {
  const PlanBlock({
    required this.id,
    required this.name,
    required this.type,
    this.rounds = 1,
    this.restBetweenRoundsSeconds = 0,
    required this.items,
  });

  final String id;
  final String name;
  final BlockType type;

  /// circuit 块按轮重复其中每项各一组。
  final int rounds;
  final int restBetweenRoundsSeconds;
  final List<PlanItem> items;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'type': type.name,
    'rounds': rounds,
    'restBetweenRoundsSeconds': restBetweenRoundsSeconds,
    'items': [for (final i in items) i.toJson()],
  };
}

class TrainingPlan {
  const TrainingPlan({
    this.schemaVersion = planSchemaVersion,
    required this.id,
    required this.source,
    this.templateId,
    required this.title,
    this.summary = '',
    required this.goal,
    required this.scene,
    this.equipment = const [],
    required this.level,
    required this.targetMinutes,
    required this.blocks,
    this.avoid = const {},
    this.notes = const [],
    this.safetyNotes = const [],
  });

  final int schemaVersion;
  final String id;

  /// template | ai
  final String source;
  final String? templateId;
  final String title;
  final String summary;
  final String goal;
  final String scene;
  final List<String> equipment;
  final int level;
  final int targetMinutes;
  final List<PlanBlock> blocks;

  /// 用户提出的保护部位（随计划保存）。
  final Set<String> avoid;
  final List<String> notes;
  final List<String> safetyNotes;

  Iterable<PlanItem> get items => blocks.expand((b) => b.items);
  Set<String> get exerciseIds => {for (final i in items) i.exerciseId};

  TrainingPlan copyWith({
    String? id,
    String? source,
    String? scene,
    int? level,
    int? targetMinutes,
    List<PlanBlock>? blocks,
    Set<String>? avoid,
    List<String>? notes,
    List<String>? safetyNotes,
  }) => TrainingPlan(
    schemaVersion: schemaVersion,
    id: id ?? this.id,
    source: source ?? this.source,
    templateId: templateId,
    title: title,
    summary: summary,
    goal: goal,
    scene: scene ?? this.scene,
    equipment: equipment,
    level: level ?? this.level,
    targetMinutes: targetMinutes ?? this.targetMinutes,
    blocks: blocks ?? this.blocks,
    avoid: avoid ?? this.avoid,
    notes: notes ?? this.notes,
    safetyNotes: safetyNotes ?? this.safetyNotes,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'id': id,
    'source': source,
    'templateId': ?templateId,
    'title': title,
    'summary': summary,
    'goal': goal,
    'scene': scene,
    'equipment': equipment,
    'level': level,
    'targetMinutes': targetMinutes,
    'blocks': [for (final b in blocks) b.toJson()],
    if (avoid.isNotEmpty) 'avoid': avoid.toList(),
    'notes': notes,
    'safetyNotes': safetyNotes,
  };
}

/// 估算计划时长（秒），与 SmartFit SessionBuilder / ai-coach-eval `estimate_seconds` 同口径：
/// 准备 10 秒；每组 = 工作 ×（单侧 2 面）+ 换侧 5 秒；组间休息（sets-1 次）；每换一个动作过渡 15 秒；
/// 轮间休息至少 15 秒。reps 按视频 repSeconds（缺省 3 秒/次）计。
class PlanDuration {
  const PlanDuration({
    this.prepSeconds = 10,
    this.switchSideSeconds = 5,
    this.transitionSeconds = 15,
    this.defaultRepSeconds = 3.0,
  });
  final int prepSeconds;
  final int switchSideSeconds;
  final int transitionSeconds;
  final double defaultRepSeconds;

  double repSeconds(Drill d) {
    for (final v in d.assets.videos) {
      if (v.repSeconds != null && v.repSeconds! > 0) return v.repSeconds!;
    }
    return defaultRepSeconds;
  }

  double estimateSeconds(TrainingPlan p, Catalog c) {
    var total = prepSeconds.toDouble();
    var first = true;
    for (final b in p.blocks) {
      for (var r = 0; r < b.rounds; r++) {
        for (final i in b.items) {
          final d = c[i.exerciseId];
          if (d == null) continue;
          if (!first) total += transitionSeconds;
          first = false;
          final sides = i.perSide ? 2 : 1;
          final work = i.mode == DoseMode.reps ? (i.reps ?? 10) * repSeconds(d) : (i.workSeconds ?? 30).toDouble();
          total += i.sets * (work * sides + (sides == 2 ? switchSideSeconds : 0)) + (i.sets - 1) * i.restSeconds;
        }
        if (r < b.rounds - 1) {
          total += b.restBetweenRoundsSeconds > transitionSeconds ? b.restBetweenRoundsSeconds : transitionSeconds;
        }
      }
    }
    return total;
  }
}
