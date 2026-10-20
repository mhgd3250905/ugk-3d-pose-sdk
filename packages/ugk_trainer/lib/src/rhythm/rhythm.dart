// Rhythm = ActionKind + KitPhase: how one action is paced. The rep-plan
// maths (phasesFor / sideSeconds / stretch / repPlan) is ported from
// HipLab@99fcc83 lib/hip/domain/action_kit.dart (ActionKit), unchanged.
// Pure Dart.
//
// Where a rhythm comes from (decision C, 2026-10-20), in this order:
//   1. Pose-Hub catalog field `rhythm` (catalog 0.3.0, [Rhythm.fromJson]);
//   2. a HipLab action kit file ([Rhythm.fromActionKitJson]);
//   3. a clip's `repSeconds` ([Rhythm.fromRepSeconds], SmartFit);
//   4. the dose: time → timed hold, reps → self-paced ([Rhythm.forDose]).
import 'dart:math' as math;

import 'package:ugk_coach/ugk_coach.dart';

import 'action_kind.dart';

enum RhythmSource { catalog, actionKit, repSeconds, dose }

class Rhythm {
  const Rhythm({
    required this.kind,
    this.lead = 1.0,
    this.phases = const [],
    this.holdSeconds,
    this.defaultReps,
    this.selfPaced = false,
    this.source = RhythmSource.catalog,
  });

  final ActionKind kind;

  /// Seconds before the first count of a set.
  final double lead;

  /// One rep's phases (empty for holds and self-paced).
  final List<KitPhase> phases;

  /// rep_hold: seconds of the `hold` phase (overrides its authored length).
  final int? holdSeconds;

  /// Reps when the dose does not say (a counted action given a time dose).
  final int? defaultReps;

  /// Reps the user counts on their own: no timer, the set ends when they
  /// tap 完成本组 (decision A, 3D-Body).
  final bool selfPaced;
  final RhythmSource source;

  static const selfPacedReps = Rhythm(
    kind: ActionKind.repUpdown,
    lead: 0,
    selfPaced: true,
    source: RhythmSource.dose,
  );

  static const timedHold = Rhythm(
    kind: ActionKind.hold,
    lead: 0,
    source: RhythmSource.dose,
  );

  /// Default by dose when nothing else is known.
  static Rhythm forDose(DoseMode mode) =>
      mode == DoseMode.reps ? selfPacedReps : timedHold;

  /// A counted rep of [repSeconds] (SmartFit clips). Counts are said on the
  /// beat end, as SmartFit always did.
  factory Rhythm.fromRepSeconds(double repSeconds) => Rhythm(
    kind: ActionKind.repUpdown,
    lead: 0,
    phases: [KitPhase('go', repSeconds, const [])],
    source: RhythmSource.repSeconds,
  );

  /// Catalog `rhythm` field:
  /// `{"kind": "rep_hold" | … | "hold" | "self_paced", "leadSeconds": 1,
  ///   "phases": [{"id": "go", "seconds": 1.2, "cue": "w.up"}, …],
  ///   "holdSeconds": 10, "reps": 8}`.
  factory Rhythm.fromJson(Map<String, dynamic> j) {
    if (j['kind'] == 'self_paced') return selfPacedReps;
    return Rhythm(
      kind: ActionKind.byId(j['kind'] as String? ?? 'hold'),
      lead: (j['leadSeconds'] as num? ?? 1).toDouble(),
      phases: [
        for (final p in (j['phases'] as List?) ?? const [])
          KitPhase.fromJson(Map<String, dynamic>.from(p as Map)),
      ],
      holdSeconds: (j['holdSeconds'] as num?)?.toInt(),
      defaultReps: (j['reps'] as num?)?.toInt(),
      source: j['source'] == 'repSeconds'
          ? RhythmSource.repSeconds
          : RhythmSource.catalog,
    );
  }

  /// HipLab action kit (`action-kit@1`, `assets/action_kits/<id>.json`).
  factory Rhythm.fromActionKitJson(Map<String, dynamic> kit) {
    if (kit['schema'] != 'action-kit@1') {
      throw FormatException('action kit schema ${kit['schema']}');
    }
    final t = Map<String, dynamic>.from(kit['training'] as Map);
    final d = Map<String, dynamic>.from(t['defaults'] as Map? ?? const {});
    final cyc = t['cycle'] as Map?;
    return Rhythm(
      kind: ActionKind.byId(t['kind'] as String),
      lead: (t['leadSeconds'] as num? ?? 1).toDouble(),
      phases: [
        for (final p in (cyc?['phases'] as List?) ?? const [])
          KitPhase.fromJson(Map<String, dynamic>.from(p as Map)),
      ],
      holdSeconds: (d['holdSeconds'] as num?)?.toInt(),
      defaultReps: (d['reps'] as num?)?.toInt(),
      source: RhythmSource.actionKit,
    );
  }

  Map<String, Object?> toJson() => selfPaced
      ? {'kind': 'self_paced'}
      : {
          'kind': kind.id,
          'leadSeconds': lead,
          if (phases.isNotEmpty) 'phases': [for (final p in phases) p.toJson()],
          'holdSeconds': ?holdSeconds,
          'reps': ?defaultReps,
        };

  /// Counted on a clock (not a hold, not self-paced).
  bool get counted => !selfPaced && kind.counted && phases.isNotEmpty;

  /// Derived from a clip's repSeconds: counts on the beat end, no words.
  bool get derived => source == RhythmSource.repSeconds;

