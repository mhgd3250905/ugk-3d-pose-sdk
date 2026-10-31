// Ported from SmartFit@e8981ee lib/domain/session.dart (SessionPhase,
// SessionBuilder, SessionEngine), itself after HipLab@99fcc83
// lib/hip/voice/session_engine.dart. Changes for ugk_trainer:
// * input is ugk_coach's TrainingPlan v1 plus one [Rhythm] per action;
// * a counted work phase is as long as its rhythm needs (lead + reps ×
//   cycle, with rep_hold's holdSeconds applied); a SmartFit repSeconds
//   rhythm stays reps × repSeconds;
// * self-paced work (decision A): the clock never ends it, [SessionEngine.
//   completeSet] does (完成本组);
// * the side-switch gap can be widened by the voice script (HipLab
//   switchMargin, see SessionScript.switchSecondsFor);
// * every phase visit is logged ([PhaseVisit]) for the SessionResult;
// * [SessionEngine.restartWith] swaps the phases from the current exercise
//   on (substitute after 不舒服).
// Pure Dart.
import 'package:ugk_coach/ugk_coach.dart';

import '../rhythm/rhythm.dart';

enum PhaseKind { prep, work, switchSide, rest, roundRest, done }

enum Side { right, left }

class SessionPhase {
  const SessionPhase({
    required this.kind,
    required this.seconds,
    this.exerciseId,
    this.item,
    this.itemIndex = -1,
    this.blockIndex = -1,
    this.itemInBlock = -1,
    this.set = 0,
    this.sets = 0,
    this.round = 0,
    this.rounds = 0,
    this.side,
    this.blockName = '',
    this.reps,
    this.repSeconds,
    this.rhythm,
    this.selfPaced = false,
    this.holdSeconds,
    this.nextExerciseId,
    this.nextItem,
    this.doneExerciseId,
    this.segmentId,
    this.segment,
  });

  final PhaseKind kind;

  /// Fixed length. A self-paced work phase has no end of its own: this is
  /// only its estimate (reps × 3 s) for totals and the keep-alive cap.
  final double seconds;

  /// The exercise on screen: the one being done, or the upcoming one during
  /// prep / rest.
  final String? exerciseId;
  final PlanItem? item;

  /// Stable segment identity within [item]; null for legacy single-part items.
  final String? segmentId;
  final PlanSegment? segment;

  SessionPhase withSeconds(double value) => SessionPhase(
    kind: kind,
    seconds: value,
    exerciseId: exerciseId,
    item: item,
    itemIndex: itemIndex,
    blockIndex: blockIndex,
    itemInBlock: itemInBlock,
    set: set,
    sets: sets,
    round: round,
    rounds: rounds,
    side: side,
    blockName: blockName,
    reps: reps,
    repSeconds: repSeconds,
    rhythm: rhythm,
    selfPaced: selfPaced,
    holdSeconds: holdSeconds,
    nextExerciseId: nextExerciseId,
    nextItem: nextItem,
    doneExerciseId: doneExerciseId,
    segmentId: segmentId,
    segment: segment,
  );

  /// Index of the exercise occurrence in play order (for progress / skip).
  final int itemIndex;

  /// Where [item] sits in the plan (for the result).
  final int blockIndex;
  final int itemInBlock;

  /// 1-based set number and total sets of this item (work / rest phases).
  final int set;
  final int sets;

  /// 1-based main/circuit round and total rounds (0 for a single round).
  final int round;
  final int rounds;
  final Side? side;
  final String blockName;

  /// Reps to count in a work phase (reps dose, or a counted rhythm).
  final int? reps;

  /// Seconds of one rep at the rhythm's pace (null for holds and
  /// self-paced sets).
  final double? repSeconds;

  /// The effective rhythm of the work (and side-switch) phase.
  final Rhythm? rhythm;
  final bool selfPaced;

  /// rep_hold: seconds held at the top of each rep.
  final int? holdSeconds;

  /// During rest: what comes next (null when the next set is the same item).
  final String? nextExerciseId;
  final PlanItem? nextItem;

  /// During the rest after an exercise: the one just finished (for "X，完成").
  final String? doneExerciseId;

