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

/// One ordered part of a set. Group count, sides and rest belong to its
/// parent item; [exerciseId] resolves this part's media and voice material.
class PlanSegment {
  const PlanSegment({
    required this.id,
    required this.exerciseId,
    required this.mode,
    this.reps,
    this.workSeconds,
    this.holdSeconds,
    this.label,
    this.rhythm,
  });

  final String id;
  final String exerciseId;
  final DoseMode mode;
  final int? reps;
  final int? workSeconds;
  final int? holdSeconds;
  final String? label;

  /// Catalog-compatible rhythm data, interpreted by the trainer package.
  final Map<String, dynamic>? rhythm;

  PlanItem toPlanItem(PlanItem parent) => PlanItem(
    exerciseId: exerciseId,
    mode: mode,
    sets: parent.sets,
    reps: reps,
    workSeconds: workSeconds,
    perSide: parent.perSide,
    restSeconds: parent.restSeconds,
    note: parent.note,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'exerciseId': exerciseId,
    'mode': mode.name,
    'reps': ?reps,
    'workSeconds': ?workSeconds,
    'holdSeconds': ?holdSeconds,
    'label': ?label,
    'rhythm': ?rhythm,
  };
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
    this.segments = const [],
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

  /// If present, these ordered parts replace the parent work dose in every
  /// set. The item remains a single displayed/statistical exercise.
  final List<PlanSegment> segments;

  PlanItem copyWith({
    int? sets,
    int? reps,
    int? workSeconds,
    bool? perSide,
    int? restSeconds,
    String? exerciseId,
    List<PlanSegment>? segments,
  }) => PlanItem(
    exerciseId: exerciseId ?? this.exerciseId,
    mode: mode,
    sets: sets ?? this.sets,
    reps: reps ?? this.reps,
    workSeconds: workSeconds ?? this.workSeconds,
    perSide: perSide ?? this.perSide,
    restSeconds: restSeconds ?? this.restSeconds,
    note: note,
    replacedFrom: replacedFrom,
    segments: segments ?? this.segments,
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
    if (segments.isNotEmpty) 'segments': [for (final s in segments) s.toJson()],
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
  Set<String> get exerciseIds => {
    for (final i in items) ...[i.exerciseId, for (final s in i.segments) s.exerciseId],
  };

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
          final work = i.segments.isEmpty
              ? (i.mode == DoseMode.reps ? (i.reps ?? 10) * repSeconds(d) : (i.workSeconds ?? 30).toDouble())
              : i.segments.fold(0.0, (sum, s) => sum + _segmentSeconds(s, c));
          final switches = i.segments.isEmpty ? 1 : i.segments.length;
          total +=
              i.sets * (work * sides + (sides == 2 ? switchSideSeconds * switches : 0)) + (i.sets - 1) * i.restSeconds;
        }
        if (r < b.rounds - 1) {
          total += b.restBetweenRoundsSeconds > transitionSeconds ? b.restBetweenRoundsSeconds : transitionSeconds;
        }
      }
    }
    return total;
  }

  double _segmentSeconds(PlanSegment s, Catalog c) {
    if (s.mode == DoseMode.time) return (s.workSeconds ?? 30).toDouble();
    final rhythm = s.rhythm ?? c[s.exerciseId]?.raw['rhythm'];
    if (rhythm is Map && rhythm['phases'] is List) {
      final phases = rhythm['phases'] as List;
      final derived = rhythm['source'] == 'repSeconds' || rhythm['source'] == 'dose';
      if (s.holdSeconds != null && derived && !phases.any((p) => p is Map && p['id'] == 'hold')) {
        return (s.reps ?? 10) * s.holdSeconds!.toDouble();
      }
      var cycle = 0.0;
      for (final phase in phases) {
        if (phase is! Map) continue;
        final hold = s.holdSeconds ?? rhythm['holdSeconds'];
        final seconds = phase['id'] == 'hold' && hold is num ? hold : phase['seconds'];
        if (seconds is num) cycle += seconds.toDouble();
      }
      if (cycle > 0) {
        final lead = rhythm['leadSeconds'];
        return (lead is num ? lead.toDouble() : 1) + (s.reps ?? 10) * cycle;
      }
    }
    final d = c[s.exerciseId];
    return (s.reps ?? 10) * (s.holdSeconds?.toDouble() ?? (d == null ? defaultRepSeconds : repSeconds(d)));
  }
}
