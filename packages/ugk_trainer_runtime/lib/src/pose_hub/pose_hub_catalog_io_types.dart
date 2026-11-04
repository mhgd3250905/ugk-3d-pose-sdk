import 'dart:typed_data';

/// Minimal HTTP surface used by the catalogue updater; tests supply fakes.
abstract interface class PoseHubCatalogHttpClient {
  /// Returns the full body. [maxBytes] aborts a larger response.
  Future<PoseHubCatalogHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    int maxBytes = 64 * 1024 * 1024,
  });
}

class PoseHubCatalogHttpResponse {
  const PoseHubCatalogHttpResponse(this.statusCode, this.body, {this.etag});
  final int statusCode;
  final Uint8List body;
  final String? etag;
}

/// Key/value storage for verified catalogue files. [writeAtomic] must never
/// leave a partially written value under [name].
abstract interface class PoseHubCatalogStore {
  Future<Uint8List?> read(String name);
  Future<void> writeAtomic(String name, List<int> bytes);
}

/// In-memory store for tests and hosts without a file system.
class MemoryPoseHubCatalogStore implements PoseHubCatalogStore {
  final Map<String, Uint8List> values = {};
  @override
  Future<Uint8List?> read(String name) async => values[name];
  @override
  Future<void> writeAtomic(String name, List<int> bytes) async {
    values[name] = Uint8List.fromList(bytes);
  }
}
