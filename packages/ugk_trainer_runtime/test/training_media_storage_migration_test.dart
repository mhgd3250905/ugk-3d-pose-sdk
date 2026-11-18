import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer_runtime/src/media/training_media_models.dart';
import 'package:ugk_trainer_runtime/src/media/training_media_storage.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const version = '0.3.0';
  final bytes = utf8.encode('verified media bytes');
  final file = TrainingMediaFile({
    'path': 'clip.mp4',
    'bytes': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
  });
  final other = TrainingMediaFile({
    'path': 'other.mp4',
    'bytes': 1,
    'sha256': sha256.convert([42]).toString(),
  });

  late Directory temp;
  late Directory legacy;
  late Directory support;
  late HttpServer server;
  late int cacheDirectoryLookups;
  late int downloads;
  final storage = <TrainingMediaStorage>[];

  setUp(() async {
    HttpOverrides.global = null;
    temp = await Directory.systemTemp.createTemp('training-media-migration-');
    legacy = Directory('${temp.path}/cache');
    support = Directory('${temp.path}/support');
    cacheDirectoryLookups = 0;
    downloads = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, (
      call,
    ) async {
      if (call.method == 'getApplicationSupportDirectory') return support.path;
      if (call.method == 'getApplicationCacheDirectory') {
        cacheDirectoryLookups++;
        return legacy.path;
      }
      throw MissingPluginException(call.method);
    });
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      downloads++;
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
  });

  tearDown(() async {
    for (final instance in storage) {
      instance.dispose();
    }
    storage.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, null);
    await server.close(force: true);
    await temp.delete(recursive: true);
  });

  Future<TrainingMediaStorage> open() async {
    final instance = await TrainingMediaStorage.create(
      version,
      null,
      const Duration(seconds: 5),
    );
    storage.add(instance);
    return instance;
  }

  Future<TrainingMediaCacheEntry> resolve(TrainingMediaStorage storage) async =>
      await storage.cached(file) ??
      await storage.download(
        file,
        [Uri.parse('http://127.0.0.1:${server.port}/${file.path}')],
        checkPolicy: () async {},
        onProgress: (_) {},
      );

  Future<void> writeLegacy(TrainingMediaFile file, List<int> data) async {
    final local = File('${legacy.path}/training-media/$version/${file.sha256}');
    await local.create(recursive: true);
    await local.writeAsBytes(data);
  }

  test(
    'uses a verified migrated file across restarts and cache eviction',
    () async {
      await writeLegacy(file, bytes);
      await writeLegacy(other, [0]);

      final first = await open();
      final entry = await resolve(first);
      expect(entry.path, startsWith(support.path));
      expect(await first.read(entry), bytes);
      expect(await first.cached(other), isNull);
      expect(await first.bytes(), bytes.length);
      expect(downloads, 0, reason: 'upgrade download count');
      first.dispose();

      final second = await open();
      expect((await resolve(second)).path, entry.path);
      expect(downloads, 0, reason: 'second launch download count');
      second.dispose();

      await legacy.delete(recursive: true);
      final afterEviction = await open();
      expect(await afterEviction.read(await resolve(afterEviction)), bytes);
      expect(downloads, 0, reason: 'launch after system cache deletion');
      expect(
        cacheDirectoryLookups,
        1,
        reason: 'one migration per support root',
      );
    },
  );

  test(
    'fresh download persists and clearing it does not reimport old data',
    () async {
      final first = await open();
      final downloaded = await resolve(first);
      expect(downloaded.path, startsWith(support.path));
      expect(downloads, 1);
      first.dispose();

      await writeLegacy(file, bytes);
      final second = await open();
      expect((await resolve(second)).path, downloaded.path);
      expect(downloads, 1, reason: 'restart uses the original download');
      await second.clear();
      second.dispose();

      final afterClear = await open();
      expect(await afterClear.cached(file), isNull);
      expect(cacheDirectoryLookups, 1);
    },
  );
}
