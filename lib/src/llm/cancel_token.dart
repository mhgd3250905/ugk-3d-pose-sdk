import 'dart:async';

/// 取消一次 ask：进行中的 HTTP 请求会被中止，结果为 cancelled，不回落、不重写。
class CancelToken {
  final _c = Completer<void>();
  String? _reason;

  bool get isCancelled => _c.isCompleted;
  String? get reason => _reason;

  /// 取消时完成的 Future，可直接作为 `http.AbortableRequest.abortTrigger`。
  Future<void> get whenCancelled => _c.future;

  void cancel([String reason = 'cancelled']) {
    if (_c.isCompleted) return;
    _reason = reason;
    _c.complete();
  }
}
