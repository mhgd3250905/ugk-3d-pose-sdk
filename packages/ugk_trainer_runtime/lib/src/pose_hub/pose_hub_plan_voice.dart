import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path_provider/path_provider.dart';

import 'pose_hub_catalog_io_stub.dart'
    if (dart.library.io) 'pose_hub_catalog_io_native.dart'
    as platform;
import 'pose_hub_catalog_io_types.dart';

/// One verified audio receipt listed in a channel plan's voice manifest.
final class PoseHubPlanVoiceFile {
  const PoseHubPlanVoiceFile._(this.path, this.url, this.bytes, this.sha256);

  final String path;
  final Uri url;
  final int bytes;
  final String sha256;

  // Keep the format suffix for native audio decoders.
  String get _cacheName {
    final extension = RegExp(r'\.[a-zA-Z0-9]{1,8}$').firstMatch(path)?.group(0);
    return 'channel-plan-voice/${sha256.substring(0, 2)}/$sha256${extension?.toLowerCase() ?? ''}';
  }

  bool _matches(List<int> data) =>
      data.length == bytes && crypto.sha256.convert(data).toString() == sha256;
}

/// Voice receipts and optional per-plan clip groups. The SDK does not need
/// to interpret the host's plan JSON to prepare the voice for its plan.
final class PoseHubPlanVoiceManifest {
  PoseHubPlanVoiceManifest._(this.files, this.plans);

  /// Parses schema 1:
  /// `{"schema":1,"files":[{"path":"zh/ready.m4a","bytes":123,"sha256":"..."}]}`.
  /// An entry may override its URL with `url`. When present, `plans` maps
  /// plan IDs to lists of paths already declared in `files`.
  ///
  /// The published `pose-hub-plan-voice@1` uses `lines` with `file` paths
  /// and origin-relative `objectKey` download locations.
  factory PoseHubPlanVoiceManifest.fromBytes(
    List<int> bytes, {
    required Uri manifestUri,
  }) {
    if (!_isPublicHttps(manifestUri)) {
      throw const FormatException('Plan voice manifest URL must use HTTPS.');
    }
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, Object?>) {
      throw const FormatException('Invalid plan voice manifest.');
    }
    final published = json['format'] == 'pose-hub-plan-voice@1';
    if (json.containsKey('format') && !published) {
      throw const FormatException('Unsupported plan voice manifest format.');
    }
    final records = json[published ? 'lines' : 'files'];
    if ((!published && (json['schema'] is! int || json['schema'] != 1)) ||
        records is! List<Object?>) {
      throw const FormatException('Invalid plan voice manifest.');
    }
    final count = json['count'];
    if (published &&
        json.containsKey('count') &&
        (count is! int || count != records.length)) {
      throw const FormatException('Plan voice manifest count mismatch.');
    }

    final origin = Uri.parse('${manifestUri.origin}/');
    final files = <String, PoseHubPlanVoiceFile>{};
    final sizes = <String, int>{};
    for (final data in records) {
      if (data is! Map) {
        throw const FormatException('Invalid plan voice file receipt.');
      }
      final path = data[published ? 'file' : 'path'];
      final sha = data['sha256'];
      final size = data['bytes'];
      final location = data[published ? 'objectKey' : 'url'];
      if (path is! String ||
          !_isRelativePath(path) ||
          sha is! String ||
          !_sha256.hasMatch(sha) ||
          size is! int ||
          size < 1 ||
          size > 64 * 1024 * 1024 ||
          (published
              ? location is! String || !_isRelativePath(location)
              : data.containsKey('url') && location is! String)) {
        throw const FormatException('Invalid plan voice file receipt.');
      }
      final reference = Uri.tryParse(location as String? ?? path);
      if (reference == null || reference.toString().isEmpty) {
        throw FormatException('Invalid plan voice file URL for $path.');
      }
      final url = (published ? origin : manifestUri).resolveUri(reference);
      if (!_isPublicHttps(url)) {
        throw FormatException('Plan voice file URL must use HTTPS for $path.');
      }
      if (files.containsKey(path) ||
          (sizes.containsKey(sha) && sizes[sha] != size)) {
        throw FormatException('Conflicting plan voice file receipt for $path.');
      }
      sizes[sha] = size;
      files[path] = PoseHubPlanVoiceFile._(path, url, size, sha);
    }
    final groups = <String, List<String>>{};
    if (json.containsKey('plans')) {
      final plans = json['plans'];
      if (plans is! Map) {
        throw const FormatException('Invalid plan voice groups.');
      }
      for (final entry in plans.entries) {
        final id = entry.key;
        final paths = entry.value;
        if (id is! String || id.trim().isEmpty || paths is! List) {
          throw const FormatException('Invalid plan voice group.');
        }
        final clips = <String>{};
        for (final path in paths) {
          if (path is! String || !files.containsKey(path)) {
            throw FormatException('Unknown voice file in plan $id.');
          }
          clips.add(path);
        }
        groups[id] = List.unmodifiable(clips);
      }
    }
    return PoseHubPlanVoiceManifest._(
      Map.unmodifiable(files),
      Map.unmodifiable(groups),
    );
  }

  final Map<String, PoseHubPlanVoiceFile> files;
  final Map<String, List<String>> plans;

  static final _sha256 = RegExp(r'^[a-f0-9]{64}$');

  static bool _isPublicHttps(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      !uri.hasFragment;

  static bool _isRelativePath(String path) {
    final url = Uri.tryParse(path);
    return url != null &&
        !url.hasScheme &&
        !url.hasAuthority &&
        !url.hasQuery &&
        !url.hasFragment &&
        path.split('/').every((segment) {
          try {
            final decoded = Uri.decodeComponent(segment);
            return decoded.isNotEmpty &&
                decoded != '.' &&
                decoded != '..' &&
                !RegExp(r'[/\\\x00-\x1f\x7f]').hasMatch(decoded);
          } on FormatException {
            return false;
          }
        });
  }
}

