// Ported from SmartFit@e8981ee lib/ui/player_page.dart (the latest player:
// countdown ring, fixed slots, haptics, light / dark). Changes for
// ugk_trainer:
// * the app gives the plan, the rhythms, the drills' names / clips
//   ([TrainerDrill]), the words ([TrainerStrings]), the colours
//   ([TrainerTheme]) and the voice ([TrainerVoice]); nothing is read from a
//   SmartFit service;
// * slots: [TrainerPlayer.onDiscomfort] (HipLab's pain ladder stays in the
//   app), [TrainerPlayer.feedbackBuilder] (done view), [TrainerPlayer.
//   mediaBuilder] (default [DrillMediaView]);
// * self-paced sets show 完成本组 (decision A);
// * the session id is fixed at start; [TrainerPlayer.onFinished] gets one
//   [SessionResult], a failed save can be retried with the same result;
// * Android keep-alive (TrainingHold, from HipLab) while the session runs;
// * SmartFit's star sky, custom glyphs and finish animations are not
//   carried over (Material icons, plain background).
import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../engine/session.dart';
import '../media/drill_media.dart';
import '../media/drill_media_view.dart';
import '../platform/screen_awake.dart';
import '../platform/training_keep_alive.dart';
import '../result/session_result.dart';
import '../rhythm/rhythm.dart';
import '../voice/session_runner.dart';
import '../voice/session_script.dart';
import '../voice/voice_cue.dart';
import '../voice/voice_queue.dart';
import '../voice/voice_source.dart';
import 'countdown_ring.dart';
import 'trainer_strings.dart';
import 'trainer_theme.dart';

/// What the player needs to show one exercise.
class TrainerDrill {
  const TrainerDrill({
    required this.id,
    required this.name,
    this.cue,
    this.media,
  });
  final String id;

  /// In the app's language.
  final String name;

  /// Key point shown while resting before it.
  final String? cue;
  final DrillMedia? media;
}

/// The voice: clips, where sound goes, the user's settings.
class TrainerVoice {
  const TrainerVoice({
    required this.source,
    required this.output,
    this.settings = const VoiceSettings(),
    this.scriptBuilder,
  });
  final VoiceSource source;
  final VoiceOutput output;
  final VoiceSettings settings;

  /// Optional app-specific calls (course names, authored dose phrases).
  /// The shared engine and runner still own timing and stale-cue handling.
  final SessionScript Function(VoiceSource source, String language)?
  scriptBuilder;

  static final silent = TrainerVoice(
    source: _NoVoice(),
    output: const MutedVoiceOutput(),
    settings: const VoiceSettings(voice: false, chimes: false),
  );
}

class _NoVoice extends VoiceSource {
  @override
  String asset(String key, {required String lang}) => key;
  @override
  String? call(VoiceCall c) => null;
  @override
  String? drill(String exerciseId, DrillLine line) => null;
  @override
  bool has(String key, {required String lang}) => false;
  @override
  Set<String> get languages => const {};
  @override
  String? line(String key, {required String lang}) => null;
  @override
  List<String> minutesPhrase(int n) => const [];
  @override
  double seconds(String key, {required String lang}) => estimateSeconds(key);
  @override
  List<String> secondsPhrase(int n) => const [];
}

/// Where 不舒服 was tapped.
class DiscomfortContext {
  const DiscomfortContext({
    required this.phase,
    required this.activeSeconds,
    required this.strings,
    required this.theme,
    SessionPhase? resumePhase,
    this.afterExercise = false,
  }) : resumePhase = resumePhase ?? phase;
  final SessionPhase phase;

  /// The phase to resume; [phase] may instead be the exercise just finished.
  final SessionPhase resumePhase;
  final bool afterExercise;
  final double activeSeconds;
  final TrainerStrings strings;
  final TrainerTheme theme;
}

/// The app's answer to 不舒服 (null: carry on as before).
class DiscomfortDecision {
  const DiscomfortDecision(
    this.action, {
    this.substituteId,
    this.note,
    this.replacementPhases,
    this.restartItemIndex,
    this.withRest = false,
    this.voiceClips = const [],
    this.subtitle,
  });
  final DiscomfortAction action;

  /// [DiscomfortAction.substitute]: the exercise to do instead (same
  /// dose; its `unilateral` must match the item's perSide).
  final String? substituteId;

  /// Recorded with the event (HipLab: the pain level).
  final String? note;

  /// App-authored remaining session, with original item/block coordinates.
  /// Takes precedence over the default action (e.g. a dose reduction or
  /// removing all remaining non-relaxation exercises in one direction).
  final List<SessionPhase>? replacementPhases;
  final int? restartItemIndex;
  final bool withRest;

  /// App-specific response, queued after changing the session so it is not
  /// cancelled by the transition itself.
  final List<String> voiceClips;

  /// App response visible even when voice is disabled or has no clip.
  final String? subtitle;
}

typedef DiscomfortHandler =
    Future<DiscomfortDecision?> Function(
      BuildContext context,
      DiscomfortContext at,
    );

class TrainerMediaRequest {
  const TrainerMediaRequest({
    required this.drill,
    required this.paused,
    required this.mirrored,
    required this.theme,
    required this.strings,
  });
  final TrainerDrill drill;
  final bool paused;

  /// Left side of a unilateral move (the clip shows the right side).
  final bool mirrored;
  final TrainerTheme theme;
  final TrainerStrings strings;
}

typedef TrainerMediaBuilder =
    Widget Function(BuildContext context, TrainerMediaRequest request);

