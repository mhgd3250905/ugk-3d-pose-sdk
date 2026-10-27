// Ported from HipLab@99fcc83 lib/hip/voice/voice_line_controller.dart
// (10-19 Android voice fix + PR #24 review). Changes: [speak] can report
// when the line really starts, and can take the time the line was asked for
// upstream (ugk_trainer PR #7).
import 'dart:async';

import 'package:clock/clock.dart';

/// What [VoiceLineController] needs from the platform: the voice player,
/// the chime player's state, and the audio session. The app implements it
/// with just_audio + audio_session (just_audio_output.dart); tests use a
/// fake that records what happened when.
abstract class VoicePlatform {
  /// iOS only lifts other apps' duck when the session deactivates.
  bool get isIOS;

  Future<void> configureSession({required bool duck});

  /// Deactivating also notifies other apps so their music comes back up.
  Future<void> setSessionActive(bool active);

  /// iOS keep-alive loop (silent clip): paused around a deactivation
  /// (deactivating with running I/O fails), resumed right after.
  Future<void> keepAlivePause();
  Future<void> keepAliveResume();

  Future<void> setVoiceVolume(double v);

  /// Load these clips (played back to back) without starting them.
  Future<void> loadVoice(List<String> assets);

  /// Start the loaded clips and complete when they have *finished* playing
  /// or were stopped – not when playback merely started.
  Future<void> playVoiceToEnd();

  Future<void> stopVoice();

  /// The voice / chime player is producing sound right now.
  bool get voiceAudible;
  bool get chimeAudible;
}

/// Owns the life of one spoken line (#13 voice audit, 2026-10-18).
///
/// The bug this replaces: `AudioPlayer.play()` completes *immediately* when
/// the player is already in the playing state – and just_audio stays
/// "playing" after a clip completes. So from the second line of a session
/// on, `speak()` thought the line was over as soon as it started, and
/// ~0.7 s later released the duck, which on iOS deactivates the audio
/// session – cutting the line that was still playing. That is the
/// "前面有声音、后面突然没了 / 长词只听到一两个字" from the iPhone test.
///
/// Rules here:
/// * a line is over when its clips have played to the end (or were cut);
/// * releasing the duck (and on iOS deactivating the session) happens only
///   [releaseDelay] after the last line ended, never while a voice or chime
///   is audible, and never when a newer line has been asked for since;
/// * all audio-session calls run one at a time, so a release that is in
///   progress can not interleave with the activation for the next line;
/// * a new line does not clip the tail of one still playing (the queue's
///   clock runs from when a line was asked for, playback starts a little
///   later) unless the queue cut it on purpose with [stopSpeech] – then it
///   waits up to [maxTailWait] for the real end.
/// * lines play in the order they were asked for (Android voice fix,
///   2026-10-19). Before, a line still waiting for the previous tail or
///   still loading was silently dropped as soon as the next one was asked
///   for – with a slow player (Android in the background) a whole 「3、2、1」
///   vanished, each number superseded by the next. Now only [stopSpeech] /
///   [abandon] drop lines; a backlog line is skipped only when it is more
///   than [staleAfter] late *and* a newer line is already waiting.
class VoiceLineController {
  VoiceLineController(
    this.p, {
    this.releaseDelay = const Duration(milliseconds: 700),
    this.maxTailWait = const Duration(milliseconds: 1200),
    this.staleAfter = const Duration(milliseconds: 3000),
    this.isActive = _always,
    this.onSkip,
  });

  /// Called with a backlog line that was skipped (logged by the app).
  final void Function(List<String> assets)? onSkip;

  final VoicePlatform p;
  final Duration releaseDelay;
  final Duration maxTailWait;

  /// A queued line this late is skipped if a newer line waits behind it.
  final Duration staleAfter;

  /// Last-resort bound on waiting for the line before.
  static const backlogLimit = Duration(seconds: 20);

  /// False after the session ended: a release then must not resume the
  /// keep-alive.
  final bool Function() isActive;
  static bool _always() => true;

  double volume = 1;

  /// Latest request: only the newest line may schedule the duck release.
  int _generation = 0;

  /// Bumped by [stopSpeech] / [abandon]: every line asked for before is
  /// dropped. A plain new line never bumps it.
  int _epoch = 0;
  double? _lastVolume;
  bool _ducking = false;
  bool _cut = false;
  Timer? _release;
  Future<void>? _line;
  Future<void> _ops = Future.value();

  bool get ducking => _ducking;

  bool _current(int gen) => gen == _generation && isActive();
  bool _alive(int epoch) => epoch == _epoch && isActive();

  /// Runs [op] after every audio-session operation queued before it.
  Future<void> serial(Future<void> Function() op) {
    final f = _ops.then((_) => op());
    _ops = f.then((_) {}, onError: (Object _) {});
    return f;
  }

  static Future<void> _step(Future<void> Function() call) async {
    try {
      await call();
    } on Object {
      /* best effort: one failing platform call must not skip the rest */
    }
  }