  bool get isWork => kind == PhaseKind.work;

  /// Counted on the clock (the ring shows the rep, not seconds).
  bool get countedOnClock => isWork && !selfPaced && reps != null;

  /// The rep shown at [elapsed] seconds into a counted work phase.
  int? repAt(double elapsed) {
    final n = reps;
    final r = rhythm;
    if (!countedOnClock || n == null || r == null) return null;
    if (r.derived) {
      final rep = repSeconds ?? 3;
      return ((elapsed / rep).floor() + 1).clamp(1, n);
    }
    final plan = r.repPlan(reps: n, hold: holdSeconds, seconds: seconds);
    if (plan.reps == 0) return 1;
    final k = ((elapsed - plan.lead) / plan.cycle).floor() + 1;
    return k.clamp(1, plan.reps);
  }

  @override
  String toString() =>
      '${kind.name}${selfPaced ? '(self)' : ''} $exerciseId s$set/$sets '
      'r$round/$rounds ${side?.name ?? ''} ${seconds.toStringAsFixed(1)}s';
}

/// One occurrence of an item in play order (main/circuit rounds repeat items).
class _Occurrence {
  _Occurrence(
    this.block,
    this.blockIndex,
    this.itemInBlock,
    this.item,
    this.round,
    this.rounds,
    this.sets,
  );
  final PlanBlock block;
  final int blockIndex;
  final int itemInBlock;
  final PlanItem item;
  final int round;
  final int rounds;
  final int sets;
}

/// Widens the side-switch gap for [item] switching to [side] (the voice
/// script makes room for its line before the 3-2-1).
typedef SwitchSeconds =
    double Function(PlanItem item, Rhythm rhythm, Side side);

class SessionBuilder {
  SessionBuilder({
    this.rhythms = const {},
    this.known,
    this.prepSeconds = 10,
    this.switchSideSeconds = 5,
    this.transitionSeconds = 15,
    this.selfPacedRepEstimate = 3.0,
    this.switchSecondsFor,
    this.rhythmDefaults = const RhythmDefaults(),
  });

  /// Rhythm by exercise id; missing ids fall back to [Rhythm.forDose].
  final Map<String, Rhythm> rhythms;

  /// Exercises the app can play; others are left out. Null: all.
  final bool Function(String exerciseId)? known;
  final int prepSeconds;
  final int switchSideSeconds;

  /// Rest before a new exercise (and the floor of a round rest), as
  /// ugk_coach PlanDuration.
  final int transitionSeconds;
  final double selfPacedRepEstimate;
  final SwitchSeconds? switchSecondsFor;
  final RhythmDefaults rhythmDefaults;

  Rhythm rhythmOf(PlanItem item) =>
      (rhythms[item.exerciseId] ??
              Rhythm.forDose(item.mode, defaults: rhythmDefaults))
          .effectiveFor(item, defaults: rhythmDefaults);

  Rhythm _segmentRhythm(PlanSegment segment, PlanItem dose) {
    var rhythm = segment.rhythm != null
        ? Rhythm.fromJson(segment.rhythm!)
        : rhythms[dose.exerciseId] ??
              Rhythm.forDose(
                dose.mode,
                defaults: rhythmDefaults,
                holdSeconds: segment.holdSeconds?.toDouble(),
              );
    final hold = segment.holdSeconds;
    if (hold != null) {
      // A derived go-only fallback has no hold phase for withHold to alter.
      // An explicit segment hold supplies rep duration until authored phases exist.
      rhythm = rhythm.derived && !rhythm.phases.any((p) => p.id == 'hold')
          ? Rhythm.forDose(
              dose.mode,
              defaults: rhythmDefaults,
              holdSeconds: hold.toDouble(),
            ).withHold(hold)
          : rhythm.withHold(hold);
    }
    return rhythm.effectiveFor(dose, defaults: rhythmDefaults);
  }

