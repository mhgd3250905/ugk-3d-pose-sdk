// Merged from SmartFit@e8981ee lib/voice/session_script.dart (one timeline
// per phase; sets, rounds, the drill-pack lines; fixed calls first, flexible
// lines only where they fit whole) and HipLab@99fcc83
// lib/hip/voice/session_script.dart (rhythm counting by kit phases: the
// count with the go word, the back word, 3-2-1 inside long holds, the last
// rep in full; the kit voice script; the side-switch gap widened so its line
// ends [switchMargin] before the 3-2-1).
//
// Changes for ugk_trainer: the clips come from a [VoiceSource] by meaning
// ([VoiceCall], [DrillLine]); a line with a missing clip is never said in
// part (phrases are all-or-nothing, a fixed call keeps only what exists),
// so a voice language without clips degrades to chimes plus the on-screen
// countdown (decision B); self-paced sets get their start call only.
// Not carried over (HipLab app features, stay in the app): routine names in
// the intro, authored dose / tip strings (textKey), the tight-side extra set
// (D-01) and the hip assessment. Pure Dart.
import 'dart:math' as math;

import 'package:ugk_coach/ugk_coach.dart';

import '../engine/session.dart';
import '../rhythm/rhythm.dart';
import 'voice_cue.dart';
import 'voice_source.dart';

/// Silence kept between two lines.
const lineGap = .35;

/// Extra room before the countdown (audio session activation / loading can
/// start a line a little late).
const countdownMargin = .5;

/// Room before the next rep count when a key point is spoken between two
/// counts.
const repGapAfter = .6;

class SessionScript {
  SessionScript({
    required this.source,
    this.lang = 'zh',
    this.switchSeconds = 5,
  });

  final VoiceSource source;

  /// Voice-language code.
  final String lang;

  /// Shortest side-switch gap.
  final int switchSeconds;

  /// Room kept between the end of the switch line and the 3-2-1, so the
  /// line is not still sounding when 「三」 comes (HipLab Android voice fix
  /// 2026-10-19).
  static const switchMargin = 0.4;

  /// Count clips exist for 1…10 in HipLab; a higher count says only its
  /// phase word.
  static const maxCountClip = 10;

  /// The source has voice in [lang]; otherwise only chimes are played.
  bool get voiced => source.supports(lang);

  final Set<String> _subtitled = {};

  double len(List<String> clips) => source.total(clips, lang: lang);
  bool _has(String k) => source.has(k, lang: lang);
  bool whole(List<String> clips) => clips.isNotEmpty && clips.every(_has);
  List<String> _strip(List<String> clips) => clips.where(_has).toList();
  List<String> _phrase(List<String> p) => whole(p) ? p : const [];

  String? call(VoiceCall c) {
    final k = source.call(c);
    return k != null && _has(k) ? k : null;
  }

  /// A move's own line key, or null when it has none in [lang].
  String? own(String exerciseId, DrillLine line) {
    final k = source.drill(exerciseId, line);
    if (k == null || !_has(k)) return null;
    if (line != DrillLine.name && line != DrillLine.finish) _subtitled.add(k);
    return k;
  }

  KitVoice? kit(String? exerciseId) =>
      exerciseId == null ? null : source.kitVoice(exerciseId);

  List<String> cueKeys(String exerciseId) => [
    for (final l in const [DrillLine.cue1, DrillLine.cue2, DrillLine.cue3])
      ?own(exerciseId, l),
  ];

  List<String> _coach(KitVoice v) {
    final out = <String>[];
    for (final c in v.coach) {
      if (_has(c)) {
        _subtitled.add(c);
        out.add(c);
      }
    }
    return out;
  }

  String? _subtitle(List<String> clips) {
    for (final c in clips) {
      if (_subtitled.contains(c)) return source.line(c, lang: lang);
    }
    return null;
  }

