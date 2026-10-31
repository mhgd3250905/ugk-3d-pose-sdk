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

/// Optional, user-reported feeling selected on the completion page.
enum TrainingFeeling { easy, justRight, tired, uncomfortable }

/// One plan item, including every main/circuit round in its block.
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
    this.completedReps,
  });

  /// The exercise actually done (after a substitute).
  final String exerciseId;
  final int blockIndex;
  final int itemInBlock;

  /// Unique required sets in the initial arrangement (normally sets × rounds).
  final int plannedSets;
  final int completedSets;

  /// Seconds spent in this item's work phases (pauses excluded).
  final double activeSeconds;
  final ItemStatus status;
  final String? replacedFrom;

  /// Optional per-side detail when sides have different doses/set counts.
  final Map<String, int> plannedSideSets;
  final Map<String, int> completedSideSets;

  /// Repetitions completed by the session rhythm, or confirmed by the user
  /// for a self-paced set. Null when no repetition dose was recorded.
  final int? completedReps;

  Map<String, Object?> toJson() => {
    'exerciseId': exerciseId,
    'blockIndex': blockIndex,
    'itemIndex': itemInBlock,
    'plannedSets': plannedSets,
    'completedSets': completedSets,
    'activeSeconds': activeSeconds.round(),
    'status': status.name,
    'replacedFrom': ?replacedFrom,
    'completedReps': ?completedReps,
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
    completedReps: (j['completedReps'] as num?)?.toInt(),
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
    this.feeling,
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
  final TrainingFeeling? feeling;

  /// The completion event keeps the original saved session identity and data.
  SessionResult withFeeling(TrainingFeeling? value) => SessionResult(
    sessionId: sessionId,
    planId: planId,
    planTitle: planTitle,
    startedAt: startedAt,
    endedAt: endedAt,
    activeSeconds: activeSeconds,
    endedEarly: endedEarly,
    completedExercises: completedExercises,
    totalExercises: totalExercises,
    items: items,
    discomfort: discomfort,
    feeling: value,
  );

  int? get completedReps => items.any((item) => item.completedReps != null)
      ? items.fold<int>(0, (sum, item) => sum + (item.completedReps ?? 0))
      : null;
  double get workSeconds =>
      items.fold<double>(0, (sum, item) => sum + item.activeSeconds);

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
    'feeling': ?feeling?.name,
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
    feeling: TrainingFeeling.values
        .where((value) => value.name == j['feeling'])
        .firstOrNull,
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

  /// Unique sets complete only after every originally required side and
  /// segment completes. Repeated visits add time, never extra completed sets.
  static List<ItemResult> itemsOf(TrainingPlan plan, SessionEngine engine) {
    final out = <ItemResult>[];
    for (final (bi, b) in plan.blocks.indexed) {
      final circuit = b.type == BlockType.circuit && b.rounds > 1;
      for (final (ii, item) in b.items.indexed) {
        final mainRounds = b.type == BlockType.main && b.rounds > 1
            ? b.rounds
            : 1;
        final planned = circuit ? b.rounds : item.sets * mainRounds;
        final mine = engine.visits.where(
          (v) => v.phase.blockIndex == bi && v.phase.itemInBlock == ii,
        );
        final work = mine.where((v) => v.phase.isWork).toList();
        final requirements = <(int, int), Set<(Side?, String?)>>{};
        for (final phase in engine.initialWorkPhases) {
          if (phase.blockIndex != bi || phase.itemInBlock != ii) continue;
          requirements.putIfAbsent((phase.itemIndex, phase.set), () => {}).add((
            phase.side,
            phase.segmentId,
          ));
        }
        final finished = <(int, int), Set<(Side?, String?)>>{};
        for (final visit in work) {
          if (visit.exit != PhaseExit.natural &&
              visit.exit != PhaseExit.completed) {
            continue;
          }
          final phase = visit.phase;
          finished.putIfAbsent((phase.itemIndex, phase.set), () => {}).add((
            phase.side,
            phase.segmentId,
          ));
        }
        final completed = requirements.entries
            .where((e) => finished[e.key]?.containsAll(e.value) ?? false)
            .length;
        final sideRequirements = <Side, Set<(int, int)>>{};
        final sideCompleted = <Side, Set<(int, int)>>{};
        for (final entry in requirements.entries) {
          for (final side in Side.values) {
            final required = entry.value.where((v) => v.$1 == side).toSet();
            if (required.isEmpty) continue;
            sideRequirements.putIfAbsent(side, () => {}).add(entry.key);
            if (finished[entry.key]?.containsAll(required) ?? false) {
              sideCompleted.putIfAbsent(side, () => {}).add(entry.key);
            }
          }
        }
        final skipped = mine.any(
          (v) =>
              (v.phase.isWork || v.phase.kind == PhaseKind.switchSide) &&
              v.exit == PhaseExit.skipped,
        );
        final requiredSets = requirements.isEmpty
            ? planned
            : requirements.length;
        final status = completed >= requiredSets
            ? ItemStatus.completed
            : skipped &&
                  item.segments.isEmpty &&
                  !work.any((v) => v.phase.segmentId != null)
            ? ItemStatus.skipped
            : work.isEmpty
            ? ItemStatus.notReached
            : ItemStatus.partial;
        final ids = work
            .map(
              (v) => v.phase.segmentId != null
                  ? v.phase.item?.exerciseId ?? v.phase.exerciseId
                  : v.phase.exerciseId,
            )
            .whereType<String>();
        final actual = ids.isEmpty ? item.exerciseId : ids.last;
        out.add(
          ItemResult(
            exerciseId: actual,
            blockIndex: bi,
            itemInBlock: ii,
            plannedSets: requiredSets,
            completedSets: completed,
            activeSeconds: work.fold(0.0, (s, v) => s + v.seconds),
            completedReps:
                item.mode == DoseMode.reps ||
                    work.any((v) => v.phase.reps != null)
                ? work.fold<int>(0, (sum, visit) => sum + _repsOf(visit))
                : null,
            status: status,
            replacedFrom: actual != item.exerciseId ? item.exerciseId : null,
            plannedSideSets: {
              for (final e in sideRequirements.entries)
                e.key.name: e.value.length,
            },
            completedSideSets: {
              for (final side in sideRequirements.keys)
                side.name: sideCompleted[side]?.length ?? 0,
            },
          ),
        );
      }
    }
    return out;
  }

  static int _repsOf(PhaseVisit visit) {
    final phase = visit.phase;
    final target = phase.reps;
    if (target == null) return 0;
    if (phase.selfPaced) {
      return visit.exit == PhaseExit.completed ? target : 0;
    }
    if (!phase.countedOnClock) return 0;
    final rhythm = phase.rhythm;
    if (rhythm == null) return 0;
    final plan = rhythm.repPlan(
      reps: target,
      hold: phase.holdSeconds,
      seconds: phase.seconds,
    );
    final lead = rhythm.derived ? 0.0 : plan.lead;
    final cycle = rhythm.derived
        ? phase.repSeconds ??
              rhythm
                  .phasesFor(hold: phase.holdSeconds)
                  .fold<double>(0, (sum, part) => sum + part.seconds)
        : plan.cycle;
    return cycle <= 0
        ? 0
        : ((visit.seconds - lead + 1e-9) / cycle).floor().clamp(0, target);
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