typedef TrainerFeedbackBuilder =
    Widget Function(BuildContext context, SessionResult result);

typedef TrainerReplayBuilder =
    Widget Function(
      BuildContext context,
      SessionResult result,
      VoidCallback replay,
    );

class TrainerRestFeedback {
  const TrainerRestFeedback({
    required this.phase,
    required this.completedPhase,
    required this.reportDiscomfort,
  });
  final SessionPhase phase;
  final SessionPhase completedPhase;

  /// Opens the same app discomfort handler, targeting the finished exercise.
  final Future<void> Function() reportDiscomfort;
}

typedef TrainerRestFeedbackBuilder =
    Widget Function(BuildContext context, TrainerRestFeedback feedback);

/// Full-screen follow-along of one [TrainingPlan]. Pops with the
/// [SessionResult] when the user taps 完成 (or closes and confirms).
class TrainerPlayer extends StatefulWidget {
  const TrainerPlayer({
    super.key,
    required this.plan,
    required this.drillOf,
    required this.strings,
    required this.onFinished,
    this.rhythms = const {},
    this.theme = TrainerTheme.dark,
    this.voice,
    this.onDiscomfort,
    this.feedbackBuilder,
    this.restFeedbackBuilder,
    this.sessionBuilder,
    this.replayBuilder,
    this.doseLabel,
    this.announceDiscomfortPause = true,
    this.mediaBuilder,
    this.sessionId,
    this.prepSeconds = 10,
    this.transitionSeconds = 15,
    this.keepAlive = true,
    this.notificationIcon,
    this.tick = const Duration(milliseconds: 50),
  });

  final TrainingPlan plan;

  /// The app's exercise by id; null: left out of the session.
  final TrainerDrill? Function(String exerciseId) drillOf;
  final TrainerStrings strings;

  /// Called once with the result when the session ends (finished, ended
  /// early or closed). Save it keyed by [SessionResult.sessionId]: a retry
  /// after a failure passes the same result.
  final Future<void> Function(SessionResult result) onFinished;

  /// Rhythm by exercise id ([rhythmsFromCatalog]); missing: by dose.
  final Map<String, Rhythm> rhythms;
  final TrainerTheme theme;

  /// Null: silent (no voice, no chimes).
  final TrainerVoice? voice;

  /// Null: the built-in sheet (continue easier / skip / end).
  final DiscomfortHandler? onDiscomfort;

  /// Shown on the done view, above 完成.
  final TrainerFeedbackBuilder? feedbackBuilder;

  /// Optional feedback during the transition after an exercise. The clock
  /// continues while the app records an answer, until discomfort is opened.
  final TrainerRestFeedbackBuilder? restFeedbackBuilder;

  /// App-specific dose/side arrangement; all clocks and playback stay here.
  final SessionBuilder? sessionBuilder;

  /// A new session in the same player after the current result is saved.
  /// The app resets its own pain/feedback state before calling replay.
  final TrainerReplayBuilder? replayBuilder;

  /// App-authored dose for this occurrence, including upcoming previews.
  final String? Function(SessionPhase phase)? doseLabel;

  /// Preserve apps whose pain dialog pauses silently; ordinary pause/resume
  /// controls still announce themselves. Defaults to the shared player policy.
  final bool announceDiscomfortPause;

  /// Null: [DrillMediaView] of [TrainerDrill.media].
  final TrainerMediaBuilder? mediaBuilder;

  /// Fixed id (e.g. resuming); null: a new one.
  final String? sessionId;
  final int prepSeconds;
  final int transitionSeconds;

  /// Android foreground service + wake lock while training.
  final bool keepAlive;

  /// Android notification small icon (`mipmap/ic_launcher_monochrome`).
  final String? notificationIcon;
  final Duration tick;

  @override
  State<TrainerPlayer> createState() => _TrainerPlayerState();
}

class _TrainerPlayerState extends State<TrainerPlayer> {
  final _clock = clock.stopwatch();
  late TrainingPlan _plan;
  late TrainerVoice _voice;
  late SessionScript _script;
  late SessionBuilder _builder;
  late SessionRunner _runner;
  late VoiceQueue _queue;
  late SessionRecorder _recorder;
  late ResultSaver _saver;
  late int _occurrences;
  TrainingHold? _hold;
  Timer? _timer;
  Timer? _terminalAudio;
  Future<void>? _audioEnding;
  bool _audioEnded = false;
  bool _audioRestarting = false;
  int _audioOwner = 0;
  StreamSubscription<AudioInterruption>? _interruptions;
  double? _endedAt;
  String? _subtitle;
  int _shownGen = -1;
  bool _saveFailed = false;
  bool _closing = false;
  bool _disposed = false;

  String _shownKey = '';
  int _hapticSecond = -1;
  int _hapticGen = -1;

  /// The ring's fill, updated every tick: only the ring's painter listens.
  final _progress = ValueNotifier<double>(0);

  double get _t => _clock.elapsedMicroseconds / 1e6;
  bool get _paused => !_clock.isRunning;
  SessionEngine get _engine => _runner.engine;
  SessionPhase get _phase => _engine.phase;
  TrainerTheme get _th => widget.theme;
  TrainerStrings get _s => widget.strings;