  /// Plays [assets] after every line asked for before. [onStarted] runs
  /// once, when the platform player is told to play this line: after the
  /// lines before it ended, after its clips loaded, and only if no
  /// [stopSpeech] / [abandon] dropped it and it was not skipped as stale.
  /// A line that never gets that far never calls it.
  ///
  /// [asked] is when the line was really asked for (default: now); an
  /// output that had to wait before calling this passes it, so the
  /// [staleAfter] backlog rule counts that wait too.
  Future<void> speak(
    List<String> assets, {
    void Function()? onStarted,
    DateTime? asked,
  }) {
    if (!isActive()) return Future<void>.value();
    _release?.cancel();
    final gen = ++_generation;
    final epoch = _epoch;
    final cut = _cut;
    _cut = false;
    final prev = _line;
    final line = _queued(
      gen,
      epoch,
      cut ? null : prev,
      asked ?? clock.now(),
      assets,
      onStarted,
    );
    _line = line;
    return line;
  }

  Future<void> _queued(
    int gen,
    int epoch,
    Future<void>? prev,
    DateTime asked,
    List<String> assets,
    void Function()? onStarted,
  ) async {
    if (prev != null) {
      // Wait for the line before (its load and its tail) instead of
      // clipping or dropping either. It always completes – played, stopped,
      // failed or dropped (playVoiceToEnd has its own timeout); the bound is
      // only a last resort against a hung platform call.
      await prev.timeout(backlogLimit, onTimeout: () {});
    }
    if (!_alive(epoch)) return;
    if (gen != _generation && clock.now().difference(asked) > staleAfter) {
      // Far behind and a newer line is waiting: skip the backlog.
      onSkip?.call(assets);
      return;
    }
    await _play(gen, epoch, assets, onStarted);
  }

  Future<void> _play(
    int gen,
    int epoch,
    List<String> assets,
    void Function()? onStarted,
  ) async {
    Future<void>? playback;
    try {
      // Serialize preparation as well as focus: an old delayed load must
      // finish before a newer request reuses the same player.
      await serial(() async {
        if (!_alive(epoch)) return;
        await _duck(true, current: () => _alive(epoch));
        if (!_alive(epoch)) return;
        // Capture the value once: the slider can move while the platform
        // call is in flight, and the cache must record what was really
        // applied, or the newer value is never sent (PR #24 review F24-2).
        final target = volume;
        if (_lastVolume != target) {
          await p.setVoiceVolume(target);
          _lastVolume = target;
        }
        if (!_alive(epoch)) return;
        await p.loadVoice(assets);
        if (!_alive(epoch)) return;
        // Do not hold the operation queue during playback: stopSpeech and
        // interruptions must be able to stop a line before it finishes.
        // Attach error handling immediately, before the serial callback
        // yields: an immediately failing player must not become unhandled.
        playback = _step(p.playVoiceToEnd);
        // The line really starts here, not when it was asked for.
        _report(onStarted);
      });
      await playback;
    } on Object {
      /* a missing clip must never stop the training */
    }
    if (!_current(gen)) return;
    _scheduleRelease(gen);
  }

  static void _report(void Function()? onStarted) {
    if (onStarted == null) return;
    try {
      onStarted();
    } on Object {
      /* a listener must never stop the line */
    }
  }

  void _scheduleRelease(int gen) {
    _release?.cancel();
    _release = Timer(releaseDelay, () {
      unawaited(
        serial(() async {
          if (!_current(gen)) return; // another line or session took over
          if (p.voiceAudible || p.chimeAudible) {
            _scheduleRelease(gen); // still sounding: try again later
            return;
          }
          await _duck(false, current: () => _current(gen));
        }),
      );
    });
  }

  /// The queue cut the line on purpose (a count or a call takes over).
  Future<void> stopSpeech() async {
    _cut = true;
    _epoch++;
    final gen = ++_generation;
    _release?.cancel();
    await serial(() => _step(p.stopVoice));
    if (_current(gen)) _scheduleRelease(gen);
  }

  /// Interruption / unplug / session end: forget the current line.
  void abandon() {
    _release?.cancel();
    _generation++;
    _epoch++;
    _cut = false;
    // A new session (or a re-activated one) sets the volume again.
    _lastVolume = null;
  }

  /// Mark the duck as gone without touching the session (an interruption
  /// already took it, or [end] reconfigures it).
  void forgetDuck() => _ducking = false;

  /// Used after unplugging: abandon invalidated the pending release timer,
  /// but the stopped session must still give other apps their volume back.
  Future<void> releaseDuck() => serial(() => _duck(false));

  Future<void> _duck(bool on, {bool Function()? current}) async {
    final valid = current ?? isActive;
    if (!valid() || on == _ducking) return;
    if (on) {
      // Adding duckOthers and (re-)activating lowers other apps' audio.
      await _step(() => p.configureSession(duck: true));
      if (!valid()) return;
      await _step(() => p.setSessionActive(true));
      // A cancelled configure has not acquired focus. Only remember a
      // duck after activation, so the next line still requests its focus.
      _ducking = true;
      return;
    }
    _ducking = false;
    await _step(() => p.configureSession(duck: false));
    if (p.isIOS) {
      // iOS only lifts the duck when the session deactivates: pause the
      // keep-alive, deactivate (notifying others), take it straight back.
      await _step(p.keepAlivePause);
      await _step(() => p.setSessionActive(false));
      if (valid()) {
        await _step(() => p.setSessionActive(true));
        await _step(p.keepAliveResume);
      }
    } else {
      await _step(() => p.setSessionActive(false));
    }
  }
}
