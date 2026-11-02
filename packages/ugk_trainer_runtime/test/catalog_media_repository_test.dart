// Selected behavior regressions from SmartFit 52d30ae.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_trainer_runtime/src/media/catalog_media_repository.dart';
import 'package:ugk_trainer_runtime/src/media/training_media_repository.dart';

class _Fixture {
  _Fixture({
    int actions = 2,
    int videoBytes = 4096,
    List<int>? videoSizes,
    int coverBytes = 48,
    bool sharedVideos = false,
  }) {
    final rows = <Map<String, Object?>>[];
    for (var i = 0; i < actions; i++) {
      final id = 'action-$i';
      final files = <String, Object?>{};
      for (final role in ['video', 'cover', 'thumbnail']) {
        final path = 'media/$id/$role.${role == 'video' ? 'mp4' : 'webp'}';
        final bytes = Uint8List.fromList(
          List.generate(
            role == 'video'
                ? (videoSizes?[i] ?? videoBytes)
                : (role == 'cover' ? coverBytes : 24),
            (n) =>
                (n * 17 +
                    role.length +
                    (sharedVideos && role == 'video' ? 0 : i)) %
                251,
          ),
        );
        bodies[path] = bytes;
        files[role] = {
          'path': path,
          'bytes': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        };
      }
      rows.add({
        'id': id,
        'nameZh': 'Fixture $id',
        ...flags,
        'availableForApp': true,
        'availableForTraining': false,
        'trainingDefinitionComplete': false,
        'trainingSemantics': {
          ...flags,
          'status': 'partial-fixture',
          'definitionComplete': false,
          'missingRequiredFields': ['defaultDose'],
          'unknownFields': [],
          'videoLoopIsTrainingDose': false,
        },
        'rhythm': {'videoLoopIsTrainingDose': false},
        'files': files,
      });
    }
    final raw = {
      'format': 'pose-hub-app-test-catalog@1',
      'id': 'fixture',
      ...flags,
      'totalCount': actions,
      'readyCount': actions,
      'pendingCount': 0,
      'actions': rows,
      'semanticCatalog': {
        'path': 'catalog/catalog.json',
        'bytes': 2,
        'sha256': sha256.convert(utf8.encode('{}')).toString(),
        'version': '0.0.0',
      },
      'trainingSemantics': {
        ...flags,
        'definitionCompleteCount': 0,
        'definitionCompleteIds': [],
        'incompleteActionIds': rows.map((r) => r['id']).toList(),
        'videoLoopIsTrainingDose': false,
      },
    };
    revision = sha256.convert(utf8.encode(jsonEncode(raw))).toString();
    catalog = coach.PoseHubAppTestCatalog.fromJson(raw);
  }

  static const flags = {
    'status': 'test-unreviewed',
    'reviewed': false,
    'releaseEligible': false,
  };
  final bodies = <String, Uint8List>{};
  late final coach.PoseHubAppTestCatalog catalog;
  late final String revision;
  coach.PoseHubPackAction get first => catalog.allActions.first;
}