  @override
  void initState() {
    super.initState();
    _plan = widget.plan;
    _voice = widget.voice ?? TrainerVoice.silent;
    _script =
        _voice.scriptBuilder?.call(_voice.source, _voice.settings.language) ??
        SessionScript(source: _voice.source, lang: _voice.settings.language);
    _builder =
        widget.sessionBuilder ??
        SessionBuilder(
          rhythms: widget.rhythms,
          known: (id) => widget.drillOf(id) != null,
          prepSeconds: widget.prepSeconds,
          transitionSeconds: widget.transitionSeconds,
          switchSecondsFor: _script.switchSecondsFor,
        );
    _occurrences = _builder.occurrenceCount(_plan);
    _runner = SessionRunner(SessionEngine(_builder.phases(_plan)), _script);
    _recorder = SessionRecorder(
      plan: _plan,
      totalExercises: _occurrences,
      sessionId: widget.sessionId,
    );
    _saver = ResultSaver(widget.onFinished);
    _voice.output.volume = _voice.settings.volume;
    _queue = VoiceQueue(
      output: _voice.output,
      lib: _voice.source,
      settings: _voice.settings,
    );
    if (_voice.settings.voice || _voice.settings.chimes) {
      unawaited(_voice.output.begin());
    }
    if (_voice.output case final InterruptibleVoiceOutput out) {
      _interruptions = out.interruptions.listen(_onInterruption);
    }
    ScreenAwake.acquire();
    if (widget.keepAlive) {
      _hold = TrainingHold.begin(
        Duration(seconds: (_runner.planSeconds + widget.prepSeconds).round()),
        mediaPlayback: true,
        notice: TrainingNotice(
          channelName: _s.notificationChannel,
          channelDescription: _s.notificationChannelDescription,
          title: _s.notificationTitle,
          text: _s.notificationText,
          icon: widget.notificationIcon,
        ),
      );
    }
    _clock.start();
    _timer = Timer.periodic(widget.tick, (_) => _tick());
    WidgetsBinding.instance.addPostFrameCallback((_) => _tick());
  }

  @override
  void dispose() {
    _disposed = true;
    _audioOwner++;
    _terminalAudio?.cancel();
    _terminalAudio = null;
    _timer?.cancel();
    _progress.dispose();
    unawaited(_interruptions?.cancel());
    ScreenAwake.release();
    _queue.cancelAll(_t);
    unawaited(_endAudio());
    _hold?.release();
    if (!_recorder.finished) {
      // Closed without the done view (route removed): still record it.
      _runner.finish(_t);
      _endedAt ??= _t;
      unawaited(_saver(_result()));
    }
    super.dispose();
  }

  SessionResult _result() =>
      _recorder.finish(_engine, activeSeconds: _endedAt ?? _t);

  void _submit(Iterable<FiredCue> fired, double t) {
    for (final f in fired) {
      _queue.submit(f.cue, t);
      if (f.cue.subtitle != null) _subtitle = f.cue.subtitle;
    }
  }

  void _tick() {
    if (_disposed || !mounted || (_paused && !_engine.done)) return;
    final t = _t;
    _submit(_runner.update(t), t);
    _queue.tick(t);
    if (_engine.generation != _shownGen && _phase.kind != PhaseKind.work) {
      _subtitle = null;
    }
    if (_engine.done) _onDone(t);
    final p = _phase;
    _syncProgress(t);
    _haptics(p, t);
    final key =
        '${_engine.generation}:${_engine.done}:${_counterValue(p, t)}:'
        '${_subtitle ?? ''}:$_saveFailed';
    if (key != _shownKey || _engine.generation != _shownGen) {
      setState(() {
        _shownKey = key;
        _shownGen = _engine.generation;
      });
    }
  }

  void _onDone(double t) {
    if (_recorder.finished) return;
    _endedAt ??= t;
    _clock.stop();
    // Keep the closing line (including queued tails) audible before ending
    // the silent loop and the foreground hold. A replay cancels this owner.
    var tail = 4.0;
    for (final line in _queue.log) {
      final remaining = line.end - t + VoiceQueue.tailGrace;
      if (remaining > tail) tail = remaining;
    }
    final owner = _audioOwner;
    final hold = _hold;
    _terminalAudio = Timer(Duration(microseconds: (tail * 1e6).ceil()), () {
      _terminalAudio = null;
      if (_disposed || owner != _audioOwner || !_engine.done) return;
      unawaited(_endAudio());
      hold?.release();
    });
    unawaited(_save());
  }

  Future<void> _endAudio() {
    if (_audioEnded) return _audioEnding ?? Future<void>.value();
    _audioEnded = true;
    return _audioEnding = Future<void>.sync(
      _voice.output.end,
    ).catchError((Object _) {});
  }

  Future<void> _restartAudioAfterEnd(int owner) async {
    await _audioEnding;
    if (_disposed || !mounted || owner != _audioOwner) return;
    _audioEnding = null;
    _audioEnded = false;
    if (_voice.settings.voice || _voice.settings.chimes) {
      await Future<void>.sync(_voice.output.begin).catchError((Object _) {});
    }
    if (_disposed || !mounted || owner != _audioOwner) return;
    _audioRestarting = false;
    _clock.start();
    _tick();
    setState(() {});
  }

  Future<bool> _save() async {
    final ok = await _saver(_result());
    if (mounted) setState(() => _saveFailed = !ok);
    return ok;
  }