  /// Seconds of one side of one set of [item].
  double workSeconds(PlanItem item, [Rhythm? rhythm]) {
    final r = rhythm ?? rhythmOf(item);
    if (r.selfPaced) return (item.reps ?? 10) * selfPacedRepEstimate;
    if (!r.counted) return (item.workSeconds ?? 30).toDouble();
    if (r.derived) return (item.reps ?? 10) * r.cycleFor();
    if (item.mode == DoseMode.reps) {
      return r.sideSeconds(reps: item.reps, budget: 0).toDouble();
    }
    return r.sideSeconds(budget: item.workSeconds ?? 30).toDouble();
  }

  List<_Occurrence> _occurrences(TrainingPlan plan) {
    final out = <_Occurrence>[];
    for (final (bi, b) in plan.blocks.indexed) {
      final circuit = b.type == BlockType.circuit && b.rounds > 1;
      final repeated =
          (b.type == BlockType.main || b.type == BlockType.circuit) &&
          b.rounds > 1;
      final rounds = repeated ? b.rounds : 1;
      for (var r = 1; r <= rounds; r++) {
        for (final (ii, item) in b.items.indexed) {
          final segmentIds = <String>{};
          for (final segment in item.segments) {
            if (segment.id.trim().isEmpty || !segmentIds.add(segment.id)) {
              throw ArgumentError(
                'Segment ids must be nonempty and unique within an item',
              );
            }
            if (segment.rhythm?['kind'] == 'self_paced') {
              throw ArgumentError(
                'self_paced must be supplied by the exercise catalog, not a plan segment',
              );
            }
          }
          if (known != null &&
              (item.segments.isEmpty
                  ? !known!(item.exerciseId)
                  : item.segments.any((s) => !known!(s.exerciseId)))) {
            continue;
          }
          out.add(
            _Occurrence(
              b,
              bi,
              ii,
              item,
              repeated ? r : 0,
              repeated ? rounds : 0,
              circuit ? 1 : item.sets,
            ),
          );
        }
      }
    }
    return out;
  }

