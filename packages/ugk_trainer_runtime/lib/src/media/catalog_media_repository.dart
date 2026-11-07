// Extracted from SmartFit 52d30ae; shared catalogue cache behavior.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;

import '../pose_hub/pose_hub_catalog_channel.dart';
import 'catalog_legacy_video_catalog.dart';
import 'catalog_media_repository_stub.dart'
    if (dart.library.io) 'catalog_media_repository_io.dart'
    as platform;
import 'catalog_media_repository_types.dart';
import 'catalog_media_timing.dart';

export 'catalog_media_repository_types.dart'
    show
        CatalogBundledFileLoader,
        CatalogLegacyVideoFile,
        CatalogMediaDownloadPhase,
        CatalogMediaDownloadState,
        CatalogMediaException,
        CatalogVideoCache,
        CatalogVideoCacheAccess,
        catalogVideoCacheLimitBytes;
export 'catalog_media_timing.dart';

abstract interface class CatalogMediaRepository
    implements CatalogVideoCache, CatalogVideoCacheAccess {
  /// Shares SmartFit's published-video LRU and playing-video retention.
  /// [maxVideoCacheBytes] may reduce the existing 300 MB ceiling.
  /// Legacy video ownership is read only when its metadata is supplied.
  static Future<CatalogMediaRepository> create({
    required coach.PoseHubAppTestCatalog catalog,
    required String catalogRevision,
    required List<Uri> mediaBaseUrls,

    /// Null uses the catalogue's own pack (the legacy fallback when it has none).
    String? packVersion,
    String? rootDirectory,
    CatalogBundledFileLoader? bundledFileLoader,

    /// Optional sanitized terminal records for the host's runtime-log sink.
    CatalogMediaTimingCallback? onTiming,
    int maxVideoCacheBytes = catalogVideoCacheLimitBytes,
    String? legacyCacheDirectory,
    List<CatalogLegacyVideoFile> legacyVideos = const [],
    String? legacyManifestAsset,
    AssetBundle? legacyBundle,
  }) => _create(
    catalog: catalog,
    catalogRevision: catalogRevision,
    mediaBaseUrls: mediaBaseUrls,
    packVersion: packVersion,
    rootDirectory: rootDirectory,
    bundledFileLoader: bundledFileLoader,
    onTiming: onTiming,
    maxVideoCacheBytes: maxVideoCacheBytes,
    legacyCacheDirectory: legacyCacheDirectory,
    legacyVideos: legacyVideos,
    legacyManifestAsset: legacyManifestAsset,
    legacyBundle: legacyBundle,
  );

  @visibleForTesting
  static Future<CatalogMediaRepository> forTesting({
    required coach.PoseHubAppTestCatalog catalog,
    required String catalogRevision,
    required List<Uri> mediaBaseUrls,

    /// Null uses the catalogue's own pack (the legacy fallback when it has none).
    String? packVersion,
    required String rootDirectory,
    CatalogBundledFileLoader? bundledFileLoader,
    CatalogMediaTimingCallback? onTiming,
    bool allowInsecureLocalhost = false,
    Duration timeout = const Duration(seconds: 15),
    Duration progressInterval = const Duration(milliseconds: 100),
    int maxConcurrent = 2,
    int maxRedirects = 5,
    int maxVideoCacheBytes = catalogVideoCacheLimitBytes,
    // Explicit AppCache parent for fixtures; no device directories are queried.
    String? legacyCacheDirectory,
    List<CatalogLegacyVideoFile> legacyVideos = const [],
    String? legacyManifestAsset,
    AssetBundle? legacyBundle,
  }) => _create(
    catalog: catalog,
    catalogRevision: catalogRevision,
    mediaBaseUrls: mediaBaseUrls,
    packVersion: packVersion,
    rootDirectory: rootDirectory,
    bundledFileLoader: bundledFileLoader,
    onTiming: onTiming,
    allowInsecureLocalhost: allowInsecureLocalhost,
    timeout: timeout,
    progressInterval: progressInterval,
    maxConcurrent: maxConcurrent,
    maxRedirects: maxRedirects,
    maxVideoCacheBytes: maxVideoCacheBytes,
    legacyCacheDirectory: legacyCacheDirectory,
    legacyVideos: legacyVideos,
    legacyManifestAsset: legacyManifestAsset,
    legacyBundle: legacyBundle,
  );

  coach.PoseHubAppTestCatalog get catalog;

  /// Created immediately; it does not promise that all catalogue files exist.
  Uri get mediaBaseUri;
  Future<Uri> ensureFile(coach.PoseHubPackFile file);
  Future<Uri> ensureAction(String actionId);
  ValueListenable<CatalogMediaDownloadState> watchFile(
    coach.PoseHubPackFile file,
  );
  ValueListenable<CatalogMediaDownloadState> watchAction(String actionId);
  void dispose();
}

