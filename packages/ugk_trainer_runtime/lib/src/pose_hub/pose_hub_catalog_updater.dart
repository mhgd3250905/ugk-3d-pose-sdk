import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;

import '../media/catalog_media_repository_stub.dart'
    if (dart.library.io) '../media/catalog_media_repository_io.dart'
    as media_platform;
import 'pose_hub_action_library.dart';
import 'pose_hub_catalog_channel.dart';
import 'pose_hub_catalog_io_stub.dart'
    if (dart.library.io) 'pose_hub_catalog_io_native.dart'
    as platform;
import 'pose_hub_catalog_io_types.dart';
import 'pose_hub_catalog_voice.dart';
import 'pose_hub_image_cache.dart';
import 'pose_hub_plan_pack.dart';

export 'package:ugk_coach/ugk_coach.dart'
    show PoseHubDisplayUpdatePhase, PoseHubDisplayUpdateProgress;

export 'pose_hub_catalog_io_types.dart';
export 'pose_hub_plan_pack.dart';
export 'pose_hub_plan_voice.dart';

/// Default HTTP client: dart:io on native platforms, unavailable on web.
PoseHubCatalogHttpClient createPoseHubCatalogHttpClient({
  Duration timeout = const Duration(seconds: 20),
}) => platform.createPoseHubCatalogHttpClient(timeout: timeout);

/// File-backed store rooted at [directory] (e.g. under application support).
PoseHubCatalogStore createPoseHubCatalogFileStore(String directory) =>
    platform.createPoseHubCatalogFileStore(directory);

const _currentName = 'current.json';
const _stateName = 'state.json';
const _packsDir = 'packs';
String _catalogName(String pack) => '$_packsDir/$pack/catalog.json';
String _semanticName(String pack) => '$_packsDir/$pack/semantic.json';
String _retiredMediaName(String pack) => '$_packsDir/$pack/retired-media.json';

String _sha(List<int> bytes) => crypto.sha256.convert(bytes).toString();

/// Reads the last verified downloaded catalogue, re-checking every byte.
/// Returns null when there is none or it cannot be trusted.
Future<coach.PoseHubAppTestCatalog?> readVerifiedPoseHubCatalog(
  PoseHubCatalogStore store,
) async {
  try {
    final current = await store.read(_currentName);
    if (current == null) return null;
    final record = jsonDecode(utf8.decode(current)) as Map<String, Object?>;
    final pack = record['pack']! as String;
    final catalogBytes = await store.read(_catalogName(pack));
    final semanticBytes = await store.read(_semanticName(pack));
    if (catalogBytes == null ||
        semanticBytes == null ||
        catalogBytes.length != record['catalog_bytes'] ||
        _sha(catalogBytes) != record['catalog_sha256']) {
      return null;
    }
    final catalog = coach.PoseHubAppTestCatalog.fromBytes(
      catalogBytes,
      semanticCatalogBytes: semanticBytes,
    );
    if (poseHubPackVersionOf(catalog) != pack) return null;
    return catalog;
  } catch (error) {
    debugPrint('PoseHub catalogue cache ignored: $error');
    return null;
  }
}

/// Update results and nonfatal pointer metadata warnings.
class PoseHubCatalogUpdateEvent {
  const PoseHubCatalogUpdateEvent(this.name, {this.pack, this.reason});
  static const updated = 'pack.updated';
  static const blocked = 'pack.update_blocked';
  static const failed = 'pack.update_failed';
  static const publishedAtUnparsed = 'pointer.published_at_unparsed';
  static const plansUpdated = 'plans.updated';
  static const plansBlocked = 'plans.update_blocked';
  static const plansFailed = 'plans.update_failed';
  final String name;
  final String? pack;
  final String? reason;
  @override
  String toString() => '$name(pack: $pack, reason: $reason)';
}

enum PoseHubCatalogUpdateOutcome {
  /// Checked within the interval during this launch; no request was made.
  throttled,

  /// The pointer answered 304 for the stored ETag.
  notModified,

  /// The pointer names the pack already in use, or an older one.
  unchanged,

  /// The pointer needs a newer SDK (`min_sdk`).
  blocked,

  /// Any download, verification or write failed; the old cache is kept.
  failed,

