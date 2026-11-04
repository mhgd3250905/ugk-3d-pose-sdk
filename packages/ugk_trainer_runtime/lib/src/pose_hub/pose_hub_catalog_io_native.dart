import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'pose_hub_catalog_io_types.dart';

PoseHubCatalogHttpClient createPoseHubCatalogHttpClient({
  Duration timeout = const Duration(seconds: 20),
}) => _IoHttp(timeout);

PoseHubCatalogStore createPoseHubCatalogFileStore(String directory) =>
    _FileStore(directory);

class _IoHttp implements PoseHubCatalogHttpClient {
  _IoHttp(this.timeout);
  final Duration timeout;

  @override
  Future<PoseHubCatalogHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    int maxBytes = 64 * 1024 * 1024,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(timeout);
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        builder.add(chunk);
        if (builder.length > maxBytes) {
          throw const HttpException('Response exceeds its size limit');
        }
      }
      return PoseHubCatalogHttpResponse(
        response.statusCode,
        builder.takeBytes(),
        etag: response.headers.value(HttpHeaders.etagHeader),
      );
    } finally {
      client.close(force: true);
    }
  }
}

class _FileStore implements PoseHubCatalogStore {
  _FileStore(this.directory);
  final String directory;
  static final _random = Random();

  File _file(String name) {
    if (name.isEmpty ||
        name.startsWith('/') ||
        name.split('/').any((s) => s.isEmpty || s == '.' || s == '..')) {
      throw FormatException('Invalid cache name: $name');
    }
    return File('$directory/$name');
  }

  @override
  Future<Uint8List?> read(String name) async {
    final file = _file(name);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  Future<List<String>> list(String directory) async {
    final dir = Directory(_file(directory).path);
    if (!await dir.exists()) return const [];
    return [
      await for (final entity in dir.list())
        entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
    ];
  }

  @override
  Future<void> delete(String name) async {
    final path = _file(name).path;
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    await (type == FileSystemEntityType.directory
            ? Directory(path)
            : File(path))
        .delete(recursive: true);
  }

  @override
  Future<void> writeAtomic(String name, List<int> bytes) async {
    final target = _file(name);
    await target.parent.create(recursive: true);
    final temp = File(
      '${target.path}.tmp-${DateTime.now().microsecondsSinceEpoch}'
      '-${_random.nextInt(1 << 32)}',
    );
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(target.path);
    } catch (_) {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }
}