  /// "3 组，每侧 12 次"; empty when any part cannot be said.
  List<String> dose(PlanItem i, {bool withSets = true}) {
    final amount = i.mode == DoseMode.reps
        ? _phrase(source.repsPhrase(i.reps ?? 10))
        : _phrase(source.secondsPhrase(i.workSeconds ?? 30));
    if (amount.isEmpty) return const [];
    final per = i.perSide ? call(VoiceCall.perSide) : null;
    if (i.perSide && per == null) return const [];
    final sets = withSets && i.sets > 1
        ? _phrase(source.setsPhrase(i.sets))
        : const <String>[];
    if (withSets && i.sets > 1 && sets.isEmpty) return const [];
    return [...sets, ?per, ...amount];
  }

  _Timeline _timeline(double seconds, {bool countdown = true}) => _Timeline(
    this,
    limit: countdown ? seconds - 3 - countdownMargin : seconds,
  );

  List<VoiceCue> _countdown(double end, {int from = 3}) => [
    for (var k = from; k >= 1; k--)
      if (end - k > 0.5)
        VoiceCue(end - k, [
          'chime.tick',
          ...source.number(k),
        ], CuePriority.count),
  ];

  /// "下一个动作，`intro`，`dose`" with shorter fall-backs.
  List<List<String>> _preview(
    VoiceCall lead,
    String id,
    PlanItem item, {
    bool withSets = true,
  }) {
    final l = call(lead);
    if (l == null) return const [];
    final d = dose(item, withSets: withSets);
    final intro = own(id, DrillLine.intro);
    final name = own(id, DrillLine.name);
    final first = item.perSide ? kit(id)?.firstSide : null;
    final side = first != null && _has(first) ? [first] : const <String>[];
    return [
      if (intro != null && d.isNotEmpty) [l, intro, ...d, ...side],
      if (name != null && d.isNotEmpty) [l, name, ...d, ...side],
      if (intro != null) [l, intro, ...side],
      if (name != null) [l, name, ...side],
    ];
  }

  // ── side switch ───────────────────────────────────────────────────────

  /// What is said when the side switches: 慢慢还原 after a hold (kit), then
  /// 换左边 / 换右边.
  List<String> switchClips(PlanItem item, Rhythm rhythm, Side side) {
    final k = kit(item.exerciseId);
    return _strip([
      'chime.end',
      if (k != null && !rhythm.counted) k.end,
      ?call(side == Side.left ? VoiceCall.switchLeft : VoiceCall.switchRight),
    ]);
  }

  /// The side-switch gap: [switchSeconds], longer when the switch line
  /// would not end [switchMargin] before the 3-2-1. Whole seconds. Pass it
  /// to [SessionBuilder.switchSecondsFor].
  double switchSecondsFor(PlanItem item, Rhythm rhythm, Side side) {
    final need =
        (len(switchClips(item, rhythm, side)) + switchMargin).ceil() + 3;
    return math.max(switchSeconds, need).toDouble();
  }

  // ── cues ──────────────────────────────────────────────────────────────

  /// Cues for [p] (times relative to the phase start). [planSeconds]: the
  /// session length for the intro; [bySkip]: entered with 跳过 (no praise
  /// for the move that was skipped).
  List<VoiceCue> cues(
    SessionPhase p, {
    required double planSeconds,
    bool bySkip = false,
  }) {
    switch (p.kind) {
      case PhaseKind.prep:
        return _prep(p, planSeconds);
      case PhaseKind.work:
        return _work(p);
      case PhaseKind.switchSide:
        final item = p.item;
        final clips = item == null
            ? _strip([
                'chime.end',
                ?call(
                  p.side == Side.left
                      ? VoiceCall.switchLeft
                      : VoiceCall.switchRight,
                ),
              ])
            : switchClips(
                item,
                p.rhythm ?? _rhythmOfSwitch(p),
                p.side ?? Side.left,
              );
        return [
          if (clips.isNotEmpty) VoiceCue(0, clips, CuePriority.call),
          ..._fixedCountdown(p.seconds),
        ];
      case PhaseKind.rest:
      case PhaseKind.roundRest:
        return _rest(p, bySkip);
      case PhaseKind.done:
        final clips = _strip(['chime.finish', ?call(VoiceCall.finish)]);
        return [if (clips.isNotEmpty) VoiceCue(0, clips, CuePriority.call)];
    }
  }

