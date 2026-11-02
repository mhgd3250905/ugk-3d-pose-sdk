// Selected behavior regressions from SmartFit 52d30ae.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_trainer_runtime/src/media/catalog_media_repository.dart';

class _CatalogFixture {
  _CatalogFixture(
    this.label, {
    List<int> videoSizes = const [4096],
    int seed = 1,
  }) {
    final actions = <Map<String, Object?>>[];
    for (var index = 0; index < videoSizes.length; index++) {
      final id = 'action-$index';
      final files = <String, Object?>{};
      for (final role in ['video', 'cover', 'thumbnail']) {
        final path = 'media/$id/$role.${role == 'video' ? 'mp4' : 'webp'}';
        final bytes = _bytes(
          role == 'video' ? videoSizes[index] : 32,
          seed + index * 13 + role.length,
        );
        bodies[path] = bytes;
        files[role] = {
          'path': path,
          'bytes': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        };
      }
      actions.add({
        'id': id,
        'nameZh': '$label $id',
        ..._flags,
        'availableForApp': true,
        'availableForTraining': false,
        'trainingDefinitionComplete': false,
        'trainingSemantics': {
          ..._flags,
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
      'id': label,
      ..._flags,
      'totalCount': actions.length,
      'readyCount': actions.length,
      'pendingCount': 0,
      'actions': actions,
      'semanticCatalog': {
        'path': 'catalog/catalog.json',
        'bytes': 2,
        'sha256': sha256.convert(utf8.encode('{}')).toString(),
        'version': '0.0.0',
      },
      'trainingSemantics': {
        ..._flags,
        'definitionCompleteCount': 0,
        'definitionCompleteIds': [],
        'incompleteActionIds': actions.map((action) => action['id']).toList(),
        'videoLoopIsTrainingDose': false,
      },
    };
    revision = sha256.convert(utf8.encode(jsonEncode(raw))).toString();
    catalog = coach.PoseHubAppTestCatalog.fromJson(raw);
  }

  static const _flags = {
    'status': 'test-unreviewed',
    'reviewed': false,
    'releaseEligible': false,
  };

  final String label;
  final bodies = <String, Uint8List>{};
  late final String revision;
  late final coach.PoseHubAppTestCatalog catalog;

  coach.PoseHubPackAction action([int index = 0]) =>
      catalog.allActions.elementAt(index);

  String requestPath([int index = 0]) => '/$label/${action(index).video.path}';
}

Uint8List _bytes(int length, int seed) => Uint8List.fromList(
  List.generate(length, (index) => (index * 17 + seed) % 251),
);

Future<File> _write(File file, List<int> bytes) async {
  await file.parent.create(recursive: true);
  return file.writeAsBytes(bytes, flush: true);
}

Future<void> _copyTree(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final relative = entity.path.substring(source.path.length + 1);
    final target = '${destination.path}${Platform.pathSeparator}$relative';
    if (entity is Directory) {
      await Directory(target).create(recursive: true);
    } else if (entity is File) {
      final modified = await entity.lastModified();
      await File(target).parent.create(recursive: true);
      await entity.copy(target);
      await File(target).setLastModified(modified);
    } else {
      throw StateError('A test cache unexpectedly contains a link.');
    }
  }
}

File _published(
  Directory support,
  String packVersion,
  _CatalogFixture fixture, [
  int index = 0,
]) => File(
  '${support.path}/posehub-media/$packVersion/${fixture.revision}/'
  '${fixture.action(index).video.path}',
);

File _legacyFile(Directory cache, String version, String hash) =>
    File('${cache.path}/training-media/$version/$hash');

CatalogLegacyVideoFile _legacyDescriptor(
  List<int> bytes, {
  String version = '0.3.0',
}) => CatalogLegacyVideoFile(
  version: version,
  bytes: bytes.length,
  sha256: sha256.convert(bytes).toString(),
);

class _Harness {
  late final Directory workspace;
  late final Directory support;
  late final Directory legacyCache;
  late final HttpServer server;
  late final Uri base;
  final requests = <String>[];
  final _bodies = <String, Uint8List>{};
  final _gates = <String, Completer<void>>{};
  final _entered = <String, Completer<void>>{};
  final _repositories = <CatalogMediaRepository>[];

  Future<void> initialize() async {
    workspace = await Directory.systemTemp.createTemp('catalog-global-video-');
    support = await Directory('${workspace.path}/support').create();
    legacyCache = await Directory('${workspace.path}/app-cache').create();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}/');
    server.listen((request) async {
      final path = request.uri.path;
      requests.add(path);
      final bytes = _bodies[path];
      try {
        if (bytes == null) {
          request.response.statusCode = HttpStatus.notFound;
        } else {
          request.response.contentLength = bytes.length;
          final gate = _gates[path];
          if (gate == null) {
            request.response.add(bytes);
          } else {
            request.response.bufferOutput = false;
            request.response.add(bytes.sublist(0, bytes.length ~/ 2));
            await request.response.flush();
            _entered[path]!.complete();
            await gate.future;
            request.response.add(bytes.sublist(bytes.length ~/ 2));
          }
        }
        await request.response.close();
      } on IOException {
        // Teardown can retire a deliberately held transport after a failure.
      }
    });
  }

  Future<CatalogMediaRepository> open(
    _CatalogFixture fixture, {
    String packVersion = 'r1-v3',
    int cap = 8192,
    Directory? supportRoot,
    Directory? legacyRoot,
    List<CatalogLegacyVideoFile> legacyVideos = const [],
  }) async {
    for (final body in fixture.bodies.entries) {
      _bodies['/${fixture.label}/${body.key}'] = body.value;
    }
    final repository = await CatalogMediaRepository.forTesting(
      catalog: fixture.catalog,
      catalogRevision: fixture.revision,
      mediaBaseUrls: [base.resolve('${fixture.label}/')],
      packVersion: packVersion,
      rootDirectory: (supportRoot ?? support).path,
      legacyCacheDirectory: (legacyRoot ?? legacyCache).path,
      legacyVideos: legacyVideos,
      allowInsecureLocalhost: true,
      timeout: const Duration(seconds: 5),
      maxVideoCacheBytes: cap,
    );
    _repositories.add(repository);
    return repository;
  }

  Future<void> hold(String path) {
    _gates[path] = Completer<void>();
    _entered[path] = Completer<void>();
    return _entered[path]!.future;
  }

  void release(String path) {
    final gate = _gates[path];
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void close(CatalogMediaRepository repository) {
    repository.dispose();
    _repositories.remove(repository);
  }

  Future<Directory> coldSupport() async {
    final restarted = Directory('${workspace.path}/restarted-support');
    await _copyTree(support, restarted);
    return restarted;
  }

  Future<void> dispose() async {
    for (final path in _gates.keys) {
      release(path);
    }
    for (final repository in _repositories) {
      repository.dispose();
    }
    _repositories.clear();
    await server.close(force: true);
    await workspace.delete(recursive: true);
  }
}

void main() {
  late _Harness harness;

  setUp(() async {
    harness = _Harness();
    await harness.initialize();
  });

  tearDown(() => harness.dispose());

  test(
    'pack versions and revisions share persisted LRU after cold reopen',
    () async {
      final old = _CatalogFixture('old', seed: 1);
      final middle = _CatalogFixture('middle', seed: 2);
      final next = _CatalogFixture('next', seed: 3);
      final first = await harness.open(old, packVersion: 'r1-v1');
      final second = await harness.open(middle, packVersion: 'r1-v2');
      final oldUri = await first.ensureFile(old.action().video);
      final middleUri = await second.ensureFile(middle.action().video);
      await File.fromUri(oldUri).setLastModified(DateTime.utc(2020));
      await File.fromUri(middleUri).setLastModified(DateTime.utc(2021));
      expect(await first.cachedVideo('action-0'), oldUri);
      final touched = await File.fromUri(oldUri).lastModified();
      expect(
        touched.isAfter(await File.fromUri(middleUri).lastModified()),
        isTrue,
      );
      harness.close(first);
      harness.close(second);

      // A new canonical support path gets a fresh coordinator, so the disk
      // ownership record and mtimes must work without in-memory registrations.
      final restarted = await harness.coldSupport();
      final current = await harness.open(
        next,
        packVersion: 'r1-v2',
        supportRoot: restarted,
      );
      expect(await _published(restarted, 'r1-v1', old).lastModified(), touched);
      await current.ensureFile(next.action().video);

      expect(
        await _published(restarted, 'r1-v1', old).readAsBytes(),
        old.bodies[old.action().video.path],
      );
      expect(await _published(restarted, 'r1-v2', middle).exists(), isFalse);
      expect(
        await _published(restarted, 'r1-v2', next).readAsBytes(),
        next.bodies[next.action().video.path],
      );
      expect(await current.videoCacheBytes(), 8192);
      expect(harness.requests, [
        old.requestPath(),
        middle.requestPath(),
        next.requestPath(),
      ]);
    },
  );

  test(
    'playing pins with identical paths protect only their namespace',
    () async {
      final fixture = _CatalogFixture('same', seed: 4);
      final incoming = _CatalogFixture('incoming', seed: 5);
      final first = await harness.open(fixture, packVersion: 'r1-v1');
      final second = await harness.open(fixture, packVersion: 'r1-v2');
      final firstUri = await first.ensureFile(fixture.action().video);
      final secondUri = await second.ensureFile(fixture.action().video);
      await File.fromUri(firstUri).setLastModified(DateTime.utc(2020));
      await File.fromUri(secondUri).setLastModified(DateTime.utc(2021));
      final release = first.retainVideo('action-0');
      try {
        final current = await harness.open(incoming, packVersion: 'r1-v3');
        await current.ensureFile(incoming.action().video);
        expect(
          await File.fromUri(firstUri).readAsBytes(),
          fixture.bodies[fixture.action().video.path],
        );
        expect(await File.fromUri(secondUri).exists(), isFalse);
        expect(await current.videoCacheBytes(), 8192);
        expect(
          harness.requests.where((path) => path == fixture.requestPath()),
          hasLength(2),
        );
      } finally {
        release();
        release();
      }
    },
  );

  test(
    'global clear preserves peer pins images JSON unknown video and peer parts',
    () async {
      final firstFixture = _CatalogFixture('clear-first', seed: 30);
      final peerFixture = _CatalogFixture('clear-peer', seed: 31);
      final first = await harness.open(firstFixture, cap: 12288);
      final peer = await harness.open(
        peerFixture,
        packVersion: 'r1-v4',
        cap: 12288,
      );
      await first.ensureAction('action-0');
      final peerUri = await peer.ensureFile(peerFixture.action().video);
      final release = peer.retainVideo('action-0');
      final json = await _write(
        File.fromUri(first.mediaBaseUri.resolve('metadata.json')),
        utf8.encode('{"keep":true}'),
      );
      final peerPart = await _write(
        File('${File.fromUri(peerUri).path}.123_456_789.part'),
        _bytes(17, 41),
      );
      final unknown = await _write(
        File.fromUri(first.mediaBaseUri.resolve('media/unknown/video.mp4')),
        _bytes(99, 42),
      );
      try {
        await first.clearVideoCache();
        expect(
          await _published(harness.support, 'r1-v3', firstFixture).exists(),
          isFalse,
        );
        expect(
          await File.fromUri(peerUri).readAsBytes(),
          peerFixture.bodies[peerFixture.action().video.path],
        );
        expect(await first.videoCacheBytes(), 4195);
        release();
        await first.clearVideoCache();
        expect(await File.fromUri(peerUri).exists(), isFalse);
        expect(await first.videoCacheBytes(), 99);
        for (final image in [
          firstFixture.action().cover,
          firstFixture.action().thumbnail,
        ]) {
          expect(
            await File.fromUri(image.resolve(first.mediaBaseUri)).readAsBytes(),
            firstFixture.bodies[image.path],
          );
        }
        expect(await json.readAsString(), '{"keep":true}');
        expect(await peerPart.readAsBytes(), _bytes(17, 41));
        expect(await unknown.readAsBytes(), _bytes(99, 42));
      } finally {
        release();
      }
    },
  );

  test(
    'trusted legacy ownership survives cold reopen without its old descriptor',
    () async {
      final oldFixture = _CatalogFixture('legacy-before', seed: 40);
      final nextFixture = _CatalogFixture('legacy-after', seed: 41);
      final legacyBytes = _bytes(4096, 91);
      final descriptor = _legacyDescriptor(legacyBytes);
      final legacy = await _write(
        _legacyFile(harness.legacyCache, descriptor.version, descriptor.sha256),
        legacyBytes,
      );
      await legacy.setLastModified(DateTime.utc(2020));
      final first = await harness.open(oldFixture, legacyVideos: [descriptor]);
      final appUri = await first.ensureFile(oldFixture.action().video);
      await File.fromUri(appUri).setLastModified(DateTime.utc(2021));
      expect(await first.videoCacheBytes(), 8192);
      harness.close(first);

      final restarted = await harness.coldSupport();
      final next = await harness.open(nextFixture, supportRoot: restarted);
      await next.ensureFile(nextFixture.action().video);
      expect(await legacy.exists(), isFalse);
      expect(
        await _published(restarted, 'r1-v3', oldFixture).readAsBytes(),
        oldFixture.bodies[oldFixture.action().video.path],
      );
      expect(
        await _published(restarted, 'r1-v3', nextFixture).readAsBytes(),
        nextFixture.bodies[nextFixture.action().video.path],
      );
      expect(await next.videoCacheBytes(), 8192);
      expect(harness.requests, [
        oldFixture.requestPath(),
        nextFixture.requestPath(),
      ]);
    },
  );

  test(
    'legacy hash mismatch stays unowned while a verified legacy video is evicted',
    () async {
      final fixture = _CatalogFixture(
        'legacy-integrity',
        videoSizes: [8192],
        seed: 50,
      );
      final trustedBytes = _bytes(4096, 101);
      final trusted = _legacyDescriptor(trustedBytes);
      final badDescriptor = _legacyDescriptor(
        _bytes(4096, 102),
        version: '0.2.0',
      );
      final good = await _write(
        _legacyFile(harness.legacyCache, trusted.version, trusted.sha256),
        trustedBytes,
      );
      final mismatchedBytes = _bytes(4096, 103);
      final bad = await _write(
        _legacyFile(
          harness.legacyCache,
          badDescriptor.version,
          badDescriptor.sha256,
        ),
        mismatchedBytes,
      );
      await good.setLastModified(DateTime.utc(2020));
      await bad.setLastModified(DateTime.utc(2019));
      final preserved = <File, List<int>>{};
      for (final filename in [
        'poster.webp',
        'metadata.json',
        '${trusted.sha256}.123.part',
      ]) {
        final file = await _write(
          File('${good.parent.path}/$filename'),
          _bytes(33, filename.length),
        );
        preserved[file] = await file.readAsBytes();
      }
      final repository = await harness.open(
        fixture,
        cap: 12288,
        legacyVideos: [trusted, badDescriptor],
      );
      expect(await repository.videoCacheBytes(), 8192);
      await repository.ensureFile(fixture.action().video);

      expect(await good.exists(), isFalse);
      expect(await bad.readAsBytes(), mismatchedBytes);
      expect(await repository.videoCacheBytes(), 12288);
      for (final entry in preserved.entries) {
        expect(await entry.key.readAsBytes(), entry.value);
      }
      await repository.clearVideoCache();
      expect(await repository.videoCacheBytes(), 4096);
      expect(await bad.readAsBytes(), mismatchedBytes);
      for (final entry in preserved.entries) {
        expect(await entry.key.readAsBytes(), entry.value);
      }
    },
  );
}