  /// A new catalogue was verified and atomically stored.
  updated,
}

/// Checks the channel pointer and stores a verified newer catalogue.
///
/// Create one instance per App launch: the first [maybeCheck] always checks,
/// later calls (e.g. on resume) only once [PoseHubCatalogUpdateConfig.
/// checkInterval] has passed since the last check. Never throws; the new
/// catalogue takes effect on the next [PoseHubActionLibrary.load] session.
class PoseHubCatalogUpdater {
  PoseHubCatalogUpdater({
    required this.config,
    required this.store,
    PoseHubCatalogHttpClient? http,
    this.loadLocal,
    DateTime Function()? now,
    this.onEvent,
  }) : http = http ?? createPoseHubCatalogHttpClient(),
       _now = now ?? DateTime.now,
       _persistentAssets = false,
       _assetRootDirectory = null;

  /// Atomically install the new catalogue and verified display assets.
  ///
  /// Videos and voice are training media loaded on demand. Subscribe to
  /// [displayProgress] and [catalogChanges] before starting the first check.
  ///
  /// On native platforms the image and voice consumers use application
  /// support by default. If the host overrides their storage root, pass the
  /// same [assetRootDirectory] here. Pass [store] to
  /// [PoseHubActionLibrary.useVerifiedCache] when setting up the host.
  ///
  /// Both [maybeCheck] and [checkNow] leave the current catalogue in place
  /// until the display downloads finish. The committed catalogue is then
  /// available immediately to display consumers.
  PoseHubCatalogUpdater.withPersistentAssets({
    required this.config,
    required this.store,
    PoseHubCatalogHttpClient? http,
    this.loadLocal,
    DateTime Function()? now,
    this.onEvent,
    this._assetRootDirectory,
  }) : http = http ?? createPoseHubCatalogHttpClient(),
       _now = now ?? DateTime.now,
       _persistentAssets = true;

  final PoseHubCatalogUpdateConfig config;
  final PoseHubCatalogStore store;
  final PoseHubCatalogHttpClient http;
  final void Function(PoseHubCatalogUpdateEvent event)? onEvent;
  final DateTime Function() _now;
  final bool _persistentAssets;
  final String? _assetRootDirectory;
  late final PoseHubImageCache? _images = _persistentAssets
      ? PoseHubImageCache(
          rootDirectory: _assetRootDirectory,
          loadBytes: (uri, maxBytes) async {
            final response = await _get(
              uri,
              'media',
              maxBytes: maxBytes,
              displayBytes: maxBytes - 1,
            );
            _ok(response, 'media', null);
            return response.body;
          },
        )
      : null;

  // Previous sessions in this process can hold the old catalogue even after
  // another updater has been constructed for the same application root.
  static final _inUsePredecessors =
      <String?, Map<String, coach.PoseHubAppTestCatalog>>{};
  bool _startupPruneChecked = false;

  final _displayEvents =
      StreamController<coach.PoseHubDisplayUpdateProgress>.broadcast();
  final _catalogEvents =
      StreamController<coach.PoseHubAppTestCatalog>.broadcast();
  final _planEvents = StreamController<PoseHubPlanSnapshot>.broadcast();
  late final _planStore = PoseHubChannelPlanStore(
    store: store,
    channelUri: config.pointerUri,
  );
  _DisplayTransfer? _display;
  _DisplayTransfer? _failedDisplay;

  /// Work and status for new compatible revisions. An unchanged pointer, a
  /// blocked SDK version, or an offline check with no known update is silent.
  Stream<coach.PoseHubDisplayUpdateProgress> get displayProgress =>
      _displayEvents.stream;

  /// Emits the verified catalogue immediately after the display files and
  /// current pointer are durable. Hosts use this to replace display data.
  Stream<coach.PoseHubAppTestCatalog> get catalogChanges =>
      _catalogEvents.stream;

  /// Emits the installed snapshot after the app's active plan record changes.
  /// Catalogue outcomes and display events are independent of plan updates.
  Stream<PoseHubPlanSnapshot> get planChanges => _planEvents.stream;

