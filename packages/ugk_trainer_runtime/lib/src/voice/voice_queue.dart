// Ported from HipLab@99fcc83 lib/hip/voice/voice_queue.dart (10-19 Android
// voice fix: tailGrace, cancelAll always stops the output). Changes: the
// clip library is a [VoiceSource]; [VoiceSettings.language] is a plain
// voice-language code chosen by the app (HipLab: 跟随 App / 中文 / English).
// Pure Dart.
import 'voice_cue.dart';
import 'voice_source.dart';

/// Where sound goes. The app uses the just_audio implementation; tests use
/// a recording fake.
abstract class VoiceOutput {
  /// Session started: configure ducking / background audio.
  Future<void> begin();

  /// Session over: release audio focus, stop keep-alive.
  Future<void> end();

  /// Play these voice clip assets back to back, replacing whatever plays.
  Future<void> speak(List<String> assets);

  /// Cut the current line.
  Future<void> stopSpeech();

  Future<void> chime(String asset);

  set volume(double v);
}

/// What the OS did to the app's audio mid-session.
enum AudioInterruption {
  /// A phone/FaceTime call, Siri, an alarm or another app took the audio
  /// session: the session should pause (a follow-along can't continue
  /// while the user is on the phone).
  began,

  /// The interruption is over and the audio session is active again.
  /// The session stays paused until the user taps 继续.
  ended,

  /// Headphones / Bluetooth audio went away ("becoming noisy"): pause so
  /// the coach doesn't suddenly talk out of the speaker.
  unplugged,
}

/// Optional extra of a [VoiceOutput]: OS audio interruptions and a way to
/// take the audio session back when the user resumes.
abstract class InterruptibleVoiceOutput {
  Stream<AudioInterruption> get interruptions;

  /// Re-activate the audio session (and the iOS background keep-alive)
  /// after a pause; safe to call when nothing was interrupted.
  Future<void> reactivate();
}

/// Optional extra of a [VoiceOutput]: tells when a line has really started.
///
/// [VoiceOutput.speak] only submits a line; the output may still play an
/// earlier line first, load the clips, or drop the line when [VoiceOutput.
/// stopSpeech] comes before it got its turn. An output that can tell
/// implements this, and [VoiceQueue.onStarted] is driven by it alone.
abstract class StartReportingVoiceOutput {
  /// Same as [VoiceOutput.speak], and calls [onStarted] once, at the moment
  /// the platform player is told to play this line (its turn came, its
  /// clips loaded, nothing stopped it). A line that is dropped, stopped,
  /// skipped as stale or fails to load before that never calls it.
  Future<void> speakReportingStart(
    List<String> assets,
    void Function() onStarted,
  );
}

/// Silent output (voice and chimes off, or widget tests).
class MutedVoiceOutput implements VoiceOutput {
  const MutedVoiceOutput();
  @override
  Future<void> begin() async {}
  @override
  Future<void> end() async {}
  @override
  Future<void> speak(List<String> assets) async {}
  @override
  Future<void> stopSpeech() async {}
  @override
  Future<void> chime(String asset) async {}
  @override
  set volume(double v) {}
}

class VoiceSettings {
  const VoiceSettings({
    this.voice = true,
    this.chimes = true,
    this.language = 'zh',
    this.volume = 1.0,
  });
  final bool voice;
  final bool chimes;

  /// Voice-language code of the clips (`zh`, `en`…). A language the
  /// source has no voice for plays chimes only.
  final String language;
  final double volume;

  VoiceSettings copyWith({
    bool? voice,
    bool? chimes,
    String? language,
    double? volume,
  }) => VoiceSettings(
    voice: voice ?? this.voice,
    chimes: chimes ?? this.chimes,
    language: language ?? this.language,
    volume: volume ?? this.volume,
  );

  Map<String, Object?> toJson() => {
    'voice': voice,
    'chimes': chimes,
    'language': language,
    'volume': volume,
  };

