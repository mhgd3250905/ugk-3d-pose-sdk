import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

void main() {
  late Directory support;
  late HttpServer server;
  late Uri base;
  late Uint8List image;
  late PoseHubPackFile file;
  late List<String> requested;
  late List<int> response;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('posehub-image-test-');
    image = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    file = PoseHubPackFile.fromJson({
      'path': 'media/updated-action/r2-v8/cover.webp',
      'bytes': image.length,
      'sha256': sha256.convert(image).toString(),
    });
    requested = [];
    response = image;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}/');
    server.listen((request) async {
      requested.add(request.uri.path);
      request.response.contentLength = response.length;
      request.response.add(response);
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await support.delete(recursive: true);
  });

  PoseHubImageCache cache() => PoseHubImageCache(
    rootDirectory: support.path,
    allowInsecureLocalhost: true,
    timeout: const Duration(seconds: 2),
  );

  test(
    'catalogue cover is downloaded and returned only after SHA verification',
    () async {
      final uri = await cache().ensureFile(file, mediaBaseUri: base);
      expect(requested, ['/media/updated-action/r2-v8/cover.webp']);
      expect(uri.scheme, 'file');
      expect(await File.fromUri(uri).readAsBytes(), image);
      expect(
        sha256.convert(await File.fromUri(uri).readAsBytes()).toString(),
        file.sha256,
      );
    },
  );

  test('wrong SHA never publishes the downloaded image', () async {
    response = List<int>.from(image)..[image.length - 1] ^= 1;
    await expectLater(
      cache().ensureFile(file, mediaBaseUri: base),
      throwsA(
        isA<CatalogMediaException>().having((e) => e.code, 'code', 'sha256'),
      ),
    );
    expect(requested, hasLength(1));
    expect(
      support
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (entry) =>
                entry.path.endsWith('.webp') || entry.path.endsWith('.part'),
          ),
      isEmpty,
    );
  });

  test(
    'a fresh consumer reuses a verified cached image while offline',
    () async {
      final first = await cache().ensureFile(file, mediaBaseUri: base);
      await server.close(force: true);
      final offline = await cache().ensureFile(file, mediaBaseUri: base);
      expect(offline, first);
      expect(requested, hasLength(1));
      expect(await File.fromUri(offline).readAsBytes(), image);
    },
  );

  test(
    'prepared local action images are verified before any CDN request',
    () async {
      final prepared = Directory('${support.path}/prepared');
      final original = File('${prepared.path}/${file.path}');
      await original.parent.create(recursive: true);
      await original.writeAsBytes(image);
      final withCdn = PoseHubPackFile.fromJson({
        ...file.raw,
        'downloadUrl': 'https://media.example.test/${file.path}',
      });
      final result = await cache().ensureFile(
        withCdn,
        mediaBaseUri: prepared.uri,
      );
      expect(await File.fromUri(result).readAsBytes(), image);
      expect(requested, isEmpty);
      expect(result, isNot(original.uri));
    },
  );
}
