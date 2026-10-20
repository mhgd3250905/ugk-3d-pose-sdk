// Ported from HipLab@99fcc83 lib/hip/voice/just_audio_output.dart (10-19
// Android voice fix). Changes: no dart:io (web must compile) – the platform
// comes from defaultTargetPlatform; the iOS keep-alive clip is this
// package's silent asset unless [keepAliveAsset] says otherwise; log tag
// UgkTrainerVoice.
import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        debugPrint,
        defaultTargetPlatform,
        kIsWeb,
        visibleForTesting;
import 'package:just_audio/just_audio.dart';

import 'voice_line_controller.dart';
import 'voice_queue.dart';

/// Real playback for voice coaching (#13).
///
/// * Voice and chimes are separate players so a tick can sit under a number.
/// * iOS category is `playback`: the coach is heard with the ring/silent
///   switch on (a workout follow-along, like a fitness app), and keeps
///   talking with the screen locked (`UIBackgroundModes: audio`).
/// * Other apps' music is lowered (ducked) only while a line is playing:
///   `duckOthers` is taken right before a line and released ~0.7 s after it
///   ends; between lines the session mixes with others at full volume.
/// * During a session a looping silent clip keeps the audio session alive,
///   so with iOS `UIBackgroundModes: audio` the app – and its absolute-time
///   training clock – keeps running with the screen locked.
/// * Interruptions are handled here, not by just_audio (its default would
///   resume a stale line after a call and pause the keep-alive when
///   headphones are unplugged): a call / Siri / alarm or unplugging the
///   headphones cuts the line and is reported on [interruptions] so the
///   player pauses the session; when the interruption ends the session and
///   keep-alive are re-activated, and the player waits for 继续.
///
/// Needs real-device verification (ducking, silent switch, lock screen and
/// interruptions are OS features that tests cannot exercise) – see
/// docs/ios-setup-and-release.md.
class JustAudioVoiceOutput
    implements VoiceOutput, InterruptibleVoiceOutput, VoicePlatform {
  JustAudioVoiceOutput({String keepAliveAsset = defaultKeepAliveAsset})
    : this._(
        AudioPlayer(
          handleAudioSessionActivation: false,
          handleInterruptions: false,
        ),
        AudioPlayer(
          handleAudioSessionActivation: false,
          handleInterruptions: false,
        ),
        AudioPlayer(
          handleAudioSessionActivation: false,
          handleInterruptions: false,
        ),
        () => AudioSession.instance,
        keepAliveAsset,
      );

  @visibleForTesting
  JustAudioVoiceOutput.forTesting({
    required AudioPlayer voice,
    required AudioPlayer chime,
    required AudioPlayer keepAlive,
    required Future<AudioSession> Function() session,
    bool? iOS,
  }) : this._(voice, chime, keepAlive, session, defaultKeepAliveAsset, iOS);

  JustAudioVoiceOutput._(
    this._voice,
    this._chime,
    this._keepAlive,
    this._getSession,
    this._silence, [
    this._iOS,
  ]) {
    _lines = VoiceLineController(
      this,
      isActive: () => _began && !_disposed,
      onSkip: (assets) => debugPrint(
        'UgkTrainerVoice skipped late line: '
        '${assets.map((a) => a.split('/').last).join('+')}',
      ),
    );
  }

  late final VoiceLineController _lines;
  int _playGeneration = 0;
  int _speechRequest = 0;
  Future<void>? _voicePlayback;

  final AudioPlayer _voice;
  final AudioPlayer _chime;
  final AudioPlayer _keepAlive;
  final Future<AudioSession> Function() _getSession;
  final _events = StreamController<AudioInterruption>.broadcast();
  final _subscriptions = <StreamSubscription<Object?>>[];
  AudioSession? _session;
  double _volume = 1;
  bool _began = false;
  int _sessionGeneration = 0;
  Future<void>? _beginning;
  Future<void>? _ending;
  Future<void>? _disposal;
  bool _disposed = false;
  bool _keepAliveSuppressed = false;
  bool _keepAliveExpired = false;
  Timer? _keepAliveLimit;

  bool _current(int generation) =>
      _began && !_disposed && generation == _sessionGeneration;

  @override
  Stream<AudioInterruption> get interruptions => _events.stream;

  /// Silent loop that keeps mobile playback active between coaching lines.
  static const defaultKeepAliveAsset =
      'packages/ugk_trainer/assets/silence.m4a';
  final String _silence;
  final bool? _iOS;

  bool get _onIOS =>
      _iOS ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);

  bool get _onAndroid =>
      !kIsWeb &&
      !_onIOS &&
      (_iOS == false || defaultTargetPlatform == TargetPlatform.android);

  // Same upper bound as the native TrainingHold. Never renew this timer for
  // each line or reactivation: a forgotten owner must not loop indefinitely.
  static const _keepAliveCap = Duration(hours: 2);

  static AudioSessionConfiguration _config({
    required bool duck,
  }) => AudioSessionConfiguration(
    avAudioSessionCategory: AVAudioSessionCategory.playback,
    avAudioSessionCategoryOptions: duck
        ? AVAudioSessionCategoryOptions.duckOthers |
              AVAudioSessionCategoryOptions.interruptSpokenAudioAndMixWithOthers
        : AVAudioSessionCategoryOptions.mixWithOthers,
    avAudioSessionMode: AVAudioSessionMode.defaultMode,
    androidAudioAttributes: const AndroidAudioAttributes(
      contentType: AndroidAudioContentType.speech,
      // Coaching (including ticks) follows media volume. Sonification routes
      // to system/alert volume and is muted when the phone is in silent mode.
      usage: AndroidAudioUsage.media,
    ),
    androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
    androidWillPauseWhenDucked: false,
  );

  @override
  Future<void> begin() {
    if (_disposed) return Future<void>.value();
    if (_began) return _beginning ?? Future<void>.value();
    _began = true;
    _keepAliveSuppressed = false;
    _keepAliveExpired = false;
    final generation = ++_sessionGeneration;
    // A new page can open while the previous page is releasing its audio.
    // Finish that release before configuring or starting this session.
    return _beginning = _initialize(generation, _ending);
  }

  Future<void> _initialize(int generation, Future<void>? ending) async {
    await ending;
    if (!_current(generation)) return;
    try {
      final s = await _getSession();
      if (!_current(generation)) return;
      _session = s;
      await s.configure(_config(duck: false));
      if (!_current(generation)) return;
      await _keepAliveOn();
      if (!_current(generation)) return;
      if (_subscriptions.isEmpty) {
        _subscriptions
          ..add(s.interruptionEventStream.listen(_onInterruption))
          ..add(s.becomingNoisyEventStream.listen((_) => _onUnplugged()));
      }
    } on Object {
      // Audio is best-effort; the visual timer works without it.
    }
  }

  /// iOS needs an active session; Android keeps a continuous silent AudioTrack
  /// alongside TrainingHold. Some devices freeze even a mediaPlayback FGS and
  /// disable its wake lock once the last spoken track goes inactive (HipLab
  /// native evidence, 2026-10-20). The silent track does not request Android
  /// focus: each spoken line still acquires/releases its own ducking focus.
  Future<void> _keepAliveOn() async {
    final generation = _sessionGeneration;
    bool current() =>
        _current(generation) && !_keepAliveSuppressed && !_keepAliveExpired;
    if ((!_onIOS && !_onAndroid) || !current()) return;
    final s = _session;
    if (s == null) return;
    if (_onIOS) await _step(() => s.setActive(true));
    if (!current()) return;
    var prepared = false;
    await _step(() async {
      if (_keepAlive.audioSource == null) {
        await _keepAlive.setAsset(_silence);
        if (!current()) return;
      }
      // An earlier session may have ended between loading and configuration.
      // Reapply these even when its source survived stop().
      await _keepAlive.setLoopMode(LoopMode.one);
      if (!current()) return;
      await _keepAlive.setVolume(0);
      prepared = true;
    });
    if (!current() || !prepared) return;
    _keepAliveLimit ??= Timer(_keepAliveCap, () {
      _keepAliveLimit = null;
      if (!_current(generation)) return;
      _keepAliveExpired = true;
      unawaited(_step(_keepAlive.stop));
    });
    unawaited(_keepAlive.play().catchError((Object _) {}));
  }

  /// Runs one platform call; a failure must not skip the calls after it.
  static Future<void> _step(Future<void> Function() call) async {
    try {
      await call();
    } on Object {
      /* best effort */
    }
  }

  void _onInterruption(AudioInterruptionEvent e) {
    if (!_began) return;
    if (e.begin) {
      // `duck`: another app's short prompt (Android transient focus); the
      // coach can keep going. Anything else (call, Siri, alarm): stop.
      if (e.type == AudioInterruptionType.duck) return;
      debugPrint('UgkTrainerVoice interruption began: ${e.type.name}');
      _keepAliveSuppressed = true;
      ++_speechRequest;
      _lines
        ..abandon()
        ..forgetDuck();
      unawaited(_step(stopVoice));
      unawaited(_step(_chime.stop));
      unawaited(_step(_keepAlive.pause));
      _events.add(AudioInterruption.began);
    } else {
      if (e.type == AudioInterruptionType.duck) return;
      unawaited(
        reactivate().then((_) {
          if (_began && !_events.isClosed) _events.add(AudioInterruption.ended);
        }),
      );
    }
  }

  void _onUnplugged() {
    if (!_began) return;
    debugPrint('UgkTrainerVoice interruption: output unplugged');
    _keepAliveSuppressed = true;
    ++_speechRequest;
    _lines.abandon();
    unawaited(_releaseUnpluggedAudio());
    _events.add(AudioInterruption.unplugged);
  }

  Future<void> _releaseUnpluggedAudio() async {
    await _step(stopVoice);
    await _step(_chime.stop);
    await _step(_keepAlive.pause);
    await _lines.releaseDuck();
  }

  @override
  Future<void> reactivate() async {
    final generation = _sessionGeneration;
    await _beginning;
    if (!_current(generation)) return;
    final s = _session;
    if (s == null) return;
    await _lines.serial(() async {
      if (!_current(generation)) return;
      await _step(() => s.configure(_config(duck: false)));
      if (!_current(generation)) return;
      _lines.forgetDuck();
      _keepAliveSuppressed = false;
      await _keepAliveOn();
    });
  }

  @override
  Future<void> end() {
    _began = false;
    _keepAliveSuppressed = true;
    _keepAliveLimit?.cancel();
    _keepAliveLimit = null;
    ++_sessionGeneration;
    ++_speechRequest;
    _lines.abandon();
    final starting = _beginning;
    _beginning = null;
    return _ending = _finish(_ending, starting);
  }

  Future<void> _finish(Future<void>? ending, Future<void>? starting) async {
    await ending;
    // Invalidate immediately, but let pending native initialization settle
    // before stopping players, so it cannot turn audio back on after end.
    await starting;
    await _lines.serial(() async {
      await _step(stopVoice);
      await _step(_chime.stop);
      await _step(_keepAlive.stop);
      _lines.forgetDuck();
      final s = _session;
      if (s != null) {
        await _step(() => s.configure(_config(duck: false)));
        await _step(
          () => s.setActive(
            false,
            avAudioSessionSetActiveOptions:
                AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation,
          ),
        );
      }
    });
  }

  @override
  Future<void> speak(List<String> assets) async {
    final request = ++_speechRequest;
    final generation = _sessionGeneration;
    await _beginning;
    if (!_current(generation) ||
        request != _speechRequest ||
        _session == null) {
      return;
    }
    await _lines.speak(assets);
  }

  @override
  Future<void> stopSpeech() {
    ++_speechRequest;
    return _lines.stopSpeech();
  }

  @override
  bool get isIOS => _onIOS;

  @override
  Future<void> configureSession({required bool duck}) async {
    await _session?.configure(_config(duck: duck));
  }

  @override
  Future<void> setSessionActive(bool active) async {
    if (active && (!_began || _disposed)) return;
    await _session?.setActive(
      active,
      avAudioSessionSetActiveOptions: active
          ? null
          : AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation,
    );
  }

  @override
  Future<void> keepAlivePause() => _keepAlive.pause();

  @override
  Future<void> keepAliveResume() async {
    if (_began && !_disposed && !_keepAliveSuppressed && !_keepAliveExpired) {
      unawaited(_keepAlive.play().catchError((Object _) {}));
    }
  }

  @override
  Future<void> setVoiceVolume(double v) => _voice.setVolume(v);

  @override
  Future<void> loadVoice(List<String> assets) async {
    // Complete the previous playback's stream/pause cleanup before a new
    // load can reuse this player, including an intentional count takeover.
    ++_playGeneration;
    if (_voice.playing) await _voice.pause();
    await _voicePlayback;
    final watch = Stopwatch()..start();
    await _voice.setAudioSources([
      for (final a in assets) AudioSource.asset(a),
    ]);
    // Device evidence for the background-playback check (logcat tag
    // "flutter"): a slow prepare is what delays and used to drop lines.
    if (watch.elapsedMilliseconds > slowLoadMs) {
      debugPrint(
        'UgkTrainerVoice slow load ${watch.elapsedMilliseconds} ms: '
        '${assets.map((a) => a.split('/').last).join('+')}',
      );
    }
  }

  /// Prepares slower than this are logged.
  static const slowLoadMs = 250;

  @override
  Future<void> playVoiceToEnd() {
    final generation = ++_playGeneration;
    return _voicePlayback = _waitForVoiceEnd(generation);
  }

  Future<void> _waitForVoiceEnd(int generation) async {
    final done = Completer<void>();
    var started = false;
    final sub = _voice.playerStateStream.listen((state) {
      if (state.playing) started = true;
      if (!done.isCompleted &&
          (state.processingState == ProcessingState.completed ||
              (started && !state.playing) ||
              (started && state.processingState == ProcessingState.idle))) {
        done.complete();
      }
    });
    unawaited(
      _voice.play().catchError((Object _) {
        if (!done.isCompleted) done.complete();
      }),
    );
    try {
      await done.future.timeout(const Duration(seconds: 30), onTimeout: () {});
    } finally {
      await sub.cancel();
      // Only the line that still owns the player may pause it. A stale
      // completion must never silence the count that just replaced it.
      if (generation == _playGeneration && _voice.playing) {
        await _step(_voice.pause);
      }
    }
  }

  @override
  Future<void> stopVoice() async {
    ++_playGeneration;
    await _voice.stop();
    await _voicePlayback;
  }

  static bool _audible(AudioPlayer p) =>
      p.playing &&
      (p.processingState == ProcessingState.ready ||
          p.processingState == ProcessingState.buffering ||
          p.processingState == ProcessingState.loading);

  @override
  bool get voiceAudible => _audible(_voice);

  @override
  bool get chimeAudible => _audible(_chime);

  @override
  Future<void> chime(String asset) async {
    final generation = _sessionGeneration;
    try {
      await _beginning;
      if (!_current(generation)) return;
      await _chime.setVolume(_volume * .9);
      if (!_current(generation)) return;
      await _chime.setAsset(asset);
      if (!_current(generation)) return;
      await _chime.play();
    } on Object {
      /* ignore */
    }
  }

  @override
  set volume(double v) {
    _volume = v.clamp(0, 1);
    _lines.volume = _volume;
  }

  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    _disposed = true;
    return _disposal = _dispose();
  }

  Future<void> _dispose() async {
    await end();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    await _events.close();
    await _voice.dispose();
    await _chime.dispose();
    await _keepAlive.dispose();
  }
}
