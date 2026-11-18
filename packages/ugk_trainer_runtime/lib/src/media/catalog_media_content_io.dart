import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'catalog_global_video_cache_io.dart';
import 'catalog_hard_link_io.dart';

final _contents = <String, CatalogMediaContent>{};
final _sha = RegExp(r'^[a-f0-9]{64}$');
final _contentName = RegExp(r'^([a-f0-9]{64})(?:\.mp4)?$');
final _pack = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');
final _legacyVersion = RegExp(r'^\d+\.\d+\.\d+$');

CatalogMediaContent catalogMediaContent(Directory root) =>
    _contents.putIfAbsent(root.path, () => CatalogMediaContent(root));

Future<bool> catalogFileMatches(File file, PoseHubPackFile expected) async {
  try {
    return await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.file &&
        await file.length() == expected.bytes &&
        (await sha256.bind(file.openRead()).first).toString() ==
            expected.sha256;
  } on FileSystemException {
    return false;
  }
}

class CatalogMediaContent {
  CatalogMediaContent(this.root);

  final Directory root;
  final _active = <Object, Set<String>>{};
  final _random = Random.secure();
  Future<Map<int, List<String>>>? _legacyMedia;

  CatalogGlobalVideoCache get _videos => catalogGlobalVideoCache(root);

  File file(PoseHubPackFile descriptor, {required bool video}) =>
      _videos.safeFile(
        root,
        video
            ? catalogVideoContentPath(descriptor.sha256)
            : 'content/${descriptor.sha256}',
      );

  void Function() attach(Iterable<PoseHubPackFile> files) {
    final key = Object();
    _active[key] = files.map((file) => file.sha256).toSet();
    return () => _active.remove(key);
  }

  Future<File?> findLegacy(
    PoseHubPackFile descriptor,
    List<Directory> legacyTrainingRoots,
  ) async {
    for (final training in legacyTrainingRoots) {
      if (await FileSystemEntity.type(training.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      await for (final version in training.list(followLinks: false)) {
        if (version is! Directory || !_legacyVersion.hasMatch(_name(version))) {
          continue;
        }
        final candidate = _videos.safeFile(
          training,
          '${_name(version)}/${descriptor.sha256}',
        );
        if (await catalogFileMatches(candidate, descriptor)) return candidate;
      }
    }
    final bySize = await (_legacyMedia ??= _scanLegacyMedia());
    for (final name in bySize[descriptor.bytes] ?? const <String>[]) {
      final candidate = _videos.safeFile(root, name);
      if (await catalogFileMatches(candidate, descriptor)) return candidate;
    }
    return null;
  }

  Future<Map<int, List<String>>> _scanLegacyMedia() async {
    final result = <int, List<String>>{};
    await for (final media in _legacyMediaDirectories()) {
      await for (final entry in media.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entry is! File || entry.path.endsWith('.part')) continue;
        final stat = await entry.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        (result[stat.size] ??= []).add(_relative(entry));
      }
    }
    return result;
  }

  Stream<Directory> _legacyMediaDirectories() async* {
    await for (final pack in root.list(followLinks: false)) {
      if (pack is! Directory ||
          !_pack.hasMatch(_name(pack)) ||
          _name(pack).length > 64 ||
          _name(pack) == 'content') {
        continue;
      }
      if (_sha.hasMatch(_name(pack))) {
        final media = Directory('${pack.path}/media');
        if (await FileSystemEntity.type(media.path, followLinks: false) ==
            FileSystemEntityType.directory) {
          yield media;
        }
      }
      await for (final revision in pack.list(followLinks: false)) {
        if (revision is! Directory || !_sha.hasMatch(_name(revision))) continue;
        final media = Directory('${revision.path}/media');
        if (await FileSystemEntity.type(media.path, followLinks: false) ==
            FileSystemEntityType.directory) {
          yield media;
        }
      }
    }
  }

  /// Both names are inside the application's private storage, and the caller
  /// has verified the source. A temporary sibling makes replacement atomic.
  void linkOrCopy(File source, File destination) {
    final temp = File(
      '${destination.path}.${pid}_${DateTime.now().microsecondsSinceEpoch}_${_random.nextInt(1 << 32)}.part',
    );
    try {
      if (!tryCatalogHardLink(source, temp)) source.copySync(temp.path);
      temp.renameSync(destination.path);
    } finally {
      if (temp.existsSync()) temp.deleteSync();
    }
  }

  Future<void> prune(
    Set<String> keepSha256,
    Iterable<PoseHubPackFile> retiredFiles,
  ) => _videos.ordered(() async {
    final retiredByPath = <String, Map<int, Set<String>>>{};
    for (final file in retiredFiles) {
      if (keepSha256.contains(file.sha256)) continue;
      ((retiredByPath[file.path] ??= {})[file.bytes] ??= {}).add(file.sha256);
    }
    final contentDir = Directory('${root.path}/content');
    _videos.safeFile(root, 'content/.path-check');
    final obsolete = <int, Set<String>>{};
    final obsoleteNames = <String, String>{};
    if (await contentDir.exists()) {
      await for (final entry in contentDir.list(followLinks: false)) {
        final name = _name(entry);
        final match = _contentName.firstMatch(name);
        if (entry is! File || match == null) continue;
        final hash = match.group(1)!;
        if (_retain(hash, keepSha256)) continue;
        (obsolete[await entry.length()] ??= {}).add(hash);
        obsoleteNames[name] = hash;
      }
    }
    if (obsolete.isEmpty && retiredByPath.isEmpty) return;
    // Remove compatibility paths for obsolete objects. Legacy bytes that
    // never entered CAS also qualify if their path, size and SHA match a
    // retired catalogue. Unknown files are left alone.
    await for (final media in _legacyMediaDirectories()) {
      await for (final entry in media.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entry is! File) continue;
        try {
          final alias = _videos.safeFile(root, _relative(entry));
          final size = await alias.length();
          final mediaRelative = entry.path
              .substring(media.path.length + 1)
              .replaceAll('\\', '/');
          final retired = retiredByPath['media/$mediaRelative']?[size];
          final candidates = obsolete[size];
          if (candidates == null && retired == null) continue;
          final hash = (await sha256.bind(alias.openRead()).first).toString();
          if ((candidates?.contains(hash) == true ||
                  retired?.contains(hash) == true) &&
              !_retain(hash, keepSha256)) {
            alias.deleteSync();
          }
        } on FileSystemException {
          // A concurrent reader/previous cleanup may have removed an alias.
        }
      }
    }
    for (final entry in obsoleteNames.entries) {
      if (_retain(entry.value, keepSha256)) continue;
      final target = _videos.safeFile(root, 'content/${entry.key}');
      if (target.existsSync()) target.deleteSync();
    }
    _legacyMedia = null;
  });

  bool _retain(String hash, Set<String> keepSha256) =>
      keepSha256.contains(hash) ||
      _videos.pins.containsKey(catalogVideoContentPath(hash)) ||
      _active.values.any((files) => files.contains(hash));

  String _relative(FileSystemEntity file) =>
      file.path.substring(root.path.length + 1).replaceAll('\\', '/');

  String _name(FileSystemEntity file) =>
      file.uri.pathSegments.where((part) => part.isNotEmpty).last;
}
