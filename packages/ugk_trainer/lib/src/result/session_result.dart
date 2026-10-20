// ugk_trainer's own: one record per training session (3D-Body kept one per
// exercise, and a retried save collided on its Session ID). The id is fixed
// when the session starts; the app stores the result keyed by it, so saving
// the same result again (a retry) is an upsert, never a second record.
// Pure Dart.
import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../engine/session.dart';

/// What the user chose after 不舒服.
enum DiscomfortAction {
  /// 减小幅度，继续.
  continueEasier,
  skip,
  end,

  /// Swap the exercise for another (the app names it).
  substitute,
}

class DiscomfortEvent {
  const DiscomfortEvent({
    required this.at,
    required this.exerciseId,
    required this.action,
    this.blockIndex = -1,
    this.itemInBlock = -1,
    this.set = 0,
    this.side,
    this.substituteId,
    this.note,
  });

  /// Active session seconds.
  final double at;
  final String? exerciseId;
  final int blockIndex;
  final int itemInBlock;
  final int set;
  final Side? side;
  final DiscomfortAction action;
  final String? substituteId;

  /// Free text from the app (HipLab: the pain level).
  final String? note;

  Map<String, Object?> toJson() => {
    'at': double.parse(at.toStringAsFixed(2)),
    'exerciseId': exerciseId,
    'blockIndex': blockIndex,
    'itemIndex': itemInBlock,
    'set': set,
    'side': ?side?.name,
    'action': action.name,
    'substituteId': ?substituteId,
    'note': ?note,
  };

  factory DiscomfortEvent.fromJson(Map<String, dynamic> j) => DiscomfortEvent(
    at: (j['at'] as num).toDouble(),
    exerciseId: j['exerciseId'] as String?,
    blockIndex: (j['blockIndex'] as num? ?? -1).toInt(),
    itemInBlock: (j['itemIndex'] as num? ?? -1).toInt(),
    set: (j['set'] as num? ?? 0).toInt(),
    side: Side.values.where((s) => s.name == j['side']).firstOrNull,
    action: DiscomfortAction.values.firstWhere(
      (a) => a.name == j['action'],
      orElse: () => DiscomfortAction.continueEasier,
    ),
    substituteId: j['substituteId'] as String?,
    note: j['note'] as String?,
  );
}

enum ItemStatus { completed, partial, skipped, notReached }

/// One plan item (a circuit item over all its rounds).
class ItemResult {
  const ItemResult({
    required this.exerciseId,
    required this.blockIndex,
    required this.itemInBlock,
    required this.plannedSets,
    required this.completedSets,
    required this.activeSeconds,
    required this.status,
    this.replacedFrom,
    this.plannedSideSets = const {},
    this.completedSideSets = const {},
  });

  /// The exercise actually done (after a substitute).
  final String exerciseId;
  final int blockIndex;
  final int itemInBlock;

  /// sets × rounds.
  final int plannedSets;
  final int completedSets;

  /// Seconds spent in this item's work phases (pauses excluded).
  final double activeSeconds;
  final ItemStatus status;
  final String? replacedFrom;

  /// Optional per-side detail when sides have different doses/set counts.
  final Map<String, int> plannedSideSets;
  final Map<String, int> completedSideSets;

  Map<String, Object?> toJson() => {
    'exerciseId': exerciseId,
    'blockIndex': blockIndex,
    'itemIndex': itemInBlock,
    'plannedSets': plannedSets,
    'completedSets': completedSets,
    'activeSeconds': activeSeconds.round(),
    'status': status.name,
    'replacedFrom': ?replacedFrom,
    if (plannedSideSets.isNotEmpty) 'plannedSideSets': plannedSideSets,
    if (completedSideSets.isNotEmpty) 'completedSideSets': completedSideSets,
  };

  factory ItemResult.fromJson(Map<String, dynamic> j) => ItemResult(
    exerciseId: j['exerciseId'] as String,
    blockIndex: (j['blockIndex'] as num).toInt(),
    itemInBlock: (j['itemIndex'] as num).toInt(),
    plannedSets: (j['plannedSets'] as num).toInt(),
    completedSets: (j['completedSets'] as num).toInt(),
    activeSeconds: (j['activeSeconds'] as num).toDouble(),
    status: ItemStatus.values.firstWhere(
      (s) => s.name == j['status'],
      orElse: () => ItemStatus.notReached,
    ),
    replacedFrom: j['replacedFrom'] as String?,
    plannedSideSets: {
      for (final e in (j['plannedSideSets'] as Map? ?? const {}).entries)
        e.key as String: (e.value as num).toInt(),
    },
    completedSideSets: {
      for (final e in (j['completedSideSets'] as Map? ?? const {}).entries)
        e.key as String: (e.value as num).toInt(),
    },
  );
}