  factory VoiceSettings.fromJson(Map<String, dynamic> j) => VoiceSettings(
    voice: j['voice'] != false,
    chimes: j['chimes'] != false,
    language: j['language'] as String? ?? 'zh',
    volume: ((j['volume'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0),
  );
}

/// One line that actually started (for tests and the demo export).
class SpokenLine {
  SpokenLine(this.start, this.clips, this.priority, this.length);
  final double start;
  final List<String> clips;
  final CuePriority priority;
  final double length;
  double? cutAt;
  double get end => cutAt ?? start + length;
  @override
  String toString() =>
      '${start.toStringAsFixed(2)}–${end.toStringAsFixed(2)} ${clips.join('+')}'
      '${cutAt != null ? ' (cut)' : ''}';
}

class _Pending {
  _Pending(this.cue, this.deadline, this.source);
  final VoiceCue cue;
  final double deadline;

  /// The cue as submitted, before clips the source lacks were trimmed.
  final VoiceCue source;
}

/// Puts cues on the air one at a time (#13): never two voices at once, a
/// count is never cut and cuts anything but another count (unless that line
/// is within [tailGrace] of its end – then the count follows it), lower
/// lines wait briefly and are dropped when their moment has passed. Chimes are layered
/// on their own channel and never wait.
///
/// Times are seconds on any monotonic clock the caller uses consistently
/// (the player passes active session time; the assessment wall time).
class VoiceQueue {
  VoiceQueue({
    required this.output,
    required this.lib,
    required this.settings,
    this.onStarted,
  });

  final VoiceOutput output;
  final VoiceSource lib;
  VoiceSettings settings;
  final List<SpokenLine> log = [];
  final List<(double, String)> chimeLog = [];
  SpokenLine? _current;
  final List<_Pending> _pending = [];

  /// Called with a submitted cue (as passed to [submit]) when [output]
  /// confirms its speech really started (see [StartReportingVoiceOutput]).
  /// Submitting, queueing behind a tail or calling [VoiceOutput.speak] is
  /// not a start: a line still waiting in the output when [cancelAll] or a
  /// takeover stops it is never reported. An output that cannot confirm
  /// starts never reports anything, and chimes are never reported.
  void Function(VoiceCue cue)? onStarted;

  /// Bumped whenever the output is told to stop: a start confirmation that
  /// comes back for an older request is ignored.
  int _stopEpoch = 0;

  String get lang => settings.language;

  /// A line with at most this much left (seconds) is not cut by a line
  /// that takes over; the newcomer follows right after it (Android voice
  /// fix 2026-10-19: endings were chopped ~0.5 s before their end).
  static const tailGrace = 0.8;

  static double _wait(CuePriority p) => switch (p) {
    CuePriority.count => 0.25,
    CuePriority.call => 2.0,
    CuePriority.info => 4.0,
    CuePriority.coach => 1.5,
  };

  bool _busy(double now) => _current != null && now < _current!.end - .02;

  void submit(VoiceCue cue, double now) {
    if (settings.chimes) {
      for (final c in cue.chimes) {
        if (lib.has(c, lang: lang)) {
          chimeLog.add((now, c));
          output.chime(lib.asset(c, lang: lang));
        }
      }
    }
    if (!settings.voice) return;
    final clips = cue.voiceClips.where((c) => lib.has(c, lang: lang)).toList();
    if (clips.isEmpty) return;
    final trimmed = VoiceCue(cue.at, clips, cue.priority);
    if (!_busy(now)) {
      _start(trimmed, now, cue);
      return;
    }
    final cur = _current!;
    final takesOver =
        (trimmed.priority == CuePriority.count &&
            cur.priority != CuePriority.count) ||
        (trimmed.priority.index > cur.priority.index &&
            cur.priority.index <= CuePriority.info.index);
    if (takesOver) {
      // Only the last word or so is left: let it finish and start the new
      // line right behind it (the output plays lines in order) instead of
      // chopping the end off a sentence. Playback runs a little behind the
      // queue's clock, so "nearly done" here is still sounding on device.
      if (cur.end - now > tailGrace) {
        _cut(now);
        _start(trimmed, now, cue);
      } else {
        // The output plays the newcomer after the tail: predict it there,
        // so the air stays busy until it has really been said (PR #24
        // review F24-1).
        _start(trimmed, cur.end, cue);
      }
      return;
    }
    _pending.add(_Pending(trimmed, now + _wait(trimmed.priority), cue));
  }

  /// Call often (every timer tick): starts a waiting line when the air is free.
  void tick(double now) {
    _pending.removeWhere((p) => p.deadline < now);
    if (_pending.isEmpty || _busy(now)) return;
    _pending.sort(
      (a, b) => b.cue.priority.index.compareTo(a.cue.priority.index),
    );
    final next = _pending.removeAt(0);
    _start(next.cue, now, next.source);
  }

  void _start(VoiceCue cue, double now, VoiceCue source) {
    final line = SpokenLine(
      now,
      cue.clips,
      cue.priority,
      lib.total(cue.clips, lang: lang),
    );
    _current = line;
    log.add(line);
    final assets = [for (final c in cue.clips) lib.asset(c, lang: lang)];
    final out = output;
    final report = onStarted;
    if (report != null && out is StartReportingVoiceOutput) {
      final epoch = _stopEpoch;
      (out as StartReportingVoiceOutput).speakReportingStart(assets, () {
        if (epoch == _stopEpoch) report(source);
      });
    } else {
      output.speak(assets);
    }
  }

  void _cut(double now) {
    final cur = _current;
    if (cur != null && now < cur.end) cur.cutAt = now;
    _current = null;
    _stopEpoch++;
    output.stopSpeech();
  }

  /// Pause / pain / skip / stop / close: silence now and forget anything
  /// waiting.
  ///
  /// Always tells the output to stop, whatever this queue predicts: the
  /// output plays lines in order and runs behind this clock (a slow load, a
  /// tail let through by [tailGrace]), so a line the queue thinks is over can
  /// still be sounding and a count can still be waiting behind it. The
  /// output's stop drops every line asked for before it (PR #24 review
  /// F24-1). The tail grace applies to a normal takeover only, never here.
  void cancelAll(double now) {
    _pending.clear();
    for (final line in log.reversed) {
      if (line.end <= now) break;
      line.cutAt ??= now < line.start ? line.start : now;
    }
    _current = null;
    _stopEpoch++;
    output.stopSpeech();
  }
}
