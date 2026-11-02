// Extracted from SmartFit 52d30ae; shared catalogue cache behavior.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;

import 'catalog_media_repository_types.dart';

final _caches = <String, CatalogGlobalVideoCache>{};

String _pathKey(String path) =>
    Platform.isWindows ? path.replaceAll('/', '\\').toLowerCase() : path;

/// One publication queue and set of playing pins for every catalogue/version.
CatalogGlobalVideoCache catalogGlobalVideoCache(Directory root) => _caches
    .putIfAbsent(_pathKey(root.path), () => CatalogGlobalVideoCache(root));

class CatalogPublishedVideo {
  const CatalogPublishedVideo({
    required this.identity,
    required this.relative,
    required this.root,
    required this.file,
    required this.stat,
    required this.owned,
  });

  final String identity;
  final String relative;
  final Directory root;
  final File file;
  final FileStat stat;
  final bool owned;
}

class _Owner {
  const _Owner(this.bytes, this.sha256);
  final int bytes;
  final String sha256;
}

class CatalogGlobalVideoCache {
  CatalogGlobalVideoCache(this.root);

  final Directory root;
  final pins = <String, int>{};
  final _limits = <Object, int>{};
  final _owners = <String, _Owner>{};
  final _legacyOwners = <String, _Owner>{};
  final _trusted = <String, _Owner>{};
  final _legacy = <String, (Directory, Map<String, _Owner>)>{};
  final _random = Random.secure();
  Future<void> _tail = Future<void>.value();
  DateTime _lastUse = DateTime.fromMillisecondsSinceEpoch(0);
  static const _indexName = 'video-cache-owners-v1.json';

  Future<T> ordered<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void Function() attach(int limit) {
    final token = Object();
    _limits[token] = limit;
    return () => _limits.remove(token);
  }

  int get _limit => _limits.values.fold(catalogVideoCacheLimitBytes, min);

  void observe(DateTime value) {
    if (value.isAfter(_lastUse)) _lastUse = value;
  }

  DateTime nextUse() {
    final now = DateTime.now();
    final next = _lastUse.add(const Duration(milliseconds: 1));
    _lastUse = now.isAfter(next) ? now : next;
    return _lastUse;
  }

  static bool _videoPath(String path) {
    final parts = path.split('/');
    final oldNamespace =
        parts.length >= 4 &&
        RegExp(r'^[a-f0-9]{64}$').hasMatch(parts[0]) &&
        parts[1] == 'media';
    final currentNamespace =
        parts.length >= 5 &&
        parts[0].length <= 64 &&
        RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(parts[0]) &&
        RegExp(r'^[a-f0-9]{64}$').hasMatch(parts[1]) &&
        parts[2] == 'media';
    return (oldNamespace || currentNamespace) &&
        path.length <= 1155 &&
        !RegExp(r'[\\:%?#\x00-\x20\x7f]').hasMatch(path) &&
        !parts.any(
          (p) => p.isEmpty || p == '.' || p == '..' || p.endsWith('.'),
        ) &&
        path.toLowerCase().endsWith('.mp4');
  }

  static Never _unsafe() => throw const CatalogMediaException(
    'unsafe_cache',
    'Media cache path or ownership record is invalid.',
  );

  /// All components, including a possibly replaced root, are checked at commit.
  File safeFile(Directory boundary, String relative) {
    if (relative.isEmpty ||
        relative.startsWith('/') ||
        RegExp(r'[\\:\x00-\x20\x7f]').hasMatch(relative) ||
        relative.split('/').any((p) => p.isEmpty || p == '.' || p == '..')) {
      _unsafe();
    }
    if (FileSystemEntity.typeSync(boundary.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        _pathKey(boundary.resolveSymbolicLinksSync()) !=
            _pathKey(boundary.path)) {
      _unsafe();
    }
    var path = boundary.path;
    final parts = relative.split('/');
    for (var i = 0; i < parts.length; i++) {
      path = '$path${Platform.pathSeparator}${parts[i]}';
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.link ||
          (type != FileSystemEntityType.notFound &&
              type !=
                  (i == parts.length - 1
                      ? FileSystemEntityType.file
                      : FileSystemEntityType.directory))) {
        _unsafe();
      }
      if (type != FileSystemEntityType.notFound &&
          !_pathKey(
            File(path).resolveSymbolicLinksSync(),
          ).startsWith('${_pathKey(boundary.path)}${Platform.pathSeparator}')) {
        _unsafe();
      }
    }
    return File(path);
  }

