import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'training_media_models.dart';
import 'training_media_storage.dart';

Future<TrainingMediaStorage> createStorage(
  String version,
  String? directory,
  Duration downloadTimeout,
) async {
  final root = directory ?? (await getApplicationCacheDirectory()).path;
  return _NativeStorage(
    Directory('$root/training-media'),
    Directory('$root/training-media/$version'),
    downloadTimeout,
  );
}

class _NativeStorage implements TrainingMediaStorage {
  _NativeStorage(this.managedRoot, this.directory, this.downloadTimeout);

  /// Owned media cache only; sibling app caches are outside this boundary.
  final Directory managedRoot;
  final Directory directory;
  final Duration downloadTimeout;
  final Set<HttpClient> _clients = {};
  int _generation = 0;
  int _sequence = 0;
  File _file(TrainingMediaFile file) =>
      File('${directory.path}/${file.sha256}');

  @override
  Future<TrainingMediaCacheEntry?> cached(TrainingMediaFile file) async {
    final target = _file(file);
    try {
      if (await target.length() == file.bytes &&
          (await sha256.bind(target.openRead()).first).toString() ==
              file.sha256) {
        return TrainingMediaCacheEntry(target.path);
      }
      await target.delete();
    } on FileSystemException {
      /* A missing/evicted cache is a normal miss. */
    }
    return null;
  }

  @override
  Future<TrainingMediaCacheEntry> download(
    TrainingMediaFile file,
    List<Uri> urls, {
    required Future<void> Function() checkPolicy,
    required void Function(int) onProgress,
  }) async {
    final generation = _generation;
    await checkPolicy();
    Object failure = const HttpException('No media mirror configured');
    for (final url in urls) {
      if (generation != _generation) throw StateError('Download cancelled');
      await checkPolicy();
      final client = HttpClient()..connectionTimeout = downloadTimeout;
      _clients.add(client);
      final part = File('${_file(file).path}.${_sequence++}.part');
      IOSink? sink;
      try {
        await directory.create(recursive: true);
        final request = await client.getUrl(url).timeout(downloadTimeout);
        request.followRedirects = false;
        final response = await request.close().timeout(downloadTimeout);
        if (response.statusCode != HttpStatus.ok ||
            (response.contentLength >= 0 &&
                response.contentLength != file.bytes)) {
          throw const HttpException('Media response size/status mismatch');
        }
        sink = part.openWrite();
        var received = 0;
        var lastPolicyCheck = DateTime.now();
        await for (final chunk in response.timeout(downloadTimeout)) {
          if (generation != _generation) throw StateError('Download cancelled');
          if (DateTime.now().difference(lastPolicyCheck).inSeconds >= 1) {
            await checkPolicy();
            lastPolicyCheck = DateTime.now();
          }
          received += chunk.length;
          if (received > file.bytes) {
            throw const FormatException('Media exceeds declared size');
          }
          sink.add(chunk);
          // Bound sink buffering even with a fast local mirror.
          await sink.flush();
          onProgress(received);
        }
        await sink.close();
        sink = null;
        await checkPolicy();
        if (received != file.bytes ||
            (await sha256.bind(part.openRead()).first).toString() !=
                file.sha256) {
          throw const FormatException('Media SHA-256 verification failed');
        }
        if (generation != _generation) throw StateError('Download cancelled');
        final completed = await part.rename(_file(file).path);
        return TrainingMediaCacheEntry(completed.path);
      } catch (error) {
        failure = error;
      } finally {
        await sink?.close();
        client.close(force: true);
        _clients.remove(client);
        if (await part.exists()) await part.delete();
      }
    }
    throw failure;
  }

  @override
  Future<Uint8List> read(TrainingMediaCacheEntry entry) =>
      File(entry.path).readAsBytes();
  @override
  Future<int> bytes() async {
    var total = 0;
    try {
      await for (final entity in managedRoot.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File && !entity.path.endsWith('.part')) {
          try {
            total += await entity.length();
          } on FileSystemException {
            // A clear/eviction can remove a file after directory enumeration.
          }
        }
      }
    } on FileSystemException {
      // This is a snapshot: the entire root or a listed version may disappear.
    }
    return total;
  }

  @override
  void cancel() {
    _generation++;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
  }

  @override
  Future<void> clear() async {
    try {
      await managedRoot.delete(recursive: true);
    } on PathNotFoundException {
      // Concurrent eviction or an empty first-run cache already did the work.
    }
  }

  @override
  void dispose() => cancel();
}