  /// Latest verified compatible snapshot for [app], then the app's bundled
  /// copy. This uses local data and does not download plans or audio.
  Future<PoseHubPlanSnapshot?> planSnapshotFor(
    String app, {
    String? catalogPack,
    Future<PoseHubPlanSnapshot?> Function()? loadBundled,
  }) async {
    final activePack = catalogPack ?? poseHubPackVersionOf(await _local());
    final cached = await _planStore.latestCompatible(
      app,
      catalogPack: activePack,
      sdkVersion: config.sdkVersion,
    );
    if (cached != null || loadBundled == null) return cached;
    final bundled = await loadBundled();
    if (bundled == null ||
        bundled.app != app ||
        !bundled.isCompatible(
          catalogPack: activePack,
          sdkVersion: config.sdkVersion,
        )) {
      return null;
    }
    await _planStore.retain(bundled);
    return bundled;
  }

  /// Restores only the exact version the host saved with its training record.
  /// The current active plan never substitutes for a missing pinned copy.
  Future<PoseHubPlanSnapshot?> restorePlanSnapshot(
    String app,
    String snapshotId,
  ) => _planStore.restore(app, snapshotId);

  /// The catalogue in use; defaults to the verified cache, else the bundle.
  final Future<coach.PoseHubAppTestCatalog> Function()? loadLocal;
  bool _launchChecked = false;
  Future<PoseHubCatalogUpdateOutcome>? _running;

  Future<PoseHubCatalogUpdateOutcome> maybeCheck() async {
    if (_running != null) return _running!;
    if (_launchChecked) {
      final last = (await _readState())['last_checked_at'];
      final at = last is String ? DateTime.tryParse(last) : null;
      if (at != null && _now().difference(at) < config.checkInterval) {
        return PoseHubCatalogUpdateOutcome.throttled;
      }
    }
    _launchChecked = true;
    return checkNow();
  }

  /// Checks immediately, ignoring the interval.
  Future<PoseHubCatalogUpdateOutcome> checkNow() =>
      _running ??= _check().whenComplete(() => _running = null);

  Future<PoseHubCatalogUpdateOutcome> _check() async {
    _display = null;
    final state = await _readState();
    // Older SDKs used the same state file but ignored plans. Re-read their
    // pointer once, even when its stored ETag still matches the server.
    final scope = '${config.sdkVersion}:${config.pointerUri}';
    final storedPlan = state['plan_snapshot'];
    final canReuseEtag =
        state['plan_scope'] == scope &&
        (storedPlan is! String || await _planStore.lookup(storedPlan) != null);
    final previousEtag = canReuseEtag && state['etag'] is String
        ? state['etag'] as String
        : null;
    String? etag = previousEtag;
    String? etagPlan = canReuseEtag && storedPlan is String ? storedPlan : null;
    PoseHubCatalogUpdateOutcome outcome;
    try {
      await _pruneAssetsOnFreshLaunch();
      outcome = await _run(previousEtag, (value, snapshotId) {
        etag = value;
        etagPlan = snapshotId;
      });
    } on _Failure catch (failure) {
      etag = previousEtag;
      outcome = _fail(failure.reason, failure.pack);
    } catch (error) {
      etag = previousEtag;
      outcome = _fail('unexpected: $error', null);
    }
    if (outcome != PoseHubCatalogUpdateOutcome.failed && _display == null) {
      // An earlier failed update can be withdrawn or superseded by the SDK.
      _failedDisplay?.finish(coach.PoseHubDisplayUpdatePhase.completed);
      _failedDisplay = null;
    }
    try {
      await store.writeAtomic(
        _stateName,
        utf8.encode(
          jsonEncode({
            'last_checked_at': _now().toUtc().toIso8601String(),
            'etag': ?etag,
            'plan_scope': scope,
            'plan_snapshot': ?etagPlan,
          }),
        ),
      );
    } catch (error) {
      debugPrint('PoseHub catalogue state not saved: $error');
    }
    return outcome;
  }

