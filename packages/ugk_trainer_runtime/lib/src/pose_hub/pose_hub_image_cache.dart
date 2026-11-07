import 'dart:async';

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
  });

  static final shared = PoseHubImageCache();

  final String? rootDirectory;
  final bool allowInsecureLocalhost;
  final Duration timeout;
  final _pending = <String, Future<Uri>>{};

  Future<Uri> ensureFile(PoseHubPackFile file, {Uri? mediaBaseUri}) {
    final key = '${file.sha256}/${file.bytes}/${file.path}';
    if (_pending[key] case final pending?) return pending;
    final source = mediaBaseUri?.scheme == 'file'
        ? file.resolve(mediaBaseUri!)
        : file.downloadUri ??
              file.resolve(
                mediaBaseUri ??
                    Uri.parse(PoseHubActionLibrary.mediaReleaseBaseUri),
              );
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

  Future<Uri> _ensure(PoseHubPackFile file, Uri source) async {
    final store = await platform.createCatalogMediaStore(
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
    );
    try {
      final cached = await store.cached(file);
      if (cached != null) return cached;
      if (source.scheme == 'file') {
        try {
          return await store.materialize(file, source);
        } catch (_) {
          if (file.downloadUri case final download?) {
            return await store.download(file, download, (_) {}, () {});
          }
          rethrow;
        }
      }
      return await store.download(file, source, (_) {}, () {});
    } finally {
      store.dispose();
    }
  }
}
