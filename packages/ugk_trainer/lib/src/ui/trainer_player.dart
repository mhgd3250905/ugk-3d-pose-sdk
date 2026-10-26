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
//   carried over (standard Cupertino symbols);
// * solid layered UI: opaque surfaces ([TrainerSurface]), circular controls,
//   a primary accent disc and calm 500 ms sequential phase changes;
// * immersive stage (sdk-stage-r1): the square clip edge-to-edge at the top,
//   its backdrop continued as a floor ([TrainerStageFloor]).
import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../engine/session.dart';
import '../media/drill_media.dart';
import '../media/drill_media_view.dart';
import '../platform/screen_awake.dart';
import '../platform/training_keep_alive.dart';
import '../pose_hub/pose_hub_media_prefetcher.dart';
import '../pose_hub/pose_hub_media_preparation.dart';
import '../pose_hub/pose_hub_pack_media.dart';
import '../result/session_result.dart';
import '../rhythm/rhythm.dart';
import '../voice/session_runner.dart';
import '../voice/session_script.dart';
import '../voice/voice_cue.dart';
import '../voice/voice_queue.dart';
import '../voice/voice_source.dart';
import 'countdown_ring.dart';
import 'trainer_stage.dart';
import 'trainer_strings.dart';
import 'trainer_surface.dart';
import 'trainer_theme.dart';
import 'ugk_play_pause_button.dart';

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
  /// dose; its `unilateral` must match the item's perSide). In a segmented
  /// item this replaces only the current segment's exercise, retaining the
  /// parent item, segment identity and other segments.
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
    this.mediaPreparer,
  });
  final TrainerDrill drill;
  final bool paused;

  /// Left side of a unilateral move (the clip shows the right side).
  final bool mirrored;
  final TrainerTheme theme;
  final TrainerStrings strings;

  /// Shared session queue for custom PoseHub media builders.
  final PoseHubMediaPreparer? mediaPreparer;
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
    this.rhythmDefaults = const RhythmDefaults(),
    this.showExtendRest = false,
    this.showCompleteTimedPhase = false,
    this.showSoundToggle = false,
    this.showSkipSegment = false,
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
    this.poseHubCatalog,
    this.poseHubActionOf,
    this.poseHubMediaBaseUri,
    this.poseHubMediaPreparer,
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
  final RhythmDefaults rhythmDefaults;

  /// Optional shared controls; existing App layouts retain their defaults.
  final bool showExtendRest;
  final bool showCompleteTimedPhase;
  final bool showSoundToggle;
  final bool showSkipSegment;
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

  /// Optional PoseHub rendering and ordered prefetch for the shared player.
  /// A custom [mediaBuilder] can use [TrainerMediaRequest.mediaPreparer] to
  /// participate in the same two-action queue. Session timing never waits.
  final PoseHubAppTestCatalog? poseHubCatalog;
  final PoseHubPackAction? Function(String exerciseId)? poseHubActionOf;
  final Uri? poseHubMediaBaseUri;
  final PoseHubMediaPreparer? poseHubMediaPreparer;

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
  Timer? _navigationVoice;
  final _mediaHost = GlobalKey();
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
  bool _soundEnabled = true;
  bool _interruptionActive = false;
  PoseHubMediaPrefetcher? _mediaPrefetcher;
  Future<void>? _mediaRetirement;
  int _mediaGeneration = -1;
  int _interruptionRevision = 0;

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

  final _materialScope = GlobalKey();
  BuildContext get _materialContext => _materialScope.currentContext ?? context;

  ThemeData _materialTheme(BuildContext context) => Theme.of(context).copyWith(
    brightness: _th.brightness,
    colorScheme: Theme.of(context).colorScheme.copyWith(
      brightness: _th.brightness,
      primary: _th.accent,
      onPrimary: _th.onAccent,
      secondary: _th.accent,
      onSecondary: _th.onAccent,
      surface: _th.surface,
      onSurface: _th.text,
      onSurfaceVariant: _th.muted,
      outline: _th.border,
      outlineVariant: _th.border,
      shadow: _th.shadow,
      surfaceTint: _th.surface,
    ),
    bottomSheetTheme: Theme.of(context).bottomSheetTheme.copyWith(
      backgroundColor: _th.surface.withValues(alpha: 1),
      modalBackgroundColor: _th.surface.withValues(alpha: 1),
      surfaceTintColor: _th.surface.withValues(alpha: 1),
      shadowColor: _th.shadow,
      dragHandleColor: _th.muted,
      elevation: 2,
      modalElevation: 2,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        elevation: const WidgetStatePropertyAll(1),
        shadowColor: WidgetStatePropertyAll(_th.shadow),
        surfaceTintColor: WidgetStatePropertyAll(
          _th.accent.withValues(alpha: 0),
        ),
        overlayColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.any(
                (s) =>
                    s == WidgetState.pressed ||
                    s == WidgetState.hovered ||
                    s == WidgetState.focused,
              )
              ? _th.onAccent.withValues(alpha: .1)
              : null,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: _th.accent,
        overlayColor: _th.accent,
      ),
    ),
  );
  TrainerStrings get _s => widget.strings;
  VoiceSettings get _soundSettings => _voice.settings.copyWith(
    voice: _soundEnabled && (_voice.settings.voice || !_voice.settings.chimes),
    chimes: _soundEnabled && (_voice.settings.chimes || !_voice.settings.voice),
  );

  @override
  void initState() {
    super.initState();
    _plan = widget.plan;
    _voice = widget.voice ?? TrainerVoice.silent;
    _soundEnabled = _voice.settings.voice || _voice.settings.chimes;
    _script =
        _voice.scriptBuilder?.call(_voice.source, _voice.settings.language) ??
        SessionScript(source: _voice.source, lang: _voice.settings.language);
    _builder =
        widget.sessionBuilder ??
        SessionBuilder(
          rhythms: widget.rhythms,
          rhythmDefaults: widget.rhythmDefaults,
          known: (id) => widget.drillOf(id) != null,
          prepSeconds: widget.prepSeconds,
          transitionSeconds: widget.transitionSeconds,
          switchSecondsFor: _script.switchSecondsFor,
        );
    _occurrences = _builder.occurrenceCount(_plan);
    _runner = SessionRunner(SessionEngine(_builder.phases(_plan)), _script);
    _configureMedia();
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
      settings: _soundSettings,
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
        mediaPlayback: _voice.settings.voice || _voice.settings.chimes,
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
    _mediaPrefetcher?.dispose();
    _audioOwner++;
    _terminalAudio?.cancel();
    _terminalAudio = null;
    _timer?.cancel();
    _navigationVoice?.cancel();
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
    if (_navigationVoice != null) {
      // Navigation settles only presentation and speech, never the clock.
      // Do not mark intermediate runner cues fired before the final target.
      _engine.update(t);
    } else {
      _submit(_runner.update(t), t);
      _queue.tick(t);
    }
    if (_engine.generation != _shownGen && _phase.kind != PhaseKind.work) {
      _subtitle = null;
    }
    if (_engine.done) _onDone(t);
    _prioritizeMedia();
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

  void _configureMedia() {
    final preparer = widget.poseHubMediaPreparer;
    if (_mediaPrefetcher?.host != preparer) {
      _retireMedia();
      _mediaPrefetcher = preparer == null
          ? null
          : PoseHubMediaPrefetcher(
              preparer,
              afterCancellation: _mediaRetirement,
            );
    }
    _mediaGeneration = -1;
    _prioritizeMedia();
  }

  void _retireMedia() {
    final previous = _mediaPrefetcher;
    previous?.dispose();
    _mediaRetirement = previous?.cancellationComplete ?? _mediaRetirement;
    _mediaPrefetcher = null;
  }

  void _prioritizeMedia() {
    final scheduler = _mediaPrefetcher;
    if ((widget.poseHubCatalog == null && widget.poseHubActionOf == null) ||
        scheduler == null ||
        _mediaGeneration == _engine.generation) {
      return;
    }
    _mediaGeneration = _engine.generation;
    scheduler.prioritize([
      for (final phase in _engine.phases.skip(_engine.index))
        ?_poseHubAction(phase.exerciseId ?? ''),
    ]);
  }

  PoseHubPackAction? _poseHubAction(String id) =>
      widget.poseHubActionOf?.call(id) ?? widget.poseHubCatalog?.tryGet(id);

  @override
  void didUpdateWidget(TrainerPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.poseHubCatalog != widget.poseHubCatalog ||
        oldWidget.poseHubActionOf != widget.poseHubActionOf ||
        oldWidget.poseHubMediaPreparer != widget.poseHubMediaPreparer ||
        oldWidget.poseHubMediaBaseUri != widget.poseHubMediaBaseUri) {
      _configureMedia();
    }
  }

  void _onDone(double t) {
    if (_recorder.finished) return;
    _retireMedia();
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
    _navigationVoice?.cancel();
    _navigationVoice = null;
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
    _configureMedia();
    _saver = ResultSaver(widget.onFinished);
    _queue = VoiceQueue(
      output: _voice.output,
      lib: _voice.source,
      settings: _soundSettings,
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
        mediaPlayback: _voice.settings.voice || _voice.settings.chimes,
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
    if (!mounted || _engine.done) return;
    if (e == AudioInterruption.ended) {
      _interruptionActive = false;
      return;
    }
    _interruptionRevision++;
    _interruptionActive = e == AudioInterruption.began;
    _queue.cancelAll(_t);
    _clock.stop();
    _hold?.setPlaybackState(paused: true);
    setState(() {});
  }

  void _togglePause({bool announce = true}) {
    if (_engine.done || _audioRestarting || (_paused && _interruptionActive)) {
      return;
    }
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

  void _after(void Function() change, {bool settleVoice = false}) {
    _navigationVoice?.cancel();
    _navigationVoice = null;
    _queue.cancelAll(_t);
    change();
    if (settleVoice && !_engine.done) {
      _navigationVoice = Timer(DrillMediaHandoff.defaultSettleDelay, () {
        _navigationVoice = null;
        if (_disposed || !mounted || _paused) return;
        // The engine may naturally cross a zero-length rest while settling.
        // The latest timer owns navigation; speak the phase that is current.
        _tick();
      });
    }
    _subtitle = null;
    _syncProgress(_t);
    _tick();
    setState(() {});
  }

  void _skip() => _after(() => _runner.skip(_t), settleVoice: true);
  void _previous() => _after(() => _runner.previous(_t), settleVoice: true);

  void _extendRest() {
    if (_runner.extendRest(_t)) {
      _queue.cancelAll(_t);
      final remaining =
          _engine.phases
              .skip(_engine.index)
              .fold(0.0, (total, phase) => total + phase.seconds) -
          _engine.elapsedIn(_t);
      _hold?.renew(Duration(seconds: remaining.clamp(0, 1e6).ceil()));
      _syncProgress(_t);
      setState(() {});
    }
  }

  void _completeTimedPhase() => _after(() => _runner.completeTimedPhase(_t));
  void _skipSegment() => _after(() => _runner.skipSegment(_t));

  void _toggleSound() {
    _queue.cancelAll(_t);
    _soundEnabled = !_soundEnabled;
    _queue.settings = _soundSettings;
    _voice.output.volume = _soundEnabled ? _voice.settings.volume : 0;
    if (_soundEnabled) unawaited(_voice.output.begin());
    setState(() {});
  }

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
                            exerciseId: i.segments.isEmpty ? id : i.exerciseId,
                            mode: i.mode,
                            sets: i.sets,
                            reps: i.reps,
                            workSeconds: i.workSeconds,
                            perSide: i.perSide,
                            restSeconds: i.restSeconds,
                            note: i.note,
                            replacedFrom: i.segments.isEmpty
                                ? i.exerciseId
                                : i.replacedFrom,
                            segments: [
                              for (final segment in i.segments)
                                segment.id != p.segmentId
                                    ? segment
                                    : PlanSegment(
                                        id: segment.id,
                                        exerciseId: id,
                                        mode: segment.mode,
                                        reps: segment.reps,
                                        workSeconds: segment.workSeconds,
                                        holdSeconds: segment.holdSeconds,
                                        label: segment.label,
                                      ),
                            ],
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
    final interruptionRevision = _interruptionRevision;
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
    final mayResume =
        wasRunning && interruptionRevision == _interruptionRevision;
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
      if (mayResume) _togglePause(announce: widget.announceDiscomfortPause);
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
        if (mayResume) _togglePause(announce: widget.announceDiscomfortPause);
        _skip();
      case DiscomfortAction.end:
        _endEarly();
      case DiscomfortAction.substitute when d!.substituteId != null:
        if (mayResume) _togglePause(announce: widget.announceDiscomfortPause);
        _substitute(d.substituteId!);
      default:
        if (mayResume) _togglePause(announce: widget.announceDiscomfortPause);
    }
    if (d != null) _decisionVoice(d);
  }

  void _decisionVoice(DiscomfortDecision decision) {
    if (decision.subtitle != null) {
      setState(() => _subtitle = decision.subtitle);
    }
    if (decision.voiceClips.isEmpty || _interruptionActive) return;
    _queue.cancelAll(_t);
    _queue.submit(VoiceCue(0, decision.voiceClips, CuePriority.call), _t);
    _queue.tick(_t);
  }

  Future<DiscomfortDecision?> _defaultDiscomfort(
    BuildContext context,
    DiscomfortContext at,
  ) => showModalBottomSheet<DiscomfortDecision>(
    context: _materialContext,
    backgroundColor: _th.surface.withValues(alpha: 1),
    barrierColor: _th.shadow.withValues(alpha: .32),
    isScrollControlled: true,
    showDragHandle: true,
    shape: RoundedSuperellipseBorder(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      side: BorderSide(color: _th.border, width: 1),
    ),
    sheetAnimationStyle: const AnimationStyle(
      duration: TrainerMotion.calm,
      reverseDuration: Duration(milliseconds: 420),
    ),
    builder: (c) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            TrainerSpace.x6,
            0,
            TrainerSpace.x6,
            TrainerSpace.x4,
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
                  CupertinoIcons.arrow_down_right_arrow_up_left,
                  _s.discomfortContinue,
                  DiscomfortAction.continueEasier,
                  _th.text,
                ),
                (
                  CupertinoIcons.forward_end_fill,
                  _s.discomfortSkip,
                  DiscomfortAction.skip,
                  _th.text,
                ),
                (
                  CupertinoIcons.stop_fill,
                  _s.discomfortEnd,
                  DiscomfortAction.end,
                  _th.danger,
                ),
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: TrainerSpace.x2),
                  child: _pillOption(
                    key: ValueKey('discomfort-${action.name}'),
                    icon: icon,
                    label: label,
                    color: color,
                    onTap: () => Navigator.pop(c, DiscomfortDecision(action)),
                  ),
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
      context: _materialContext,
      barrierColor: _th.shadow.withValues(alpha: .32),
      builder: (c) => AlertDialog(
        backgroundColor: _th.surface.withValues(alpha: 1),
        surfaceTintColor: _th.surface.withValues(alpha: 1),
        shadowColor: _th.shadow,
        elevation: 2,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(28),
          side: BorderSide(color: _th.border, width: 1),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(
          TrainerSpace.x4,
          0,
          TrainerSpace.x4,
          TrainerSpace.x4,
        ),
        title: Text(_s.closeTitle, style: _th.title),
        content: Text(_s.closeBody, style: _th.body.copyWith(color: _th.muted)),
        actions: [
          TextButton(
            key: const ValueKey('close-confirm'),
            style: TextButton.styleFrom(
              minimumSize: const Size(64, 44),
              shape: const StadiumBorder(),
            ),
            onPressed: () => Navigator.pop(c, true),
            child: Text(_s.closeConfirm, style: TextStyle(color: _th.muted)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _th.accent,
              foregroundColor: _th.onAccent,
              minimumSize: const Size(88, 44),
              shape: StadiumBorder(side: BorderSide(color: _th.border)),
            ),
            onPressed: () => Navigator.pop(c, false),
            child: Text(_s.closeCancel),
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
      // The stage is the clips' own backdrop ([TrainerTheme.mediaStage]),
      // so the edge-to-edge clip and the floor below read as one space.
      child: Theme(
        data: _materialTheme(context),
        child: Builder(
          key: _materialScope,
          builder: (_) => Scaffold(
            backgroundColor: _th.mediaStage,
            body: _engine.done
                ? TrainerResultStage(
                    theme: _th,
                    child: SafeArea(child: _doneView()),
                  )
                : _sessionView(p, d),
          ),
        ),
      ),
    );
  }

  Widget _circle({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    double size = 44,
  }) => TrainerIconButton(
    key: key,
    theme: _th,
    icon: Icon(icon),
    tooltip: tooltip,
    size: size,

    onPressed: () {
      unawaited(HapticFeedback.selectionClick());
      onPressed();
    },
  );

  /// A full-width solid option row (the built-in discomfort choices).
  Widget _pillOption({
    required Key key,
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) => Semantics(
    button: true,
    child: GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: TrainerSurface(
        theme: _th,
        level: TrainerSurfaceLevel.control,
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: TrainerSpace.x5),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: TrainerSpace.x3),
            Expanded(
              child: Text(label, style: _th.callout.copyWith(color: color)),
            ),
          ],
        ),
      ),
    ),
  );

  /// Semantic foreground for the opaque panels above media.
  Color get _mediaInk => _th.text;

  /// Safety foreground resolved by the active theme.
  Color get _mediaCaution => _th.caution;

  /// A small solid HUD chip on the stage (32 px, on the fixed media body,
  /// so it reads at arm's length without covering the figure).
  Widget _tag(String label, {IconData? icon, Color? color, Key? key}) =>
      TrainerSurface(
        key: key,
        theme: _th,

        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: TrainerSpace.x3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: color ?? _mediaInk),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontFamily: _th.fontFamily,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: color ?? _mediaInk,
              ),
            ),
          ],
        ),
      );

  Widget _fade(
    Widget child, {
    Alignment alignment = Alignment.centerLeft,
    bool sizeToCurrent = false,
  }) => AnimatedSwitcher(
    // Calm and sequential: the old text is gone (first 40 %) before the
    // new one fades in (last 60 %); fade only, no layout motion.
    duration: TrainerMotion.calm,
    switchInCurve: const Interval(.4, 1, curve: TrainerMotion.calmCurve),
    switchOutCurve: const Interval(.6, 1, curve: TrainerMotion.calmCurve),
    // [sizeToCurrent]: the outgoing child is laid out but takes no room,
    // so the slot is the new child's size from the first frame and does
    // not snap when the old one is removed at the end of the fade.
    layoutBuilder: (current, previous) => Stack(
      alignment: alignment,
      clipBehavior: Clip.none,
      children: [
        if (sizeToCurrent)
          for (final w in previous)
            Positioned(left: 0, right: 0, bottom: 0, child: w)
        else
          ...previous,
        ?current,
      ],
    ),
    child: child,
  );

  /// Edge-to-edge on the stage: [theme] carries radius 0.
  Widget _media(SessionPhase p, TrainerDrill d, TrainerTheme theme) {
    final req = TrainerMediaRequest(
      drill: d,
      paused: _paused,
      mirrored: p.side == Side.left,
      theme: theme,
      strings: _s,
      mediaPreparer: _mediaPrefetcher,
    );
    if (widget.mediaBuilder != null) return widget.mediaBuilder!(context, req);
    final action = _poseHubAction(d.id);
    if (action != null) {
      final media = PoseHubPackMedia(
        action: action,
        baseUri: widget.poseHubMediaBaseUri ?? Uri(),
        playing: !_engine.done,
        paused: _paused,
        theme: theme,
        mediaPreparer: _mediaPrefetcher,
      );
      return p.side == Side.left
          ? Transform.flip(flipX: true, child: media)
          : media;
    }
    final m = d.media;
    if (m == null) {
      return ColoredBox(color: _th.mediaStage);
    }
    return DrillMediaView(
      key: const ValueKey('player-media'),
      media: m,
      paused: _paused,
      mirrored: p.side == Side.left,
      radius: 0,
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
    final sub =
        _subtitle ??
        (rest || _poseHubAction(d?.id ?? '') != null ? d?.cue : null);
    final current = (p.itemIndex + 1).clamp(
      1,
      _occurrences < 1 ? 1 : _occurrences,
    );
    final mq = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final h = box.maxHeight;
        // Slim top card · the clip as large as fits · transport. Everything
        // else (tags, next-up, 完成本组, subtitle, rest feedback) is a small
        // pendant overlaid on the stage, at the edges, never on the body.
        final midTop = mq.padding.top + _cardTop;
        final midBottom = h - _transportH - mq.padding.bottom;
        final room = math.max(0.0, midBottom - midTop);
        // The clips are square on a flat backdrop that continues as the
        // stage, so the clip may run a little past the screen's sides; the
        // figure stands in the middle of the frame.
        final v = math.min(w * _clipOverscan, math.max(160.0, room));
        final left = (w - v) / 2;
        // Sit a little above centre: the room below the feet is where the
        // pendants hang.
        final top = midTop + math.max(0.0, room - v) * .35;
        final tagTop = midTop + TrainerSpace.x1;
        final mediaRadius = _th.copyWith(radius: 0);
        final bottomPendant = _restFeedback(p);
        final topPendant = p.kind == PhaseKind.switchSide
            ? _tag(
                _s.switchTo(p.side ?? Side.left),
                key: const ValueKey('tag-side'),
                icon: CupertinoIcons.arrow_left_right,
                color: _mediaCaution,
              )
            : rest && p.nextExerciseId != null
            ? _tag(_s.next, key: const ValueKey('tag-next'))
            : _nextUp(p);
        final showDiscomfort =
            widget.restFeedbackBuilder == null ||
            p.isWork ||
            p.kind == PhaseKind.switchSide;
        return Stack(
          children: [
            // The studio is behind the media. Alpha video keeps its natural
            // colours; depth/floor lighting must never tint the person.
            Positioned.fill(
              child: TrainerStageFloor(
                theme: _th,
                clipSize: v,
                clipLeft: left,
                clipTop: top,
              ),
            ),
            if (d != null)
              Positioned(
                left: left,
                top: top,
                width: v,
                height: v,
                child: DrillMediaHandoff(
                  child: KeyedSubtree(
                    key: ValueKey('media-${d.id}'),
                    child: RepaintBoundary(
                      key: _mediaHost,
                      child: _media(p, d, mediaRadius),
                    ),
                  ),
                ),
              ),
            // Bottom pendants (sdk-stage-r7): the subtitle chip is the
            // lowest thing on the stage, just above the transport — below
            // the clip's bottom edge wherever the stage leaves room — so it
            // covers as little of the demo as possible. The action / preview
            // pendant hangs above it. Both sit in fixed slots, so neither
            // moves across pages, phases or subtitle line counts.
            Positioned(
              left: TrainerSpace.x3,
              right: TrainerSpace.x3,
              bottom: h - midBottom + TrainerSpace.x2,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // A fixed slot for the built-in pendants (none / next
                      // up / 完成本组) (sdk-stage-r6).
                      ConstrainedBox(
                        key: const ValueKey('pendant-slot'),
                        constraints: const BoxConstraints(
                          minHeight: _pendantSlot,
                        ),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          heightFactor: 1,
                          child: _fade(
                            alignment: Alignment.bottomCenter,
                            sizeToCurrent: true,
                            bottomPendant ??
                                const SizedBox(
                                  key: ValueKey('next-none'),
                                  width: double.infinity,
                                ),
                          ),
                        ),
                      ),
                      const SizedBox(height: TrainerSpace.x2),
                      // A fixed slot for the subtitle (two lines), the chip
                      // bottom-aligned in it, so a one- or two-line line
                      // never shifts the pendant above.
                      ConstrainedBox(
                        key: const ValueKey('subtitle-slot'),
                        constraints: BoxConstraints(minHeight: _subtitleSlot),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          heightFactor: 1,
                          child: _fade(
                            alignment: Alignment.bottomCenter,
                            sizeToCurrent: true,
                            _subtitleChip(sub),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _transport(p, t, rest, mq.padding.bottom),
            ),
            if (d != null)
              Positioned(
                left: TrainerSpace.x3,
                right: TrainerSpace.x3,
                top: tagTop,
                child: Row(
                  key: const ValueKey('top-hud'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: _fade(
                          topPendant ??
                              const SizedBox.shrink(key: ValueKey('tag-none')),
                        ),
                      ),
                    ),
                    if (showDiscomfort) ...[
                      const SizedBox(width: TrainerSpace.x2),
                      Semantics(
                        excludeSemantics: true,
                        button: true,
                        label: _s.discomfort,
                        onTap: _discomfort,
                        child: GestureDetector(
                          key: const ValueKey('discomfort'),
                          behavior: HitTestBehavior.opaque,
                          onTap: _discomfort,
                          child: Padding(
                            // 32 px chip, 44 px touch target.
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: _tag(
                              _s.discomfort,
                              icon: CupertinoIcons.waveform_path_ecg,
                              color: _mediaCaution,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: SafeArea(
                bottom: false,
                child: _infoCard(
                  p,
                  label,
                  d,
                  rest,
                  current: current,
                  done: done,
                  still: still,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// The top information card, two levels only: the move name (the one prominent
  /// line) over one short muted line (block / set · side / what is next),
  /// and on the right a quiet exercise index — a large light current number
  /// with a small muted `/ total` on its baseline. The workout progress is a
  /// hairline along the inside bottom. Fixed slots: a phase change only
  /// changes what is written, never where.
  Widget _infoCard(
    SessionPhase p,
    String label,
    TrainerDrill? d,
    bool rest, {
    required int current,
    required int done,
    required bool still,
  }) {
    final total = _occurrences < 1 ? 1 : _occurrences;
    final segment = p.segment;
    final segmentName = segment?.label ?? d?.name;
    final line = [
      if (segment != null && segmentName != null) segmentName,
      _subline(p, label),
    ].where((part) => part.isNotEmpty).join(' · ');
    final parentDrill = p.item == null
        ? null
        : widget.drillOf(p.item!.exerciseId);
    final displayDrill = segment == null ? d : parentDrill ?? d;
    final lineColor = p.kind == PhaseKind.switchSide
        ? _th.caution
        : label.isEmpty
        ? _th.muted
        : _th.accentText;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            TrainerSpace.x3,
            TrainerSpace.x2,
            TrainerSpace.x3,
            0,
          ),
          child: TrainerSurface(
            key: const ValueKey('info-card'),
            theme: _th,
            radius: 16,
            height: _cardH,
            padding: const EdgeInsets.fromLTRB(
              TrainerSpace.x3,
              _cardPadV,
              TrainerSpace.x4,
              _cardPadV,
            ),
            // Close is centred on the card's full height; name, muted
            // line and the segmented progress share one left edge, and
            // the progress ends under the index's right edge.
            child: Row(
              children: [
                _circle(
                  key: const ValueKey('close'),
                  icon: CupertinoIcons.xmark,
                  tooltip: _s.close,
                  size: 34,
                  onPressed: _close,
                ),
                const SizedBox(width: TrainerSpace.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _fade(
                                    Text(
                                      displayDrill?.name ?? '',
                                      key: ValueKey('name-${displayDrill?.id}'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: _th.title.copyWith(
                                        fontSize: 17,
                                        height: 1.2,
                                        fontWeight: FontWeight.w600,
                                        letterSpacing: -.2,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  _fade(
                                    Text(
                                      line,
                                      key: ValueKey('label-$line'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: _th.label.copyWith(
                                        fontSize: 12.5,
                                        height: 1.25,
                                        fontWeight: FontWeight.w500,
                                        color: lineColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: TrainerSpace.x3),
                            _index(current, total),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      _track(
                        done: done,
                        current: current,
                        still: still,
                        compact: true,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Exercise index: a large light `4` and a small muted `/5` on one
  /// baseline, tabular so it never jitters.
  Widget _index(int current, int total) => Semantics(
    key: const ValueKey('index'),
    label: '$current / $total',
    excludeSemantics: true,
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$current',
            style: _th
                .numeral(30, color: _th.text)
                .copyWith(fontWeight: FontWeight.w300, letterSpacing: -.6),
          ),
          TextSpan(
            text: ' /$total',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: _th.muted,
              letterSpacing: .2,
            ),
          ),
        ],
      ),
      style: TextStyle(
        fontFamily: _th.fontFamily,
        fontFeatures: TrainerTheme.tabular,
      ),
    ),
  );

  /// The card's one muted line, at most two short parts. Working: set ·
  /// side, topped up with a timed move's dose when there is room
  /// (`第 2/3 组 · 左侧`, `左侧 · 30 秒`), else the block name (`热身`). Prep / rest / switch: the phase label · the
  /// dose coming up.
  String _subline(SessionPhase p, String label) {
    final item = p.item;
    final dose = item == null ? null : _dose(item, phase: p);
    if (label.isNotEmpty) return dose == null ? label : '$label · $dose';
    final parts = <String>[
      if (p.sets > 1) _s.setOf(p.set, p.sets),
      if (p.side != null) _s.sideName(p.side!),
    ];
    // A self-paced set's target (e.g. `8 次`, or the host's doseLabel)
    // stays on the card for the whole set — work, paused, next set — since
    // 完成本组 holds the transport slot (sdk-stage-r9). It leads, so a
    // narrow card ellipsizes the set / side, never the target.
    if (p.selfPaced && dose != null) {
      return [dose, ...parts].join(' · ');
    }
    // Clock-counted sets show their dose at the transport.
    if (parts.length < 2 && dose != null && !p.countedOnClock) {
      parts.add(dose);
    }
    return parts.isEmpty ? p.blockName : parts.join(' · ');
  }

  /// Workout progress: one short segment per exercise (filled = done, tinted
  /// = now), or a single bar for long plans, with n / total beside it.
  Widget _track({
    required int done,
    required int current,
    required bool still,
    bool finished = false,
    bool compact = false,
  }) {
    final total = _occurrences < 1 ? 1 : _occurrences;
    final dur = still ? Duration.zero : TrainerMotion.calm;
    final Widget bar;
    if (total <= 24) {
      bar = Row(
        children: [
          for (var i = 0; i < total; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(
              child: Container(
                height: 4,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  color: i < done
                      ? _th.accent
                      : !finished && i == done
                      ? _th.accentSubtle
                      : _th.track,
                ),
              ),
            ),
          ],
        ],
      );
    } else {
      bar = TweenAnimationBuilder<double>(
        tween: Tween(end: done / total),
        duration: dur,
        curve: TrainerMotion.calmCurve,
        builder: (_, v, _) => ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: v,
            minHeight: 4,
            backgroundColor: _th.track,
            color: _th.accent,
          ),
        ),
      );
    }
    if (compact) {
      return SizedBox(key: const ValueKey('progress'), height: 3, child: bar);
    }
    return SizedBox(
      key: const ValueKey('progress'),
      height: 16,
      child: Row(
        children: [
          const SizedBox(width: TrainerSpace.x1),
          Expanded(child: bar),
          const SizedBox(width: TrainerSpace.x3),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${finished ? done : current}',
                  style: _th.label.copyWith(
                    color: _th.text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                TextSpan(text: ' / $total', style: _th.label),
              ],
            ),
            style: const TextStyle(
              fontSize: 13,
              fontFeatures: TrainerTheme.tabular,
            ),
          ),
        ],
      ),
    );
  }

  /// The coach's line as a compact solid chip (max two lines).
  Widget _subtitleChip(String? sub) => sub == null
      ? const SizedBox(key: ValueKey('sub-none'), width: double.infinity)
      : Center(
          key: ValueKey('sub-$sub'),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: TrainerSurface(
              theme: _th,

              radius: 16,
              padding: const EdgeInsets.symmetric(
                horizontal: TrainerSpace.x3,
                vertical: 6,
              ),
              child: Text(
                sub,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: _th.fontFamily,
                  fontSize: 13,
                  height: 1.4,
                  fontWeight: FontWeight.w400,
                  color: _mediaInk,
                ),
              ),
            ),
          ),
        );

  /// Previous / pause / skip, hovering above the stage floor. The phase's
  /// countdown is a thin ring around the emerald button, and its number sits
  /// just above the button on the same axis: read at a glance from the mat,
  /// while the button keeps its one job (pause / resume).
  Widget _transport(SessionPhase p, double t, bool rest, double bottomInset) =>
      Padding(
        padding: EdgeInsets.fromLTRB(
          40,
          TrainerSpace.x3,
          40,
          TrainerSpace.x5 + bottomInset,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_hasOptionalControls) _optionalControls(p),
            SizedBox(
              height: _digitsH,
              // Scale down rather than clip if a host theme's numerals run
              // taller than the slot (sdk-stage-r9).
              child: Center(
                child: RepaintBoundary(
                  child: FittedBox(fit: BoxFit.scaleDown, child: _digits(p, t)),
                ),
              ),
            ),
            const SizedBox(height: _digitsGap),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                RepaintBoundary(
                  child: _circle(
                    key: const ValueKey('prev'),
                    icon: CupertinoIcons.backward_end_fill,
                    tooltip: _s.previous,
                    size: 56,
                    onPressed: _previous,
                  ),
                ),
                UgkPlayPauseButton(
                  key: const ValueKey('pause'),
                  isPlaying: !_paused,
                  progress: _progress,
                  onTap: _togglePause,
                  theme: _th,
                  strings: _s,
                  trackColor: _th.track,
                  progressColor: rest || p.kind == PhaseKind.switchSide
                      ? _th.muted
                      : _th.accent,
                  knobColor: _th.ringKnob,
                  ringSize: _ringD,
                ),
                RepaintBoundary(
                  child: _circle(
                    key: const ValueKey('skip'),
                    icon: CupertinoIcons.forward_end_fill,
                    tooltip: _s.skip,
                    size: 56,
                    onPressed: _skip,
                  ),
                ),
              ],
            ),
          ],
        ),
      );

  /// Fixed slots follow the system text size (sdk-stage-r9): each is at
  /// least its 1× size and grows with [MediaQuery.textScalerOf], so large
  /// text is never clipped and the slots stay fixed within one screen.
  double _sc(double fontSize) =>
      MediaQuery.textScalerOf(context).scale(fontSize);

  /// Top card: one row (close, name over one muted line, index; 42 px at
  /// 1×) and the hairline progress under it.
  static const _cardPadV = 10.0;
  double get _cardRowH => math.max(
    42.0,
    math.max(_sc(17) * 1.2 + 3 + _sc(12.5) * 1.25 + 2, _sc(30) * 1.25),
  );
  double get _cardH => _cardPadV + _cardRowH + 8 + 3 + _cardPadV;
  double get _cardTop => TrainerSpace.x2 + _cardH + TrainerSpace.x2;

  /// How far the square clip may run past the screen's width.
  static const _clipOverscan = 1.15;

  /// Height reserved above the subtitle chip for host rest feedback.
  /// Next-up lives under the top card; 完成本组 lives in the transport.
  static const double _pendantSlot = 36;

  /// Height reserved for the subtitle chip: two 13 px lines at 1.4 plus
  /// its 6 px vertical padding.
  double get _subtitleSlot => 2 * _sc(13) * 1.4 + 12 + 1;

  /// Countdown number slot above the button, and the ring around it.
  /// 44: also holds 完成本组 (44 px touch target) on self-paced sets.
  double get _digitsH => math.max(44.0, _sc(32) * 1.2);
  static const _digitsGap = 2.0;
  static const _ringD = 96.0;

  /// The transport (number slot + row) without the bottom inset.
  double get _transportH =>
      TrainerSpace.x3 +
      _digitsH +
      _digitsGap +
      _ringD +
      TrainerSpace.x5 +
      (_hasOptionalControls ? 44 : 0);

  bool get _hasOptionalControls =>
      widget.showExtendRest ||
      widget.showCompleteTimedPhase ||
      widget.showSoundToggle ||
      widget.showSkipSegment;

  Widget _optionalControls(SessionPhase p) => SizedBox(
    height: 44,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.showExtendRest &&
            (p.kind == PhaseKind.rest || p.kind == PhaseKind.roundRest))
          IconButton(
            key: const ValueKey('extend-rest'),
            tooltip: _s.extendRest,
            icon: const Icon(CupertinoIcons.timer),
            onPressed: _extendRest,
          ),
        if (widget.showCompleteTimedPhase &&
            p.isWork &&
            !p.selfPaced &&
            !p.countedOnClock)
          IconButton(
            key: const ValueKey('complete-timed-phase'),
            tooltip: _s.completeTimedPhase,
            icon: const Icon(CupertinoIcons.check_mark_circled),
            onPressed: _paused ? null : _completeTimedPhase,
          ),
        if (widget.showSkipSegment && p.isWork && p.segmentId != null)
          IconButton(
            key: const ValueKey('skip-segment'),
            tooltip: _s.skipSegment,
            icon: const Icon(CupertinoIcons.list_bullet),
            onPressed: _skipSegment,
          ),
        if (widget.showSoundToggle)
          IconButton(
            key: const ValueKey('sound-toggle'),
            tooltip: _soundEnabled ? _s.soundOff : _s.soundOn,
            icon: Icon(
              _soundEnabled
                  ? CupertinoIcons.speaker_2
                  : CupertinoIcons.speaker_slash,
            ),
            onPressed: _toggleSound,
          ),
      ],
    ),
  );

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
    item = phase?.segment?.toPlanItem(item) ?? item;
    final reps = item.mode == DoseMode.reps;
    return _s.dose(
      reps: reps,
      amount: reps ? (item.reps ?? 10) : (item.workSeconds ?? 30),
      perSide: item.perSide,
    );
  }

  /// 完成本组: a compact emerald pill in the transport's number slot, just
  /// above the pause button (sdk-stage-r8).
  Widget? _completeButton() {
    if (!_engine.awaitingCompletion) return null;
    return Center(
      key: const ValueKey('complete-set'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: FilledButton.icon(
          key: const ValueKey('complete-set-button'),
          style: FilledButton.styleFrom(
            backgroundColor: _th.accent,
            foregroundColor: _th.onAccent,
            disabledBackgroundColor: _th.surfaceHigh,
            disabledForegroundColor: _th.faint,
            padding: const EdgeInsets.symmetric(horizontal: TrainerSpace.x5),
            shape: StadiumBorder(side: BorderSide(color: _th.border)),
          ),
          onPressed: _paused ? null : _completeSet,
          icon: const Icon(CupertinoIcons.check_mark, size: 20),
          label: Text(
            _s.completeSet,
            style: _th.callout.copyWith(
              fontSize: 15,
              color: _th.onAccent,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  /// While working or paused: the move after this one, beneath the info card
  /// on the left. Its text wraps within the room left by the safety control.
  Widget? _nextUp(SessionPhase p) {
    final phases = _engine.phases;
    SessionPhase? next;
    for (var i = _engine.index + 1; i < phases.length; i++) {
      final q = phases[i];
      if (q.kind == PhaseKind.work &&
          q.exerciseId != null &&
          q.itemIndex != p.itemIndex) {
        next = q;
        break;
      }
    }
    final d = next == null ? null : widget.drillOf(next.exerciseId!);
    if (next == null || d == null) return null;
    final poster = d.media?.posterFor(light: !_th.isDark);
    // Keep the thumbnail slot useful when a drill has no poster or a host's
    // asset is unavailable, rather than leaving an opaque empty circle.
    final placeholder = Icon(
      CupertinoIcons.forward_end_fill,
      size: 14,
      color: _th.muted,
    );
    final small = TextStyle(
      fontFamily: _th.fontFamily,
      fontSize: 13,
      color: _th.muted,
    );
    return Align(
      key: ValueKey('next-${d.id}'),
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 240),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: TrainerSurface(
            theme: _th,

            padding: const EdgeInsets.fromLTRB(4, 4, TrainerSpace.x3, 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipOval(
                  child: SizedBox.square(
                    dimension: 28,
                    child: ColoredBox(
                      color: _th.surfaceHigh,
                      child: poster == null
                          ? placeholder
                          : Image.asset(
                              poster,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => placeholder,
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: TrainerSpace.x2),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(text: '${_s.nextUp} · '),
                        TextSpan(
                          text: d.name,
                          style: small.copyWith(
                            color: _mediaInk,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    style: small,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The number above the button: seconds left for timed moves, prep, rest
  /// and side switches (the last three seconds of a timed move take the
  /// accent and breathe); the rep on the clock with `/ 12 次` for counted
  /// sets; the dose alone for self-paced sets. Screen readers get the same
  /// reading as one label.
  Widget _digits(SessionPhase p, double t) {
    final counted = p.countedOnClock;
    final left = _engine.secondsLeft(t);
    final working = p.isWork;
    if (working && p.selfPaced) {
      // 完成本组 takes the number slot above the pause button (the dose
      // is already on the top card) (sdk-stage-r8).
      final done = _completeButton();
      if (done != null) return done;
      final item = p.item;
      if (item == null) return const SizedBox.shrink(key: ValueKey('counter'));
      final dose = _dose(item, phase: p);
      return Text(
        dose,
        key: const ValueKey('counter'),
        style: _th.callout.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: _th.muted,
        ),
      );
    }
    final urgent =
        !counted &&
        working &&
        p.seconds > 0 &&
        left >= 1 &&
        left <= 3 &&
        !_paused;
    final value = _counterValue(p, t);
    final unit = counted
        ? _s.repsCaption(p.reps!)
        : working
        ? _s.secondsCaption
        : _s.startsInCaption;
    return Semantics(
      label: '$value $unit',
      excludeSemantics: true,
      child: TrainerCountdownDigits(
        theme: _th,
        value: value,
        unit: unit,
        size: 32,
        color: working ? _th.text : _th.muted,
        urgent: urgent,
        dim: _paused,
        numberKey: const ValueKey('counter'),
      ),
    );
  }

  Widget _doneView() {
    final result = _recorder.result;
    final full =
        !_engine.endedEarly && _engine.fullyCompletedExercises >= _occurrences;
    final minutes = ((_endedAt ?? _t) / 60).round();
    final numeral = _th.numeral(32);
    return Column(
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                TrainerSpace.x3,
                TrainerSpace.x2,
                TrainerSpace.x3,
                0,
              ),
              child: TrainerSurface(
                key: const ValueKey('done-card'),
                theme: _th,
                radius: 28,
                padding: const EdgeInsets.fromLTRB(
                  TrainerSpace.x4,
                  TrainerSpace.x4,
                  TrainerSpace.x4,
                  TrainerSpace.x4,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        TrainerSurface(
                          theme: _th,
                          level: TrainerSurfaceLevel.control,
                          width: 56,
                          height: 56,
                          child: Icon(
                            full
                                ? CupertinoIcons.check_mark
                                : CupertinoIcons.flag,
                            size: 30,
                            color: _th.accent,
                          ),
                        ),
                        const SizedBox(width: TrainerSpace.x4),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                full ? _s.doneFull : _s.donePartial,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: _th.title.copyWith(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _plan.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: _th.label.copyWith(fontSize: 14),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: TrainerSpace.x4),
                    _track(
                      done: _engine.fullyCompletedExercises,
                      current: _engine.fullyCompletedExercises,
                      still: TrainerMotion.reduced(context),
                      finished: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: TrainerSpace.x6,
                vertical: TrainerSpace.x5,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            TrainerSpace.x6,
            0,
            TrainerSpace.x6,
            TrainerSpace.x5,
          ),
          child: SizedBox(
            width: double.infinity,
            height: 56,
            child: FilledButton(
              key: const ValueKey('finish'),
              style: FilledButton.styleFrom(
                backgroundColor: _th.accent,
                foregroundColor: _th.onAccent,
                disabledBackgroundColor: _th.track,
                shape: StadiumBorder(side: BorderSide(color: _th.border)),
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
        ),
      ],
    );
  }

  Widget _stat(Widget value, String label) => TrainerSurface(
    theme: _th,
    radius: _th.radius,
    padding: const EdgeInsets.symmetric(vertical: TrainerSpace.x5),
    child: Column(
      children: [
        value,
        const SizedBox(height: 2),
        Text(label, style: _th.label),
      ],
    ),
  );
}