  Future<PoseHubCatalogUpdateOutcome> _run(
    String? previousEtag,
    void Function(String? etag, String? planSnapshotId) keepEtag,
  ) async {
    final pointerResponse = await _get(
      config.pointerUri,
      'pointer',
      headers: {'If-None-Match': ?previousEtag, 'Cache-Control': 'no-cache'},
      maxBytes: 64 * 1024,
    );
    if (pointerResponse.statusCode == 304 && previousEtag != null) {
      return PoseHubCatalogUpdateOutcome.notModified;
    }
    _ok(pointerResponse, 'pointer', null);
    final PoseHubCatalogPointer pointer;
    try {
      pointer = PoseHubCatalogPointer.fromBytes(pointerResponse.body);
    } catch (error) {
      throw _Failure('pointer_invalid: $error');
    }
    final pack = pointer.pack;
    if (pointer.publishedAtUnparsed) {
      final warning = PoseHubCatalogUpdateEvent(
        PoseHubCatalogUpdateEvent.publishedAtUnparsed,
        pack: pack,
        reason: 'published_at could not be parsed; ignored',
      );
      debugPrint(warning.toString());
      onEvent?.call(warning);
    }
    final local = await _local();
    final localPack = poseHubPackVersionOf(local);
    final PoseHubCatalogUpdateOutcome outcome;
    try {
      outcome = await _updateCatalogue(pointer, local, localPack);
    } on _Failure {
      // An independent plan can still be used with the catalogue on disk.
      await _updatePlans(pointer, localPack);
      rethrow;
    }
    final activePack = outcome == PoseHubCatalogUpdateOutcome.updated
        ? pointer.pack
        : localPack;
    final plans = await _updatePlans(pointer, activePack);
    if (!plans.retry) keepEtag(pointerResponse.etag, plans.snapshotId);
    return outcome;
  }

