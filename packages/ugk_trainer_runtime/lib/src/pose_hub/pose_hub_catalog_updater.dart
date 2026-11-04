import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;

import 'pose_hub_action_library.dart';
import 'pose_hub_catalog_channel.dart';
import 'pose_hub_catalog_io_stub.dart'
    if (dart.library.io) 'pose_hub_catalog_io_native.dart'
    as platform;
import 'pose_hub_catalog_io_types.dart';

export 'pose_hub_catalog_io_types.dart';

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

/// Event names: `pack.updated`, `pack.update_blocked`, `pack.update_failed`.
class PoseHubCatalogUpdateEvent {
  const PoseHubCatalogUpdateEvent(this.name, {this.pack, this.reason});
  static const updated = 'pack.updated';
  static const blocked = 'pack.update_blocked';
  static const failed = 'pack.update_failed';
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

  /// The pointer names the pack already in use.
  unchanged,

  /// The pointer needs a newer SDK (`min_sdk`).
  blocked,

  /// Any download, verification or write failed; the old cache is kept.
  failed,

  /// A new catalogue was verified and stored for the next load.
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
       _now = now ?? DateTime.now;

  final PoseHubCatalogUpdateConfig config;
  final PoseHubCatalogStore store;
  final PoseHubCatalogHttpClient http;
  final void Function(PoseHubCatalogUpdateEvent event)? onEvent;
  final DateTime Function() _now;

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
    final state = await _readState();
    final previousEtag = state['etag'] is String
        ? state['etag'] as String
        : null;
    String? etag = previousEtag;
    PoseHubCatalogUpdateOutcome outcome;
    try {
      outcome = await _run(previousEtag, (value) => etag = value);
    } on _Failure catch (failure) {
      etag = previousEtag;
      outcome = _fail(failure.reason, failure.pack);
    } catch (error) {
      etag = previousEtag;
      outcome = _fail('unexpected: $error', null);
    }
    try {
      await store.writeAtomic(
        _stateName,
        utf8.encode(
          jsonEncode({
            'last_checked_at': _now().toUtc().toIso8601String(),
            'etag': ?etag,
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
    void Function(String? etag) keepEtag,
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
    final local = await _local();
    if (poseHubPackVersionOf(local) == pack) {
      keepEtag(pointerResponse.etag);
      return PoseHubCatalogUpdateOutcome.unchanged;
    }
    if (comparePoseHubSdkVersions(pointer.minSdk, config.sdkVersion) > 0) {
      keepEtag(pointerResponse.etag);
      onEvent?.call(
        PoseHubCatalogUpdateEvent(
          PoseHubCatalogUpdateEvent.blocked,
          pack: pack,
          reason: 'min_sdk ${pointer.minSdk} > ${config.sdkVersion}',
        ),
      );
      return PoseHubCatalogUpdateOutcome.blocked;
    }

    final catalogResponse = await _get(
      pointer.catalog,
      'catalog',
      pack: pack,
      maxBytes: pointer.catalogBytes + 1,
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
    // The legacy bundled r1-v3 has no lineage to keep (user, 2026-11-04).
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
    final semanticResponse = await _get(
      pointer.catalog.resolve(semanticFile.path),
      'semantic',
      pack: pack,
      maxBytes: semanticFile.bytes + 1,
    );
    _ok(semanticResponse, 'semantic', pack);
    final semanticBytes = semanticResponse.body;
    try {
      coach.PoseHubAppTestCatalog.fromBytes(
        catalogBytes,
        semanticCatalogBytes: semanticBytes,
      );
    } catch (error) {
      throw _Failure('semantic_invalid: $error', pack);
    }

    try {
      await store.writeAtomic(_semanticName(pack), semanticBytes);
      await store.writeAtomic(_catalogName(pack), catalogBytes);
      // The switch itself: one atomic write of the current record.
      await store.writeAtomic(
        _currentName,
        utf8.encode(
          jsonEncode({
            'pack': pack,
            'catalog_sha256': pointer.catalogSha256,
            'catalog_bytes': pointer.catalogBytes,
            'published_at': pointer.publishedAt.toIso8601String(),
          }),
        ),
      );
    } catch (error) {
      throw _Failure('cache_write_failed: $error', pack);
    }
    await _prune(keep: {pack, poseHubPackVersionOf(local)});
    keepEtag(pointerResponse.etag);
    onEvent?.call(
      PoseHubCatalogUpdateEvent(PoseHubCatalogUpdateEvent.updated, pack: pack),
    );
    return PoseHubCatalogUpdateOutcome.updated;
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
      if (custom != null) return await custom();
      return await readVerifiedPoseHubCatalog(store) ??
          await PoseHubActionLibrary.loadBundled();
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
  }) async {
    try {
      return await http.get(uri, headers: headers, maxBytes: maxBytes);
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

class _Failure implements Exception {
  _Failure(this.reason, [this.pack]);
  final String reason;
  final String? pack;
}
