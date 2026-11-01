// Ported from SmartFit@e8981ee lib/voice/session_runner.dart ([SessionEngine]
// + [SessionScript]; stale cues dropped with HipLab's tolerances). Added:
// completeSet (完成本组) and restartWith (substitute). Pure Dart.
import '../engine/session.dart';
import 'session_script.dart';
import 'voice_cue.dart';

/// Something the session wants said now.
class FiredCue {
  const FiredCue(this.time, this.cue);

  /// Active session time when it was due.
  final double time;
  final VoiceCue cue;
  @override
  String toString() => '${time.toStringAsFixed(2)} ${cue.clips.join('+')}';
}

/// Advances the clock and returns the cues that fell due. Cues already
/// stale when the clock gets there (after a long background stretch) are
/// dropped instead of read out late.
class SessionRunner {
  SessionRunner(this.engine, this.script)
    : planSeconds = engine.phases
          .where((p) => p.kind != PhaseKind.prep)
          .fold(0.0, (s, p) => s + p.seconds) {
    _load();
  }

  final SessionEngine engine;
  final SessionScript script;
  final double planSeconds;
  List<VoiceCue> _cues = const [];
  final Set<int> _fired = {};
  int _gen = -1;

  static double tolerance(VoiceCue c) => switch (c.priority) {
    CuePriority.count => .6,
    CuePriority.call => 1.5,
    CuePriority.info => 2.5,
    CuePriority.coach => 2.0,
  };

  /// Cues of the phase on now.
  List<VoiceCue> get cues => _cues;

  void _load() {
    _gen = engine.generation;
    _cues = engine.endedEarly
        ? const []
        : script.cues(
            engine.phase,
            planSeconds: planSeconds,
            bySkip: engine.enteredBySkip,
          );
    _fired.clear();
  }

  List<FiredCue> update(double t) {
    engine.update(t);
    return _due(t);
  }

  List<FiredCue> _due(double t) {
    final out = <FiredCue>[];
    // Several phases may have passed (background): only the current one speaks.
    if (engine.generation != _gen) _load();
    final local = t - engine.phaseStart;
    for (var i = 0; i < _cues.length; i++) {
      final c = _cues[i];
      if (_fired.contains(i) || c.at > local + 1e-9) continue;
      _fired.add(i);
      if (local - c.at <= tolerance(c)) {
        out.add(FiredCue(engine.phaseStart + c.at, c));
      }
    }
    return out;
  }

  void skip(double t) {
    engine.skip(t);
    _load();
  }

  void previous(double t) {
    engine.previous(t);
    _load();
  }

  bool skipSegment(double t) {
    if (!engine.skipSegment(t)) return false;
    _load();
    return true;
  }

  bool completeTimedPhase(double t) {
    if (!engine.completeTimedPhase(t)) return false;
    _load();
    return true;
  }

  /// Move the remaining countdown without replaying the rest introduction
  /// or a countdown tick already passed at the moment of extension.
  bool extendRest(double t, {double seconds = 15}) {
    if (!engine.extendRest(t, seconds: seconds)) return false;
    _load();
    final local = t - engine.phaseStart;
    for (var i = 0; i < _cues.length; i++) {
      if (_cues[i].at <= local + 1e-9) _fired.add(i);
    }
    return true;
  }

  void finish(double t) {
    engine.finish(t);
    _load();
  }

  /// 完成本组; returns the cues of the phase it leads into.
  List<FiredCue> completeSet(double t) {
    if (!engine.completeSet(t)) return const [];
    return _due(t);
  }

  void restartWith(
    List<SessionPhase> phases,
    double t, {
    int? fromItemIndex,
    bool withRest = false,
  }) {
    engine.restartWith(
      phases,
      t,
      fromItemIndex: fromItemIndex,
      withRest: withRest,
    );
    _load();
  }
}
