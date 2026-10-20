// Ported from SmartFit@e8981ee lib/core/platform/screen_awake.dart (same as
// HipLab@99fcc83 lib/core/platform/screen_awake.dart). Unchanged.
import 'dart:async';

import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps the screen on while a timed session is open, so auto-lock never
/// sends the app to the background mid-session. A manual lock is covered by
/// [TrainingHold] on Android and the silent audio loop on iOS.
///
/// Reference-counted so nested sessions don't release each other's hold.
/// Platform errors are swallowed (tests, unsupported platforms).
class ScreenAwake {
  ScreenAwake._();

  static int _holds = 0;

  static void acquire() {
    if (_holds++ == 0) _set(true);
  }

  static void release() {
    if (_holds == 0) return;
    if (--_holds == 0) _set(false);
  }

  static void _set(bool on) {
    try {
      unawaited(WakelockPlus.toggle(enable: on).catchError((Object _) {}));
    } catch (_) {
      // Plugin missing (tests / web stub): nothing to keep awake.
    }
  }
}
