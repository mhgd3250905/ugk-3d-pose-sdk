import 'package:flutter/services.dart';
import 'package:ugk_coach/ugk_coach.dart';

/// Compressed R1 v3 metadata ships with the SDK. Hosts download and verify
/// individual media objects separately; no video or image is embedded in Git.
abstract final class PoseHubActionLibrary {
  static const assetRoot =
      'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/';

  /// Audit digest of this SDK's bundled catalogue, not an acceptance gate for
  /// other internally consistent catalogue versions.
  static const catalogSha256 =
      '75881cf91621c967f80732f0219f23e85b35e8bde5d1a51ee75dec5f7c5edd36';

  /// Public v3 metadata. Media download URLs are declared on each file record.
  static const catalogDownloadUri =
      'https://github.com/mhgd3250905/ugk-3d-pose-sdk/releases/download/'
      'posehub-app-test-pack-r1-v3/catalog.json';
  static const mediaReleaseBaseUri = 'https://media.uuugk.win/pack/r1-v3/';

  /// Legacy v2 whole-pack ZIP, retained for existing hosts. V3 hosts use
  /// [catalogDownloadUri] and each file's individual download location.
  static const downloadUri =
      'https://github.com/mhgd3250905/ugk-3d-pose-sdk/releases/download/'
      'posehub-app-test-pack-r1-v2/posehub-app-test-pack-r1-v2.zip';
  static Future<PoseHubAppTestCatalog>? _bundled;

  static Future<PoseHubAppTestCatalog> load({AssetBundle? bundle}) =>
      bundle == null ? (_bundled ??= _load(rootBundle)) : _load(bundle);

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
