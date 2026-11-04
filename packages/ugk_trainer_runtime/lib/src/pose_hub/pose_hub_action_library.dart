import 'package:flutter/services.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'pose_hub_catalog_channel.dart';
import 'pose_hub_catalog_io_types.dart';
import 'pose_hub_catalog_updater.dart' show readVerifiedPoseHubCatalog;

/// The r2-v1 baseline catalogue (249 actions, first action-library version)
/// ships with the SDK. Hosts download and verify
/// individual media objects separately; no video or image is embedded in Git.
abstract final class PoseHubActionLibrary {
  static const assetRoot =
      'packages/ugk_trainer/assets/pose_hub/app-pack-r2-v1/';

  /// Audit digest of this SDK's bundled catalogue, not an acceptance gate for
  /// other internally consistent catalogue versions.
  static const catalogSha256 =
      '02721e4c24a0445f2a05ef185b2569dc105566d630c5b8f901da059c0945117b';

  /// Bundled pack version (`pack` in the bundled catalogue).
  static const packVersion = 'r2-v1';

  /// Public r2-v1 metadata. Media download URLs are declared on each file.
  static const catalogDownloadUri =
      'https://media.uuugk.win/pack/r2-v1/catalog.json';
  static const mediaReleaseBaseUri = 'https://media.uuugk.win/pack/r2-v1/';

  /// Media root of [catalog]'s pack.
  static Uri mediaBaseUriFor(PoseHubAppTestCatalog catalog) =>
      poseHubMediaBaseUriForPack(poseHubPackVersionOf(catalog));

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
      if (cached != null) return cached;
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
