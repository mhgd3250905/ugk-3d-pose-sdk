import 'dart:async';

import 'package:flutter/foundation.dart';

/// A short retained-paint window shared by this chat and its host route.
/// Each route hold is released independently; it never spans a workout.
class CoachChatTransitionActivity extends ChangeNotifier {
  var _holds = 0;
  Completer<void>? _idle;
  bool _disposed = false;
  bool get active => _holds != 0;

  VoidCallback hold() {
    if (_disposed) return () {};
    var released = false;
    if (_holds++ == 0) {
      _idle = Completer<void>();
      notifyListeners();
    }
    return () {
      if (released || _disposed) return;
      released = true;
      if (--_holds == 0) {
        final idle = _idle;
        _idle = null;
        notifyListeners();
        idle?.complete();
      }
    };
  }

  Future<void> waitUntilIdle() async {
    while (active) {
      await _idle!.future;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _holds = 0;
    _idle?.complete();
    _idle = null;
    super.dispose();
  }
}