  Rhythm withHold(int seconds) => Rhythm(
    kind: kind,
    lead: lead,
    phases: phases,
    holdSeconds: seconds,
    defaultReps: defaultReps,
    selfPaced: selfPaced,
    source: source,
  );

  /// What this action does for [item]: a time dose on a derived or
  /// self-paced rhythm is a timed hold (SmartFit, 3D-Body), a reps dose on
  /// a hold kit is counted by the user.
  Rhythm effectiveFor(PlanItem item) {
    if (item.mode == DoseMode.time) {
      if (selfPaced || derived || !counted) return timedHold;
      return this;
    }
    if (!counted) return selfPacedReps;
    return this;
  }

  // ── rep plan (ported from ActionKit) ────────────────────────────────────

  /// Phases with the hold length applied ([hold] overrides [holdSeconds]).
  List<KitPhase> phasesFor({int? hold}) {
    final h = hold ?? holdSeconds;
    return [
      for (final p in phases)
        p.id == 'hold' && h != null ? p.withSeconds(h.toDouble()) : p,
    ];
  }

  double cycleFor({int? hold}) =>
      phasesFor(hold: hold).fold(0.0, (s, p) => s + p.seconds);

  /// Whole seconds of one side (or of the unsided set). Counted rhythms
  /// keep [budget] when every rep fits in it at the rhythm's pace (the reps
  /// are then slowed down, see [stretch]) and grow to the lead plus every
  /// rep in full when they do not. Same formula as HipLab
  /// build_action_kits.side_seconds().
  int sideSeconds({int? reps, int? hold, required int budget}) {
    if (!counted) return budget;
    final n = reps ?? defaultReps ?? 1;
    final need = (lead + n * cycleFor(hold: hold) - 1e-9).ceil();
    return math.max(budget, need);
  }

  /// Share of a slowed rep's extra time spent at the top (the rest goes to
  /// the pause at the bottom).
  static const stretchTop = .6;

  /// [ph] slowed to a cycle of [target] seconds: the movements keep the
  /// demo's speed, the pauses at the top / bottom take the extra time (a
  /// timed hold keeps its length, the pause after it grows); a loop
  /// (rep_cycle) slows down evenly.
  List<KitPhase> stretch(List<KitPhase> ph, double target) {
    final base = ph.fold(0.0, (s, p) => s + p.seconds);
    final extra = target - base;
    if (extra <= 1e-9) return ph;
    if (kind == ActionKind.repCycle || ph.length == 1) {
      final f = target / base;
      return [for (final p in ph) p.withSeconds(p.seconds * f)];
    }
    final hasRest = ph.any((p) => p.id == 'rest');
    final top = kind == ActionKind.repHold ? 0.0 : stretchTop;
    return [
      for (final p in ph)
        p.withSeconds(
          p.seconds +
              (p.id == 'hold'
                  ? extra * (hasRest ? top : 1)
                  : p.id == 'rest' && hasRest
                  ? extra * (1 - top)
                  : 0),
        ),
    ];
  }

  /// The rep plan for a work phase of [seconds] with [sets] sets. Each set:
  /// the lead, then every rep in full – the last rep ends exactly when the
  /// phase ends. Longer than needed: reps slow down to fill it; shorter:
  /// reps are dropped (never a rep that cannot finish).
  RepPlan repPlan({
    int? reps,
    int? hold,
    required double seconds,
    int sets = 1,
  }) {
    final ph = phasesFor(hold: hold);
    final cycle = ph.fold(0.0, (s, p) => s + p.seconds);
    final per = seconds / sets;
    var n = reps ?? defaultReps ?? 1;
    if (per + 1e-9 >= lead + n * cycle) {
      return RepPlan(
        lead: lead,
        reps: n,
        sets: sets,
        phases: stretch(ph, (per - lead) / n),
      );
    }
    n = math.max(0, math.min(n, ((per - lead + 1e-9) / cycle).floor()));
    return RepPlan(
      lead: math.max(0.0, per - n * cycle),
      reps: n,
      sets: sets,
      phases: ph,
    );
  }
}

/// Rhythms for every drill of [catalog] that has one: the catalog's own
/// `rhythm` field (Pose-Hub 0.3.0, read from the raw drill JSON) or the
/// first clip `repSeconds`. Drills with neither are left out and fall back
/// to [Rhythm.forDose] when played. [overrides] (e.g. HipLab action kits)
/// win over both.
Map<String, Rhythm> rhythmsFromCatalog(
  Catalog catalog, {
  Map<String, Rhythm> overrides = const {},
}) {
  final out = <String, Rhythm>{};
  final raw = catalog.raw['drills'];
  final byId = <String, Map<String, dynamic>>{};
  if (raw is List) {
    for (final d in raw) {
      if (d is Map && d['id'] is String && d['rhythm'] is Map) {
        byId[d['id'] as String] = Map<String, dynamic>.from(d['rhythm'] as Map);
      }
    }
  }
  for (final d in catalog.drills) {
    final j = byId[d.id];
    if (j != null) {
      out[d.id] = Rhythm.fromJson(j);
      continue;
    }
    for (final v in d.assets.videos) {
      final r = v.repSeconds;
      if (r != null && r > 0) {
        out[d.id] = Rhythm.fromRepSeconds(r);
        break;
      }
    }
  }
  out.addAll(overrides);
  return out;
}
