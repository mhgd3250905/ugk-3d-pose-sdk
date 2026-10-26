import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../ui/trainer_surface.dart';
import '../ui/trainer_theme.dart';

/// The host owns downloading, caching, byte/hash verification and persistence.
/// Cancelling the subscription asks the host to stop this consumer's work.
abstract interface class PoseHubMediaPreparer {
  Stream<PoseHubMediaPreparationEvent> prepareAction(PoseHubPackAction action);
}

@immutable
sealed class PoseHubMediaPreparationEvent {
  const PoseHubMediaPreparationEvent();
}

/// Any quantity may be unknown. Fractions must be finite and between 0 and 1;
/// byte counts must be nonnegative, with received <= total when total > 0.
final class PoseHubMediaProgress extends PoseHubMediaPreparationEvent {
  const PoseHubMediaProgress({
    this.fraction,
    this.receivedBytes,
    this.totalBytes,
  });
  final double? fraction;
  final int? receivedBytes;
  final int? totalBytes;

  double? get value =>
      fraction ??
      (totalBytes != null && totalBytes! > 0 && receivedBytes != null
          ? receivedBytes! / totalBytes!
          : null);
}

/// Emit only after the host has verified the final installed action files.
/// Install every original files.*.path beneath this base directory.
/// Native callers supply an absolute file directory URI. Web callers supply
/// an HTTP(S) directory on the page's own origin (or a relative directory).
/// Release/CDN download URLs are not prepared playback directories.
final class PoseHubMediaReady extends PoseHubMediaPreparationEvent {
  const PoseHubMediaReady({required this.mediaBaseUri});
  final Uri mediaBaseUri;
}

/// [reason] must be safe, user-facing copy, without credentials or raw errors.
final class PoseHubMediaFailed extends PoseHubMediaPreparationEvent {
  const PoseHubMediaFailed({required this.reason});
  final String reason;
}

enum PoseHubMediaPreparationStatus { idle, preparing, ready, failed }

@immutable
final class PoseHubMediaPreparationState {
  const PoseHubMediaPreparationState._({
    required this.status,
    this.progress,
    this.mediaBaseUri,
    this.failureReason,
  });
  final PoseHubMediaPreparationStatus status;
  final PoseHubMediaProgress? progress;
  final Uri? mediaBaseUri;
  final String? failureReason;
}

/// A cancellable preparation gate for SDK widgets or custom host presentation.
/// The first ready/failed/error/done outcome wins. Later events are ignored.
/// Stream errors are mapped to safe generic copy, never shown verbatim.
final class PoseHubMediaPreparationController extends ChangeNotifier {
  static const _failedMessage = '动作资源准备失败，请重试';
  static const _incompleteMessage = '动作资源准备未完成，请重试';
  var _state = const PoseHubMediaPreparationState._(
    status: PoseHubMediaPreparationStatus.idle,
  );
  StreamSubscription<PoseHubMediaPreparationEvent>? _subscription;
  Future<void> _cancellation = Future<void>.value();
  var _generation = 0;
  var _terminal = true;
  var _disposed = false;

  PoseHubMediaPreparationState get state => _state;

  /// Completes after all retired host subscriptions have stopped their work.
  Future<void> get cancellationComplete => _cancellation;

  void start(PoseHubMediaPreparer preparer, PoseHubPackAction action) {
    if (_disposed) return;
    final generation = ++_generation;
    _stopSubscription();
    // Host cancellation can synchronously replace, cancel or dispose this gate.
    if (!_ownsAttempt(generation)) return;
    _terminal = false;
    _publish(
      const PoseHubMediaPreparationState._(
        status: PoseHubMediaPreparationStatus.preparing,
      ),
    );
    if (!_current(generation)) return;
    try {
      final stream = preparer.prepareAction(action);
      if (!_current(generation)) return;
      final subscription = stream.listen(
        (event) => _accept(generation, event),
        onError: (Object _, StackTrace _) => _fail(generation, _failedMessage),
        onDone: () => _fail(generation, _incompleteMessage),
        cancelOnError: true,
      );
      if (_current(generation)) {
        _subscription = subscription;
      } else {
        _retireSubscription(subscription);
      }
    } catch (_) {
      _fail(generation, _failedMessage);
    }
  }

  bool _ownsAttempt(int generation) => !_disposed && generation == _generation;

  bool _current(int generation) => _ownsAttempt(generation) && !_terminal;

  void _accept(int generation, PoseHubMediaPreparationEvent event) {
    if (!_current(generation)) return;
    switch (event) {
      case PoseHubMediaProgress():
        final fraction = event.fraction;
        final received = event.receivedBytes;
        final total = event.totalBytes;
        if ((fraction != null &&
                (!fraction.isFinite || fraction < 0 || fraction > 1)) ||
            (received != null && received < 0) ||
            (total != null && total < 0) ||
            (received != null &&
                total != null &&
                total > 0 &&
                received > total)) {
          _fail(generation, _failedMessage);
          return;
        }
        _publish(
          PoseHubMediaPreparationState._(
            status: PoseHubMediaPreparationStatus.preparing,
            progress: event,
          ),
        );
      case PoseHubMediaReady():
        final baseUri = _readyDirectory(event.mediaBaseUri);
        if (baseUri == null) {
          _fail(generation, _failedMessage);
          return;
        }
        _finish(
          generation,
          PoseHubMediaPreparationState._(
            status: PoseHubMediaPreparationStatus.ready,
            mediaBaseUri: baseUri,
          ),
        );
      case PoseHubMediaFailed():
        _fail(
          generation,
          event.reason.trim().isEmpty ? _failedMessage : event.reason,
        );
    }
  }