enum CatalogMediaPriority { current, prefetch }

/// Optional scheduling capability. Existing host repository implementations
/// continue to work through [CatalogMediaPriorityAccess].
abstract interface class CatalogMediaPriorityRepository {
  Future<Uri> ensureFileWithPriority(
    coach.PoseHubPackFile file, {
    required CatalogMediaPriority priority,
  });
}

extension CatalogMediaPriorityAccess on CatalogMediaRepository {
  Future<Uri> ensureFileWithPriority(
    coach.PoseHubPackFile file, {
    CatalogMediaPriority priority = CatalogMediaPriority.current,
  }) {
    final repository = this;
    if (repository is CatalogMediaPriorityRepository) {
      final prioritized = repository as CatalogMediaPriorityRepository;
      return prioritized.ensureFileWithPriority(file, priority: priority);
    }
    return ensureFile(file);
  }
}

Future<CatalogMediaRepository> _create({
  required coach.PoseHubAppTestCatalog catalog,
  required String catalogRevision,
  required List<Uri> mediaBaseUrls,
  required String? packVersion,
  String? rootDirectory,
  CatalogBundledFileLoader? bundledFileLoader,
  CatalogMediaTimingCallback? onTiming,
  bool allowInsecureLocalhost = false,
  Duration timeout = const Duration(seconds: 15),
  Duration progressInterval = const Duration(milliseconds: 100),
  int maxConcurrent = 2,
  int maxRedirects = 5,
  int maxVideoCacheBytes = catalogVideoCacheLimitBytes,
  String? legacyCacheDirectory,
  List<CatalogLegacyVideoFile> legacyVideos = const [],
  String? legacyManifestAsset,
  AssetBundle? legacyBundle,
}) async {
  final String resolvedPack;
  try {
    resolvedPack = packVersion ?? poseHubPackVersionOf(catalog);
  } on FormatException {
    throw const FormatException('Invalid media repository configuration.');
  }
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(catalogRevision) ||
      !RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(resolvedPack) ||
      resolvedPack.length > 64 ||
      timeout <= Duration.zero ||
      progressInterval < Duration.zero ||
      maxConcurrent < 1 ||
      maxConcurrent > 3 ||
      maxVideoCacheBytes < 1 ||
      maxVideoCacheBytes > catalogVideoCacheLimitBytes ||
      maxRedirects < 0 ||
      maxRedirects > 8) {
    throw const FormatException('Invalid media repository configuration.');
  }
  final files = {
    for (final action in catalog.allActions)
      for (final file in action.files.values) file.path: file,
  };
  final bases = List<Uri>.unmodifiable(mediaBaseUrls);
  final store = await platform.createCatalogMediaStore(
    revision: catalogRevision,
    packVersion: resolvedPack,
    rootDirectory: rootDirectory,
    files: files.values.toList(),
    videos: {
      for (final action in catalog.allActions) action.video.path: action.video,
    }.values.toList(),
    mediaBaseUrls: bases,
    allowInsecureLocalhost: allowInsecureLocalhost,
    timeout: timeout,
    maxRedirects: maxRedirects,
    maxVideoCacheBytes: maxVideoCacheBytes,
    legacyCacheDirectory: legacyCacheDirectory,
    legacyVideos: [
      ...legacyVideos,
      if (legacyManifestAsset != null)
        ...await loadCatalogLegacyVideoCatalog(
          manifestAsset: legacyManifestAsset,
          bundle: legacyBundle,
        ),
    ],
  );
  return _Repository(
    catalog,
    files,
    store,
    bases,
    bundledFileLoader,
    timeout,
    progressInterval,
    maxConcurrent,
    onTiming,
  );
}