  /// The switch phase carries no rhythm; a hold is any time dose here.
  Rhythm _rhythmOfSwitch(SessionPhase p) =>
      p.item?.mode == DoseMode.time ? Rhythm.timedHold : Rhythm.selfPacedReps;

  List<VoiceCue> _fixedCountdown(double end, {int from = 3}) => [
    for (final c in _countdown(end, from: from))
      if (_strip(c.clips).isNotEmpty)
        VoiceCue(c.at, _strip(c.clips), c.priority),
  ];

  List<VoiceCue> _prep(SessionPhase p, double planSeconds) {
    final t = _timeline(p.seconds)..fixAll(_countdown(p.seconds));
    final ready = call(VoiceCall.ready);
    if (ready != null) {
      final at = p.seconds - 3 - len([ready]) - .2;
      if (at >= 0) t.fix(VoiceCue(at, [ready], CuePriority.call));
    }
    final minutes = (planSeconds / 60).round().clamp(1, 600);
    final welcome = call(VoiceCall.welcome);
    final total = call(VoiceCall.total);
    final m = _phrase(source.minutesPhrase(minutes));
    t.place([
      if (welcome != null && total != null && m.isNotEmpty)
        [welcome, total, ...m],
      ?(welcome == null ? null : [welcome]),
    ], CuePriority.info);
    final id = p.exerciseId;
    if (id != null && p.item != null) {
      t.place(_preview(VoiceCall.first, id, p.item!), CuePriority.info);
      final c = cueKeys(id);
      if (c.isNotEmpty) {
        t.place([
          [c.first],
        ], CuePriority.coach);
      }
    }
    return t.cues;
  }

  List<VoiceCue> _rest(SessionPhase p, bool bySkip) {
    final rest = p.seconds.round();
    final t = _timeline(p.seconds)..fixAll(_countdown(p.seconds));
    final r = call(VoiceCall.rest);
    final secs = _phrase(source.secondsPhrase(rest));
    final tails = <List<String>>[
      if (r != null && secs.isNotEmpty) [r, ...secs],
      ?(r == null ? null : [r]),
    ];
    final doneId = p.doneExerciseId;
    String? doneLine;
    if (doneId != null && !bySkip) {
      doneLine = own(doneId, DrillLine.finish);
      final end = kit(doneId)?.end;
      if (doneLine == null && end != null && _has(end)) doneLine = end;
    }
    final nice = bySkip ? null : call(VoiceCall.nice);
    final heads = <List<String>>[
      if (p.kind == PhaseKind.roundRest) ...[
        ?(call(VoiceCall.roundDone) == null
            ? null
            : ['chime.end', call(VoiceCall.roundDone)!]),
      ] else ...[
        ?(doneLine == null ? null : ['chime.end', doneLine]),
        ?(nice == null ? null : ['chime.end', nice]),
      ],
      ['chime.end'],
    ];
    t.place([
      for (final h in heads)
        for (final tail in tails) [...h, ...tail],
      ['chime.end'],
    ], CuePriority.call);
    if (p.kind == PhaseKind.roundRest && p.round > 0) {
      t.place([_phrase(source.ordinalRound(p.round))], CuePriority.info);
    }
    final id = p.exerciseId;
    final next = p.nextExerciseId != null && id != null && p.item != null;
    if (next) {
      // Before a new move: what it is, how much, then its first key point.
      final previews = _preview(
        VoiceCall.next,
        id,
        p.item!,
        withSets: p.rounds == 0,
      );
      final cues = cueKeys(id);
      // The dose matters more than the point: never drop it to make room.
      final withDose = previews.where((pv) => pv.length > 2).toList();
      final placed =
          cues.isNotEmpty &&
          t.placeGroup([
            for (final pv in withDose.isEmpty ? previews : withDose)
              [
                (pv, CuePriority.info),
                ([cues.first], CuePriority.coach),
              ],
          ]);
      if (!placed) t.place(previews, CuePriority.info);
      if (placed && cues.length > 1) {
        t.place([
          [cues[1]],
        ], CuePriority.coach);
      }
    } else if (id != null) {
      // Between sets of the same move: which set, then the move's rest tip.
      final last = call(VoiceCall.lastSet);
      if (p.set == p.sets && p.sets > 1 && last != null) {
        t.place([
          [last],
        ], CuePriority.info);
      } else if (p.sets > 1) {
        t.place([_phrase(source.ordinalSet(p.set))], CuePriority.info);
      }
      final tip = own(id, DrillLine.rest);
      final cues = cueKeys(id);
      for (final line in [
        ?(tip == null ? null : [tip]),
        if (cues.isNotEmpty) [cues.last],
      ]) {
        if (t.place(
          [line],
          CuePriority.coach,
          from: t.limit - len(line) - 1.5,
        )) {
          break;
        }
      }
    }
    return t.cues;
  }