  Future<PoseHubCatalogUpdateOutcome> _updateCatalogue(
    PoseHubCatalogPointer pointer,
    coach.PoseHubAppTestCatalog local,
    String localPack,
  ) async {
    final pack = pointer.pack;
    // Packs only move forward: a pointer naming an older pack than the one in
    // use (e.g. stable still on r2-v1 while the SDK bundles r2-v2) is a no-op.
    if (localPack == pack || (comparePoseHubPacks(pack, localPack) ?? 0) < 0) {
      return PoseHubCatalogUpdateOutcome.unchanged;
    }
    if (comparePoseHubSdkVersions(pointer.minSdk, config.sdkVersion) > 0) {
      onEvent?.call(
        PoseHubCatalogUpdateEvent(
          PoseHubCatalogUpdateEvent.blocked,
          pack: pack,
          reason: 'min_sdk ${pointer.minSdk} > ${config.sdkVersion}',
        ),
      );
      return PoseHubCatalogUpdateOutcome.blocked;
    }

    if (_persistentAssets) {
      _display = _DisplayTransfer(
        pack,
        pointer.catalogBytes,
        _displayEvents.add,
      );
    }
    final catalogResponse = await _get(
      pointer.catalog,
      'catalog',
      pack: pack,
      maxBytes: pointer.catalogBytes + 1,
      displayBytes: pointer.catalogBytes,
    );
    _ok(catalogResponse, 'catalog', pack);
    final catalogBytes = catalogResponse.body;
    if (catalogBytes.length != pointer.catalogBytes) {
      throw _Failure(
        'catalog_bytes_mismatch: ${catalogBytes.length} != '
        '${pointer.catalogBytes}',
        pack,
      );
    }
    if (_sha(catalogBytes) != pointer.catalogSha256) {
      throw _Failure('catalog_sha256_mismatch', pack);
    }
    final coach.PoseHubAppTestCatalog index;
    try {
      index = coach.PoseHubAppTestCatalog.fromBytes(catalogBytes);
    } catch (error) {
      throw _Failure('catalog_invalid: $error', pack);
    }
    final String indexPack;
    try {
      indexPack = poseHubPackVersionOf(index);
    } catch (error) {
      throw _Failure('catalog_invalid: $error', pack);
    }
    if (indexPack != pack) {
      throw _Failure('catalog_pack_mismatch: $indexPack', pack);
    }
    // Add-only counts from r2-v1, the first catalogue that declares `pack`.
    // A local catalogue without `pack` has no lineage to keep (user, 2026-11-04).
    final newIds = {for (final a in index.allActions) a.id};
    final missing = [
      if (local.raw['pack'] != null)
        for (final a in local.allActions)
          if (!newIds.contains(a.id)) a.id,
    ];
    if (missing.isNotEmpty) {
      throw _Failure('missing_action_ids: ${missing.join(',')}', pack);
    }

    final semanticFile = index.semanticCatalogFile;
    final semanticBytes = await _semanticBytes(pointer, semanticFile, local);
    final coach.PoseHubAppTestCatalog verified;
    try {
      verified = coach.PoseHubAppTestCatalog.fromBytes(
        catalogBytes,
        semanticCatalogBytes: semanticBytes,
      );
    } catch (error) {
      throw _Failure('semantic_invalid: $error', pack);
    }

    if (_images case final images?) {
      try {
        final display = _display!;
        display.verifyDocuments();
        // Prepare verified display files before exposing the new catalogue.
        await _prepareDisplayAssets(verified, images, display);
      } catch (error) {
        throw _Failure('assets_not_ready: $error', pack);
      }
    }

    try {
      await store.writeAtomic(_semanticName(pack), semanticBytes);
      await store.writeAtomic(_catalogName(pack), catalogBytes);
      if (_persistentAssets) {
        final keep = _mediaHashes([verified]);
        final retiring = <(String, String), coach.PoseHubPackFile>{
          for (final file in await _readRetiredMedia(localPack))
            if (!keep.contains(file.sha256)) (file.path, file.sha256): file,
          for (final file in _catalogMedia(local))
            if (!keep.contains(file.sha256)) (file.path, file.sha256): file,
        };
        await store.writeAtomic(
          _retiredMediaName(pack),
          utf8.encode(
            jsonEncode([
              for (final file in retiring.values)
                {'path': file.path, 'bytes': file.bytes, 'sha256': file.sha256},
            ]),
          ),
        );
      }
      // The switch itself: one atomic write of the current record.
      await store.writeAtomic(
        _currentName,
        utf8.encode(
          jsonEncode({
            'pack': pack,
            'catalog_sha256': pointer.catalogSha256,
            'catalog_bytes': pointer.catalogBytes,
            if (_images != null) 'assets_ready': true,
            'published_at': ?pointer.publishedAt?.toIso8601String(),
          }),
        ),
      );
    } catch (error) {
      throw _Failure('cache_write_failed: $error', pack);
    }
    if (_display case final display?) {
      PoseHubActionLibrary.refreshVerifiedCache(store);
      _catalogEvents.add(verified);
      display.finish(coach.PoseHubDisplayUpdatePhase.completed);
      _failedDisplay = null;
    }
    await _prune(keep: {pack, localPack});
    if (_images case final images?) {
      final inUse = _inUsePredecessors.putIfAbsent(
        images.rootDirectory,
        () => {},
      );
      inUse[localPack] = local;
      await _pruneAssets([verified, ...inUse.values], images);
    }
    onEvent?.call(
      PoseHubCatalogUpdateEvent(PoseHubCatalogUpdateEvent.updated, pack: pack),
    );
    return PoseHubCatalogUpdateOutcome.updated;
  }

