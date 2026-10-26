import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:ugk_coach/ugk_coach.dart';

/// Original R1 metadata ships with the SDK; the full media pack is installed
/// separately. No video or image is embedded in the Git package.
abstract final class PoseHubActionLibrary {
  static const assetRoot =
      'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/';
  static const catalogSha256 =
      'c5f090aa06e2743904a3f0c1f9193c87955242b1aa7f054a14a9f6e7c824be54';
  static const downloadUri =
      'https://github.com/mhgd3250905/ugk-3d-pose-sdk/releases/download/'
      'posehub-app-test-pack-r1-v1/posehub-app-test-pack-r1.zip';
  static Future<PoseHubAppTestCatalog>? _bundled;

  static Future<PoseHubAppTestCatalog> load({AssetBundle? bundle}) =>
      bundle == null ? (_bundled ??= _load(rootBundle)) : _load(bundle);

  static Future<PoseHubAppTestCatalog> _load(AssetBundle bundle) async {
    final raw = await bundle.load('${assetRoot}catalog.json');
    final catalog = raw.buffer.asUint8List(
      raw.offsetInBytes,
      raw.lengthInBytes,
    );
    if (sha256.convert(catalog).toString() != catalogSha256) {
      throw const FormatException('Pose-Hub R1 catalog checksum mismatch');
    }
    final semantics = await bundle.load('${assetRoot}catalog/catalog.json');
    return PoseHubAppTestCatalog.fromBytes(
      catalog,
      semanticCatalogBytes: semantics.buffer.asUint8List(
        semantics.offsetInBytes,
        semantics.lengthInBytes,
      ),
    );
  }
}