  /// Key points for this side: on the second side the move's own
  /// side_switch line takes the place of the primary point.
  List<String> _sideLines(SessionPhase p, String id) {
    final c = cueKeys(id);
    final sw = p.side == Side.left ? own(id, DrillLine.sideSwitch) : null;
    if (sw == null) return c;
    return [sw, ...c.skip(1)];
  }

  List<VoiceCue> _work(SessionPhase p) {
    final id = p.exerciseId;
    final rhythm = p.rhythm ?? Rhythm.timedHold;
    final v = kit(id);
    final firstSide = p.side == Side.right;
    final goKey = v != null && _has(v.go)
        ? v.go
        : call(firstSide ? VoiceCall.goRight : VoiceCall.go) ??
              call(VoiceCall.go);
    if (p.selfPaced) return _selfPaced(p, id, goKey);
    if (rhythm.counted && !rhythm.derived) return _rhythmCues(p, rhythm, v);
    if (rhythm.counted) return _derivedCues(p, id, goKey);
    return _hold(p, id, goKey, v);
  }

  /// Self-paced set (完成本组): the start call and one key point; no count
  /// and no countdown – the user decides when the set is done.
  List<VoiceCue> _selfPaced(SessionPhase p, String? id, String? go) {
    final t = _Timeline(this, limit: p.seconds)
      ..fix(VoiceCue(0, ['chime.start', ?go], CuePriority.call));
    if (id != null) {
      final lines = _sideLines(p, id);
      if (lines.isNotEmpty) {
        final pick = p.side == Side.left
            ? lines.first
            : lines[p.set.clamp(0, 99) % lines.length];
        t.place([
          [pick],
        ], CuePriority.coach);
      }
    }
    return t.cues;
  }