Future<void> _until(bool Function() condition) async {
  final timer = Stopwatch()..start();
  while (!condition()) {
    if (timer.elapsed > const Duration(seconds: 5)) {
      throw StateError('Timed out waiting for test server.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory support;
  late _Fixture fixture;
  late HttpServer server;
  late Uri base;
  late Future<void> Function(HttpRequest) handler;
  late List<String> requested;
  final repositories = <CatalogMediaRepository>[];

  setUp(() async {
    support = await Directory.systemTemp.createTemp('catalog-media-test-');
    fixture = _Fixture();
    requested = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}/');
    handler = (request) async {
      final bytes = fixture.bodies[request.uri.path.substring(1)];
      if (bytes == null) {
        request.response.statusCode = 404;
      } else {
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
      }
      await request.response.close();
    };
    server.listen((request) async {
      requested.add(request.uri.path);
      try {
        await handler(request);
      } on IOException {
        // Several cases deliberately terminate a client or an incomplete body.
      }
    });
  });

  tearDown(() async {
    for (final repository in repositories) {
      repository.dispose();
    }
    repositories.clear();
    await server.close(force: true);
    await support.delete(recursive: true);
  });

  Future<CatalogMediaRepository> create({
    CatalogBundledFileLoader? bundled,
    List<Uri>? mediaBases,
    bool offline = false,
    Duration timeout = const Duration(seconds: 3),
    Duration progressInterval = const Duration(milliseconds: 25),
    int concurrent = 2,
    int redirects = 5,
    String? revision,
    String packVersion = 'r1-v3',
    int cacheBytes = catalogVideoCacheLimitBytes,
  }) async {
    final result = await CatalogMediaRepository.forTesting(
      catalog: fixture.catalog,
      catalogRevision: revision ?? fixture.revision,
      mediaBaseUrls: offline ? [] : (mediaBases ?? [base]),
      packVersion: packVersion,
      rootDirectory: support.path,
      bundledFileLoader: bundled,
      allowInsecureLocalhost: true,
      timeout: timeout,
      progressInterval: progressInterval,
      maxConcurrent: concurrent,
      maxRedirects: redirects,
      maxVideoCacheBytes: cacheBytes,
    );
    repositories.add(result);
    return result;
  }

  Future<void> noParts(CatalogMediaRepository repository) async {
    final files = await Directory.fromUri(
      repository.mediaBaseUri,
    ).list(recursive: true).toList();
    expect(
      files.whereType<File>().where((f) => f.path.endsWith('.part')),
      isEmpty,
    );
  }

  test(
    'create makes an empty versioned root immediately and requests no media',
    () async {
      final repo = await create();
      expect(repo.catalog, same(fixture.catalog));
      expect(repo.mediaBaseUri.scheme, 'file');
      expect(
        repo.mediaBaseUri.path.endsWith('/r1-v3/${fixture.revision}/'),
        isTrue,
      );
      expect(await Directory.fromUri(repo.mediaBaseUri).exists(), isTrue);
      expect(await Directory.fromUri(repo.mediaBaseUri).list().isEmpty, isTrue);
      expect(requested, isEmpty);
    },
  );

  test(
    'ensureAction prepares only its three files and merges repeated calls',
    () async {
      final repo = await create();
      final first = repo.ensureAction(fixture.first.id);
      expect(repo.ensureAction(fixture.first.id), same(first));
      expect(await first, repo.mediaBaseUri);
      expect(
        requested.toSet(),
        fixture.first.files.values.map((f) => '/${f.path}').toSet(),
      );
      expect(requested.length, 3);
      for (final file in fixture.first.files.values) {
        expect(
          await File.fromUri(file.resolve(repo.mediaBaseUri)).readAsBytes(),
          fixture.bodies[file.path],
        );
      }
      expect(
        repo.watchAction(fixture.first.id).value.phase,
        CatalogMediaDownloadPhase.ready,
      );
      await noParts(repo);
    },
  );

  test(
    'same file Future and same SHA across distinct paths share one HTTP job',
    () async {
      fixture = _Fixture(sharedVideos: true);
      final repo = await create();
      final a = fixture.catalog.allActions[0].video;
      final b = fixture.catalog.allActions[1].video;
      final first = repo.ensureFile(a);
      expect(repo.ensureFile(a), same(first));
      final uris = await Future.wait([first, repo.ensureFile(b)]);
      expect(requested.length, 1);
      expect(uris, [
        a.resolve(repo.mediaBaseUri),
        b.resolve(repo.mediaBaseUri),
      ]);
      expect(await File.fromUri(uris[1]).readAsBytes(), fixture.bodies[b.path]);
    },
  );

  test(
    'valid cache survives repository restart and works without a source URL',
    () async {
      final first = await create();
      final file = fixture.first.video;
      final uri = await first.ensureFile(file);
      first.dispose();
      final second = await create(offline: true);
      expect(await second.ensureFile(file), uri);
      expect(requested.length, 1);
      expect(
        second.watchFile(file).value.phase,
        CatalogMediaDownloadPhase.ready,
      );
    },
  );

  test(
    'bundled small images are verified, remain unchanged and never fetch videos',
    () async {
      final loaded = <String>[];
      final repo = await create(
        bundled: (file) async {
          expect(file.path.endsWith('.webp'), isTrue);
          loaded.add(file.path);
          return fixture.bodies[file.path];
        },
      );
      final coverBefore = Uint8List.fromList(
        fixture.bodies[fixture.first.cover.path]!,
      );
      await repo.ensureAction(fixture.first.id);
      expect(loaded.toSet(), {
        fixture.first.cover.path,
        fixture.first.thumbnail.path,
      });
      expect(requested, ['/${fixture.first.video.path}']);
      expect(fixture.bodies[fixture.first.cover.path], coverBefore);
    },
  );

  test(
    'truncated real HTTP body fails, cleans temporary files and retries',
    () async {
      var truncate = true;
      handler = (request) async {
        final bytes = fixture.bodies[fixture.first.video.path]!;
        request.response.contentLength = bytes.length;
        if (truncate) {
          final socket = await request.response.detachSocket();
          socket.add(bytes.sublist(0, bytes.length ~/ 2));
          await socket.flush();
          socket.destroy();
        } else {
          request.response.add(bytes);
          await request.response.close();
        }
      };
      final repo = await create();
      await expectLater(
        repo.ensureFile(fixture.first.video),
        throwsA(isA<CatalogMediaException>()),
      );
      await noParts(repo);
      expect(
        await File.fromUri(
          fixture.first.video.resolve(repo.mediaBaseUri),
        ).exists(),
        isFalse,
      );
      truncate = false;
      await repo.ensureFile(fixture.first.video);
      expect(requested.length, 2);
    },
  );

  test(
    'HTTP errors remain observable and a manual retry starts a new request',
    () async {
      var fail = true;
      handler = (request) async {
        if (fail) {
          request.response.statusCode = 503;
        } else {
          final bytes = fixture.bodies[fixture.first.video.path]!;
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
        }
        await request.response.close();
      };
      final repo = await create();
      await expectLater(
        repo.ensureFile(fixture.first.video),
        throwsA(isA<CatalogMediaException>()),
      );
      expect(
        repo.watchFile(fixture.first.video).value.phase,
        CatalogMediaDownloadPhase.failed,
      );
      fail = false;
      await repo.ensureFile(fixture.first.video);
      expect(repo.watchFile(fixture.first.video).value.error, isNull);
      expect(requested.length, 2);
    },
  );

  test(
    'base URL resolves the original nested catalog path without flat mapping',
    () async {
      final file = fixture.first.video;
      handler = (request) async {
        expect(request.uri.path, '/pack/r1-v3/${file.path}');
        final bytes = fixture.bodies[file.path]!;
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      };
      final repo = await create(mediaBases: [base.resolve('pack/r1-v3/')]);
      await repo.ensureFile(file);
      expect(requested, ['/pack/r1-v3/${file.path}']);
    },
  );

  test(
    'idle response timeout cleans temporary output and exposes a safe error',
    () async {
      final gate = Completer<void>();
      handler = (request) async {
        request.response.bufferOutput = false;
        request.response.contentLength = fixture.first.video.bytes;
        request.response.add([fixture.bodies[fixture.first.video.path]!.first]);
        await request.response.flush();
        await gate.future;
        await request.response.close();
      };
      final repo = await create(timeout: const Duration(milliseconds: 100));
      try {
        await expectLater(
          repo.ensureFile(fixture.first.video),
          throwsA(
            isA<CatalogMediaException>().having(
              (e) => e.code,
              'code',
              'timeout',
            ),
          ),
        );
        await noParts(repo);
      } finally {
        gate.complete();
      }
    },
  );

  test(
    'empty media bases fail closed without any guessed download URL',
    () async {
      final repo = await create(mediaBases: []);
      await expectLater(
        repo.ensureFile(fixture.first.video),
        throwsA(
          isA<CatalogMediaException>().having(
            (e) => e.code,
            'code',
            'not_configured',
          ),
        ),
      );
      expect(requested, isEmpty);
      await noParts(repo);
    },
  );

  test(
    'a failed primary connection automatically tries the next base',
    () async {
      final unavailable = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final deadBase = Uri.parse('http://127.0.0.1:${unavailable.port}/');
      await unavailable.close(force: true);
      final repo = await create(mediaBases: [deadBase, base]);
      final file = fixture.first.video;
      final uri = await repo.ensureFile(file);
      expect(await File.fromUri(uri).readAsBytes(), fixture.bodies[file.path]);
      expect(requested, ['/${file.path}']);
      await noParts(repo);
    },
  );

  test(
    'clear cancels in-flight video and prevents late publish before redownload',
    () async {
      fixture = _Fixture(videoBytes: 32768);
      final release = Completer<void>();
      final oldServerDone = Completer<void>();
      var firstRequest = true;
      handler = (request) async {
        final bytes = fixture.bodies[fixture.first.video.path]!;
        if (!firstRequest) {
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
          await request.response.close();
          return;
        }
        firstRequest = false;
        try {
          request.response.bufferOutput = false;
          request.response.contentLength = bytes.length;
          request.response.add(bytes.sublist(0, bytes.length ~/ 2));
          await request.response.flush();
          await release.future;
          request.response.add(bytes.sublist(bytes.length ~/ 2));
          await request.response.close();
        } catch (_) {
          // The client intentionally closes this socket during cache retirement.
        } finally {
          oldServerDone.complete();
        }
      };
      final repo = await create(progressInterval: Duration.zero);
      final cache = repo;
      final file = fixture.first.video;
      final old = repo.ensureFile(file);
      final cancelled = expectLater(
        old,
        throwsA(
          isA<CatalogMediaException>().having(
            (e) => e.code,
            'code',
            'cache_cleared',
          ),
        ),
      );
      try {
        await _until(() => repo.watchFile(file).value.receivedBytes > 0);
        final clearing = cache.clearVideoCache();
        expect(cache.clearVideoCache(), same(clearing));
        await clearing.timeout(const Duration(seconds: 2));
        await cancelled;
        expect(await cache.videoCacheBytes(), 0);
        expect(
          await File.fromUri(file.resolve(repo.mediaBaseUri)).exists(),
          isFalse,
        );
        await noParts(repo);
        release.complete();
        await oldServerDone.future;
        expect(
          await File.fromUri(file.resolve(repo.mediaBaseUri)).exists(),
          isFalse,
        );
        await noParts(repo);
        final uri = await repo.ensureFile(file);
        expect(
          await File.fromUri(uri).readAsBytes(),
          fixture.bodies[file.path],
        );
        expect(await cache.videoCacheBytes(), file.bytes);
        expect(requested.length, 2);
      } finally {
        if (!release.isCompleted) release.complete();
      }
    },
  );

  test(
    'cache-only lookup validates, touches and never requests a miss',
    () async {
      final repo = await create();
      final access = repo;
      final action = fixture.first;
      expect(await access.cachedVideo(action.id), isNull);
      expect(requested, isEmpty);
      final uri = await repo.ensureFile(action.video);
      final file = File.fromUri(uri);
      final old = DateTime.utc(2020);
      await file.setLastModified(old);
      expect(await access.cachedVideo(action.id), uri);
      expect((await file.lastModified()).isAfter(old), isTrue);
      expect(requested, ['/${action.video.path}']);
      await file.writeAsBytes(Uint8List(action.video.bytes));
      expect(await access.cachedVideo(action.id), isNull);
      expect(requested, ['/${action.video.path}']);
      expect(
        repo.watchFile(action.video).value.phase,
        CatalogMediaDownloadPhase.idle,
      );
    },
  );

  test('video cap cannot be disabled or increased beyond 300MB', () async {
    expect(catalogVideoCacheLimitBytes, 300000000);
    for (final cap in [0, -1, 300000001]) {
      await expectLater(
        CatalogMediaRepository.create(
          catalog: fixture.catalog,
          catalogRevision: fixture.revision,
          mediaBaseUrls: const [],
          rootDirectory: support.path,
          maxVideoCacheBytes: cap,
        ),
        throwsFormatException,
      );
    }
    expect(requested, isEmpty);
  });

  test(
    'public catalogue factory accepts a smaller video cache budget',
    () async {
      final repo = await TrainingMediaRepository.fromCatalog(
        catalog: fixture.catalog,
        catalogRevision: fixture.revision,
        mediaBaseUrls: const [],
        rootDirectory: support.path,
        maxVideoCacheBytes: 4096,
        bundledFileLoader: (file) async => fixture.bodies[file.path],
      );
      repositories.add(repo);
      expect(repo.catalog, same(fixture.catalog));
      await repo.ensureFile(fixture.first.cover);
      expect(await repo.videoCacheBytes(), 0);
      expect(requested, isEmpty);
    },
  );
}