  Future<({bool retry, String? snapshotId})> _updatePlans(
    PoseHubCatalogPointer pointer,
    String catalogPack,
  ) async {
    final descriptor = pointer.plans;
    if (descriptor == null) {
      if (pointer.plansError case final error?) {
        _planEvent(PoseHubCatalogUpdateEvent.plansFailed, pointer.pack, error);
        return (retry: true, snapshotId: null);
      }
      return (retry: false, snapshotId: null);
    }
    if (comparePoseHubSdkVersions(descriptor.minSdk, config.sdkVersion) > 0) {
      _planEvent(
        PoseHubCatalogUpdateEvent.plansBlocked,
        pointer.pack,
        'min_sdk ${descriptor.minSdk} > ${config.sdkVersion}',
      );
      return (retry: false, snapshotId: null);
    }
    try {
      final existing = await _planStore.lookup(descriptor.sha256);
      final List<int>? downloaded;
      final PoseHubPlanPack pack;
      if (existing == null) {
        downloaded = await _planDocument(
          descriptor.uri,
          descriptor.bytes,
          descriptor.sha256,
          'plans',
          pointer.pack,
        );
        pack = PoseHubPlanPack.fromBytes(downloaded);
      } else {
        downloaded = null;
        pack = existing.planPack;
      }
      if (pack.version != descriptor.version ||
          pack.byteLength != descriptor.bytes) {
        throw _Failure('plans_descriptor_mismatch', pointer.pack);
      }
      final order = comparePoseHubPacks(catalogPack, pack.minCatalogPack);
      if (order == null ? catalogPack != pack.minCatalogPack : order < 0) {
        _planEvent(
          PoseHubCatalogUpdateEvent.plansBlocked,
          pointer.pack,
          'min_catalog_pack ${pack.minCatalogPack} > $catalogPack',
        );
        return (retry: true, snapshotId: null);
      }
      final current = await _planStore.latestCompatible(
        pack.app,
        catalogPack: catalogPack,
        sdkVersion: config.sdkVersion,
      );
      if (current != null &&
          current.id == descriptor.sha256 &&
          current.minSdk == descriptor.minSdk) {
        // The compatible fallback may not be the most recently selected row.
        await _planStore.install(current);
        return (retry: false, snapshotId: current.id);
      }
      final PoseHubPlanSnapshot snapshot;
      if (existing == null) {
        final voice = pack.voiceManifest;
        final voiceBytes = await _planDocument(
          voice.uri,
          voice.bytes,
          voice.sha256,
          'voice_manifest',
          pointer.pack,
        );
        snapshot = PoseHubPlanSnapshot.fromBytes(
          downloaded!,
          voiceBytes,
          minSdk: descriptor.minSdk,
        );
      } else {
        snapshot = existing.withMinSdk(descriptor.minSdk);
      }
      await _planStore.install(snapshot);
      _planEvents.add(snapshot);
      _planEvent(PoseHubCatalogUpdateEvent.plansUpdated, pointer.pack);
      return (retry: false, snapshotId: snapshot.id);
    } catch (error) {
      _planEvent(
        PoseHubCatalogUpdateEvent.plansFailed,
        pointer.pack,
        error.toString(),
      );
      // Keep the previous ETag so the server can offer this revision again.
      return (retry: true, snapshotId: null);
    }
  }

  void _planEvent(String name, String pack, [String? reason]) => onEvent?.call(
    PoseHubCatalogUpdateEvent(name, pack: pack, reason: reason),
  );

  Future<List<int>> _planDocument(
    Uri uri,
    int bytes,
    String sha256,
    String label,
    String pack,
  ) async {
    final response = await _get(uri, label, pack: pack, maxBytes: bytes + 1);
    _ok(response, label, pack);
    if (response.body.length != bytes || _sha(response.body) != sha256) {
      throw _Failure('${label}_integrity_mismatch', pack);
    }
    return response.body;
  }

  Future<List<int>> _semanticBytes(
    PoseHubCatalogPointer pointer,
    coach.PoseHubPackFile file,
    coach.PoseHubAppTestCatalog local,
  ) async {
    if (_images != null && local.semanticCatalogFile.sha256 == file.sha256) {
      final bytes = await store.read(
        _semanticName(poseHubPackVersionOf(local)),
      );
      if (bytes != null &&
          bytes.length == file.bytes &&
          _sha(bytes) == file.sha256) {
        return bytes;
      }
    }
    _display?.addDocument(file.bytes);
    final response = await _get(
      pointer.catalog.resolve(file.path),
      'semantic',
      pack: pointer.pack,
      maxBytes: file.bytes + 1,
      displayBytes: file.bytes,
    );
    _ok(response, 'semantic', pointer.pack);
    return response.body;
  }

  Future<void> _prepareDisplayAssets(
    coach.PoseHubAppTestCatalog catalog,
    PoseHubImageCache images,
    _DisplayTransfer transfer,
  ) async {
    final base = PoseHubActionLibrary.mediaBaseUriFor(catalog);
    final files = {
      for (final file in catalog.displayMediaFiles)
        (file.sha256, file.bytes): file,
    }.values;
    final missing = <coach.PoseHubPackFile>[];
    await _forDisplayAssets(files, (file) async {
      if (await images.findLocal(file, mediaBaseUri: base) == null) {
        missing.add(file);
      }
    });
    transfer.planAssets(missing);
    await _forDisplayAssets(missing, (file) async {
      await images.ensureFile(file, mediaBaseUri: base);
      transfer.verifyFile();
    });
  }