  /// SmartFit repSeconds rhythm: each rep counted on its beat end.
  List<VoiceCue> _derivedCues(SessionPhase p, String? id, String? go) {
    final w = p.seconds;
    final reps = p.reps ?? 0;
    final rep = p.repSeconds ?? 3;
    final t = _Timeline(this, limit: w)
      ..fix(VoiceCue(0, ['chime.start', ?go], CuePriority.call));
    final goLen = go == null ? 0.0 : len([go]);
    if (rep >= 1.6) {
      for (var k = 1; k <= reps; k++) {
        final n = source.number(k);
        if (!whole(n)) continue;
        final at = (k * rep - .45).clamp(0.0, w - len(n) - .05);
        if (at < goLen + .3 || at >= w) continue;
        t.fix(VoiceCue(at, n, CuePriority.count));
      }
    } else if (reps >= 6) {
      final slow = call(VoiceCall.slow);
      if (slow != null) {
        t.place([
          [slow],
        ], CuePriority.coach);
      }
    }
    if (id != null) {
      final lines = _sideLines(p, id);
      if (lines.isNotEmpty) {
        // The preview before the move already said the first point, so set
        // 1 takes the second one… (second side: side_switch).
        final pick = p.side == Side.left
            ? lines.first
            : lines[p.set.clamp(0, 99) % lines.length];
        final others = [...lines]
          ..remove(pick)
          ..sort((a, b) => len([a]).compareTo(len([b])));
        t.place(
          [
            [pick],
            for (final o in others) [o],
          ],
          CuePriority.coach,
          gapAfter: repGapAfter,
        );
      }
    }
    return t.cues;
  }

  /// Kit / catalog rhythm (HipLab _repCues): "开始", then on every rep the
  /// count with the go word ("一，起"), the back word at the return
  /// ("落"), 3-2-1 inside holds of 6 s or more; rep k starts on a fixed
  /// beat and the last rep ends exactly when the phase ends.
  List<VoiceCue> _rhythmCues(SessionPhase p, Rhythm rhythm, KitVoice? v) {
    final plan = rhythm.repPlan(
      reps: p.reps,
      hold: p.holdSeconds,
      seconds: p.seconds,
    );
    if (plan.reps == 0) return const [];
    final go = v != null && _has(v.go) ? v.go : call(VoiceCall.go);
    final lastRep = v != null && _has(v.lastRep)
        ? v.lastRep
        : call(VoiceCall.lastRep);
    String? count(int k) {
      if (k > maxCountClip) return null;
      final c = v?.countClip(k);
      if (c != null && _has(c)) return c;
      final n = source.number(k);
      return n.length == 1 && _has(n.single) ? n.single : null;
    }

    final raw = <VoiceCue>[
      VoiceCue(0, ['chime.start', ?go], CuePriority.call),
    ];
    for (var k = 1; k <= plan.reps; k++) {
      var t = plan.repStart(0, k);
      final last = k == plan.reps && plan.reps >= 3 && lastRep != null;
      for (final (i, ph) in plan.phases.indexed) {
        final word = ph.cueFor(k);
        if (i == 0) {
          raw.add(
            VoiceCue(t, [
              ?(last ? lastRep : count(k)),
              ?word,
            ], CuePriority.count),
          );
        } else if (word != null) {
          raw.add(VoiceCue(t + ph.cueAt, [word], CuePriority.count));
        }
        if (ph.id == 'hold' && ph.seconds >= 6) {
          for (var n = 3; n >= 1; n--) {
            raw.add(
              VoiceCue(t + ph.seconds - n, source.number(n), CuePriority.count),
            );
          }
        }
        t += ph.seconds;
      }
    }
    final out = [
      for (final c in raw)
        if (_strip(c.clips).isNotEmpty)
          VoiceCue(c.at, _strip(c.clips), c.priority),
    ]..sort((a, b) => a.at.compareTo(b.at));
    return out;
  }