class SessionResult {
  const SessionResult({
    required this.sessionId,
    required this.planId,
    required this.planTitle,
    required this.startedAt,
    required this.endedAt,
    required this.activeSeconds,
    required this.endedEarly,
    required this.completedExercises,
    required this.totalExercises,
    required this.items,
    this.discomfort = const [],
  });

  static const schema = 'ugk-session-result@1';

  /// Fixed when the session starts: the key the app saves under.
  final String sessionId;
  final String planId;
  final String planTitle;
  final DateTime startedAt;
  final DateTime endedAt;

  /// Training time, pauses excluded.
  final double activeSeconds;
  final bool endedEarly;
  final int completedExercises;
  final int totalExercises;
  final List<ItemResult> items;
  final List<DiscomfortEvent> discomfort;

  bool get full => !endedEarly && completedExercises >= totalExercises;
  int get minutes => (activeSeconds / 60).round();

  Map<String, Object?> toJson() => {
    'schema': schema,
    'sessionId': sessionId,
    'planId': planId,
    'planTitle': planTitle,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'endedAt': endedAt.toUtc().toIso8601String(),
    'activeSeconds': activeSeconds.round(),
    'endedEarly': endedEarly,
    'completedExercises': completedExercises,
    'totalExercises': totalExercises,
    'items': [for (final i in items) i.toJson()],
    'discomfort': [for (final d in discomfort) d.toJson()],
  };

  factory SessionResult.fromJson(Map<String, dynamic> j) => SessionResult(
    sessionId: j['sessionId'] as String,
    planId: j['planId'] as String,
    planTitle: j['planTitle'] as String? ?? '',
    startedAt: DateTime.parse(j['startedAt'] as String),
    endedAt: DateTime.parse(j['endedAt'] as String),
    activeSeconds: (j['activeSeconds'] as num).toDouble(),
    endedEarly: j['endedEarly'] == true,
    completedExercises: (j['completedExercises'] as num).toInt(),
    totalExercises: (j['totalExercises'] as num).toInt(),
    items: [
      for (final i in j['items'] as List? ?? const [])
        ItemResult.fromJson(Map<String, dynamic>.from(i as Map)),
    ],
    discomfort: [
      for (final d in j['discomfort'] as List? ?? const [])
        DiscomfortEvent.fromJson(Map<String, dynamic>.from(d as Map)),
    ],
  );
}

/// A new session id: start time (ms, base 36) + 48 random bits.
String newSessionId([math.Random? random]) {
  final r = random ?? math.Random.secure();
  final ms = clock.now().millisecondsSinceEpoch.toRadixString(36);
  final bits = List.generate(
    3,
    (_) => r.nextInt(1 << 16).toRadixString(16).padLeft(4, '0'),
  ).join();
  return 's-$ms-$bits';
}

/// Collects one session's result. Created when the session starts (the id
/// is fixed then); [finish] freezes the result, later calls return the
/// same object.
class SessionRecorder {
  SessionRecorder({
    required this.plan,
    required this.totalExercises,
    String? sessionId,
    DateTime? startedAt,
  }) : sessionId = sessionId ?? newSessionId(),
       startedAt = startedAt ?? clock.now();

  final TrainingPlan plan;
  final int totalExercises;
  final String sessionId;
  final DateTime startedAt;
  final List<DiscomfortEvent> _discomfort = [];
  SessionResult? _result;

  SessionResult? get result => _result;
  bool get finished => _result != null;

  void discomfort(DiscomfortEvent e) {
    if (_result == null) _discomfort.add(e);
  }

  SessionResult finish(SessionEngine engine, {required double activeSeconds}) {
    final done = _result;
    if (done != null) return done;
    return _result = SessionResult(
      sessionId: sessionId,
      planId: plan.id,
      planTitle: plan.title,
      startedAt: startedAt,
      endedAt: clock.now(),
      activeSeconds: activeSeconds,
      endedEarly: engine.endedEarly,
      completedExercises: engine.fullyCompletedExercises,
      totalExercises: totalExercises,
      items: itemsOf(plan, engine),
      discomfort: List.unmodifiable(_discomfort),
    );
  }

