import 'package:path_provider/path_provider.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../voice/catalog_voice_source.dart';
import '../voice/voice_source.dart';
import 'pose_hub_action_library.dart';
import 'pose_hub_catalog_io_types.dart';

Future<String> _voiceDirectory(String? assetRootDirectory) async {
  final root =
      assetRootDirectory ?? (await getApplicationSupportDirectory()).path;
  return '$root/ugk_catalog_voice';
}

CatalogVoiceIndex _voiceIndex(
  PoseHubAppTestCatalog catalog, {
  bool requireValidFiles = false,
}) => CatalogVoiceIndex.fromCatalogJson(
  catalog.raw,
  baseUrl: PoseHubActionLibrary.mediaBaseUriFor(catalog),
  requireValidFiles: requireValidFiles,
);

/// Explicitly prepares all published voice clips for offline training.
/// The player can reuse the verified files by content hash.
Future<void> preparePoseHubCatalogVoice(
  PoseHubAppTestCatalog catalog, {
  String? assetRootDirectory,
  PoseHubCatalogHttpClient? http,
}) async {
  final index = _voiceIndex(catalog, requireValidFiles: true);
  final clips = index.allClips.toList();
  if (clips.isEmpty) return;
  final cache = CatalogVoiceCache.files(
    await _voiceDirectory(assetRootDirectory),
    http: http,
  );
  final result = await cache.prefetch(clips, parallel: 8);
  if (result.failed.isNotEmpty) {
    throw StateError(
      '${result.failed.length} Pose-Hub voice clips failed verification '
      '(first: ${result.failed.first}).',
    );
  }
}

/// Call after activation to drop voice objects no retained catalogue uses.
Future<void> prunePoseHubCatalogVoice(
  Iterable<PoseHubAppTestCatalog> keep, {
  String? assetRootDirectory,
}) async {
  final cache = CatalogVoiceCache.files(
    await _voiceDirectory(assetRootDirectory),
  );
  await cache.prune(keep.expand((catalog) => _voiceIndex(catalog).allClips));
}

/// The app's own voice ([primary]) with the active Pose-Hub catalogue's
/// recorded lines behind it. Opening an action lets the player verify and
/// reuse the clips in application support or fetch the missing recordings.
///
/// [catalog] defaults to [PoseHubActionLibrary.load]. If the updater uses
/// a custom application support root, pass the same [assetRootDirectory].
/// [cacheDirectory] overrides the voice cache directory itself.
Future<VoiceSource> withPoseHubCatalogVoice(
  VoiceSource primary, {
  PoseHubAppTestCatalog? catalog,
  String? cacheDirectory,
  String? assetRootDirectory,
}) async {
  try {
    final c = catalog ?? await PoseHubActionLibrary.load();
    final dir = cacheDirectory ?? await _voiceDirectory(assetRootDirectory);
    return LayeredVoiceSource(
      primary: primary,
      catalog: _voiceIndex(c),
      cache: CatalogVoiceCache.files(dir),
    );
  } catch (_) {
    return primary;
  }
}
