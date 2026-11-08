import 'dart:convert';

/// Optional diagnostics for one deduplicated file request. Records never
/// contain request URLs, redirect locations or HTTP headers.
typedef CatalogMediaTimingCallback = void Function(CatalogMediaTiming timing);

/// A terminal file-task record for a host's existing runtime-log channel.
/// Missing stages mean that no such work was necessary (for example, a cache
/// hit has no network first byte). A SHA-shared content job can start before a
/// later file alias is enqueued. [baseIndex] is one-based.
class CatalogMediaTiming {
  const CatalogMediaTiming({
    required this.actionId,
    required this.kind,
    required this.bytes,
    required this.enqueuedAt,
    required this.completedAt,
    required this.result,
    required this.source,
    this.acquiredAt,
    this.requestStartedAt,
    this.firstByteAt,
    this.downloadCompletedAt,
    this.verifiedAt,
    this.baseIndex,
    this.retries = 0,
    this.code,
  });

  static const event = 'media.timing';
  final String actionId;
  final String kind;
  final int bytes;
  final DateTime enqueuedAt;
  final DateTime? acquiredAt;
  final DateTime? requestStartedAt;
  final DateTime? firstByteAt;
  final DateTime? downloadCompletedAt;
  final DateTime? verifiedAt;
  final DateTime completedAt;
  final int? baseIndex;
  final int retries;
  final String result;
  final String source;
  final String? code;

  int? _milliseconds(DateTime? from, DateTime? to) {
    if (from == null || to == null) return null;
    final milliseconds = to.difference(from).inMilliseconds;
    return milliseconds < 0 ? 0 : milliseconds;
  }

  Map<String, Object?> toFields() => {
    'actionId': actionId,
    'kind': kind,
    'bytes': bytes,
    'enqueuedAt': enqueuedAt.toUtc().toIso8601String(),
    'acquiredAt': acquiredAt?.toUtc().toIso8601String(),
    'requestStartedAt': requestStartedAt?.toUtc().toIso8601String(),
    'firstByteAt': firstByteAt?.toUtc().toIso8601String(),
    'downloadCompletedAt': downloadCompletedAt?.toUtc().toIso8601String(),
    'verifiedAt': verifiedAt?.toUtc().toIso8601String(),
    'completedAt': completedAt.toUtc().toIso8601String(),
    'queueMs': _milliseconds(enqueuedAt, acquiredAt),
    'ttfbMs': _milliseconds(requestStartedAt, firstByteAt),
    'downloadMs': _milliseconds(firstByteAt, downloadCompletedAt),
    'verifyMs': _milliseconds(downloadCompletedAt, verifiedAt),
    'elapsedMs': _milliseconds(enqueuedAt, completedAt),
    'baseIndex': baseIndex,
    'retries': retries,
    'result': result,
    'source': source,
    'code': code,
  };

  String toLogLine() => '$event ${jsonEncode(toFields())}';
}
