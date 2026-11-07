import 'package:flutter/services.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'pose_hub_catalog_channel.dart';
import 'pose_hub_catalog_io_types.dart';
import 'pose_hub_catalog_updater.dart' show readVerifiedPoseHubCatalog;

/// The bundled baseline catalogue ships with the SDK. Synchronize it with
/// the published channel using `tool/sync_bundled_pack.py` before packaging.
/// Hosts download and verify individual media objects separately; no video
/// or image is embedded in Git apart from the standing frame-zero images.
abstract final class PoseHubActionLibrary {
  static const assetRoot =
      'packages/ugk_trainer/assets/pose_hub/app-pack-r2-v7/';

  /// Frame-zero images and their video identity index for the bundled pack.
  /// Other catalogue media revisions use verified cover/thumbnail caches.
  static const standingAssetRoot =
      'packages/ugk_trainer/assets/pose_hub/app-pack-r2-v7/standing/';

  /// Audit digest of this SDK's bundled catalogue, not an acceptance gate for
  /// other internally consistent catalogue versions.
  static const catalogSha256 =
      '92cff0a0eb31f8d51122d838842c27080a39e26619879978ff95c65ac69569f9';

  /// Bundled pack version (`pack` in the bundled catalogue).
  static const packVersion = 'r2-v7';

  /// Public metadata of the bundled pack.
  static const catalogDownloadUri =
      'https://media.uuugk.win/pack/r2-v7/catalog.json';

  /// Media root of the bundled pack (its `mediaDistribution`).
  static const mediaReleaseBaseUri = 'https://media.uuugk.win/pack/r2-v1/';

  /// Media root of [catalog]'s pack.
  static Uri mediaBaseUriFor(PoseHubAppTestCatalog catalog) =>
      poseHubMediaBaseUriForPack(poseHubMediaPackOf(catalog));

  static Future<PoseHubAppTestCatalog>? _bundled;
  static PoseHubCatalogStore? _verifiedCache;

  /// Opt in to catalogues downloaded by `PoseHubCatalogUpdater`. Null (the
  /// default) keeps the bundled catalogue only. Takes effect on next load.
  static void useVerifiedCache(PoseHubCatalogStore? store) {
    _verifiedCache = store;
    _bundled = null;
  }

  /// Starts a new session: the next [load] re-reads the verified cache.
  /// The catalogue in use is never switched underneath a running session.
  static void resetForNextSession() => _bundled = null;

  /// Prefers the verified local cache, then the bundled baseline.
  static Future<PoseHubAppTestCatalog> load({
    AssetBundle? bundle,
    PoseHubCatalogStore? verifiedCache,
  }) {
    final store = verifiedCache ?? _verifiedCache;
    if (bundle == null && verifiedCache == null) {
      return _bundled ??= _preferred(rootBundle, store);
    }
    return _preferred(bundle ?? rootBundle, store);
  }

  /// The SDK's bundled baseline, ignoring any downloaded catalogue.
  static Future<PoseHubAppTestCatalog> loadBundled({AssetBundle? bundle}) =>
      _load(bundle ?? rootBundle);

  static Future<PoseHubAppTestCatalog> _preferred(
    AssetBundle bundle,
    PoseHubCatalogStore? store,
  ) async {
    if (store != null) {
      final cached = await readVerifiedPoseHubCatalog(store);
      if (cached != null) {
        final bundled = await _load(bundle);
        // A cache older than the bundled baseline (downloaded before this
        // SDK shipped a newer pack) never shadows it.
        final order = comparePoseHubPacks(
          poseHubPackVersionOf(cached),
          poseHubPackVersionOf(bundled),
        );
        return order != null && order < 0 ? bundled : cached;
      }
    }
    return _load(bundle);
  }

  static Future<PoseHubAppTestCatalog> _load(AssetBundle bundle) async {
    final raw = await bundle.load('${assetRoot}catalog.json');
    final catalog = raw.buffer.asUint8List(
      raw.offsetInBytes,
      raw.lengthInBytes,
    );
    final index = PoseHubAppTestCatalog.fromBytes(catalog);
    final semantics = await bundle.load(
      '$assetRoot${index.semanticCatalogFile.path}',
    );
    return PoseHubAppTestCatalog.fromBytes(
      catalog,
      semanticCatalogBytes: semantics.buffer.asUint8List(
        semantics.offsetInBytes,
        semantics.lengthInBytes,
      ),
    );
  }
}
