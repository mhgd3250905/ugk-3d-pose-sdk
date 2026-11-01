import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'training_media_models.dart';
import 'training_media_preview_policy.dart';
import 'training_media_storage.dart';

export 'training_media_models.dart';

/// Only the repository can mint a cached resource, after integrity validation.
final class TrainingMediaResource {
  const TrainingMediaResource._({this.assetKey, this.cachePath});
  final String? assetKey;
  final String? cachePath;
}

class TrainingMediaScope extends InheritedWidget {
  const TrainingMediaScope({
    super.key,
    required this.repository,
    required super.child,
  });
  final TrainingMediaRepository repository;
  static TrainingMediaRepository? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<TrainingMediaScope>()
      ?.repository;
  @override
  bool updateShouldNotify(TrainingMediaScope oldWidget) =>
      oldWidget.repository != repository;
}

/// Versioned, integrity checked media shared by all trainer clients.
class TrainingMediaRepository extends ChangeNotifier {
  TrainingMediaRepository._(
    this.manifest,
    this._bundle,
    this._assetRoot,
    this.baseUrls,
    this._storage,
    this._bundledKeys,
    this._networkProbe,
    this._allowPending,
    this._wifiOnly,
  );

  static Future<TrainingMediaRepository> create({
    required String manifestAsset,
    required List<Uri> baseUrls,
    bool allowPending = false,
    bool wifiOnly = true,
    AssetBundle? bundle,
    TrainingMediaNetworkProbe? networkProbe,
    String? cacheDirectory,
    String? manifestSha256,
    Iterable<String>? bundledAssetKeys,
    Duration downloadTimeout = const Duration(seconds: 15),
  }) async {
    if (downloadTimeout <= Duration.zero) {
      throw ArgumentError.value(downloadTimeout, 'downloadTimeout');
    }
    final assets = bundle ?? rootBundle;
    final data = await assets.load(manifestAsset);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    if (manifestSha256 != null &&
        sha256.convert(bytes).toString() != manifestSha256) {
      throw const FormatException('Main manifest SHA-256 verification failed');
    }
    final manifest = TrainingMediaManifest.fromBytes(bytes);
    for (final url in baseUrls) {
      if (!['http', 'https'].contains(url.scheme) ||
          !url.hasAuthority ||
          url.userInfo.isNotEmpty ||
          url.hasQuery ||
          url.hasFragment ||
          !url.path.endsWith('/')) {
        throw const FormatException(
          'Media base URL must be an HTTP(S) directory',
        );
      }
    }
    final keys =
        bundledAssetKeys?.toSet() ??
        (await AssetManifest.loadFromAssetBundle(assets)).listAssets().toSet();
    final repository = TrainingMediaRepository._(
      manifest,
      assets,
      manifestAsset.substring(0, manifestAsset.lastIndexOf('/') + 1),
      List.unmodifiable(baseUrls),
      await TrainingMediaStorage.create(
        manifest.version,
        cacheDirectory,
        downloadTimeout,
      ),
      keys,
      networkProbe ?? _probeNetwork,
      allowPending,
      wifiOnly,
    );
    for (final id in ['builtin', 'realistic-dark']) {
      if (manifest.packages.containsKey(id)) {
        await repository._loadPackage(id, download: false);
      }
    }
    await repository.availableActionIds();
    await repository.canDownload();
    if (networkProbe == null) {
      repository._networkSubscription = Connectivity().onConnectivityChanged
          .listen((results) {
            repository._updateNetwork(_networkOf(results));
          });
    }
    return repository;
  }

