import 'package:flutter/services.dart';

/// Names of the common playback resources, independent of action catalogues.
/// Legacy hosts keep their physical keys; runtime-only hosts use this package.
abstract final class TrainerRuntimeAssets {
  static const package = 'ugk_trainer_runtime';
  static const legacyPrefix = 'packages/ugk_trainer/';
  static const runtimePrefix = 'packages/ugk_trainer_runtime/';
  static const playerPrefix = '${runtimePrefix}assets/media_player/';
  static const poseHubPlayer =
      '${runtimePrefix}assets/pose_hub_player/player.html';
  static const silence = '${runtimePrefix}assets/silence.m4a';
  static const shader = '${runtimePrefix}shaders/packed_alpha.frag';

  /// Resolves only common legacy resource aliases. Action paths are untouched.
  /// A missing resource remains missing; this never fetches a full action pack.
  static Future<String> resolveAsset(String key, {AssetBundle? bundle}) async {
    if (!key.startsWith(legacyPrefix)) return key;
    final relative = key.substring(legacyPrefix.length);
    if (relative != 'assets/silence.m4a' &&
        relative != 'shaders/packed_alpha.frag' &&
        !relative.startsWith('assets/media_player/') &&
        !relative.startsWith('assets/pose_hub_player/')) {
      return key;
    }
    final selectedBundle = bundle ?? rootBundle;
    final assets = (await AssetManifest.loadFromAssetBundle(
      selectedBundle,
    )).listAssets();
    if (assets.contains(key)) return key;
    // Package-under-test bundles can load their own qualified resource key
    // even though the manifest lists it without the package prefix.
    try {
      await selectedBundle.load(key);
      return key;
    } on Exception {
      // Only the known common alias may be tried below.
    } on Error {
      // Missing assets are reported as FlutterError by some bundles.
    }
    final runtimeKey = '$runtimePrefix$relative';
    if (assets.contains(runtimeKey)) return runtimeKey;
    // Flutter compiles shader entries separately on some targets; they may be
    // loadable even when they do not appear in AssetManifest's ordinary list.
    if (relative == 'shaders/packed_alpha.frag') {
      for (final candidate in [key, runtimeKey]) {
        try {
          await selectedBundle.load(candidate);
          return candidate;
        } on Exception {
          // Try only the other known common shader key.
        } on Error {
          // AssetBundle can report an absent asset as FlutterError.
        }
      }
    }
    return key;
  }
}