typedef PoseHubBundledVoiceReader = Future<List<int>?> Function(String sha256);
typedef PoseHubBundledVoiceFileReader =
    Future<List<int>?> Function(String path);

/// Prepares only the files a host requests for its pinned plan snapshot.
/// Plan audio lives separately from the catalog voice cache so updating or
/// pruning a catalog cannot evict files used by running or saved sessions.
final class PoseHubPlanVoiceCache {
  PoseHubPlanVoiceCache({
    required this.store,
    required this.uriOf,
    PoseHubCatalogHttpClient? http,
    this.loadBundled,
    this.loadBundledFile,
  }) : http = http ?? platform.createPoseHubCatalogHttpClient();

  factory PoseHubPlanVoiceCache.files(
    String directory, {
    PoseHubCatalogHttpClient? http,
    PoseHubBundledVoiceReader? loadBundled,
    PoseHubBundledVoiceFileReader? loadBundledFile,
  }) => PoseHubPlanVoiceCache(
    store: platform.createPoseHubCatalogFileStore(directory),
    uriOf: (name) => Uri.file('$directory/$name'),
    http: http,
    loadBundled: loadBundled,
    loadBundledFile: loadBundledFile,
  );

  /// On native platforms keeps audio in persistent application support.
  static Future<PoseHubPlanVoiceCache> inApplicationSupport({
    String? assetRootDirectory,
    PoseHubCatalogHttpClient? http,
    PoseHubBundledVoiceReader? loadBundled,
    PoseHubBundledVoiceFileReader? loadBundledFile,
  }) async {
    final root =
        assetRootDirectory ?? (await getApplicationSupportDirectory()).path;
    return PoseHubPlanVoiceCache.files(
      '$root/ugk_channel_plans',
      http: http,
      loadBundled: loadBundled,
      loadBundledFile: loadBundledFile,
    );
  }

  final PoseHubCatalogStore store;
  final Uri Function(String cacheName) uriOf;
  final PoseHubCatalogHttpClient http;

  /// Optional host asset reader indexed by digest, independent of logical path.
  final PoseHubBundledVoiceReader? loadBundled;

  /// Optional host asset reader using the manifest's `file` or `path` key.
  /// The bytes still have to match the manifest before they are used.
  final PoseHubBundledVoiceFileReader? loadBundledFile;

  final _jobs = <(String, int), Future<Uri?>>{};

  /// A verified local audio URI, or null if missing, corrupt, or offline.
  Future<Uri?> ensureFile(PoseHubPlanVoiceManifest manifest, String path) {
    final file = manifest.files[path];
    if (file == null) return Future.value();
    final key = (file._cacheName, file.bytes);
    return _jobs[key] ??= _ensure(manifest, file).whenComplete(() {
      _jobs.remove(key);
    });
  }

  Future<Uri?> _ensure(
    PoseHubPlanVoiceManifest manifest,
    PoseHubPlanVoiceFile file,
  ) async {
    try {
      final name = file._cacheName;
      final cached = await store.read(name);
      if (cached != null && file._matches(cached)) return uriOf(name);
      final bundled = await _readBundled(manifest, file);
      if (bundled != null) {
        await store.writeAtomic(name, bundled);
      } else {
        final result = await http.get(file.url, maxBytes: file.bytes);
        if (result.statusCode != 200 || !file._matches(result.body)) {
          return null;
        }
        await store.writeAtomic(name, result.body);
      }
      return uriOf(name);
    } catch (_) {
      return null;
    }
  }

  Future<List<int>?> _readBundled(
    PoseHubPlanVoiceManifest manifest,
    PoseHubPlanVoiceFile file,
  ) async {
    final byPath = loadBundledFile;
    for (final (reader, key) in [
      (loadBundled, file.sha256),
      if (byPath != null) ...[
        (byPath, file.path),
        // Published manifests can give identical audio several logical paths.
        for (final alias in manifest.files.values)
          if (alias.path != file.path &&
              alias.sha256 == file.sha256 &&
              alias.bytes == file.bytes)
            (byPath, alias.path),
      ],
    ]) {
      try {
        final bytes = await reader?.call(key);
        if (bytes != null && file._matches(bytes)) return bytes;
      } catch (_) {
        // The host may not have bundled this clip.
      }
    }
    return null;
  }

  /// Prepares the clips declared for [planId]. If the manifest does not group
  /// that plan, the host can supply its selected clip paths to [prefetchFiles].
  Future<Map<String, Uri?>> prefetchPlan(
    PoseHubPlanVoiceManifest manifest,
    String planId,
  ) {
    final paths = manifest.plans[planId];
    if (paths == null) {
      throw ArgumentError.value(planId, 'planId', 'No voice group');
    }
    return prefetchFiles(manifest, paths);
  }

  /// Prepares only [paths], reporting each verified local URI or a null miss.
  Future<Map<String, Uri?>> prefetchFiles(
    PoseHubPlanVoiceManifest manifest,
    Iterable<String> paths,
  ) async {
    final selected = paths.toSet();
    final queue = selected.iterator;
    final local = <String, Uri?>{};
    Future<void> worker() async {
      while (queue.moveNext()) {
        final path = queue.current;
        local[path] = await ensureFile(manifest, path);
      }
    }

    await Future.wait([worker(), worker(), worker()]);
    return Map.unmodifiable({for (final path in selected) path: local[path]});
  }
}