  final TrainingMediaManifest manifest;
  final AssetBundle _bundle;
  final String _assetRoot;
  final List<Uri> baseUrls;
  final TrainingMediaStorage _storage;
  final Set<String> _bundledKeys;
  final TrainingMediaNetworkProbe _networkProbe;
  final Map<String, List<TrainingMediaFile>> _packages = {};
  final Map<String, Future<List<TrainingMediaFile>>> _packageJobs = {};
  final Map<String, Future<TrainingMediaResource>> _jobs = {};
  final Map<String, TrainingMediaState> _states = {};
  final Set<String> _ready = {};
  final List<Completer<void>> _queue = [];
  final Map<String, (String, String, String)> _retryActions = {};
  final Set<String> _retryPackages = {};
  StreamSubscription<List<ConnectivityResult>>? _networkSubscription;
  TrainingMediaNetwork _lastNetwork = TrainingMediaNetwork.offline;
  int _generation = 0;
  int _active = 0;
  bool _clearing = false;
  bool _disposed = false;
  bool _allowPending;
  bool _wifiOnly;
  Future<void>? _clearJob;

  /// Changes when cache capabilities are invalidated, including during clear.
  int get cacheRevision => _generation;

  bool get allowPending => TrainingMediaPreviewPolicy.enabled && _allowPending;
  set allowPending(bool value) {
    _allowPending = value;
    if (!allowPending) _ready.removeWhere((id) => !_eligible(id));
    _notify();
  }

  bool get wifiOnly => _wifiOnly;
  set wifiOnly(bool value) {
    _wifiOnly = value;
    if (_blockedNetwork) {
      _storage.cancel();
    } else {
      _resumeBlocked();
    }
    _notify();
  }

  bool get isOffline => _lastNetwork == TrainingMediaNetwork.offline;
  Set<String> get readyActionIds => Set.unmodifiable(_ready.where(_eligible));
  List<TrainingMediaAction> get visibleActions => manifest.actions
      .where((a) => a.releaseEligible || allowPending)
      .toList(growable: false);
  bool _eligible(String id) => manifest.actions.any(
    (a) => a.id == id && (a.releaseEligible || allowPending),
  );
  bool get _blockedNetwork =>
      isOffline || (wifiOnly && _lastNetwork != TrainingMediaNetwork.wifi);