  void _replay() {
    if (!_engine.done || !_saver.saved || _closing) return;
    final owner = ++_audioOwner;
    _terminalAudio?.cancel();
    _terminalAudio = null;
    // End the previous owner's delayed close before acquiring a new one.
    // The shared output stays open; no old route can end the new session.
    _hold?.release();
    _queue.cancelAll(_t);
    _clock
      ..stop()
      ..reset();
    _plan = widget.plan;
    _script =
        _voice.scriptBuilder?.call(_voice.source, _voice.settings.language) ??
        SessionScript(source: _voice.source, lang: _voice.settings.language);
    _occurrences = _builder.occurrenceCount(_plan);
    _runner = SessionRunner(SessionEngine(_builder.phases(_plan)), _script);
    _recorder = SessionRecorder(plan: _plan, totalExercises: _occurrences);
    _saver = ResultSaver(widget.onFinished);
    _queue = VoiceQueue(
      output: _voice.output,
      lib: _voice.source,
      settings: _voice.settings,
    );
    _endedAt = null;
    _subtitle = null;
    _shownGen = -1;
    _shownKey = '';
    _saveFailed = false;
    _hapticGen = -1;
    _hapticSecond = -1;
    _progress.value = 0;
    if (!_audioEnded && (_voice.settings.voice || _voice.settings.chimes)) {
      unawaited(_voice.output.begin());
    }
    if (widget.keepAlive) {
      _hold = TrainingHold.begin(
        Duration(seconds: (_runner.planSeconds + widget.prepSeconds).round()),
        mediaPlayback: true,
        notice: TrainingNotice(
          channelName: _s.notificationChannel,
          channelDescription: _s.notificationChannelDescription,
          title: _s.notificationTitle,
          text: _s.notificationText,
          icon: widget.notificationIcon,
        ),
      );
    }
    if (_audioEnded) {
      // An earlier terminal end may still be stopping native players. Wait
      // before beginning and starting the new clock, so it cannot stop a
      // new round or swallow that round's first cue.
      _audioRestarting = true;
      unawaited(_restartAudioAfterEnd(owner));
    } else {
      _clock.start();
      _tick();
    }
    setState(() {});
  }

  void _haptics(SessionPhase p, double t) {
    if (_engine.done || _paused) return;
    if (_engine.generation != _hapticGen) {
      _hapticGen = _engine.generation;
      _hapticSecond = -1;
      if (p.isWork && _engine.generation > 0) {
        unawaited(HapticFeedback.mediumImpact());
      }
    }
    if (p.seconds == 0 || p.selfPaced || p.countedOnClock) return;
    final left = _engine.secondsLeft(t);
    if (left >= 1 && left <= 3 && left != _hapticSecond) {
      _hapticSecond = left;
      unawaited(HapticFeedback.selectionClick());
    }
  }

  /// The big number in the ring: the rep, the self-paced target or the
  /// seconds left.
  String _counterValue(SessionPhase p, double t) {
    if (p.isWork && p.selfPaced) return '${p.reps ?? ''}';
    final rep = p.repAt(_engine.elapsedIn(t));
    if (rep != null) return '$rep';
    return '${_engine.secondsLeft(t)}';
  }

  void _onInterruption(AudioInterruption e) {
    if (!mounted || _engine.done || e == AudioInterruption.ended || _paused) {
      return;
    }
    _queue.cancelAll(_t);
    _clock.stop();
    _hold?.setPlaybackState(paused: true);
    setState(() {});
  }

  void _togglePause({bool announce = true}) {
    if (_engine.done || _audioRestarting) return;
    if (_paused) {
      if (_voice.output case final InterruptibleVoiceOutput out) {
        unawaited(out.reactivate());
      }
      _hold?.renew(
        Duration(seconds: (_runner.planSeconds - _t).clamp(0, 1e6).round()),
      );
      _clock.start();
      _hold?.setPlaybackState(paused: false);
      final resume = announce ? _script.call(VoiceCall.resume) : null;
      if (resume != null) {
        _queue.submit(VoiceCue(0, [resume], CuePriority.call), _t);
      }
    } else {
      _queue.cancelAll(_t);
      final paused = announce ? _script.call(VoiceCall.paused) : null;
      if (paused != null) {
        _queue.submit(VoiceCue(0, [paused], CuePriority.call), _t);
      }
      _clock.stop();
      _hold?.setPlaybackState(paused: true);
    }
    setState(() {});
  }

  void _syncProgress(double t) {
    if (_engine.done) return;
    final p = _phase;
    _progress.value = p.selfPaced || p.seconds == 0
        ? 0.0
        : (_engine.elapsedIn(t) / p.seconds).clamp(0.0, 1.0);
  }

  void _after(void Function() change) {
    _queue.cancelAll(_t);
    change();
    _subtitle = null;
    _syncProgress(_t);
    _tick();
    setState(() {});
  }

  void _skip() => _after(() => _runner.skip(_t));
  void _previous() => _after(() => _runner.previous(_t));

  void _completeSet() {
    if (_paused || !_engine.awaitingCompletion) return;
    unawaited(HapticFeedback.lightImpact());
    _queue.cancelAll(_t);
    _submit(_runner.completeSet(_t), _t);
    _subtitle = null;
    _tick();
    setState(() {});
  }

  void _endEarly() {
    _queue.cancelAll(_t);
    _runner.finish(_t);
    _endedAt ??= _t;
    _onDone(_t);
    setState(() {});
  }

  void _substitute(String id) {
    final p = _phase;
    if (p.blockIndex < 0 || widget.drillOf(id) == null) return;
    final blocks = [
      for (final (bi, b) in _plan.blocks.indexed)
        bi != p.blockIndex
            ? b
            : PlanBlock(
                id: b.id,
                name: b.name,
                type: b.type,
                rounds: b.rounds,
                restBetweenRoundsSeconds: b.restBetweenRoundsSeconds,
                items: [
                  for (final (ii, i) in b.items.indexed)
                    ii != p.itemInBlock
                        ? i
                        : PlanItem(
                            exerciseId: id,
                            mode: i.mode,
                            sets: i.sets,
                            reps: i.reps,
                            workSeconds: i.workSeconds,
                            perSide: i.perSide,
                            restSeconds: i.restSeconds,
                            note: i.note,
                            replacedFrom: i.exerciseId,
                          ),
                ],
              ),
    ];
    _plan = _plan.copyWith(blocks: blocks);
    _after(() => _runner.restartWith(_builder.phases(_plan), _t));
  }

