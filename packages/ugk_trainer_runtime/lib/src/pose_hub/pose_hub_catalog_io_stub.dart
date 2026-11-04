import 'pose_hub_catalog_io_types.dart';

PoseHubCatalogHttpClient createPoseHubCatalogHttpClient({
  Duration timeout = const Duration(seconds: 20),
}) => const _UnsupportedHttp();

PoseHubCatalogStore createPoseHubCatalogFileStore(String directory) =>
    throw UnsupportedError('File catalogue cache is unavailable here.');

class _UnsupportedHttp implements PoseHubCatalogHttpClient {
  const _UnsupportedHttp();
  @override
  Future<PoseHubCatalogHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    int maxBytes = 64 * 1024 * 1024,
  }) => Future.error(UnsupportedError('HTTP is unavailable on this platform.'));
}