  Future<void> _forDisplayAssets(
    Iterable<coach.PoseHubPackFile> files,
    Future<void> Function(coach.PoseHubPackFile) operation,
  ) async {
    final remaining = files.iterator;
    Object? failed;

    Future<void> worker() async {
      while (failed == null && remaining.moveNext()) {
        try {
          await operation(remaining.current);
        } catch (error) {
          failed ??= error;
        }
      }
    }

    await Future.wait(List.generate(6, (_) => worker()));
    if (failed case final error?) throw error;
  }

  Future<void> _pruneAssetsOnFreshLaunch() async {
    final images = _images;
    if (images == null || _startupPruneChecked) return;
    _startupPruneChecked = true;
    if (_inUsePredecessors.containsKey(images.rootDirectory)) return;
    try {
      final bytes = await store.read(_currentName);
      if (bytes == null) return;
      final record = jsonDecode(utf8.decode(bytes));
      if (record is! Map<String, Object?> || record['assets_ready'] != true) {
        return;
      }
      final current = await readVerifiedPoseHubCatalog(store);
      if (current == null) return;
      await _pruneAssets(
        [current],
        images,
        retiredFiles: await _readRetiredMedia(poseHubPackVersionOf(current)),
      );
    } catch (error) {
      debugPrint('PoseHub catalogue startup cleanup deferred: $error');
    }
  }

  Future<List<coach.PoseHubPackFile>> _readRetiredMedia(String pack) async {
    try {
      final retired = await store.read(_retiredMediaName(pack));
      if (retired == null) return const [];
      return (jsonDecode(utf8.decode(retired)) as List<Object?>)
          .map(coach.PoseHubPackFile.fromJson)
          .toList();
    } catch (error) {
      debugPrint('PoseHub retired asset list ignored: $error');
      return const [];
    }
  }

  Future<void> _pruneAssets(
    List<coach.PoseHubAppTestCatalog> keep,
    PoseHubImageCache images, {
    Iterable<coach.PoseHubPackFile> retiredFiles = const [],
  }) async {
    try {
      await media_platform.pruneCatalogMediaContent(
        rootDirectory: images.rootDirectory,
        keepSha256: _mediaHashes(keep),
        retiredFiles: retiredFiles,
      );
      await prunePoseHubCatalogVoice(
        keep,
        assetRootDirectory: images.rootDirectory,
      );
    } catch (error) {
      debugPrint('PoseHub catalogue assets not pruned: $error');
    }
  }

  Set<String> _mediaHashes(Iterable<coach.PoseHubAppTestCatalog> catalogs) => {
    for (final catalog in catalogs)
      for (final file in _catalogMedia(catalog)) file.sha256,
  };

  Iterable<coach.PoseHubPackFile> _catalogMedia(
    coach.PoseHubAppTestCatalog catalog,
  ) sync* {
    yield* catalog.displayAssets.values;
    for (final action in catalog.allActions) {
      yield* action.allMediaFiles;
    }
  }

  /// Keeps only the current and the previous pack in the cache. Best
  /// effort: the switch has already happened, so a failed delete is retried
  /// on the next successful update.
  Future<void> _prune({required Set<String> keep}) async {
    try {
      for (final name in await store.list(_packsDir)) {
        if (!keep.contains(name)) await store.delete('$_packsDir/$name');
      }
    } catch (error) {
      debugPrint('PoseHub catalogue cache not pruned: $error');
    }
  }

  Future<coach.PoseHubAppTestCatalog> _local() async {
    try {
      final custom = loadLocal;
      if (_images == null) {
        if (custom != null) return await custom();
        return await readVerifiedPoseHubCatalog(store) ??
            await PoseHubActionLibrary.loadBundled();
      }
      final verified = await readVerifiedPoseHubCatalog(store);
      final fallback = await (custom == null
          ? PoseHubActionLibrary.loadBundled()
          : custom());
      if (verified == null) return fallback;
      final order = comparePoseHubPacks(
        poseHubPackVersionOf(verified),
        poseHubPackVersionOf(fallback),
      );
      return order != null && order < 0 ? fallback : verified;
    } catch (error) {
      throw _Failure('local_catalog_unavailable: $error');
    }
  }

