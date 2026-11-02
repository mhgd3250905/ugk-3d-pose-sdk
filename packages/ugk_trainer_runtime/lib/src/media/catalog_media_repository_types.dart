// Extracted from SmartFit 52d30ae; shared catalogue cache behavior.
import 'dart:typed_data';

import 'package:ugk_coach/ugk_coach.dart' as coach;

enum CatalogMediaDownloadPhase {
  idle,
  queued,
  checking,
  downloading,
  verifying,
  ready,
  failed,
}

class CatalogMediaDownloadState {
  const CatalogMediaDownloadState({
    required this.phase,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.error,
  });

  final CatalogMediaDownloadPhase phase;
  final int receivedBytes;
  final int totalBytes;
  final Object? error;
  int get bytes => receivedBytes;
  int get total => totalBytes;
  double? get progress =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : null;
}

/// Receives the original path and expected SHA. Videos never use this loader.
typedef CatalogBundledFileLoader =
    Future<Uint8List?> Function(coach.PoseHubPackFile file);

/// Messages deliberately contain no request URI, redirect signature or headers.
class CatalogMediaException implements Exception {
  const CatalogMediaException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

/// Optional settings capability for the App's shared published-video budget.
/// Images, partial downloads, unknown files and playing videos are preserved.
abstract interface class CatalogVideoCache {
  /// Shared published-video budget, including preserved unknown legacy SHA
  /// objects conservatively. Image paths and unfinished downloads are excluded.
  Future<int> videoCacheBytes();
  Future<void> clearVideoCache();
}

const catalogVideoCacheLimitBytes = 300000000;

/// Trusted legacy descriptor. The old SDK stores this video at version/SHA.
class CatalogLegacyVideoFile {
  const CatalogLegacyVideoFile({
    required this.version,
    required this.bytes,
    required this.sha256,
  });

  final String version;
  final int bytes;
  final String sha256;
}

/// Playback retention and cache-only access for catalogue media consumers.
abstract interface class CatalogVideoCacheAccess {
  /// Validates a published video and records its use, without downloading.
  Future<Uri?> cachedVideo(String actionId);

  /// Protects a video before asynchronous preparation/playback begins. Release
  /// after the decoder is disposed; repeated release calls have no effect.
  void Function() retainVideo(String actionId);
}

/// Internal platform boundary, so the public service also compiles for Web.
abstract interface class CatalogMediaFileStore {
  Uri get mediaBaseUri;
  Future<Uri?> cached(coach.PoseHubPackFile file);
  Future<Uri?> reusable(coach.PoseHubPackFile file);
  void Function() retainVideo(coach.PoseHubPackFile file);
  Future<Uri> bundled(
    coach.PoseHubPackFile file,
    Uint8List bytes,
    void Function(int) onProgress,
    void Function() onVerifying,
  );
  Future<Uri> download(
    coach.PoseHubPackFile file,
    Uri url,
    void Function(int) onProgress,
    void Function() onVerifying,
  );
  Future<Uri> materialize(coach.PoseHubPackFile file, Uri source);
  void cancelVideoDownloads();
  Future<int> videoCacheBytes();
  Future<void> clearVideoCache();
  void dispose();
}