  /// Timed hold: start, halfway, ten seconds left, the countdown (5-4-3-2-1
  /// with a kit, else 3-2-1), key points spread over the gaps.
  List<VoiceCue> _hold(SessionPhase p, String? id, String? go, KitVoice? v) {
    final w = p.seconds;
    final from = v != null && w >= 8 ? v.countdown : 3;
    final t = _Timeline(this, limit: w - from - countdownMargin)
      ..fix(VoiceCue(0, ['chime.start', ?go], CuePriority.call))
      ..fixAll(_countdown(w, from: from));
    if (v != null) {
      final half = v.half, last10 = v.last10;
      if (w >= 30 && half != null) {
        t.fix(VoiceCue(w / 2, [half], CuePriority.info));
      }
      if (w >= 20 && last10 != null) {
        t.fix(VoiceCue(w - 10, [last10], CuePriority.call));
      }
    } else {
      final half = call(VoiceCall.half), ten = call(VoiceCall.tenLeft);
      if (w >= 40 && half != null) {
        t.fix(VoiceCue(w / 2, [half], CuePriority.info));
      }
      if (w >= 25 && ten != null) {
        t.fix(VoiceCue(w - 10, [ten], CuePriority.call));
      }
    }
    final lines = v != null
        ? [
            ...?(_coach(v).isEmpty ? null : [_coach(v).first]),
            if (w >= 40 && _coach(v).length > 1) _coach(v)[1],
          ]
        : id == null
        ? const <String>[]
        : _sideLines(p, id);
    // Spread the key points over the hold instead of back to back.
    final start = (go == null ? 0 : len([go])) + lineGap;
    final span = (t.limit - start).clamp(0, 1e9);
    for (var k = 0; k < lines.length; k++) {
      t.place(
        [
          [lines[k]],
        ],
        CuePriority.coach,
        from: start + span * k / lines.length,
      );
    }
    return t.cues;
  }
}

/// One phase's lines with their real lengths; nothing ever overlaps.
class _Timeline {
  _Timeline(this.script, {required this.limit});

  final SessionScript script;

  /// Flexible lines must end by this time (phase-local seconds).
  final double limit;
  final _taken = <(double, double)>[];
  final _cues = <VoiceCue>[];

  /// Where the next flexible line may start (keeps spoken order).
  double _cursor = 0;

  List<VoiceCue> get cues => [..._cues]..sort((a, b) => a.at.compareTo(b.at));

  /// A fixed call at its time; clips the source lacks are dropped (a
  /// count without its number still ticks).
  void fix(VoiceCue c) {
    final clips = script._strip(c.clips);
    if (clips.isEmpty) return;
    final cue = VoiceCue(c.at, clips, c.priority, subtitle: c.subtitle);
    _cues.add(cue);
    _taken.add((cue.at, cue.at + script.len(clips)));
  }

  void fixAll(Iterable<VoiceCue> cs) => cs.forEach(fix);

  bool _free(double a, double b, double before, double after) {
    for (final (s, e) in _taken) {
      if (a < e + before && b + after > s) return false;
    }
    return true;
  }

  /// Place the first alternative that exists whole and fits whole at or
  /// after [from], with [gap] of silence before it and [gapAfter] (default
  /// [gap]) before whatever follows; returns false when none fits.
  bool place(
    List<List<String>> alternatives,
    CuePriority priority, {
    double from = 0,
    double gap = lineGap,
    double? gapAfter,
  }) {
    final after = gapAfter ?? gap;
    for (final clips in alternatives) {
      if (!script.whole(clips)) continue;
      final l = script.len(clips);
      final earliest = from > _cursor ? from : _cursor;
      final starts = <double>[
        earliest,
        for (final (_, e) in _taken)
          if (e + gap > earliest) e + gap,
      ]..sort();
      for (final s in starts) {
        if (s + l > limit) break;
        if (_free(s, s + l, gap, after)) {
          _cues.add(
            VoiceCue(s, clips, priority, subtitle: script._subtitle(clips)),
          );
          _taken.add((s, s + l));
          _cursor = s + l + lineGap;
          return true;
        }
      }
    }
    return false;
  }

  /// Try each option (lines said one after another); keep the first option
  /// whose lines all fit, otherwise change nothing.
  bool placeGroup(List<List<(List<String>, CuePriority)>> options) {
    for (final option in options) {
      final taken = [..._taken], cues = [..._cues], cursor = _cursor;
      if (option.every((line) => place([line.$1], line.$2))) return true;
      _taken
        ..clear()
        ..addAll(taken);
      _cues
        ..clear()
        ..addAll(cues);
      _cursor = cursor;
    }
    return false;
  }
}