  Future<PoseHubCatalogHttpResponse> _get(
    Uri uri,
    String what, {
    String? pack,
    Map<String, String> headers = const {},
    required int maxBytes,
    int? displayBytes,
  }) async {
    try {
      final display = _display;
      final client = http;
      final planned = displayBytes;
      if (display != null && planned != null) {
        void received(int bytes) =>
            display.receive(uri, bytes.clamp(0, planned));
        if (client is PoseHubCatalogProgressHttpClient) {
          return await client.getWithProgress(
            uri,
            headers: headers,
            maxBytes: maxBytes,
            onBytes: received,
          );
        }
        final response = await client.get(
          uri,
          headers: headers,
          maxBytes: maxBytes,
        );
        received(response.body.length);
        return response;
      }
      return await client.get(uri, headers: headers, maxBytes: maxBytes);
    } catch (error) {
      throw _Failure('${what}_download_failed: $error', pack);
    }
  }

  void _ok(PoseHubCatalogHttpResponse response, String what, String? pack) {
    if (response.statusCode != 200) {
      throw _Failure('${what}_http_${response.statusCode}', pack);
    }
  }

  PoseHubCatalogUpdateOutcome _fail(String reason, String? pack) {
    if (_display case final display?) {
      display.finish(coach.PoseHubDisplayUpdatePhase.failed, reason);
      _failedDisplay = display;
    }
    onEvent?.call(
      PoseHubCatalogUpdateEvent(
        PoseHubCatalogUpdateEvent.failed,
        pack: pack,
        reason: reason,
      ),
    );
    return PoseHubCatalogUpdateOutcome.failed;
  }

  Future<Map<String, Object?>> _readState() async {
    try {
      final bytes = await store.read(_stateName);
      if (bytes == null) return const {};
      final value = jsonDecode(utf8.decode(bytes));
      return value is Map<String, Object?> ? value : const {};
    } catch (_) {
      return const {};
    }
  }
}

class _DisplayTransfer {
  _DisplayTransfer(this.version, this.totalBytes, this.report) {
    _emit();
  }

  final String version;
  final void Function(coach.PoseHubDisplayUpdateProgress) report;
  int totalFiles = 1;
  int totalBytes;
  int completedFiles = 0;
  int receivedBytes = 0;
  bool totalsKnown = false;
  final _receivedByUrl = <Uri, int>{};
  final _clock = Stopwatch()..start();
  int _lastReport = 0;

  void receive(Uri uri, int bytes) {
    final previous = _receivedByUrl[uri] ?? 0;
    if (bytes <= previous) return;
    _receivedByUrl[uri] = bytes;
    receivedBytes += bytes - previous;
    _reportIfDue();
  }

  void addDocument(int bytes) {
    totalFiles++;
    totalBytes += bytes;
  }

  void verifyDocuments() => completedFiles = totalFiles;

  void planAssets(List<coach.PoseHubPackFile> files) {
    totalFiles += files.length;
    totalBytes += files.fold(0, (total, file) => total + file.bytes);
    totalsKnown = true;
    _emit();
  }

  void verifyFile() {
    completedFiles++;
    _reportIfDue();
  }

  void _reportIfDue() {
    if (_clock.elapsedMilliseconds - _lastReport >= 40) _emit();
  }

  void finish(coach.PoseHubDisplayUpdatePhase phase, [String? error]) =>
      _emit(phase, error);

  void _emit([
    coach.PoseHubDisplayUpdatePhase phase =
        coach.PoseHubDisplayUpdatePhase.downloading,
    String? error,
  ]) {
    _lastReport = _clock.elapsedMilliseconds;
    report(
      coach.PoseHubDisplayUpdateProgress(
        phase: phase,
        version: version,
        totalFiles: totalFiles,
        completedFiles: completedFiles,
        totalBytes: totalBytes,
        receivedBytes: receivedBytes,
        totalsKnown: totalsKnown,
        error: error,
      ),
    );
  }
}

class _Failure implements Exception {
  _Failure(this.reason, [this.pack]);
  final String reason;
  final String? pack;
}
