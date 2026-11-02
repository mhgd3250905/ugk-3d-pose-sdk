import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer_runtime/src/media/catalog_legacy_video_catalog.dart';

class _Bundle extends CachingAssetBundle {
  _Bundle(this.files);

  final Map<String, List<int>> files;
  final loaded = <String>[];

  @override
  Future<ByteData> load(String key) async {
    loaded.add(key);
    return ByteData.sublistView(Uint8List.fromList(files[key]!));
  }
}

void main() {
  test(
    'legacy descriptors use the supplied asset root without opening clips',
    () async {
      const root = 'host-assets/legacy/';
      final video = utf8.encode('shared-legacy-video');
      final hash = sha256.convert(video).toString();
      final assets = <String, List<int>>{};
      final packages = <String, Object>{};
      for (final name in ['builtin', 'realistic-dark', 'realistic-light']) {
        final theme = name == 'realistic-light' ? 'light' : 'dark';
        final bytes = utf8.encode(
          jsonEncode({
            'files': [
              {
                'path': '../v0.3.0/realistic/$theme/action-0.mp4',
                'bytes': video.length,
                'sha256': hash,
              },
            ],
          }),
        );
        final path = 'packages/$name.json';
        assets['$root$path'] = bytes;
        packages[name] = {
          'fileCount': 1,
          'totalBytes': video.length,
          'manifest': {
            'path': path,
            'bytes': bytes.length,
            'sha256': sha256.convert(bytes).toString(),
          },
        };
      }
      const manifest = '${root}app-manifest.json';
      assets[manifest] = utf8.encode(
        jsonEncode({'version': '0.3.0', 'packages': packages}),
      );
      final bundle = _Bundle(assets);
      final descriptors = await loadCatalogLegacyVideoCatalog(
        manifestAsset: manifest,
        bundle: bundle,
      );
      expect(descriptors, hasLength(1));
      expect(descriptors.single.version, '0.3.0');
      expect(descriptors.single.bytes, video.length);
      expect(descriptors.single.sha256, hash);
      expect(bundle.loaded, [
        manifest,
        ...assets.keys.where((key) => key != manifest),
      ]);
    },
  );
}