  Future<void> _discomfort({SessionPhase? completedPhase}) async {
    if (_engine.done) return;
    final wasRunning = !_paused;
    if (wasRunning) _togglePause(announce: widget.announceDiscomfortPause);
    final at = DiscomfortContext(
      phase: completedPhase ?? _phase,
      resumePhase: _phase,
      afterExercise: completedPhase != null,
      activeSeconds: _t,
      strings: _s,
      theme: _th,
    );
    final handler = widget.onDiscomfort ?? _defaultDiscomfort;
    final d = await handler(context, at);
    if (!mounted) return;
    final p = completedPhase ?? _phase;
    if (d != null) {
      _recorder.discomfort(
        DiscomfortEvent(
          at: _t,
          exerciseId: p.exerciseId,
          blockIndex: p.blockIndex,
          itemInBlock: p.itemInBlock,
          set: p.set,
          side: p.side,
          action: d.action,
          substituteId: d.substituteId,
          note: d.note,
        ),
      );
    }
    if (d?.replacementPhases case final phases?) {
      if (wasRunning) _togglePause(announce: widget.announceDiscomfortPause);
      _after(
        () => _runner.restartWith(
          phases,
          _t,
          fromItemIndex: d!.restartItemIndex,
          withRest: d.withRest,
        ),
      );
      _decisionVoice(d!);
      return;
    }
    switch (d?.action) {
      case DiscomfortAction.skip:
        if (wasRunning) _togglePause(announce: widget.announceDiscomfortPause);
        _skip();
      case DiscomfortAction.end:
        _endEarly();
      case DiscomfortAction.substitute when d!.substituteId != null:
        if (wasRunning) _togglePause(announce: widget.announceDiscomfortPause);
        _substitute(d.substituteId!);
      default:
        if (wasRunning) _togglePause(announce: widget.announceDiscomfortPause);
    }
    if (d != null) _decisionVoice(d);
  }

  void _decisionVoice(DiscomfortDecision decision) {
    if (decision.subtitle != null) {
      setState(() => _subtitle = decision.subtitle);
    }
    if (decision.voiceClips.isEmpty) return;
    _queue.cancelAll(_t);
    _queue.submit(VoiceCue(0, decision.voiceClips, CuePriority.call), _t);
    _queue.tick(_t);
  }

  Future<DiscomfortDecision?> _defaultDiscomfort(
    BuildContext context,
    DiscomfortContext at,
  ) => showModalBottomSheet<DiscomfortDecision>(
    context: context,
    backgroundColor: _th.surface,
    isScrollControlled: true,
    builder: (c) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            TrainerSpace.gutter,
            TrainerSpace.x5,
            TrainerSpace.gutter,
            TrainerSpace.x2,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_s.discomfortTitle, style: _th.title),
              const SizedBox(height: TrainerSpace.x2),
              Text(
                _s.discomfortBody,
                style: _th.body.copyWith(fontSize: 15, color: _th.muted),
              ),
              const SizedBox(height: TrainerSpace.x4),
              for (final (icon, label, action, color) in [
                (
                  Icons.compress,
                  _s.discomfortContinue,
                  DiscomfortAction.continueEasier,
                  _th.text,
                ),
                (
                  Icons.skip_next,
                  _s.discomfortSkip,
                  DiscomfortAction.skip,
                  _th.text,
                ),
                (
                  Icons.stop,
                  _s.discomfortEnd,
                  DiscomfortAction.end,
                  _th.danger,
                ),
              ])
                ListTile(
                  key: ValueKey('discomfort-${action.name}'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(icon, color: color),
                  title: Text(label, style: _th.callout.copyWith(color: color)),
                  onTap: () => Navigator.pop(c, DiscomfortDecision(action)),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<bool> _confirmClose() async {
    if (_engine.done) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: _th.surface,
        title: Text(_s.closeTitle, style: _th.title),
        content: Text(_s.closeBody, style: _th.body),
        actions: [
          TextButton(
            key: const ValueKey('close-confirm'),
            onPressed: () => Navigator.pop(c, true),
            child: Text(_s.closeConfirm, style: TextStyle(color: _th.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(_s.closeCancel, style: TextStyle(color: _th.accent)),
          ),
        ],
      ),
    );
    if (ok == true) _endEarly();
    return ok == true;
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    final nav = Navigator.of(context);
    try {
      if (!await _confirmClose() || !mounted) return;
      // A confirmed early exit and system back share the same save as the
      // done view. Keep the result and retry action on screen if it fails.
      if (await _save() && mounted) nav.pop(_recorder.result);
    } finally {
      _closing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _phase;
    final d = p.exerciseId == null ? null : widget.drillOf(p.exerciseId!);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _close();
      },
      child: Scaffold(
        backgroundColor: _th.background,
        body: SafeArea(child: _engine.done ? _doneView() : _sessionView(p, d)),
      ),
    );
  }

  Widget _circle({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    double size = 44,
  }) => Tooltip(
    message: tooltip,
    child: Material(
      key: key,
      color: _th.surfaceHigh,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () {
          unawaited(HapticFeedback.selectionClick());
          onPressed();
        },
        child: SizedBox.square(
          dimension: size,
          child: Icon(icon, size: size * .46, color: _th.text),
        ),
      ),
    ),
  );

