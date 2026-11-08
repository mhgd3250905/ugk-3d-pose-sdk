import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

void main() {
  test(
    'every bundled standing image belongs to the bundled video revision',
    () async {
      final root = PoseHubActionLibrary.standingAssetRoot.replaceFirst(
        'packages/ugk_trainer/',
        '',
      );
      final index =
          jsonDecode(File('${root}index.json').readAsStringSync())
              as Map<String, Object?>;
      final records = index['actions']! as Map<String, Object?>;
      final catalog =
          jsonDecode(
                File(
                  '${PoseHubActionLibrary.assetRoot.replaceFirst('packages/ugk_trainer/', '')}catalog.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      final actions = (catalog['actions']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(index['schema'], 1);
      expect(index['pack'], PoseHubActionLibrary.packVersion);
      expect(index['frame'], 0);
      expect(index['width'], 640);
      expect(index['height'], 640);
      expect(records.keys.toSet(), {
        for (final action in actions) action['id'],
      });
      for (final action in actions) {
        final id = action['id'] as String;
        final video =
            (action['files']! as Map<String, Object?>)['video']!
                as Map<String, Object?>;
        final record = records[id]! as Map<String, Object?>;
        expect(record['videoPath'], video['path'], reason: id);
        expect(record['videoSha256'], video['sha256'], reason: id);
        final image = File('$root$id.webp').readAsBytesSync();
        expect(image.length, record['imageBytes'], reason: id);
        expect(
          sha256.convert(image).toString(),
          record['imageSha256'],
          reason: id,
        );
        final codec = await ui.instantiateImageCodec(image);
        final frame = await codec.getNextFrame();
        expect(frame.image.width, 640, reason: id);
        expect(frame.image.height, 640, reason: id);
        frame.image.dispose();
        codec.dispose();
      }
    },
  );
}