  List<SessionPhase> phases(TrainingPlan plan) {
    final occ = _occurrences(plan);
    final out = <SessionPhase>[];
    if (occ.isEmpty) {
      return [const SessionPhase(kind: PhaseKind.done, seconds: 0)];
    }
    final f = occ.first;
    out.add(
      SessionPhase(
        kind: PhaseKind.prep,
        seconds: prepSeconds.toDouble(),
        exerciseId:
            f.item.segments.firstOrNull?.exerciseId ?? f.item.exerciseId,
        segment: f.item.segments.firstOrNull,
        segmentId: f.item.segments.firstOrNull?.id,
        item: f.item,
        itemIndex: 0,
        blockIndex: f.blockIndex,
        itemInBlock: f.itemInBlock,
        sets: f.sets,
        set: 1,
        round: f.round,
        rounds: f.rounds,
        blockName: f.block.name,
      ),
    );
    for (var i = 0; i < occ.length; i++) {
      final o = occ[i];
      final item = o.item;
      for (var s = 1; s <= o.sets; s++) {
        final segments = item.segments.isEmpty
            ? <PlanSegment?>[null]
            : item.segments;
        for (final segment in segments) {
          final dose = segment?.toPlanItem(item) ?? item;
          final rhythm = segment == null
              ? rhythmOf(item)
              : _segmentRhythm(segment, dose);
          final work = workSeconds(dose, rhythm);
          final counted = rhythm.counted;
          final reps = rhythm.selfPaced
              ? dose.reps
              : counted
              ? (dose.mode == DoseMode.reps
                    ? dose.reps
                    : (rhythm.defaultReps ?? 1))
              : null;
          SessionPhase at(PhaseKind kind, double seconds, Side? side) =>
              SessionPhase(
                kind: kind,
                seconds: seconds,
                exerciseId: dose.exerciseId,
                item: item,
                segmentId: segment?.id,
                segment: segment,
                itemIndex: i,
                blockIndex: o.blockIndex,
                itemInBlock: o.itemInBlock,
                set: s,
                sets: o.sets,
                round: o.round,
                rounds: o.rounds,
                side: side,
                blockName: o.block.name,
                reps: kind == PhaseKind.work ? reps : null,
                repSeconds: kind == PhaseKind.work && counted
                    ? rhythm.cycleFor()
                    : null,
                rhythm: rhythm,
                selfPaced: kind == PhaseKind.work && rhythm.selfPaced,
                holdSeconds: kind == PhaseKind.work ? rhythm.holdSeconds : null,
              );
          final sides = item.perSide ? [Side.right, Side.left] : [null];
          for (var k = 0; k < sides.length; k++) {
            if (k > 0) {
              final side = sides[k]!;
              final base = switchSideSeconds.toDouble();
              final widened =
                  switchSecondsFor?.call(dose, rhythm, side) ?? base;
              out.add(
                at(PhaseKind.switchSide, widened > base ? widened : base, side),
              );
            }
            out.add(at(PhaseKind.work, work, sides[k]));
          }
        }
        if (s < o.sets) {
          out.add(
            SessionPhase(
              kind: PhaseKind.rest,
              seconds: item.restSeconds.toDouble(),
              exerciseId:
                  item.segments.firstOrNull?.exerciseId ?? item.exerciseId,
              segment: item.segments.firstOrNull,
              segmentId: item.segments.firstOrNull?.id,
              item: item,
              itemIndex: i,
              blockIndex: o.blockIndex,
              itemInBlock: o.itemInBlock,
              set: s + 1,
              sets: o.sets,
              round: o.round,
              rounds: o.rounds,
              blockName: o.block.name,
            ),
          );
        }
      }
      if (i < occ.length - 1) {
        final n = occ[i + 1];
        final roundBoundary =
            n.block == o.block && n.round != o.round && o.rounds > 0;
        final restLen = roundBoundary
            ? (o.block.restBetweenRoundsSeconds > transitionSeconds
                  ? o.block.restBetweenRoundsSeconds
                  : transitionSeconds)
            : transitionSeconds;
        out.add(
          SessionPhase(
            kind: roundBoundary ? PhaseKind.roundRest : PhaseKind.rest,
            seconds: restLen.toDouble(),
            exerciseId:
                n.item.segments.firstOrNull?.exerciseId ?? n.item.exerciseId,
            segment: n.item.segments.firstOrNull,
            segmentId: n.item.segments.firstOrNull?.id,
            item: n.item,
            itemIndex: i + 1,
            blockIndex: n.blockIndex,
            itemInBlock: n.itemInBlock,
            set: 1,
            sets: n.sets,
            round: n.round,
            rounds: n.rounds,
            blockName: n.block.name,
            nextExerciseId: n.item.exerciseId,
            nextItem: n.item,
            doneExerciseId: o.item.exerciseId,
          ),
        );
      }
    }
    out.add(
      SessionPhase(kind: PhaseKind.done, seconds: 0, itemIndex: occ.length),
    );
    return out;
  }

  /// Total seconds of the plan excluding the lead-in (self-paced sets at
  /// their estimate).
  double planSeconds(TrainingPlan plan) => phases(
    plan,
  ).where((p) => p.kind != PhaseKind.prep).fold(0.0, (s, p) => s + p.seconds);

  int occurrenceCount(TrainingPlan plan) => _occurrences(plan).length;
}

/// How a phase was left.
enum PhaseExit {
  /// Its time ran out.
  natural,

  /// User completion of a self-paced set or a timed work phase.
  completed,

  /// 跳过.
  skipped,

  /// 上一个.
  back,

  /// Ended early (结束 / 不适 → end / closing the player).
  ended,

  /// Replaced (substitute).
  replaced,
}

/// One stretch of active time spent in one phase.
class PhaseVisit {
  const PhaseVisit(this.phase, this.start, this.end, this.exit);
  final SessionPhase phase;
  final double start;
  final double end;
  final PhaseExit exit;
  double get seconds => end - start;
}

/// The training clock: absolute active time (pauses excluded) decides the
/// phase, so dropped frames, a throttled timer or a stretch in the
/// background never drift the count.
class SessionEngine {
  /// Only absorbs floating-point arithmetic error, never a visible timer tick.
  static const phaseEndTolerance = 1e-9;
  SessionEngine(List<SessionPhase> phases)
    : _phases = List.unmodifiable(phases),
      initialWorkPhases = List.unmodifiable(phases.where((p) => p.isWork)) {
    for (final phase in phases.where((p) => p.isWork)) {
      _requiredWork.putIfAbsent(phase.itemIndex, () => {}).add((
        phase.set,
        phase.side,
        phase.segmentId,
      ));
    }
  }