  Widget _tag(String label, {IconData? icon, Color? color, Key? key}) =>
      Container(
        key: key,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: _th.scrim,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: color ?? Colors.white),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontFamily: _th.fontFamily,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color ?? Colors.white,
              ),
            ),
          ],
        ),
      );

  Widget _fade(Widget child, {Alignment alignment = Alignment.centerLeft}) =>
      AnimatedSwitcher(
        duration: TrainerMotion.fast,
        layoutBuilder: (current, previous) =>
            Stack(alignment: alignment, children: [...previous, ?current]),
        child: child,
      );

  Widget _media(SessionPhase p, TrainerDrill d) {
    final req = TrainerMediaRequest(
      drill: d,
      paused: _paused,
      mirrored: p.side == Side.left,
      theme: _th,
      strings: _s,
    );
    if (widget.mediaBuilder != null) return widget.mediaBuilder!(context, req);
    final m = d.media;
    if (m == null) {
      return AspectRatio(
        aspectRatio: 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _th.mediaStage,
            borderRadius: BorderRadius.circular(_th.radius),
          ),
        ),
      );
    }
    return DrillMediaView(
      key: ValueKey('player-${d.id}'),
      media: m,
      paused: _paused,
      mirrored: p.side == Side.left,
      radius: _th.radius,
      stage: _th.mediaStage,
      errorLabel: _s.mediaUnavailable,
      errorColor: _th.muted,
    );
  }

  Widget _sessionView(SessionPhase p, TrainerDrill? d) {
    final t = _t;
    final still = TrainerMotion.reduced(context);
    final rest =
        p.kind == PhaseKind.rest ||
        p.kind == PhaseKind.roundRest ||
        p.kind == PhaseKind.prep;
    final done = _engine.completedExercises;
    final label = switch (p.kind) {
      PhaseKind.prep => _s.prepFirst,
      PhaseKind.rest when p.nextExerciseId != null => _s.restNext,
      PhaseKind.rest => _s.restBetweenSets,
      PhaseKind.roundRest => _s.roundRest,
      PhaseKind.switchSide => _s.switchTo(p.side ?? Side.left),
      _ => '',
    };
    final sub = _subtitle ?? (rest ? d?.cue : null);
    final current = (p.itemIndex + 1).clamp(
      1,
      _occurrences < 1 ? 1 : _occurrences,
    );
    final fraction = _occurrences == 0 ? 0.0 : done / _occurrences;
    final meta = _meta(p);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            TrainerSpace.x4,
            TrainerSpace.x2,
            TrainerSpace.gutter,
            TrainerSpace.x2,
          ),
          child: Row(
            children: [
              _circle(
                key: const ValueKey('close'),
                icon: Icons.close,
                tooltip: _s.close,
                onPressed: _close,
              ),
              const SizedBox(width: TrainerSpace.x4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _fade(
                      Text(
                        p.blockName,
                        key: ValueKey('block-${p.blockName}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _th.label.copyWith(
                          color: _th.accentText,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    TweenAnimationBuilder<double>(
                      tween: Tween(end: fraction),
                      duration: still ? Duration.zero : TrainerMotion.slow,
                      curve: TrainerMotion.standard,
                      builder: (_, v, _) => ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: v,
                          minHeight: 4,
                          backgroundColor: _th.track,
                          color: _th.accent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: TrainerSpace.x4),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '$current',
                      style: _th.callout.copyWith(fontWeight: FontWeight.w700),
                    ),
                    TextSpan(text: ' / $_occurrences', style: _th.label),
                  ],
                ),
                style: const TextStyle(fontFeatures: TrainerTheme.tabular),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              TrainerSpace.x4,
              TrainerSpace.x2,
              TrainerSpace.x4,
              TrainerSpace.x2,
            ),
            children: [
              if (d != null)
                Stack(
                  children: [
                    AnimatedSwitcher(
                      duration: TrainerMotion.slow,
                      layoutBuilder: (current, previous) =>
                          Stack(children: [...previous, ?current]),
                      child: KeyedSubtree(
                        key: ValueKey('media-${d.id}'),
                        child: _media(p, d),
                      ),
                    ),
                    Positioned(
                      left: TrainerSpace.x3,
                      top: TrainerSpace.x3,
                      child: _fade(
                        _paused
                            ? _tag(_s.paused, key: const ValueKey('tag-paused'))
                            : p.kind == PhaseKind.switchSide
                            ? _tag(
                                _s.switchTo(p.side ?? Side.left),
                                key: const ValueKey('tag-side'),
                                icon: Icons.swap_horiz,
                                color: TrainerTheme.dark.caution,
                              )
                            : rest && p.nextExerciseId != null
                            ? _tag(_s.next, key: const ValueKey('tag-next'))
                            : const SizedBox.shrink(key: ValueKey('tag-none')),
                      ),
                    ),
                    if (widget.restFeedbackBuilder == null ||
                        p.isWork ||
                        p.kind == PhaseKind.switchSide)
                      Positioned(
                        right: TrainerSpace.x2,
                        top: TrainerSpace.x2,
                        child: Semantics(
                          excludeSemantics: true,
                          button: true,
                          label: _s.discomfort,
                          onTap: _discomfort,
                          child: GestureDetector(
                            key: const ValueKey('discomfort'),
                            onTap: _discomfort,
                            child: Padding(
                              padding: const EdgeInsets.all(TrainerSpace.x1),
                              child: _tag(
                                _s.discomfort,
                                icon: Icons.healing,
                                color: TrainerTheme.dark.caution,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: TrainerSpace.x5),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: TrainerSpace.x1,
                ),
                // Fixed slots: changing phase only changes what is written,
                // never where.
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            height: _labelSlot,
                            child: _fade(
                              Text(
                                label,
                                key: ValueKey('label-$label'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: _th.label.copyWith(
                                  color: p.kind == PhaseKind.switchSide
                                      ? _th.caution
                                      : _th.muted,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          _fade(
                            Text(
                              d?.name ?? '',
                              key: ValueKey('name-${d?.id}'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: _th.title.copyWith(
                                fontSize: 24,
                                height: 1.25,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          _fade(
                            Text(
                              meta,
                              key: ValueKey('meta-$meta'),
                              style: _th.label.copyWith(fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: TrainerSpace.x3),
                    _counter(
                      p,
                      t,
                      working: !rest && p.kind != PhaseKind.switchSide,
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: _subtitleSlot,
                child: _fade(
                  alignment: Alignment.topLeft,
                  sub == null
                      ? const SizedBox(
                          key: ValueKey('sub-none'),
                          width: double.infinity,
                        )
                      : Padding(
                          key: ValueKey('sub-$sub'),
                          padding: const EdgeInsets.fromLTRB(
                            TrainerSpace.x1,
                            TrainerSpace.x4,
                            TrainerSpace.x1,
                            0,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Icon(
                                  Icons.subtitles_outlined,
                                  size: 18,
                                  color: _th.faint,
                                ),
                              ),
                              const SizedBox(width: TrainerSpace.x2),
                              Expanded(
                                child: Text(
                                  sub,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: _th.body.copyWith(
                                    fontSize: 15,
                                    height: 1.55,
                                    color: _th.muted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
              SizedBox(
                height: _nextSlot,
                child: _fade(
                  alignment: Alignment.topCenter,
                  _restFeedback(p) ??
                      (p.selfPaced ? _completeButton() : null) ??
                      (rest ? null : _nextUp(p)) ??
                      const SizedBox(
                        key: ValueKey('next-none'),
                        width: double.infinity,
                      ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            48,
            TrainerSpace.x2,
            48,
            TrainerSpace.x5,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _circle(
                key: const ValueKey('prev'),
                icon: Icons.skip_previous_rounded,
                tooltip: _s.previous,
                size: 56,
                onPressed: _previous,
              ),
              Tooltip(
                message: _paused ? _s.resume : _s.pause,
                child: Material(
                  key: const ValueKey('pause'),
                  color: _th.accent,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () {
                      unawaited(HapticFeedback.lightImpact());
                      _togglePause();
                    },
                    child: SizedBox.square(
                      dimension: 76,
                      child: AnimatedSwitcher(
                        duration: TrainerMotion.fast,
                        transitionBuilder: (child, a) => still
                            ? FadeTransition(opacity: a, child: child)
                            : FadeTransition(
                                opacity: a,
                                child: ScaleTransition(
                                  scale: a.drive(Tween(begin: .6, end: 1)),
                                  child: child,
                                ),
                              ),
                        child: Icon(
                          _paused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                          key: ValueKey(_paused),
                          size: 36,
                          color: _th.onAccent,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              _circle(
                key: const ValueKey('skip'),
                icon: Icons.skip_next_rounded,
                tooltip: _s.skip,
                size: 56,
                onPressed: _skip,
              ),
            ],
          ),
        ),
      ],
    );
  }

  static const _labelSlot = 22.0;
  static const _subtitleSlot = TrainerSpace.x4 + 15 * 1.55 * 3 + 2;
  static const _nextSlot = TrainerSpace.x5 + 60.0;

  Widget? _restFeedback(SessionPhase phase) {
    final build = widget.restFeedbackBuilder;
    if (build == null ||
        (phase.kind != PhaseKind.rest && phase.kind != PhaseKind.roundRest)) {
      return null;
    }
    SessionPhase? completed;
    for (final visit in _engine.visits.reversed) {
      if (visit.phase.isWork) {
        completed = visit.phase;
        break;
      }
    }
    if (completed == null || completed.itemIndex >= phase.itemIndex) {
      return null;
    }
    final target = completed;
    return build(
      context,
      TrainerRestFeedback(
        phase: phase,
        completedPhase: target,
        reportDiscomfort: () => _discomfort(completedPhase: target),
      ),
    );
  }

  String _dose(PlanItem item, {SessionPhase? phase}) {
    final label = phase == null ? null : widget.doseLabel?.call(phase);
    if (label != null) return label;
    final reps = item.mode == DoseMode.reps;
    return _s.dose(
      reps: reps,
      amount: reps ? (item.reps ?? 10) : (item.workSeconds ?? 30),
      perSide: item.perSide,
    );
  }

  String _meta(SessionPhase p) {
    final parts = <String>[];
    if (p.rounds > 0) parts.add(_s.roundOf(p.round, p.rounds));
    if (p.sets > 1) parts.add(_s.setOf(p.set, p.sets));
    if (p.side != null) parts.add(_s.sideName(p.side!));
    final item = p.item;
    if (item != null) parts.add(_dose(item, phase: p));
    return parts.join(' · ');
  }

  Widget? _completeButton() {
    if (!_engine.awaitingCompletion) return null;
    return Padding(
      key: const ValueKey('complete-set'),
      padding: const EdgeInsets.only(top: TrainerSpace.x5),
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: FilledButton(
          key: const ValueKey('complete-set-button'),
          style: FilledButton.styleFrom(
            backgroundColor: _th.accent,
            foregroundColor: _th.onAccent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          onPressed: _paused ? null : _completeSet,
          child: Text(
            _s.completeSet,
            style: _th.callout.copyWith(
              color: _th.onAccent,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  /// While working: the move after this one.
  Widget? _nextUp(SessionPhase p) {
    final phases = _engine.phases;
    SessionPhase? next;
    for (var i = _engine.index + 1; i < phases.length; i++) {
      final q = phases[i];
      if (q.kind == PhaseKind.work &&
          q.exerciseId != null &&
          q.exerciseId != p.exerciseId) {
        next = q;
        break;
      }
    }
    final d = next == null ? null : widget.drillOf(next.exerciseId!);
    if (next == null || d == null) return null;
    final dose = next.item == null ? null : _dose(next.item!, phase: next);
    final poster = d.media?.posterFor(light: !_th.isDark);
    return Padding(
      key: ValueKey('next-${d.id}'),
      padding: const EdgeInsets.only(top: TrainerSpace.x5),
      child: Container(
        padding: const EdgeInsets.all(TrainerSpace.x2),
        decoration: BoxDecoration(
          color: _th.surface,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox.square(
                dimension: 44,
                child: ColoredBox(
                  color: _th.mediaStage,
                  child: poster == null
                      ? null
                      : Image.asset(
                          poster,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                ),
              ),
            ),
            const SizedBox(width: TrainerSpace.x3),
            Text(_s.nextUp, style: _th.label),
            const SizedBox(width: TrainerSpace.x2),
            Expanded(
              child: Text(
                d.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _th.callout,
              ),
            ),
            if (dose != null) ...[
              const SizedBox(width: TrainerSpace.x2),
              Text(dose, style: _th.label),
            ],
            const SizedBox(width: TrainerSpace.x2),
          ],
        ),
      ),
    );
  }

  Widget _counter(SessionPhase p, double t, {required bool working}) {
    final counted = p.countedOnClock;
    final left = _engine.secondsLeft(t);
    final urgent =
        !counted &&
        !p.selfPaced &&
        p.seconds > 0 &&
        left >= 1 &&
        left <= 3 &&
        !_paused;
    final caption = p.isWork && p.selfPaced
        ? _s.selfPacedCaption
        : counted
        ? _s.repsCaption(p.reps!)
        : p.isWork
        ? _s.secondsCaption
        : _s.startsInCaption;
    return TrainerCountdownRing(
      theme: _th,
      progress: _progress,
      value: _counterValue(p, t),
      numberKey: const ValueKey('counter'),
      caption: caption,
      size: 112,
      color: working || urgent ? _th.accent : _th.text.withValues(alpha: .55),
      urgent: urgent,
      dim: _paused,
    );
  }

  Widget _doneView() {
    final result = _recorder.result;
    final full =
        !_engine.endedEarly && _engine.fullyCompletedExercises >= _occurrences;
    final minutes = ((_endedAt ?? _t) / 60).round();
    final numeral = _th.numeral(26);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        TrainerSpace.x6,
        0,
        TrainerSpace.x6,
        TrainerSpace.x5,
      ),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      full ? Icons.check_circle_rounded : Icons.flag_rounded,
                      size: 64,
                      color: _th.accent,
                    ),
                    const SizedBox(height: TrainerSpace.x2),
                    Text(
                      full ? _s.doneFull : _s.donePartial,
                      style: _th.display,
                    ),
                    const SizedBox(height: TrainerSpace.x2),
                    Text(
                      _plan.title,
                      textAlign: TextAlign.center,
                      style: _th.body.copyWith(color: _th.muted),
                    ),
                    const SizedBox(height: TrainerSpace.x8),
                    Row(
                      children: [
                        Expanded(
                          child: _stat(
                            Text('$minutes', style: numeral),
                            _s.minutes,
                          ),
                        ),
                        const SizedBox(width: TrainerSpace.x3),
                        Expanded(
                          child: _stat(
                            Text(
                              '${_engine.fullyCompletedExercises}/$_occurrences',
                              style: numeral,
                            ),
                            _s.exercisesDone,
                          ),
                        ),
                      ],
                    ),
                    if (result != null && widget.feedbackBuilder != null) ...[
                      const SizedBox(height: TrainerSpace.x6),
                      widget.feedbackBuilder!(context, result),
                    ],
                    if (result != null &&
                        _saver.saved &&
                        widget.replayBuilder != null) ...[
                      const SizedBox(height: TrainerSpace.x3),
                      widget.replayBuilder!(context, result, _replay),
                    ],
                    if (_saveFailed) ...[
                      const SizedBox(height: TrainerSpace.x5),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              _s.saveFailed,
                              style: _th.label.copyWith(color: _th.danger),
                            ),
                          ),
                          TextButton(
                            key: const ValueKey('save-retry'),
                            onPressed: () => unawaited(_save()),
                            child: Text(
                              _s.saveRetry,
                              style: TextStyle(color: _th.accent),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: FilledButton(
              key: const ValueKey('finish'),
              style: FilledButton.styleFrom(
                backgroundColor: _th.accent,
                foregroundColor: _th.onAccent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              onPressed: _saver.saved ? _close : null,
              child: Text(
                _s.finish,
                style: _th.callout.copyWith(
                  color: _th.onAccent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(Widget value, String label) => Container(
    padding: const EdgeInsets.symmetric(vertical: TrainerSpace.x4),
    decoration: BoxDecoration(
      color: _th.surface,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      children: [
        value,
        const SizedBox(height: 2),
        Text(label, style: _th.label),
      ],
    ),
  );
}
