// Ported from HipLab@99fcc83 lib/core/platform/training_service.dart
// (TrainingService / TrainingHold → TrainingKeepAlive / TrainingHold).
// Changes: the service is this package's Android plugin (android/,
// com.ugk.trainer.TrainingSessionService) on channel
// `ugk_trainer/training_session`; the notification texts come from the app
// ([TrainingNotice]); iOS / web do nothing (iOS keeps the clock alive with
// the silent audio loop of JustAudioVoiceOutput).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The ongoing notification shown while the Android service runs.
class TrainingNotice {
  const TrainingNotice({
    required this.channelName,
    required this.channelDescription,
    required this.title,
    required this.text,
    this.icon,
  });

  /// Android notification channel (Settings → Notifications).
  final String channelName;
  final String channelDescription;
  final String title;
  final String text;

  /// Small icon resource name (`mipmap/ic_launcher_monochrome`,
  /// `drawable/ic_stat_training`); null: the app icon.
  final String? icon;

  Map<String, Object> toArgs() => {
    'channelName': channelName,
    'channelDescription': channelDescription,
    'title': title,
    'text': text,
    'icon': ?icon,
  };
}

/// The channel to the Android training session foreground service
/// (android/…/TrainingSessionService.kt). Pages use it through
/// [TrainingHold].
///
/// Android voice fix (2026-10-19): with the app in the background the
/// process was an ordinary cached process – background CPU group, free to
/// suspend between voice lines, and on Android 15+ refused audio focus for
/// every line. The service (type `mediaPlayback`, partial wake lock, one
/// quiet notification) keeps the session clock and the voice on time. No
/// plugin dependency: a plain method channel to MainActivity.
///
/// PR #24 review (2026-10-19): every START / STOP carries the id of the
/// training session it belongs to. Only the newest session is current; a
/// STOP for an older one is not sent here and is ignored by the service, so
/// leaving a page and quickly opening the next never ends the new session's
/// keep-alive (F24-4).
///
/// Errors are swallowed: in tests, on iOS / web and when the system refuses
/// the start, the session simply runs as before.
class TrainingKeepAlive {
  TrainingKeepAlive._();

  static const channel = MethodChannel('ugk_trainer/training_session');

  /// Test hook: the platform this runs on.
  @visibleForTesting
  static bool Function() isAndroid = () =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static int _sequence = 0;
  static int? _current;

  /// The session the service should be running for, if any.
  @visibleForTesting
  static int? get currentSession => _current;

  static void _invoke(
    String method,
    Map<String, Object> args, {
    void Function(bool? ok)? then,
  }) {
    if (!isAndroid()) return;
    try {
      unawaited(
        channel
            .invokeMethod<bool>(method, args)
            .then((ok) => then?.call(ok), onError: (Object _) {}),
      );
    } catch (_) {
      // No engine / channel (unit tests): nothing to keep alive.
    }
  }
}

/// One training session's hold on the Android keep-alive (foreground
/// service + CPU wake lock): taken when the training starts, released when
/// it is over – finished on its own (also in the background), stopped for
/// pain, left, or the page disposed – whichever comes first (PR #24 review
/// F24-3). Releasing twice is harmless.
class TrainingHold {
  TrainingHold._(this.session, this.notice, this.mediaPlayback, this._duration);

  final int session;
  final TrainingNotice? notice;

  /// True only for a guided audio playback session. Self-checks keep the
  /// service hold without advertising a media playback session.
  final bool mediaPlayback;
  final Duration _duration;
  bool _paused = false;
  bool _released = false;
  Timer? _later;

  /// Margin on top of the planned length for the CPU wake-lock timeout, and
  /// its bounds. The lock is a safety net – the hold releases it as soon as
  /// the training is over – so it must never outlive a forgotten session by
  /// hours (before: 3 h from opening the page).
  static const margin = Duration(minutes: 15);
  static const minCap = Duration(minutes: 20);
  static const maxCap = Duration(hours: 2);

  static Duration capFor(Duration expected) {
    final cap = expected + margin;
    if (cap < minCap) return minCap;
    if (cap > maxCap) return maxCap;
    return cap;
  }

  /// Starts the keep-alive for a new session expected to last [expected].
  /// A previous session's hold stops counting (its release sends nothing).
  static TrainingHold begin(
    Duration expected, {
    TrainingNotice? notice,
    bool mediaPlayback = false,
  }) {
    final hold = TrainingHold._(
      ++TrainingKeepAlive._sequence,
      notice,
      mediaPlayback,
      expected,
    );
    TrainingKeepAlive._current = hold.session;
    hold._start(expected);
    return hold;
  }

  /// This hold still owns the keep-alive.
  bool get active => !_released && TrainingKeepAlive._current == session;

  void _start(Duration expected) {
    TrainingKeepAlive._invoke(
      'start',
      {
        'session': session,
        'maxMs': capFor(expected).inMilliseconds,
        'mediaPlayback': mediaPlayback,
        'paused': _paused,
        'durationMs': _duration.inMilliseconds,
        ...?notice?.toArgs(),
      },
      then: (ok) {
        // Refused (e.g. started from the background): nothing to stop.
        if (ok == false && TrainingKeepAlive._current == session) {
          TrainingKeepAlive._current = null;
        }
      },
    );
  }

  /// Re-arms the wake-lock timeout after a pause: [remaining] is what is
  /// left of the training.
  void renew(Duration remaining) {
    if (active) _start(remaining);
  }

  /// Reports the real player state; a paused training never claims to be
  /// playing. It does not start a new owner or extend the timeout.
  void setPlaybackState({required bool paused}) {
    if (!active || !mediaPlayback || _paused == paused) return;
    _paused = paused;
    TrainingKeepAlive._invoke('setPlaybackState', {
      'session': session,
      'paused': paused,
    });
  }

  /// Ends the hold. With [after], once that much time has passed – the
  /// closing line («训练完成») still plays with the screen locked; an
  /// immediate release (dispose) cuts the wait short.
  void release({Duration after = Duration.zero}) {
    if (_released) return;
    if (after > Duration.zero) {
      _later ??= Timer(after, release);
      return;
    }
    _released = true;
    _later?.cancel();
    _later = null;
    if (TrainingKeepAlive._current != session) return;
    TrainingKeepAlive._current = null;
    TrainingKeepAlive._invoke('stop', {'session': session});
  }
}