  static TrainingMediaNetwork _networkOf(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.wifi)) {
      return TrainingMediaNetwork.wifi;
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return TrainingMediaNetwork.mobile;
    }
    if (results.isEmpty || results.every((r) => r == ConnectivityResult.none)) {
      return TrainingMediaNetwork.offline;
    }
    return TrainingMediaNetwork.other;
  }

  static Future<TrainingMediaNetwork> _probeNetwork() async =>
      _networkOf(await Connectivity().checkConnectivity());
  Future<bool> canDownload() async {
    try {
      _updateNetwork(await _networkProbe());
    } catch (_) {
      _updateNetwork(TrainingMediaNetwork.offline);
    }
    return !_blockedNetwork && !_clearing && !_disposed;
  }

  void _updateNetwork(TrainingMediaNetwork network) {
    if (_lastNetwork == network) return;
    _lastNetwork = network;
    if (_blockedNetwork) {
      _storage.cancel();
    } else {
      _resumeBlocked();
    }
    _notify();
  }

  /// Only policy-blocked requests resume. HTTP/integrity failures stay failed.
  void _resumeBlocked() {
    if (_disposed || _clearing) return;
    final actions = _retryActions.values.toList();
    final packages = _retryPackages.toList();
    _retryActions.clear();
    _retryPackages.clear();
    for (final (id, skin, theme) in actions) {
      if (_eligible(id)) {
        unawaited(
          ensureVideo(
            id,
            skin: skin,
            theme: theme,
          ).then<void>((_) {}, onError: (Object _) {}),
        );
      }
    }
    for (final id in packages) {
      unawaited(downloadPackage(id).then<void>((_) {}, onError: (Object _) {}));
    }
  }

  Future<void> _checkPolicy() async {
    if (!await canDownload()) {
      throw StateError(
        isOffline ? 'No network connection' : 'Waiting for Wi-Fi',
      );
    }
  }

  String _asset(String path) => Uri.parse(_assetRoot).resolve(path).path;
  String coverAsset(String id) {
    if (!manifest.actions.any((a) => a.id == id)) {
      throw ArgumentError.value(id, 'id');
    }
    return _asset('common-lossy/covers/$id.webp');
  }

  TrainingMediaState stateFor(String id) =>
      _states[id] ?? const TrainingMediaState(TrainingMediaPhase.idle);
  void _set(String id, TrainingMediaState state) {
    _states[id] = state;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _checkGeneration(int generation) {
    if (_disposed || _clearing || generation != _generation) {
      throw StateError('Download cancelled');
    }
  }

  Future<List<TrainingMediaFile>> _loadPackage(
    String id, {
    bool download = true,
  }) async {
    if (_packages[id] case final files?) return files;
    if (_packageJobs[id] case final job?) return job;
    final generation = _generation;
    final job = _readPackage(id, download, generation);
    _packageJobs[id] = job;
    try {
      return await job;
    } finally {
      _packageJobs.removeWhere(
        (key, value) => key == id && identical(value, job),
      );
    }
  }

  Future<List<TrainingMediaFile>> _readPackage(
    String id,
    bool download,
    int generation,
  ) async {
    final package = manifest.packages[id];
    if (package == null ||
        package.manifest.path != 'packages/$id.json' ||
        !manifest.permitsPath(package.manifest.path)) {
      throw const FormatException('Unknown/unsafe package manifest');
    }
    final reference = package.manifest;
    Uint8List? bytes;
    final key = _asset(reference.path);
    if (_bundledKeys.contains(key)) {
      final data = await _bundle.load(key);
      bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } else {
      var cached = await _storage.cached(reference);
      if (cached == null && download) {
        cached = await _storage.download(
          reference,
          baseUrls.map((base) => base.resolve(reference.path)).toList(),
          checkPolicy: _checkPolicy,
          onProgress: (_) {},
        );
      }
      if (cached != null) bytes = await _storage.read(cached);
    }
    if (bytes == null) return const [];
    if (bytes.length != reference.bytes ||
        sha256.convert(bytes).toString() != reference.sha256) {
      throw const FormatException(
        'Package manifest SHA-256 verification failed',
      );
    }
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final files = (json['files'] as List)
        .map((e) => TrainingMediaFile(e as Map<String, dynamic>))
        .toList(growable: false);
    if (files.length != package.fileCount ||
        files.fold<int>(0, (n, file) => n + file.bytes) != package.totalBytes ||
        files.any((file) => !manifest.permitsPath(file.path)) ||
        files.map((file) => file.path).toSet().length != files.length) {
      throw const FormatException('Package file index mismatch');
    }
    if (package.kind == 'video') {
      final render = id == 'builtin' ? 'realistic-dark' : id;
      final split = render.lastIndexOf('-');
      if (split < 1) throw const FormatException('Invalid video render');
      final directory =
          '../v${manifest.version}/'
          '${render.substring(0, split)}/${render.substring(split + 1)}/';
      final expected = package.actionIds
          .map((id) => '$directory$id.mp4')
          .toSet();
      if (files.length != expected.length ||
          files.any((file) => !expected.contains(file.path))) {
        throw const FormatException('Package video action index mismatch');
      }
    }
    _checkGeneration(generation);
    _packages[id] = files;
    return files;
  }

  Future<TrainingMediaFile?> _video(
    String id,
    String skin,
    String theme, {
    bool downloadManifest = true,
  }) async {
    if (!_eligible(id)) throw StateError('Action is not release eligible');
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(skin) ||
        !RegExp(r'^[a-z0-9-]+$').hasMatch(theme)) {
      throw ArgumentError('Invalid render');
    }
    final path = '../v${manifest.version}/$skin/$theme/$id.mp4';
    final packageIds = [
      if (skin == 'realistic' && theme == 'dark') 'builtin',
      '$skin-$theme',
    ];
    for (final packageId in packageIds) {
      if (!manifest.packages.containsKey(packageId)) continue;
      for (final file in await _loadPackage(
        packageId,
        download: downloadManifest,
      )) {
        if (file.path == path) return file;
      }
    }
    return null;
  }

  Future<TrainingMediaResource?> _available(TrainingMediaFile file) async {
    final key = _asset(file.path);
    if (_bundledKeys.contains(key)) {
      return TrainingMediaResource._(assetKey: key);
    }
    final cached = await _storage.cached(file);
    return cached == null
        ? null
        : TrainingMediaResource._(cachePath: cached.path);
  }

  Future<TrainingMediaResource?> availableVideo(
    String id, {
    String skin = 'realistic',
    String theme = 'dark',
  }) async {
    final generation = _generation;
    final file = await _video(id, skin, theme, downloadManifest: false);
    final resource = file == null ? null : await _available(file);
    _checkGeneration(generation);
    if (skin == 'realistic' && theme == 'dark') {
      if (resource == null) {
        _ready.remove(id);
      } else {
        _ready.add(id);
      }
    }
    return resource;
  }

  Future<Set<String>> availableActionIds() async {
    final generation = _generation;
    for (final action in visibleActions) {
      await availableVideo(action.id);
      _checkGeneration(generation);
    }
    _notify();
    return readyActionIds;
  }

  Future<void> _acquire() async {
    if (_active >= 3) {
      final waiter = Completer<void>();
      _queue.add(waiter);
      await waiter.future;
    } else {
      _active++;
    }
  }

  void _release() {
    if (_queue.isNotEmpty) {
      _queue.removeAt(0).complete();
    } else {
      _active--;
    }
  }

  Future<TrainingMediaResource> _ensureFile(
    TrainingMediaFile file,
    String stateId,
  ) async {
    final generation = _generation;
    _checkGeneration(generation);
    final ready = await _available(file);
    _checkGeneration(generation);
    if (ready != null) return ready;
    if (_jobs[file.sha256] case final job?) return job;
    final job = () async {
      _set(
        stateId,
        TrainingMediaState(TrainingMediaPhase.queued, totalBytes: file.bytes),
      );
      await _acquire();
      try {
        _checkGeneration(generation);
        final entry = await _storage.download(
          file,
          baseUrls.map((base) => base.resolve(file.path)).toList(),
          checkPolicy: () async {
            _checkGeneration(generation);
            await _checkPolicy();
          },
          onProgress: (n) => _set(
            stateId,
            TrainingMediaState(
              TrainingMediaPhase.downloading,
              receivedBytes: n,
              totalBytes: file.bytes,
            ),
          ),
        );
        _checkGeneration(generation);
        return TrainingMediaResource._(cachePath: entry.path);
      } finally {
        _release();
      }
    }();
    _jobs[file.sha256] = job;
    try {
      return await job;
    } finally {
      _jobs.removeWhere(
        (key, value) => key == file.sha256 && identical(value, job),
      );
    }
  }

  Future<TrainingMediaResource> ensureVideo(
    String id, {
    String skin = 'realistic',
    String theme = 'dark',
  }) async {
    final generation = _generation;
    try {
      final file = await _video(id, skin, theme);
      _checkGeneration(generation);
      if (file == null) {
        throw StateError('Video is absent from the media index');
      }
      final resource = await _ensureFile(file, id);
      _checkGeneration(generation);
      if (!_eligible(id)) throw StateError('Action is not release eligible');
      if (skin == 'realistic' && theme == 'dark') _ready.add(id);
      _set(
        id,
        TrainingMediaState(
          TrainingMediaPhase.ready,
          receivedBytes: file.bytes,
          totalBytes: file.bytes,
        ),
      );
      return resource;
    } catch (error) {
      if (generation != _generation || _disposed || _clearing) rethrow;
      if (_blockedNetwork && generation == _generation && !_clearing) {
        _retryActions['$id/$skin/$theme'] = (id, skin, theme);
      }
      _set(
        id,
        TrainingMediaState(
          _blockedNetwork
              ? (isOffline
                    ? TrainingMediaPhase.offline
                    : TrainingMediaPhase.waitingForWifi)
              : TrainingMediaPhase.failed,
          error: error.toString(),
        ),
      );
      rethrow;
    }
  }

  /// Failures stay observable in stateFor; training never awaits this work.
  Future<void> prefetchActions(Iterable<String> ids) async {
    await Future.wait(
      ids.toSet().where(_eligible).map((id) async {
        try {
          await ensureVideo(id);
        } catch (_) {
          /* Cover remains available. */
        }
      }),
    );
  }

  /// Package progress is available through stateFor(packageId).
  Future<void> downloadPackage([String packageId = 'realistic-dark']) async {
    final package = manifest.packages[packageId];
    if (package == null || package.kind != 'video') {
      throw ArgumentError('Unknown video package');
    }
    final generation = _generation;
    _set(
      packageId,
      TrainingMediaState(
        TrainingMediaPhase.queued,
        totalBytes: package.totalBytes,
      ),
    );
    var completed = 0;
    try {
      final files = await _loadPackage(packageId);
      for (final file in files) {
        _checkGeneration(generation);
        final id = file.path
            .split('/')
            .last
            .replaceFirst(RegExp(r'\.mp4$'), '');
        if (!_eligible(id)) continue;
        await _ensureFile(file, id);
        _checkGeneration(generation);
        completed += file.bytes;
        if (packageId == 'realistic-dark' || packageId == 'builtin') {
          _ready.add(id);
        }
        _set(
          id,
          TrainingMediaState(
            TrainingMediaPhase.ready,
            receivedBytes: file.bytes,
            totalBytes: file.bytes,
          ),
        );
        _set(
          packageId,
          TrainingMediaState(
            TrainingMediaPhase.downloading,
            receivedBytes: completed,
            totalBytes: package.totalBytes,
          ),
        );
      }
      _set(
        packageId,
        TrainingMediaState(
          TrainingMediaPhase.ready,
          receivedBytes: completed,
          totalBytes: package.totalBytes,
        ),
      );
    } catch (error) {
      if (generation != _generation || _disposed || _clearing) rethrow;
      if (_blockedNetwork && generation == _generation && !_clearing) {
        _retryPackages.add(packageId);
      }
      _set(
        packageId,
        TrainingMediaState(
          _blockedNetwork
              ? (isOffline
                    ? TrainingMediaPhase.offline
                    : TrainingMediaPhase.waitingForWifi)
              : TrainingMediaPhase.failed,
          receivedBytes: completed,
          totalBytes: package.totalBytes,
          error: error.toString(),
        ),
      );
      rethrow;
    }
  }

  Future<int> cacheBytes() => _storage.bytes();
  Future<void> clearCache() =>
      _clearJob ??= _clearCache().whenComplete(() => _clearJob = null);

  Future<void> _clearCache() async {
    _clearing = true;
    _generation++;
    _retryActions.clear();
    _retryPackages.clear();
    _storage.cancel();
    _notify();
    await Future.wait(
      [..._jobs.values, ..._packageJobs.values].map((job) async {
        try {
          await job;
        } catch (_) {
          /* Cancelled by generation. */
        }
      }),
    );
    try {
      await _storage.clear();
      _ready.clear();
      _states.clear();
      _packages.clear();
    } finally {
      _clearing = false;
    }
    if (_disposed) return;
    for (final id in ['builtin', 'realistic-dark']) {
      if (manifest.packages.containsKey(id)) {
        await _loadPackage(id, download: false);
      }
    }
    await availableActionIds();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    unawaited(_networkSubscription?.cancel());
    _storage.dispose();
    super.dispose();
  }
}