  Uri? _readyDirectory(Uri supplied) {
    if (supplied.userInfo.isNotEmpty ||
        supplied.hasQuery ||
        supplied.hasFragment ||
        !supplied.path.endsWith('/') ||
        !supplied.toString().endsWith('/') ||
        supplied.path.contains('\\') ||
        supplied.pathSegments.any(
          (part) => part == '.' || part == '..' || part.contains('\\'),
        )) {
      return null;
    }
    if (!kIsWeb) {
      return supplied.scheme == 'file' &&
              supplied.isAbsolute &&
              supplied.host.isEmpty &&
              supplied.path.startsWith('/')
          ? supplied
          : null;
    }
    final resolved = Uri.base.resolveUri(supplied);
    return const ['http', 'https'].contains(resolved.scheme) &&
            resolved.origin == Uri.base.origin
        ? resolved
        : null;
  }

  void _fail(int generation, String reason) => _finish(
    generation,
    PoseHubMediaPreparationState._(
      status: PoseHubMediaPreparationStatus.failed,
      failureReason: reason,
    ),
  );

  void _finish(int generation, PoseHubMediaPreparationState state) {
    if (!_current(generation)) return;
    _terminal = true;
    _stopSubscription();
    if (!_ownsAttempt(generation)) return;
    _publish(state);
  }

  void _publish(PoseHubMediaPreparationState state) {
    _state = state;
    notifyListeners();
  }

  void cancel() {
    if (_disposed) return;
    final generation = ++_generation;
    _terminal = true;
    _stopSubscription();
    if (!_ownsAttempt(generation)) return;
    _publish(
      const PoseHubMediaPreparationState._(
        status: PoseHubMediaPreparationStatus.idle,
      ),
    );
  }

  void _stopSubscription() {
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) _retireSubscription(subscription);
  }

  void _retireSubscription(
    StreamSubscription<PoseHubMediaPreparationEvent> subscription,
  ) {
    _cancellation = Future.wait<void>([
      _cancellation,
      _cancelQuietly(subscription),
    ]).then((_) {});
  }

  static Future<void> _cancelQuietly(
    StreamSubscription<PoseHubMediaPreparationEvent> subscription,
  ) async {
    try {
      await subscription.cancel();
    } catch (_) {
      // The generation guard has already retired this consumer.
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    _terminal = true;
    _stopSubscription();
    super.dispose();
  }
}

/// Opaque, theme-driven presentation for the host-owned preparation gate.
class PoseHubMediaPreparationPanel extends StatelessWidget {
  const PoseHubMediaPreparationPanel({
    super.key,
    required this.state,
    required this.theme,
    this.onRetry,
    this.readyLabel = '动作资源已就绪',
  });
  final PoseHubMediaPreparationState state;
  final TrainerTheme theme;
  final VoidCallback? onRetry;
  final String readyLabel;

  @override
  Widget build(BuildContext context) {
    if (state.status == PoseHubMediaPreparationStatus.idle) {
      return const SizedBox.shrink();
    }
    final progress = state.progress;
    final value = progress?.value;
    return TrainerSurface(
      key: const ValueKey('posehub-media-preparation'),
      theme: theme,
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.status == PoseHubMediaPreparationStatus.preparing) ...[
            Text('正在准备动作资源', style: theme.callout),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              key: const ValueKey('posehub-media-preparation-progress'),
              value: value,
              color: theme.accent,
              backgroundColor: theme.surfaceHigh,
            ),
            const SizedBox(height: 6),
            if (value != null)
              Text('${(value * 100).round()}%', style: theme.label),
            if (progress?.receivedBytes case final received?)
              Text(
                progress?.totalBytes != null
                    ? '已准备 $received / ${progress!.totalBytes} 字节'
                    : '已准备 $received 字节',
                style: theme.label,
              ),
          ],
          if (state.status == PoseHubMediaPreparationStatus.failed) ...[
            Text(
              state.failureReason!,
              key: const ValueKey('posehub-media-preparation-reason'),
              style: theme.body.copyWith(color: theme.caution),
            ),
            TextButton(
              key: const ValueKey('posehub-media-preparation-retry'),
              onPressed: onRetry,
              style: TextButton.styleFrom(foregroundColor: theme.accentText),
              child: const Text('重试'),
            ),
          ],
          if (state.status == PoseHubMediaPreparationStatus.ready)
            Text(
              readyLabel,
              style: theme.label.copyWith(color: theme.accentText),
            ),
        ],
      ),
    );
  }
}
