// Ported from SmartFit@e8981ee lib/core/media/scene_asset_router.dart
// (3D-Body SceneAssetRouter). Changes: generic – a bundle asset is served
// at `/<asset key>` when its key starts with one of [prefixes] and its type
// is allowed (player page html/js/css; clips mp4 with byte ranges; images).
// The 3D-scene / font routes are dropped. Pure Dart.
import 'dart:typed_data';

typedef AssetLoader = Future<Uint8List> Function(String assetKey);

class AssetResponse {
  const AssetResponse({
    required this.statusCode,
    required this.contentType,
    required this.body,
    this.headers = const {},
    required this.contentLength,
  });

  final int statusCode;
  final String contentType;
  final Uint8List body;
  final Map<String, String> headers;
  final int contentLength;
}

/// Resolves only assets explicitly present in the Flutter bundle manifest.
/// No request path is ever joined to a filesystem directory.
class AssetRouter {
  AssetRouter({
    required Iterable<String> assets,
    required this.load,
    this.prefixes = defaultPrefixes,
  }) : _assets = {
         for (final key in assets)
           if (mimeFor(key) != null && prefixes.any(key.startsWith)) key,
       };

  /// The player page of this package and the app's own assets.
  static const playerPrefix = 'packages/ugk_trainer/assets/media_player/';
  static const defaultPrefixes = [playerPrefix, 'assets/'];

  final List<String> prefixes;
  final Set<String> _assets;
  final AssetLoader load;

  Future<AssetResponse> route(
    String requestTarget, {
    String method = 'GET',
    String? range,
  }) async {
    if (method != 'GET' && method != 'HEAD') return _error(405);
    final name = _assetName(requestTarget);
    if (name == null) return _error(400);
    if (!_assets.contains(name)) return _error(404);
    final mime = mimeFor(name)!;
    try {
      final bytes = await load(name);
      final isMedia = mime.startsWith('video/');
      final headers = <String, String>{if (isMedia) 'Accept-Ranges': 'bytes'};
      if (isMedia && method == 'GET' && range != null) {
        final selected = _range(range, bytes.length);
        if (selected == null) {
          return AssetResponse(
            statusCode: 416,
            contentType: mime,
            body: Uint8List(0),
            contentLength: 0,
            headers: {...headers, 'Content-Range': 'bytes */${bytes.length}'},
          );
        }
        final (start, end) = selected;
        return AssetResponse(
          statusCode: 206,
          contentType: mime,
          body: Uint8List.sublistView(bytes, start, end + 1),
          contentLength: end - start + 1,
          headers: {
            ...headers,
            'Content-Range': 'bytes $start-$end/${bytes.length}',
          },
        );
      }
      return AssetResponse(
        statusCode: 200,
        contentType: mime,
        body: method == 'HEAD' ? Uint8List(0) : bytes,
        contentLength: bytes.length,
        headers: headers,
      );
    } catch (_) {
      return _error(404);
    }
  }

  // A bounded, open-ended or suffix byte range. Multiple ranges are not
  // supported: never return multipart bytes under a video MIME type.
  static (int, int)? _range(String value, int length) {
    if (length == 0) return null;
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value.trim());
    if (match == null) return null;
    final first = match.group(1)!;
    final last = match.group(2)!;
    if (first.isEmpty) {
      final suffix = int.tryParse(last);
      if (suffix == null || suffix <= 0) return null;
      return (suffix >= length ? 0 : length - suffix, length - 1);
    }
    final start = int.tryParse(first);
    final end = last.isEmpty ? length - 1 : int.tryParse(last);
    if (start == null || end == null || start >= length || end < start) {
      return null;
    }
    return (start, end >= length ? length - 1 : end);
  }

  static String? _assetName(String target) {
    // Validate the raw path before Uri parsing can normalize dot segments.
    final raw = target.split('?').first;
    if (!raw.startsWith('/') || raw.startsWith('//') || raw.contains('#')) {
      return null;
    }
    String path;
    try {
      path = Uri.decodeComponent(raw);
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
    if (path.contains('%') ||
        path.contains('\\') ||
        path.contains(':') ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(path)) {
      return null;
    }
    final segments = path.substring(1).split('/');
    if (segments.any((part) => part.isEmpty || part.startsWith('.'))) {
      return null;
    }
    return segments.join('/');
  }

  /// Types the player may load; anything else (json, audio …) is never
  /// served.
  static String? mimeFor(String name) =>
      switch (name.split('.').last.toLowerCase()) {
        'html' => 'text/html; charset=utf-8',
        'js' => 'text/javascript; charset=utf-8',
        'css' => 'text/css; charset=utf-8',
        'mp4' => 'video/mp4',
        'jpg' || 'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'webp' => 'image/webp',
        _ => null,
      };

  static AssetResponse _error(int status) => AssetResponse(
    statusCode: status,
    contentType: 'text/plain; charset=utf-8',
    body: Uint8List(0),
    contentLength: 0,
  );
}
