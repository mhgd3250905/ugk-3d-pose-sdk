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
  final root = directory ?? (await getApplicationSupportDirectory()).path;
  final managedRoot = Directory('$root/training-media');
  if (directory == null) await _migrateLegacyCache(managedRoot);
  return _NativeStorage(
    managedRoot,
    Directory('${managedRoot.path}/$version'),
    downloadTimeout,
  );
}

final _migrations = <String, Future<void>>{};
final _legacyVersion = RegExp(r'^\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.-]+)?$');
final _digestName = RegExp(r'^[a-f0-9]{64}$');

Future<void> _migrateLegacyCache(Directory managedRoot) =>
    _migrations.putIfAbsent(
      managedRoot.path,
      () => _copyLegacyCache(managedRoot).whenComplete(() {
        _migrations.remove(managedRoot.path);
      }),
    );

Future<void> _copyLegacyCache(Directory managedRoot) async {
  // Keep the marker through an explicit media clear, so deleted media stays
  // deleted. Legacy readers may still use the old cache while upgrading.
  final marker = File('${managedRoot.parent.path}/.training-media-migrated-v1');
  try {
    if (await marker.exists()) return;
    final cache = await getApplicationCacheDirectory();
    final legacy = Directory('${cache.path}/training-media');
    if (await _plainDirectory(legacy)) {
      await managedRoot.create(recursive: true);
      if (!await _plainDirectory(managedRoot)) return;
      final oldPath = await legacy.resolveSymbolicLinks();
      final newPath = await managedRoot.resolveSymbolicLinks();
      final sameDirectory = Platform.isWindows
          ? oldPath.toLowerCase() == newPath.toLowerCase()
          : oldPath == newPath;
      if (!sameDirectory) {
        await for (final entry in legacy.list(followLinks: false)) {
          if (entry is! Directory) continue;
          final segments = entry.uri.pathSegments;
          final version = segments[segments.length - 2];
          if (!_legacyVersion.hasMatch(version)) continue;
          final target = Directory('${managedRoot.path}/$version');
          await _copyLegacyVersion(entry, target);
        }
      }
    }
    await marker.create(recursive: true);
  } on MissingPlatformDirectoryException {
    // A platform can provide support storage without a legacy cache.
  } on FileSystemException {
    // Keep the verified copies already made and retry on the next open.
  }
}

Future<bool> _plainDirectory(Directory directory) async =>
    await FileSystemEntity.type(directory.path, followLinks: false) ==
    FileSystemEntityType.directory;

Future<void> _copyLegacyVersion(Directory source, Directory target) async {
  await target.create();
  if (!await _plainDirectory(target)) return;
  await for (final entry in source.list(followLinks: false)) {
    if (entry is! File) continue;
    final digest = entry.uri.pathSegments.last;
    if (!_digestName.hasMatch(digest)) continue;
    final length = await entry.length();
    if (length <= 0 || length > 128 * 1024 * 1024) continue;

    final destination = File('${target.path}/$digest');
    final type = await FileSystemEntity.type(
      destination.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      continue;
    }
    if (type == FileSystemEntityType.file &&
        await _matchesDigest(destination, length, digest)) {
      continue;
    }

    final temporary = await target.createTemp('.migration-');
    final part = File('${temporary.path}/payload.part');
    try {
      await entry.copy(part.path);
      if (await _matchesDigest(part, length, digest)) {
        await part.rename(destination.path);
      }
    } finally {
      if (await part.exists()) await part.delete();
      await temporary.delete();
    }
  }
}

Future<bool> _matchesDigest(File file, int bytes, String digest) async =>
    await file.length() == bytes &&
    (await sha256.bind(file.openRead()).first).toString() == digest;

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
      if (await _matchesDigest(target, file.bytes, file.sha256)) {
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