  List<SessionPhase> _phases;

  /// Original work arrangement, before substitutions/direction filtering.
  final List<SessionPhase> initialWorkPhases;
  int _index = 0;
  double _phaseStart = 0;
  bool _enteredBySkip = false;
  int? _completedOnEarlyEnd;
  final List<PhaseVisit> _visits = [];
  final Map<int, Set<(int, Side?, String?)>> _requiredWork = {};

  /// Bumped every time the phase changes (for listeners).
  int generation = 0;

  List<SessionPhase> get phases => _phases;
  SessionPhase get phase => _phases[_index];
  int get index => _index;
  bool get done => phase.kind == PhaseKind.done;
  bool get endedEarly => _completedOnEarlyEnd != null;
  double get phaseStart => _phaseStart;
  bool get enteredBySkip => _enteredBySkip;

  /// Waiting for 完成本组.
  bool get awaitingCompletion => !done && phase.selfPaced;

  /// Every phase left so far, in order.
  List<PhaseVisit> get visits => List.unmodifiable(_visits);

  double elapsedIn(double t) {
    final e = t - _phaseStart;
    if (e < 0) return 0;
    if (phase.selfPaced) return e;
    return e > phase.seconds ? phase.seconds : e;
  }

  double remainingIn(double t) =>
      phase.selfPaced ? 0 : phase.seconds - elapsedIn(t);
  int secondsLeft(double t) => remainingIn(t).ceil();

  /// Exercise occurrences fully passed (prep 0; a transition rest already
  /// points at the next one, so its index equals the count done).
  int get completedExercises =>
      _completedOnEarlyEnd ?? phase.itemIndex.clamp(0, 1 << 30);

  /// Exercises whose originally required sets/sides/segments actually finished.
  /// [completedExercises] is a navigation position and includes skipped items.
  int get fullyCompletedExercises {
    final finished = <int, Set<(int, Side?, String?)>>{};
    for (final v in _visits) {
      if (v.phase.isWork &&
          (v.exit == PhaseExit.natural || v.exit == PhaseExit.completed)) {
        finished.putIfAbsent(v.phase.itemIndex, () => {}).add((
          v.phase.set,
          v.phase.side,
          v.phase.segmentId,
        ));
      }
    }
    return _requiredWork.entries
        .where(
          (entry) => finished[entry.key]?.containsAll(entry.value) ?? false,
        )
        .length;
  }

  void _leave(double at, PhaseExit exit) {
    if (done) return;
    _visits.add(PhaseVisit(phase, _phaseStart, at, exit));
  }

  /// Advance to active time [t]; returns true when the phase changed. A
  /// self-paced set holds the clock until [completeSet].
  bool update(double t) {
    var changed = false;
    while (!done &&
        !phase.selfPaced &&
        t + phaseEndTolerance >= _phaseStart + phase.seconds) {
      final end = _phaseStart + phase.seconds;
      _leave(end, PhaseExit.natural);
      _phaseStart = end;
      _index++;
      _enteredBySkip = false;
      changed = true;
    }
    if (changed) generation++;
    return changed;
  }

  /// 完成本组: ends a self-paced set at [t]; false when not in one.
  bool completeSet(double t) {
    update(t);
    if (!awaitingCompletion) return false;
    _leave(t, PhaseExit.completed);
    _index++;
    _phaseStart = t;
    _enteredBySkip = false;
    generation++;
    return true;
  }

  /// Finish the current timed work phase early. Counted reps and explicit
  /// self-paced work keep their own completion rules.
  bool completeTimedPhase(double t) {
    // A click arriving at the boundary belongs to the phase just shown;
    // never complete the newly entered work phase as well.
    if (update(t)) return false;
    if (!phase.isWork || phase.selfPaced || phase.countedOnClock) return false;
    _leave(t, PhaseExit.completed);
    _index++;
    _phaseStart = t;
    _enteredBySkip = false;
    generation++;
    return true;
  }

