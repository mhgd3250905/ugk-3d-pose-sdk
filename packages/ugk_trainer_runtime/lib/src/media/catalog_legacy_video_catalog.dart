// Extracted from SmartFit 52d30ae; shared catalogue cache behavior.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'catalog_media_repository_types.dart';

/// Read the retained, immutable video metadata; never open/download a clip.
Future<List<CatalogLegacyVideoFile>> loadCatalogLegacyVideoCatalog({
  required String manifestAsset,
  AssetBundle? bundle,
}) async {
  final assets = bundle ?? rootBundle;
  final assetRoot = manifestAsset.substring(
    0,
    manifestAsset.lastIndexOf('/') + 1,
  );
  final manifest =
      jsonDecode(await assets.loadString(manifestAsset))
          as Map<String, dynamic>;
  final version = manifest['version'] as String;
  if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
    throw const FormatException('Invalid legacy video version.');
  }
  final packages = manifest['packages'] as Map<String, Object?>;
  final videos = <String, CatalogLegacyVideoFile>{};
  for (final name in ['builtin', 'realistic-dark', 'realistic-light']) {
    final package = packages[name] as Map<String, Object?>;
    final descriptor = package['manifest'] as Map<String, Object?>;
    if (descriptor['path'] != 'packages/$name.json') {
      throw const FormatException('Invalid legacy video manifest path.');
    }
    final data = await assets.load('${assetRoot}packages/$name.json');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    if (bytes.length != descriptor['bytes'] ||
        sha256.convert(bytes).toString() != descriptor['sha256']) {
      throw const FormatException('Legacy video manifest checksum mismatch.');
    }
    final files =
        (jsonDecode(utf8.decode(bytes)) as Map<String, Object?>)['files']
            as List<Object?>;
    var total = 0;
    final paths = <String>{};
    for (final raw in files.cast<Map<String, Object?>>()) {
      final path = raw['path'] as String;
      final size = raw['bytes'] as int;
      final hash = raw['sha256'] as String;
      final theme = name == 'realistic-light' ? 'light' : 'dark';
      if (!RegExp(
            '^\\.\\./v${RegExp.escape(version)}/realistic/$theme/'
            r'[a-zA-Z0-9-]+\.mp4$',
          ).hasMatch(path) ||
          !paths.add(path) ||
          size <= 0 ||
          size > 128 * 1024 * 1024 ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
        throw const FormatException('Invalid legacy video descriptor.');
      }
      total += size;
      final previous = videos[hash];
      if (previous != null && previous.bytes != size) {
        throw const FormatException('Conflicting legacy video descriptor.');
      }
      videos[hash] = CatalogLegacyVideoFile(
        version: version,
        bytes: size,
        sha256: hash,
      );
    }
    if (files.length != package['fileCount'] ||
        total != package['totalBytes']) {
      throw const FormatException('Legacy video manifest size mismatch.');
    }
  }
  return List.unmodifiable(videos.values);
}