class _Repository
    implements CatalogMediaRepository, CatalogMediaPriorityRepository {
  _Repository(
    this.catalog,
    this.files,
    this.store,
    this.bases,
    this.loadBundle,
    this.timeout,
    this.progressInterval,
    this.maxConcurrent,
    this.onTiming,
  ) {
    for (final action in catalog.allActions) {
      for (final role in action.files.entries) {
        final file = role.value;
        (_actionsForFile[file.path] ??= {}).add(action.id);
        (_filesForHash[file.sha256] ??= []).add(file);
        if (role.key != 'video') _images.add(file.path);
        if (role.key == 'video') _videos.add(file.path);
      }
    }
  }

  @override
  final coach.PoseHubAppTestCatalog catalog;
  final Map<String, coach.PoseHubPackFile> files;
  final CatalogMediaFileStore store;
  final List<Uri> bases;
  final CatalogBundledFileLoader? loadBundle;
  final Duration timeout, progressInterval;
  final int maxConcurrent;
  final CatalogMediaTimingCallback? onTiming;
  final _fileJobs = <String, Future<Uri>>{};
  final _contentJobs = <String, Future<Uri>>{};
  final _contentTimings = <String, _ContentTiming>{};
  final _actionJobs = <String, Future<Uri>>{};
  final _afterClearFiles = <String, Future<Uri>>{};
  final _afterClearPriorities = <String, CatalogMediaPriority>{};
  final _afterClearActions = <String, Future<Uri>>{};
  final _fileStates = <String, ValueNotifier<CatalogMediaDownloadState>>{};
  final _actionStates = <String, ValueNotifier<CatalogMediaDownloadState>>{};
  final _actionsForFile = <String, Set<String>>{};
  final _filesForHash = <String, List<coach.PoseHubPackFile>>{};
  final _images = <String>{};
  final _videos = <String>{};
  final _lastProgress = <String, DateTime>{};
  final _queue = <({Completer<void> ready, int? generation, String sha256})>[];
  final _priorities = <String, CatalogMediaPriority>{};
  int _active = 0;
  int _generation = 0;
  Future<void>? _clearing;
  bool _disposed = false;

  @override
  Uri get mediaBaseUri => store.mediaBaseUri;

  void _check([int? generation]) {
    if (_disposed) {
      throw const CatalogMediaException(
        'disposed',
        'Media preparation stopped.',
      );
    }
    if (generation != null && generation != _generation) {
      throw const CatalogMediaException(
        'cache_cleared',
        'Video preparation stopped while its cache was cleared.',
      );
    }
  }

  coach.PoseHubPackFile _known(coach.PoseHubPackFile file) {
    _check();
    final known = files[file.path];
    if (known == null ||
        known.bytes != file.bytes ||
        known.sha256 != file.sha256) {
      throw const FormatException('File does not match the selected catalog.');
    }
    return known;
  }

  coach.PoseHubPackAction _action(String id) {
    _check();
    final action = catalog.tryGet(id);
    if (action == null) throw ArgumentError('Unknown catalogue action.');
    return action;
  }

  @override
  ValueListenable<CatalogMediaDownloadState> watchFile(
    coach.PoseHubPackFile file,
  ) {
    file = _known(file);
    return _fileStates.putIfAbsent(
      file.path,
      () => ValueNotifier(
        CatalogMediaDownloadState(
          phase: CatalogMediaDownloadPhase.idle,
          totalBytes: file.bytes,
        ),
      ),
    );
  }

  @override
  ValueListenable<CatalogMediaDownloadState> watchAction(String actionId) {
    final action = _action(actionId);
    return _actionStates.putIfAbsent(
      actionId,
      () => ValueNotifier(_aggregate(action)),
    );
  }

  CatalogMediaDownloadState _aggregate(coach.PoseHubPackAction action) {
    final states = [
      for (final file in action.files.values)
        _fileStates[file.path]?.value ??
            CatalogMediaDownloadState(
              phase: CatalogMediaDownloadPhase.idle,
              totalBytes: file.bytes,
            ),
    ];
    final failed = states.where(
      (s) => s.phase == CatalogMediaDownloadPhase.failed,
    );
    var phase = CatalogMediaDownloadPhase.idle;
    if (failed.isNotEmpty) {
      phase = CatalogMediaDownloadPhase.failed;
    } else if (states.every(
      (s) => s.phase == CatalogMediaDownloadPhase.ready,
    )) {
      phase = CatalogMediaDownloadPhase.ready;
    } else {
      for (final candidate in const [
        CatalogMediaDownloadPhase.downloading,
        CatalogMediaDownloadPhase.verifying,
        CatalogMediaDownloadPhase.checking,
        CatalogMediaDownloadPhase.queued,
      ]) {
        if (states.any((s) => s.phase == candidate)) {
          phase = candidate;
          break;
        }
      }
    }
    return CatalogMediaDownloadState(
      phase: phase,
      receivedBytes: states.fold(0, (n, s) => n + s.receivedBytes),
      totalBytes: states.fold(0, (n, s) => n + s.totalBytes),
      error: failed.isEmpty ? null : failed.first.error,
    );
  }

  void _set(
    coach.PoseHubPackFile file,
    CatalogMediaDownloadPhase phase, {
    int received = 0,
    Object? error,
  }) {
    if (_disposed) return;
    final notifier =
        watchFile(file) as ValueNotifier<CatalogMediaDownloadState>;
    final now = DateTime.now();
    if (phase == CatalogMediaDownloadPhase.downloading &&
        notifier.value.phase == phase &&
        received >= notifier.value.receivedBytes &&
        received < file.bytes) {
      final previous = _lastProgress[file.path];
      if (previous != null && now.difference(previous) < progressInterval) {
        return;
      }
    }
    _lastProgress[file.path] = now;
    notifier.value = CatalogMediaDownloadState(
      phase: phase,
      receivedBytes: received.clamp(0, file.bytes),
      totalBytes: file.bytes,
      error: error,
    );
    for (final id in _actionsForFile[file.path] ?? const <String>{}) {
      _actionStates[id]?.value = _aggregate(catalog.tryGet(id)!);
    }
  }

  void _contentState(
    coach.PoseHubPackFile file,
    CatalogMediaDownloadPhase phase, {
    int received = 0,
  }) {
    for (final alias in _filesForHash[file.sha256]!) {
      if (_fileJobs.containsKey(alias.path)) {
        _set(alias, phase, received: received);
      }
    }
  }

  @override
  Future<Uri> ensureFile(coach.PoseHubPackFile file) =>
      ensureFileWithPriority(file, priority: CatalogMediaPriority.current);

  @override
  Future<Uri> ensureFileWithPriority(
    coach.PoseHubPackFile file, {
    required CatalogMediaPriority priority,
  }) {
    try {
      file = _known(file);
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    if (_clearing case final barrier?) {
      if (!_afterClearPriorities.containsKey(file.path) ||
          priority == CatalogMediaPriority.current) {
        _afterClearPriorities[file.path] = priority;
      }
      return _afterClear(
        _afterClearFiles,
        file.path,
        barrier,
        () => ensureFileWithPriority(
          file,
          priority: _afterClearPriorities.remove(file.path) ?? priority,
        ),
      );
    }
    _prioritize(file, priority);
    if (_fileJobs[file.path] case final job?) return job;
    final generation = _images.contains(file.path) ? null : _generation;
    final timing = onTiming == null
        ? null
        : _FileTiming(
            actionId: _actionsForFile[file.path]!.first,
            kind: _kindOf(file),
            bytes: file.bytes,
          );
    final job = Future<Uri>.microtask(
      () => _ensureFile(file, generation, timing),
    );
    _fileJobs[file.path] = job;
    job.then<void>(
      (_) {
        _fileJobs.remove(file.path);
        _forgetPriority(file);
      },
      onError: (Object _, StackTrace _) {
        _fileJobs.remove(file.path);
        _forgetPriority(file);
      },
    );
    return job;
  }

  void _prioritize(coach.PoseHubPackFile file, CatalogMediaPriority priority) {
    if (_priorities[file.sha256] == CatalogMediaPriority.current &&
        priority == CatalogMediaPriority.prefetch) {
      return;
    }
    _priorities[file.sha256] = priority;
    if (priority != CatalogMediaPriority.current) return;
    final queued = _queue.indexWhere((entry) => entry.sha256 == file.sha256);
    if (queued > 0) _queue.insert(0, _queue.removeAt(queued));
  }

  void _forgetPriority(coach.PoseHubPackFile file) {
    if (!_filesForHash[file.sha256]!.any(
      (alias) => _fileJobs.containsKey(alias.path),
    )) {
      _priorities.remove(file.sha256);
    }
  }

  Future<Uri> _ensureFile(
    coach.PoseHubPackFile file,
    int? generation,
    _FileTiming? timing,
  ) async {
    // Content aliases may be the source of materialize(), so keep them alive
    // until this request has finished copying and publishing its own path.
    final releases = [
      for (final alias in _filesForHash[file.sha256]!)
        if (_videos.contains(alias.path)) store.retainVideo(alias),
    ];
    try {
      _check(generation);
      _set(file, CatalogMediaDownloadPhase.checking);
      final cached = await store.cached(file);
      _check(generation);
      if (cached != null) {
        timing?.source = 'cache';
        timing?.verifiedAt = DateTime.now().toUtc();
        _set(file, CatalogMediaDownloadPhase.ready, received: file.bytes);
        return cached;
      }
      final content = await _content(file, generation, timing);
      _check(generation);
      _set(file, CatalogMediaDownloadPhase.verifying, received: file.bytes);
      final uri = await store.materialize(file, content);
      _check(generation);
      timing?.verifiedAt = DateTime.now().toUtc();
      _set(file, CatalogMediaDownloadPhase.ready, received: file.bytes);
      return uri;
    } catch (error) {
      final safe = _safeError(error);
      timing?.code = safe.code;
      _set(file, CatalogMediaDownloadPhase.failed, error: safe);
      throw safe;
    } finally {
      for (final release in releases) {
        release();
      }
      if (timing != null) {
        try {
          onTiming?.call(timing.finish());
        } on Object {
          // Host diagnostics must not change file delivery.
        }
      }
    }
  }

  Future<Uri> _content(
    coach.PoseHubPackFile file,
    int? generation,
    _FileTiming? timing,
  ) {
    if (_contentJobs[file.sha256] case final job?) {
      timing?.content = _contentTimings[file.sha256];
      return job;
    }
    final contentTiming = timing == null ? null : _ContentTiming();
    timing?.content = contentTiming;
    if (contentTiming != null) _contentTimings[file.sha256] = contentTiming;
    final job = Future<Uri>.microtask(
      () => _prepareContent(file, generation, contentTiming),
    );
    _contentJobs[file.sha256] = job;
    job.then<void>(
      (_) {
        _contentJobs.remove(file.sha256);
        _contentTimings.remove(file.sha256);
      },
      onError: (Object _, StackTrace _) {
        _contentJobs.remove(file.sha256);
        _contentTimings.remove(file.sha256);
      },
    );
    return job;
  }

  Future<void> _acquire(coach.PoseHubPackFile file, int? generation) async {
    _check(generation);
    if (_active >= maxConcurrent) {
      final waiter = Completer<void>();
      final entry = (
        ready: waiter,
        generation: generation,
        sha256: file.sha256,
      );
      if (_priorities[file.sha256] == CatalogMediaPriority.current) {
        _queue.insert(0, entry);
      } else {
        _queue.add(entry);
      }
      await waiter.future;
    } else {
      _active++;
    }
  }

  void _release() {
    if (_queue.isEmpty) {
      _active--;
    } else {
      _queue.removeAt(0).ready.complete();
    }
  }

  Future<Uri> _prepareContent(
    coach.PoseHubPackFile file,
    int? generation,
    _ContentTiming? timing,
  ) async {
    _contentState(file, CatalogMediaDownloadPhase.queued);
    await _acquire(file, generation);
    timing?.acquiredAt = DateTime.now().toUtc();
    try {
      _check(generation);
      _contentState(file, CatalogMediaDownloadPhase.checking);
      final reusable = await store.reusable(file);
      _check(generation);
      if (reusable != null) {
        timing?.source = 'reused';
        return reusable;
      }
      void progress(int n) => _contentState(
        file,
        CatalogMediaDownloadPhase.downloading,
        received: n,
      );
      void verifying() {
        timing?.downloadCompletedAt = DateTime.now().toUtc();
        _contentState(
          file,
          CatalogMediaDownloadPhase.verifying,
          received: file.bytes,
        );
      }

      if (_images.contains(file.path) && loadBundle != null) {
        final bytes = await loadBundle!(file).timeout(timeout);
        _check(generation);
        if (bytes != null) {
          timing?.source = 'bundled';
          return await store.bundled(file, bytes, progress, verifying);
        }
      }
      if (bases.isEmpty) {
        throw const CatalogMediaException(
          'not_configured',
          'Media download is not configured yet.',
        );
      }
      Object? failure;
      for (final (index, base) in bases.indexed) {
        _check(generation);
        timing?.baseIndex = index + 1;
        timing?.retries = index;
        timing?.source = 'network';
        timing?.requestStartedAt = DateTime.now().toUtc();
        timing?.firstByteAt = null;
        timing?.downloadCompletedAt = null;
        _contentState(file, CatalogMediaDownloadPhase.downloading);
        try {
          return await store.download(
            file,
            base.resolve(file.path),
            progress,
            verifying,
            onFirstByte: timing == null
                ? null
                : () => timing.firstByteAt ??= DateTime.now().toUtc(),
          );
        } catch (error) {
          // A disposed consumer does not start a new mirror request. Each
          // failed transport has already closed and removed its own temp file.
          _check(generation);
          if (error is CatalogMediaException && error.code == 'cache_full') {
            rethrow;
          }
          failure = error;
        }
      }
      throw _safeError(failure!);
    } finally {
      _release();
    }
  }

  String _kindOf(coach.PoseHubPackFile file) {
    for (final id in _actionsForFile[file.path]!) {
      for (final entry in _action(id).files.entries) {
        if (entry.value.path == file.path) return entry.key;
      }
    }
    return 'unknown';
  }

  @override
  Future<Uri> ensureAction(String actionId) {
    coach.PoseHubPackAction action;
    try {
      action = _action(actionId);
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    if (_clearing case final barrier?) {
      return _afterClear(
        _afterClearActions,
        actionId,
        barrier,
        () => ensureAction(actionId),
      );
    }
    if (_actionJobs[actionId] case final job?) return job;
    final job = Future.wait(
      action.files.values.map(ensureFile),
      eagerError: true,
    ).then((_) => mediaBaseUri);
    _actionJobs[actionId] = job;
    job.then<void>(
      (_) {
        _actionJobs.remove(actionId);
      },
      onError: (Object _, StackTrace _) {
        _actionJobs.remove(actionId);
      },
    );
    return job;
  }

  Future<Uri> _afterClear(
    Map<String, Future<Uri>> waiting,
    String key,
    Future<void> barrier,
    Future<Uri> Function() start,
  ) {
    if (waiting[key] case final existing?) return existing;
    late Future<Uri> next;
    void forget() {
      if (identical(waiting[key], next)) waiting.remove(key);
    }

    next = barrier.then((_) {
      forget();
      return start();
    });
    waiting[key] = next;
    next.then<void>(
      (_) => forget(),
      onError: (Object _, StackTrace _) => forget(),
    );
    return next;
  }

  @override
  Future<Uri?> cachedVideo(String actionId) async {
    final video = _action(actionId).video;
    await _clearing;
    _check();
    final uri = await store.cached(video);
    _check();
    _set(
      video,
      uri == null
          ? CatalogMediaDownloadPhase.idle
          : CatalogMediaDownloadPhase.ready,
      received: uri == null ? 0 : video.bytes,
    );
    return uri;
  }

  @override
  void Function() retainVideo(String actionId) =>
      store.retainVideo(_action(actionId).video);

  @override
  Future<int> videoCacheBytes() async {
    _check();
    await _clearing;
    _check();
    return store.videoCacheBytes();
  }

  @override
  Future<void> clearVideoCache() {
    try {
      _check();
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    if (_clearing case final existing?) return existing;
    final job = Future<void>.microtask(_clearVideos);
    _clearing = job;
    job.then<void>(
      (_) {
        _clearing = null;
      },
      onError: (Object _, StackTrace _) {
        _clearing = null;
      },
    );
    return job;
  }

  Future<void> _clearVideos() async {
    // SDK TrainingMediaRepository uses the same retire/cancel/await ordering.
    // Here the retirement and filesystem deletion are scoped to videos only.
    _generation++;
    final old = [
      for (final entry in _fileJobs.entries)
        if (!_images.contains(entry.key)) entry.value,
    ];
    final queuedVideos = _queue
        .where((entry) => entry.generation != null)
        .toList();
    _queue.removeWhere((entry) => entry.generation != null);
    for (final queued in queuedVideos) {
      queued.ready.completeError(
        const CatalogMediaException(
          'cache_cleared',
          'Video preparation stopped while its cache was cleared.',
        ),
      );
    }
    store.cancelVideoDownloads();
    await Future.wait(
      old.map(
        (job) => job.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
    );
    _check();
    await store.clearVideoCache();
    _check();
    for (final action in catalog.allActions) {
      if (_fileStates.containsKey(action.video.path)) {
        _set(action.video, CatalogMediaDownloadPhase.idle);
      }
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    store.dispose();
    for (final queued in _queue) {
      queued.ready.completeError(
        const CatalogMediaException('disposed', 'Media preparation stopped.'),
      );
    }
    _queue.clear();
    for (final state in [..._fileStates.values, ..._actionStates.values]) {
      state.dispose();
    }
  }
}

class _ContentTiming {
  DateTime? acquiredAt;
  DateTime? requestStartedAt;
  DateTime? firstByteAt;
  DateTime? downloadCompletedAt;
  int? baseIndex;
  int retries = 0;
  String source = 'none';
}

class _FileTiming {
  _FileTiming({
    required this.actionId,
    required this.kind,
    required this.bytes,
  });

  final String actionId;
  final String kind;
  final int bytes;
  final enqueuedAt = DateTime.now().toUtc();
  _ContentTiming? content;
  DateTime? verifiedAt;
  String source = 'none';
  String? code;

  CatalogMediaTiming finish() => CatalogMediaTiming(
    actionId: actionId,
    kind: kind,
    bytes: bytes,
    enqueuedAt: enqueuedAt,
    acquiredAt: content?.acquiredAt,
    requestStartedAt: content?.requestStartedAt,
    firstByteAt: content?.firstByteAt,
    downloadCompletedAt: content?.downloadCompletedAt,
    verifiedAt: verifiedAt,
    completedAt: DateTime.now().toUtc(),
    baseIndex: content?.baseIndex,
    retries: content?.retries ?? 0,
    result: code == null ? 'ready' : 'failed',
    source: content?.source ?? source,
    code: code,
  );
}

CatalogMediaException _safeError(Object error) {
  if (error is CatalogMediaException) return error;
  if (error is TimeoutException) {
    return const CatalogMediaException('timeout', 'Media request timed out.');
  }
  return const CatalogMediaException(
    'unavailable',
    'Media is unavailable. Please retry.',
  );
}