  void _loadOwners() {
    final index = safeFile(root, _indexName);
    if (!index.existsSync()) {
      _owners.clear();
      _legacyOwners.clear();
      return;
    }
    try {
      if (index.lengthSync() > 8 * 1024 * 1024) _unsafe();
      final parsed =
          jsonDecode(index.readAsStringSync()) as Map<String, Object?>;
      if (parsed['format'] != 'smartfit-video-cache-owners@1') _unsafe();
      final owners = <String, _Owner>{};
      for (final entry
          in (parsed['videos'] as List<Object?>).cast<Map<String, Object?>>()) {
        final path = entry['relative'] as String;
        final size = entry['bytes'] as int;
        final hash = entry['sha256'] as String;
        if (!_videoPath(path) ||
            size <= 0 ||
            size > 128 * 1024 * 1024 ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
            owners.containsKey(path)) {
          _unsafe();
        }
        owners[path] = _Owner(size, hash);
      }
      _owners
        ..clear()
        ..addAll(owners);
      final legacyOwners = <String, _Owner>{};
      for (final entry
          in ((parsed['legacyVideos'] as List<Object?>?) ?? const [])
              .cast<Map<String, Object?>>()) {
        final path = entry['relative'] as String;
        final size = entry['bytes'] as int;
        final hash = entry['sha256'] as String;
        if (!RegExp(
              r'^[a-f0-9]{64}/\d+\.\d+\.\d+/[a-f0-9]{64}$',
            ).hasMatch(path) ||
            size <= 0 ||
            size > 128 * 1024 * 1024 ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
            !path.endsWith('/$hash') ||
            legacyOwners.containsKey(path)) {
          _unsafe();
        }
        legacyOwners[path] = _Owner(size, hash);
      }
      _legacyOwners
        ..clear()
        ..addAll(legacyOwners);
    } on CatalogMediaException {
      rethrow;
    } on Object {
      _unsafe();
    }
  }

  void _saveOwners() {
    final index = safeFile(root, _indexName);
    final tempName =
        '$_indexName.${pid}_${DateTime.now().microsecondsSinceEpoch}_${_random.nextInt(1 << 32)}.part';
    final temp = safeFile(root, tempName);
    final paths = _owners.keys.toList()..sort();
    final json = jsonEncode({
      'format': 'smartfit-video-cache-owners@1',
      'videos': [
        for (final path in paths)
          {
            'relative': path,
            'bytes': _owners[path]!.bytes,
            'sha256': _owners[path]!.sha256,
          },
      ],
      'legacyVideos': [
        for (final path in (_legacyOwners.keys.toList()..sort()))
          {
            'relative': path,
            'bytes': _legacyOwners[path]!.bytes,
            'sha256': _legacyOwners[path]!.sha256,
          },
      ],
    });
    try {
      temp.createSync(exclusive: true);
      temp.writeAsStringSync('$json\n', flush: true);
      safeFile(root, _indexName);
      temp.renameSync(index.path);
    } finally {
      if (temp.existsSync()) temp.deleteSync();
    }
  }