  /// Add active seconds to the current rest without restarting its clock.
  bool extendRest(double t, {double seconds = 15}) {
    if (!seconds.isFinite || seconds <= 0) {
      throw ArgumentError.value(
        seconds,
        'seconds',
        'must be finite and positive',
      );
    }
    if (update(t)) return false;
    if (phase.kind != PhaseKind.rest && phase.kind != PhaseKind.roundRest) {
      return false;
    }
    final updated = _phases.toList();
    updated[_index] = phase.withSeconds(phase.seconds + seconds);
    _phases = List.unmodifiable(updated);
    generation++;
    return true;
  }

  /// Skip the remaining sides of this segment, retaining the other segments
  /// and sets. A legacy item without segments is unaffected.
  bool skipSegment(double t) {
    if (update(t)) return false;
    if (done ||
        phase.segmentId == null ||
        (!phase.isWork && phase.kind != PhaseKind.switchSide)) {
      return false;
    }
    final current = phase;
    var target = _index + 1;
    while (target < _phases.length - 1 &&
        _phases[target].itemIndex == current.itemIndex &&
        _phases[target].set == current.set &&
        _phases[target].segmentId == current.segmentId) {
      target++;
    }
    _jump(target, t, PhaseExit.skipped);
    return true;
  }

  void _jump(int index, double t, PhaseExit exit) {
    _leave(t, exit);
    _completedOnEarlyEnd = null;
    _index = index.clamp(0, _phases.length - 1);
    _phaseStart = t;
    _enteredBySkip = true;
    generation++;
  }

  /// 跳过: from prep / rest straight into the next work; from work (any
  /// set or side) to the rest before the next exercise.
  void skip(double t) {
    update(t);
    if (done) return;
    var target = _index + 1;
    if (phase.kind == PhaseKind.work || phase.kind == PhaseKind.switchSide) {
      final cur = phase.itemIndex;
      while (target < _phases.length - 1 && _phases[target].itemIndex <= cur) {
        target++;
      }
    } else {
      while (target < _phases.length - 1 && !_phases[target].isWork) {
        target++;
      }
    }
    _jump(target, t, PhaseExit.skipped);
  }

  /// 上一个: back to the start of the previous exercise occurrence.
  void previous(double t) {
    update(t);
    final cur = phase.itemIndex;
    var target = _phases.indexWhere(
      (p) => p.itemIndex == (cur - 1).clamp(0, 1 << 30) && p.isWork,
    );
    if (target < 0) target = 0;
    _jump(target, t, PhaseExit.back);
  }

  /// End now, preserving progress instead of counting unvisited exercises.
  void finish(double t) {
    update(t);
    if (done) return;
    final completed = completedExercises;
    _jump(_phases.length - 1, t, PhaseExit.ended);
    _completedOnEarlyEnd = completed;
  }

  /// Replace the phases from the current exercise occurrence on with
  /// [phases] (a rebuilt plan with the same occurrences, e.g. a substitute)
  /// and restart at its first work phase.
  void restartWith(
    List<SessionPhase> phases,
    double t, {
    int? fromItemIndex,
    bool withRest = false,
  }) {
    update(t);
    if (done) return;
    final cur = fromItemIndex ?? phase.itemIndex;
    final head = _phases.sublist(0, _index);
    var tailStart = phases.indexWhere(
      (p) =>
          p.itemIndex >= cur &&
          (p.isWork ||
              (withRest &&
                  (p.kind == PhaseKind.rest || p.kind == PhaseKind.roundRest))),
    );
    // Direction filters may remove the current item and every later item.
    // Still enter done so saving and keep-alive release follow the usual path.
    if (tailStart < 0) {
      tailStart = phases.indexWhere((p) => p.kind == PhaseKind.done);
    }
    if (tailStart < 0) {
      throw ArgumentError('Replacement phases need a done phase');
    }
    _leave(t, PhaseExit.replaced);
    _phases = List.unmodifiable([...head, ...phases.sublist(tailStart)]);
    _index = head.length;
    _phaseStart = t;
    _enteredBySkip = true;
    generation++;
  }
}
