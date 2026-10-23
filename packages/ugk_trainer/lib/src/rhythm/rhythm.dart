// Rhythm = ActionKind + KitPhase: how one action is paced. The rep-plan
// maths (phasesFor / sideSeconds / stretch / repPlan) is ported from
// HipLab@99fcc83 lib/hip/domain/action_kit.dart (ActionKit), unchanged.
// Pure Dart.
//
// Resolution: App overrides (including action kits), catalog rhythm,
// defaultDose.holdSeconds, explicit clip repSeconds, then public defaults.
import 'dart:math' as math;

import 'package:ugk_coach/ugk_coach.dart';

import 'action_kind.dart';

enum RhythmSource { catalog, actionKit, repSeconds, dose }

/// Fallback pacing until an authored catalog rhythm is available. Video
/// loop duration is deliberately never used as a repetition duration.
class RhythmDefaults {
  const RhythmDefaults({
    this.defaultRepSeconds = 3.0,
    this.categoryRepSeconds = const {
      'strength': 3.0,
      'core': 3.0,
      'cardio': 3.0,
      'mobility': 3.0,
      'stretch': 3.0,
    },
  });

  final double defaultRepSeconds;
  final Map<String, double> categoryRepSeconds;

  double secondsFor({String? category, double? holdSeconds}) {
    final seconds =
        holdSeconds ?? categoryRepSeconds[category] ?? defaultRepSeconds;
    if (!seconds.isFinite || seconds <= 0) {
      throw ArgumentError.value(
        seconds,
        'repSeconds',
        'must be finite and positive',
      );
    }
    return seconds;
  }
}

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
  /// tap 完成本组. Requires an explicit catalog or App rhythm marker.
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
  static Rhythm forDose(
    DoseMode mode, {
    RhythmDefaults defaults = const RhythmDefaults(),
    String? category,
    double? holdSeconds,
  }) => mode == DoseMode.time
      ? timedHold
      : Rhythm(
          kind: holdSeconds == null ? ActionKind.repUpdown : ActionKind.repHold,
          lead: 0,
          phases: [
            KitPhase(
              holdSeconds == null ? 'go' : 'hold',
              defaults.secondsFor(category: category, holdSeconds: holdSeconds),
              const [],
            ),
          ],
          source: RhythmSource.dose,
        );

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
      source: switch (j['source']) {
        'repSeconds' => RhythmSource.repSeconds,
        'dose' => RhythmSource.dose,
        _ => RhythmSource.catalog,
      },
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
          if (derived) 'source': source.name,
        };

  /// Counted on a clock (not a hold, not self-paced).
  bool get counted => !selfPaced && kind.counted && phases.isNotEmpty;

  /// Derived from a clip's repSeconds: counts on the beat end, no words.
  bool get derived =>
      source == RhythmSource.repSeconds ||
      (source == RhythmSource.dose && counted);

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
  /// a hold kit uses the automatic dose defaults unless explicitly self-paced.
  Rhythm effectiveFor(
    PlanItem item, {
    RhythmDefaults defaults = const RhythmDefaults(),
  }) {
    if (item.mode == DoseMode.time) {
      if (selfPaced || derived || !counted) return timedHold;
      return this;
    }
    if (selfPaced) return this;
    if (!counted) {
      return forDose(
        item.mode,
        defaults: defaults,
        holdSeconds: holdSeconds?.toDouble(),
      );
    }
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
/// first clip `repSeconds`. Drills with neither use [defaults], including
/// their category and defaultDose.holdSeconds. [overrides] (e.g. HipLab action kits)
/// win over both.
Map<String, Rhythm> rhythmsFromCatalog(
  Catalog catalog, {
  Map<String, Rhythm> overrides = const {},
  RhythmDefaults defaults = const RhythmDefaults(),
}) {
  final out = <String, Rhythm>{};
  final raw = catalog.raw['drills'];
  final byId = <String, Map<String, dynamic>>{};
  if (raw is List) {
    for (final d in raw) {
      if (d is Map && d['id'] is String) {
        byId[d['id'] as String] = Map<String, dynamic>.from(d);
      }
    }
  }
  for (final d in catalog.drills) {
    final rawDrill = byId[d.id];
    final j = rawDrill?['rhythm'];
    if (j is Map) {
      out[d.id] = Rhythm.fromJson(Map<String, dynamic>.from(j));
      continue;
    }
    final dose = rawDrill?['defaultDose'];
    final hold = dose is Map ? dose['holdSeconds'] : null;
    if (hold is num && hold.isFinite && hold > 0) {
      out[d.id] = Rhythm.forDose(
        d.defaultDose.mode,
        defaults: defaults,
        category: d.category,
        holdSeconds: hold.toDouble(),
      );
      continue;
    }
    for (final v in d.assets.videos) {
      final r = v.repSeconds;
      if (r != null && r.isFinite && r > 0) {
        out[d.id] = Rhythm.fromRepSeconds(r);
        break;
      }
    }
    out.putIfAbsent(
      d.id,
      () => Rhythm.forDose(
        d.defaultDose.mode,
        defaults: defaults,
        category: d.category,
      ),
    );
  }
  out.addAll(overrides);
  return out;
}