  Future<void> initialize({
    required String namespace,
    required List<coach.PoseHubPackFile> videos,
    required Directory? legacyRoot,
    required List<CatalogLegacyVideoFile> legacyVideos,
  }) async {
    _loadOwners();
    for (final file in videos) {
      final relative = '$namespace/${file.path}';
      if (!_videoPath(relative)) _unsafe();
      final owner = _Owner(file.bytes, file.sha256);
      _owners[relative] = owner;
      _trusted['${owner.bytes}/${owner.sha256}'] = owner;
    }
    if (legacyRoot != null) {
      final known = _legacy
          .putIfAbsent(_pathKey(legacyRoot.path), () => (legacyRoot, {}))
          .$2;
      for (final file in legacyVideos) {
        if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(file.version) ||
            file.bytes <= 0 ||
            file.bytes > 128 * 1024 * 1024 ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(file.sha256)) {
          _unsafe();
        }
        final key = '${file.version}/${file.sha256}';
        final previous = known[key];
        if (previous != null && previous.bytes != file.bytes) _unsafe();
        known[key] = _Owner(file.bytes, file.sha256);
      }
    }
    _saveOwners();
    final entries = await publishedVideos();
    try {
      makeRoom(entries);
    } on CatalogMediaException catch (error) {
      if (error.code != 'cache_full') rethrow;
      // An older cache can exceed the budget because unknown files or playing
      // pins must survive. Keep verified reads, usage and clear available;
      // publication still requires makeRoom's complete, non-destructive check.
    }
  }

  Future<bool> _matches(File file, _Owner expected, FileStat stat) async =>
      stat.size == expected.bytes &&
      (await sha256.bind(file.openRead()).first).toString() == expected.sha256;

  Future<List<CatalogPublishedVideo>> publishedVideos() async {
    final result = <CatalogPublishedVideo>[];
    safeFile(root, _indexName);
    var adopted = false;
    Future<void> scanMedia(String mediaRelative) async {
      final media = Directory('${root.path}/$mediaRelative');
      final type = FileSystemEntity.typeSync(media.path, followLinks: false);
      if (type == FileSystemEntityType.link) _unsafe();
      if (type != FileSystemEntityType.directory) return;
      safeFile(root, '$mediaRelative/.path-check');
      await for (final entity in media.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is Link) _unsafe();
        if (entity is! File || !entity.path.toLowerCase().endsWith('.mp4')) {
          continue;
        }
        final relative = entity.path
            .substring(root.path.length + 1)
            .replaceAll('\\', '/');
        if (!_videoPath(relative)) continue;
        final file = safeFile(root, relative);
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        if (!_owners.containsKey(relative) &&
            _trusted.values.any((o) => o.bytes == stat.size)) {
          final digest = (await sha256.bind(file.openRead()).first).toString();
          final trusted = _trusted['${stat.size}/$digest'];
          if (trusted != null) {
            _owners[relative] = trusted;
            adopted = true;
          }
        }
        observe(stat.modified);
        result.add(
          CatalogPublishedVideo(
            identity: relative,
            relative: relative,
            root: root,
            file: file,
            stat: stat,
            owned: _owners.containsKey(relative),
          ),
        );
      }
    }

    await for (final version in root.list(followLinks: false)) {
      final name = version.uri.pathSegments.where((p) => p.isNotEmpty).last;
      if (!RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(name) ||
          name.length > 64) {
        continue;
      }
      if (version is Link) _unsafe();
      if (version is! Directory) continue;
      // The original App cache predated packVersion directory isolation.
      if (RegExp(r'^[a-f0-9]{64}$').hasMatch(name)) {
        await scanMedia('$name/media');
      }
      await for (final revision in version.list(followLinks: false)) {
        final hash = revision.uri.pathSegments.where((p) => p.isNotEmpty).last;
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) continue;
        if (revision is Link) _unsafe();
        if (revision is! Directory) continue;
        await scanMedia('$name/$hash/media');
      }
    }
    for (final (legacyRoot, known) in _legacy.values) {
      final rootId = sha256
          .convert(utf8.encode(_pathKey(legacyRoot.path)))
          .toString();
      final rootType = FileSystemEntity.typeSync(
        legacyRoot.path,
        followLinks: false,
      );
      if (rootType == FileSystemEntityType.notFound) continue;
      if (rootType != FileSystemEntityType.directory ||
          _pathKey(legacyRoot.resolveSymbolicLinksSync()) !=
              _pathKey(legacyRoot.path)) {
        _unsafe();
      }
      await for (final version in legacyRoot.list(followLinks: false)) {
        final name = version.uri.pathSegments.where((p) => p.isNotEmpty).last;
        if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(name)) continue;
        if (version is Link) _unsafe();
        if (version is! Directory) continue;
        await for (final entry in version.list(followLinks: false)) {
          if (entry is Link) _unsafe();
          if (entry is! File) continue;
          final filename = entry.uri.pathSegments.last;
          // SDK published objects have SHA names. JSON/images with a known
          // non-video SHA remain unowned; no filename-only deletion is allowed.
          if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(filename)) continue;
          final relative = '$name/$filename';
          final file = safeFile(legacyRoot, relative);
          final stat = await file.stat();
          if (stat.type != FileSystemEntityType.file) continue;
          final expected = known[relative];
          final key = '$rootId/$relative';
          final recorded = _legacyOwners[key];
          if (expected != null &&
              recorded != null &&
              (recorded.bytes != expected.bytes ||
                  recorded.sha256 != expected.sha256)) {
            _unsafe();
          }
          // The persisted receipt remains useful after a later catalogue drops
          // this legacy version; its path and content were verified on adoption.
          var owned = recorded != null && stat.size == recorded.bytes;
          if (!owned &&
              expected != null &&
              await _matches(file, expected, stat)) {
            _legacyOwners[key] = expected;
            adopted = true;
            owned = true;
          }
          observe(stat.modified);
          result.add(
            CatalogPublishedVideo(
              identity: 'legacy:${_pathKey(legacyRoot.path)}/$relative',
              relative: relative,
              root: legacyRoot,
              file: file,
              stat: stat,
              owned: owned,
            ),
          );
        }
      }
    }
    if (adopted) _saveOwners();
    return result;
  }

  void makeRoom(
    List<CatalogPublishedVideo> entries, {
    String? incoming,
    int incomingBytes = 0,
  }) {
    var bytes = entries.fold<int>(0, (n, e) => n + e.stat.size);
    if (incoming != null) {
      bytes -= entries
          .where((e) => e.identity == incoming)
          .fold<int>(0, (n, e) => n + e.stat.size);
      bytes += incomingBytes;
    }
    if (bytes <= _limit) return;
    final candidates =
        entries
            .where(
              (e) =>
                  e.owned &&
                  e.identity != incoming &&
                  !pins.containsKey(e.identity),
            )
            .toList()
          ..sort((a, b) {
            final modified = a.stat.modified.compareTo(b.stat.modified);
            return modified != 0 ? modified : a.identity.compareTo(b.identity);
          });
    final victims = <File>[];
    for (final entry in candidates) {
      victims.add(safeFile(entry.root, entry.relative));
      bytes -= entry.stat.size;
      if (bytes <= _limit) break;
    }
    if (bytes > _limit) {
      throw const CatalogMediaException(
        'cache_full',
        'Video download storage is full while videos are in use or unknown files are retained.',
      );
    }
    // Pins cannot interleave between the complete eviction plan and publication.
    for (final victim in victims) {
      victim.deleteSync();
    }
  }

  Future<int> bytes() async =>
      (await publishedVideos()).fold<int>(0, (n, e) => n + e.stat.size);

  Future<void> clear() async {
    final entries = await publishedVideos();
    final victims = [
      for (final entry in entries)
        if (entry.owned && !pins.containsKey(entry.identity))
          safeFile(entry.root, entry.relative),
    ];
    for (final file in victims) {
      file.deleteSync();
    }
  }
}