  /// Per-item stats from the engine's visit log: a set counts when its last
  /// side's work ran out or was completed (完成本组).
  static List<ItemResult> itemsOf(TrainingPlan plan, SessionEngine engine) {
    final out = <ItemResult>[];
    for (final (bi, b) in plan.blocks.indexed) {
      final circuit = b.type == BlockType.circuit && b.rounds > 1;
      for (final (ii, item) in b.items.indexed) {
        final planned = circuit ? b.rounds : item.sets;
        final mine = engine.visits.where(
          (v) => v.phase.blockIndex == bi && v.phase.itemInBlock == ii,
        );
        final work = mine.where((v) => v.phase.isWork).toList();
        final sideRequirements = <(int, Side), int>{};
        for (final phase in engine.initialWorkPhases) {
          if (phase.blockIndex != bi ||
              phase.itemInBlock != ii ||
              phase.side == null) {
            continue;
          }
          final key = (phase.itemIndex, phase.side!);
          final n = phase.sets > 0 ? phase.sets : 1;
          if (n > (sideRequirements[key] ?? 0)) sideRequirements[key] = n;
        }
        final sideCompleted = <Side, Set<(int, int)>>{};
        for (final visit in work) {
          final phase = visit.phase;
          if (phase.side == null ||
              (visit.exit != PhaseExit.natural &&
                  visit.exit != PhaseExit.completed)) {
            continue;
          }
          sideCompleted.putIfAbsent(phase.side!, () => {}).add((
            phase.itemIndex,
            phase.set,
          ));
        }
        var completed = 0;
        for (final v in work) {
          final lastSide = !item.perSide || v.phase.side == Side.left;
          if (lastSide &&
              (v.exit == PhaseExit.natural || v.exit == PhaseExit.completed)) {
            completed++;
          }
        }
        if (completed > planned) completed = planned;
        final skipped = mine.any(
          (v) =>
              (v.phase.isWork || v.phase.kind == PhaseKind.switchSide) &&
              v.exit == PhaseExit.skipped,
        );
        final status = completed >= planned
            ? ItemStatus.completed
            : skipped
            ? ItemStatus.skipped
            : work.isEmpty
            ? ItemStatus.notReached
            : ItemStatus.partial;
        final ids = work.map((v) => v.phase.exerciseId).whereType<String>();
        final actual = ids.isEmpty ? item.exerciseId : ids.last;
        out.add(
          ItemResult(
            exerciseId: actual,
            blockIndex: bi,
            itemInBlock: ii,
            plannedSets: planned,
            completedSets: completed,
            activeSeconds: work.fold(0.0, (s, v) => s + v.seconds),
            status: status,
            replacedFrom: actual != item.exerciseId ? item.exerciseId : null,
            plannedSideSets: {
              for (final side in Side.values)
                if (sideRequirements.keys.any((key) => key.$2 == side))
                  side.name: sideRequirements.entries
                      .where((e) => e.key.$2 == side)
                      .fold(0, (sum, e) => sum + e.value),
            },
            completedSideSets: {
              for (final side in Side.values)
                if (sideRequirements.keys.any((key) => key.$2 == side))
                  side.name: sideCompleted[side]?.length ?? 0,
            },
          ),
        );
      }
    }
    return out;
  }
}

/// Saves a result through the app's callback: one save at a time, a failed
/// save can be retried (same result, same id), a saved result is never
/// sent again.
class ResultSaver {
  ResultSaver(this.save);
  final Future<void> Function(SessionResult result) save;

  Future<bool>? _running;
  bool _saved = false;
  Object? lastError;

  bool get saved => _saved;

  /// True when saved (now or before).
  Future<bool> call(SessionResult result) {
    if (_saved) return Future.value(true);
    return _running ??= _run(result);
  }

  Future<bool> _run(SessionResult result) async {
    try {
      // A synchronous throw must also yield before clearing _running:
      // call() assigns the returned future after _run() starts.
      await Future<void>.sync(() => save(result));
      _saved = true;
      lastError = null;
      return true;
    } on Object catch (e) {
      lastError = e;
      return false;
    } finally {
      _running = null;
    }
  }
}
