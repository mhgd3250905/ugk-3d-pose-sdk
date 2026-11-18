import 'dart:async';
import 'dart:typed_data';

import 'package:ugk_coach/ugk_coach.dart';

import '../media/catalog_media_repository_stub.dart'
    if (dart.library.io) '../media/catalog_media_repository_io.dart'
    as platform;
import '../media/catalog_media_repository_types.dart';
import 'pose_hub_action_library.dart';

/// Small image consumer of the same verified store used by catalogue media.
/// Images survive catalogue revisions: their namespace is their content SHA.
/// Every cache hit is checked by the store before it is returned to a widget.
class PoseHubImageCache {
  PoseHubImageCache({
    this.rootDirectory,
    this.allowInsecureLocalhost = false,
    this.timeout = const Duration(seconds: 15),
    this._loadBytes,
  });

  static final shared = PoseHubImageCache();

  final String? rootDirectory;
  final bool allowInsecureLocalhost;
  final Duration timeout;
  final Future<Uint8List> Function(Uri source, int maxBytes)? _loadBytes;
  final _pending = <String, Future<Uri>>{};

  Future<Uri> ensureFile(PoseHubPackFile file, {Uri? mediaBaseUri}) {
    final key = '${file.sha256}/${file.bytes}';
    if (_pending[key] case final pending?) return pending;
    final source = _source(file, mediaBaseUri);
    final job = _ensure(file, source);
    _pending[key] = job;
    unawaited(
      job.then<void>(
        (_) {
          _pending.remove(key);
        },
        onError: (Object _, StackTrace _) {
          _pending.remove(key);
        },
      ),
    );
    return job;
  }

  /// Looks up a verified image by content, including migratable legacy copies.
  /// This method makes no network request.
  Future<Uri?> findLocal(PoseHubPackFile file, {Uri? mediaBaseUri}) async {
    final store = await _openStore(file, _source(file, mediaBaseUri));
    try {
      return await store.cached(file) ?? await store.reusable(file);
    } finally {
      store.dispose();
    }
  }

  static Uri _source(PoseHubPackFile file, Uri? base) => base?.scheme == 'file'
      ? file.resolve(base!)
      : file.downloadUri ??
            file.resolve(
              base ?? Uri.parse(PoseHubActionLibrary.mediaReleaseBaseUri),
            );

  Future<CatalogMediaFileStore> _openStore(PoseHubPackFile file, Uri source) =>
      platform.createCatalogMediaStore(
        revision: file.sha256,
        packVersion: 'images',
        rootDirectory: rootDirectory,
        files: [file],
        videos: const [],
        mediaBaseUrls: source.scheme == 'file' ? [] : [source.resolve('.')],
        allowInsecureLocalhost: allowInsecureLocalhost,
        timeout: timeout,
        maxRedirects: 5,
        maxVideoCacheBytes: catalogVideoCacheLimitBytes,
        legacyCacheDirectory: null,
        legacyVideos: const [],
        contentOnly: true,
      );

  Future<Uri> _ensure(PoseHubPackFile file, Uri source) async {
    final store = await _openStore(file, source);
    try {
      final cached = await store.cached(file) ?? await store.reusable(file);
      if (cached != null) return cached;
      Future<Uri> fetch(Uri uri) async {
        final loadBytes = _loadBytes;
        if (loadBytes == null) {
          return store.download(file, uri, (_) {}, () {});
        }
        final bytes = await loadBytes(uri, file.bytes + 1);
        return store.bundled(file, bytes, (_) {}, () {});
      }

      if (source.scheme == 'file') {
        try {
          return await store.materialize(file, source);
        } catch (_) {
          if (file.downloadUri case final download?) {
            return await fetch(download);
          }
          rethrow;
        }
      }
      return await fetch(source);
    } finally {
      store.dispose();
    }
  }
}
