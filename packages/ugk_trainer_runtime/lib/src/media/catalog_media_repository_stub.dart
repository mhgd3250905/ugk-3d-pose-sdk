// Extracted from SmartFit 52d30ae; shared catalogue cache behavior.
import 'package:ugk_coach/ugk_coach.dart' as coach;

import 'catalog_media_repository_types.dart';

Future<CatalogMediaFileStore> createCatalogMediaStore({
  required String revision,
  required String packVersion,
  required String? rootDirectory,
  required List<coach.PoseHubPackFile> files,
  required List<coach.PoseHubPackFile> videos,
  required List<Uri> mediaBaseUrls,
  required bool allowInsecureLocalhost,
  required Duration timeout,
  required int maxRedirects,
  required int maxVideoCacheBytes,
  required String? legacyCacheDirectory,
  required List<CatalogLegacyVideoFile> legacyVideos,
}) => Future.error(
  const CatalogMediaException(
    'unsupported',
    'Persistent media is unavailable on this platform.',
  ),
);
