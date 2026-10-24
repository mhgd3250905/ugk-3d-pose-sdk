import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/src/media/asset_server.dart';
import 'package:ugk_trainer/src/media/media_view.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

class _Bundle extends CachingAssetBundle {
  _Bundle(this.files);
  final Map<String, List<int>> files;
  @override
  Future<ByteData> load(String key) async {
    final data = files[key];
    if (data == null) throw FlutterError('Missing asset $key');
    return ByteData.sublistView(Uint8List.fromList(data));
  }
}

class _Fixture {
  _Fixture({this.pending = false}) {
    final builtin = _file('../v0.3.0/realistic/dark/builtin.mp4', builtinVideo);
    final extra = _file('../v0.3.0/realistic/dark/extra.mp4', extraVideo);
    packages['builtin'] = _package('builtin', [builtin], ['builtin']);
    packages['realistic-dark'] = _package('realistic-dark', [extra], ['extra']);
    assets['assets/training_media/v0.3.0/realistic/dark/builtin.mp4'] =
        builtinVideo;
    refreshMain();
  }
  static const root = 'assets/training_media/v0.3.0-app/';
  final bool pending;
  final builtinVideo = utf8.encode('builtin-video');
  final extraVideo = List<int>.generate(4096, (i) => i % 251);
  final Map<String, List<int>> assets = {};
  final Map<String, dynamic> packages = {};
  final Map<String, List<int>> remote = {};
  Map<String, dynamic> _file(String path, List<int> bytes) => {
    'path': path,
    'bytes': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
  };
  Map<String, dynamic> _package(
    String id,
    List<Map<String, dynamic>> files,
    List<String> ids,
  ) {
    final bytes = utf8.encode(jsonEncode({'files': files}));
    assets['${root}packages/$id.json'] = bytes;
    remote['/v0.3.0-app/packages/$id.json'] = bytes;
    return {
      'kind': 'video',
      'actionIds': ids,
      'totalBytes': files.fold<int>(0, (sum, f) => sum + (f['bytes'] as int)),
      'fileCount': files.length,
      'manifest': _file('packages/$id.json', bytes),
    };
  }

  void refreshMain() {
    assets['${root}app-manifest.json'] = utf8.encode(
      jsonEncode({
        'version': '0.3.0',
        'packages': packages,
        'actions': [
          for (final id in ['builtin', 'extra'])
            {'id': id, 'nameZh': id, 'releaseEligible': !pending},
        ],
      }),
    );
    remote['/v0.3.0/realistic/dark/extra.mp4'] = extraVideo;
  }

  Future<TrainingMediaRepository> create(
    Directory directory, {
    List<Uri> mirrors = const [],
    bool allowPending = false,
    TrainingMediaNetworkProbe? probe,
    String? manifestSha256,
    Duration downloadTimeout = const Duration(seconds: 15),
  }) => TrainingMediaRepository.create(
    manifestAsset: '${root}app-manifest.json',
    baseUrls: mirrors,
    allowPending: allowPending,
    bundle: _Bundle(assets),
    cacheDirectory: directory.path,
    bundledAssetKeys: assets.keys,
    networkProbe: probe ?? () async => TrainingMediaNetwork.wifi,
    manifestSha256: manifestSha256,
    downloadTimeout: downloadTimeout,
  );
}

void main() {
  late Directory temp;
  final repositories = <TrainingMediaRepository>[];
  final servers = <HttpServer>[];
  setUp(() async {
    HttpOverrides.global = null;
    temp = await Directory.systemTemp.createTemp('trainer-media-test-');
  });
  tearDown(() async {
    for (final repository in repositories) {
      repository.dispose();
    }
    repositories.clear();
    for (final server in servers) {
      await server.close(force: true);
    }
    servers.clear();
    await temp.delete(recursive: true);
  });
  Future<HttpServer> serve(Future<void> Function(HttpRequest) handler) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(server);
    server.listen((r) => unawaited(handler(r)));
    return server;
  }

  Uri base(HttpServer server) =>
      Uri.parse('http://127.0.0.1:${server.port}/v0.3.0-app/');

  Future<void> showMedia(
    WidgetTester tester,
    TrainingMediaRepository repository, {
    required DrillMedia media,
    bool playing = true,
    Brightness brightness = Brightness.dark,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      themeAnimationDuration: Duration.zero,
      home: TrainingMediaScope(
        repository: repository,
        child: SizedBox(
          width: 200,
          height: 200,
          child: DrillMediaView(
            playing: playing,
            media: media,
            unavailableLabel: 'Still illustration',
            errorLabel: 'Playback failed',
          ),
        ),
      ),
    ),
  );
  Future<void> respond(HttpRequest r, _Fixture fixture) async {
    final bytes = fixture.remote[r.uri.path];
    if (bytes == null) {
      r.response.statusCode = 404;
    } else {
      r.response.contentLength = bytes.length;
      r.response.add(bytes);
    }
    await r.response.close();
  }

  test(
    'default policy hides pending actions; explicit debug gate reveals them',
    () async {
      final fixture = _Fixture(pending: true);
      final repository = await fixture.create(temp);
      repositories.add(repository);
      expect(repository.visibleActions, isEmpty);
      expect(repository.readyActionIds, isEmpty);
      await expectLater(repository.ensureVideo('builtin'), throwsStateError);
      repository.allowPending = true;
      expect(repository.visibleActions.map((a) => a.id), ['builtin', 'extra']);
      expect(await repository.availableActionIds(), {'builtin'});
      repository.allowPending = false;
      expect(repository.readyActionIds, isEmpty);
    },
  );

  test('bundled dark extras and light videos resolve offline', () async {
    final fixture = _Fixture();
    final light = utf8.encode('light-extra-video');
    fixture.packages['realistic-light'] = fixture._package(
      'realistic-light',
      [fixture._file('../v0.3.0/realistic/light/extra.mp4', light)],
      ['extra'],
    );
    fixture.assets['assets/training_media/v0.3.0/realistic/dark/extra.mp4'] =
        fixture.extraVideo;
    fixture.assets['assets/training_media/v0.3.0/realistic/light/extra.mp4'] =
        light;
    fixture.refreshMain();
    final repository = await fixture.create(
      temp,
      probe: () async => TrainingMediaNetwork.offline,
    );
    repositories.add(repository);
    expect(repository.baseUrls, isEmpty);
    expect(
      (await repository.ensureVideo('extra')).assetKey,
      'assets/training_media/v0.3.0/realistic/dark/extra.mp4',
    );
    expect(
      (await repository.ensureVideo('extra', theme: 'light')).assetKey,
      'assets/training_media/v0.3.0/realistic/light/extra.mp4',
    );
    expect(await repository.cacheBytes(), 0);
  });

  test('main and bundled submanifest hash mismatch fail closed', () async {
    final fixture = _Fixture();
    await expectLater(
      fixture.create(temp, manifestSha256: '0' * 64),
      throwsFormatException,
    );
    fixture.assets['${_Fixture.root}packages/builtin.json'] = utf8.encode(
      '{"files":[]}',
    );
    await expectLater(fixture.create(temp), throwsFormatException);
  });

  test(
    'builtin plays offline; missing media reports offline without network request',
    () async {
      final repository = await _Fixture().create(
        temp,
        probe: () async => TrainingMediaNetwork.offline,
      );
      repositories.add(repository);
      expect(repository.isOffline, isTrue);
      expect(
        (await repository.ensureVideo('builtin')).assetKey,
        contains('builtin.mp4'),
      );
      await expectLater(repository.ensureVideo('extra'), throwsStateError);
      expect(repository.stateFor('extra').phase, TrainingMediaPhase.offline);
      expect(repository.isOffline, isTrue);
      expect(await repository.cacheBytes(), 0);
    },
  );

  test(
    'mirrors fallback after bad digest; concurrent callers download once and cache is reverified',
    () async {
      final fixture = _Fixture();
      var badHits = 0;
      var goodHits = 0;
      final bad = await serve((r) async {
        badHits++;
        r.response.contentLength = fixture.extraVideo.length;
        r.response.add(List.filled(fixture.extraVideo.length, 0));
        await r.response.close();
      });
      final good = await serve((r) async {
        goodHits++;
        await respond(r, fixture);
      });
      final repository = await fixture.create(
        temp,
        mirrors: [base(bad), base(good)],
      );
      repositories.add(repository);
      final resources = await Future.wait(
        List.generate(6, (_) => repository.ensureVideo('extra')),
      );
      expect(badHits, 1);
      expect(goodHits, 1);
      expect(
        resources.every((r) => r.cachePath == resources.first.cachePath),
        isTrue,
      );
      expect(await repository.cacheBytes(), fixture.extraVideo.length);
      expect(await repository.availableActionIds(), {'builtin', 'extra'});
      repository.wifiOnly = false;
      final offline = await fixture.create(
        temp,
        probe: () async => TrainingMediaNetwork.offline,
      );
      repositories.add(offline);
      expect(
        (await offline.ensureVideo('extra')).cachePath,
        resources.first.cachePath,
      );
      await File(
        resources.first.cachePath!,
      ).writeAsBytes(List.filled(fixture.extraVideo.length, 1));
      expect(await offline.availableVideo('extra'), isNull);
      expect(await offline.cacheBytes(), 0);
    },
  );

  test(
    'weak streamed download is unavailable until complete and verified',
    () async {
      final fixture = _Fixture();
      final started = Completer<void>();
      final release = Completer<void>();
      final server = await serve((r) async {
        r.response.contentLength = fixture.extraVideo.length;
        r.response.add(fixture.extraVideo.sublist(0, 128));
        await r.response.flush();
        started.complete();
        await release.future;
        r.response.add(fixture.extraVideo.sublist(128));
        await r.response.close();
      });
      final repository = await fixture.create(temp, mirrors: [base(server)]);
      repositories.add(repository);
      final pending = repository.ensureVideo('extra');
      await started.future;
      expect(await repository.availableVideo('extra'), isNull);
      expect(repository.readyActionIds, {'builtin'});
      expect(await repository.cacheBytes(), 0);
      release.complete();
      final resource = await pending;
      expect(await File(resource.cachePath!).readAsBytes(), fixture.extraVideo);
      expect(repository.stateFor('extra').phase, TrainingMediaPhase.ready);
    },
  );

  test(
    'cache size and clear include old versions but preserve other app caches',
    () async {
      final fixture = _Fixture();
      final server = await serve((r) => respond(r, fixture));
      final repository = await fixture.create(temp, mirrors: [base(server)]);
      repositories.add(repository);
      final current = await repository.ensureVideo('extra');
      expect(current.cachePath, contains('/training-media/0.3.0/'));
      final old = Directory('${temp.path}/training-media/0.2.0');
      await old.create(recursive: true);
      await File('${old.path}/old-video').writeAsBytes(List.filled(73, 1));
      await File(
        '${old.path}/interrupted.part',
      ).writeAsBytes(List.filled(11, 0));
      final unrelated = File('${temp.path}/other-feature/cache');
      await unrelated.parent.create(recursive: true);
      await unrelated.writeAsString('keep app cache');
      expect(await repository.cacheBytes(), fixture.extraVideo.length + 73);
      await repository.clearCache();
      expect(await repository.cacheBytes(), 0);
      expect(await Directory('${temp.path}/training-media').exists(), isFalse);
      expect(await unrelated.readAsString(), 'keep app cache');
      expect(repository.readyActionIds, {'builtin'});
    },
  );

  test(
    'cache size tolerates concurrent deletion of version directories and files',
    () async {
      final repository = await _Fixture().create(temp);
      repositories.add(repository);
      final old = Directory('${temp.path}/training-media/0.2.0');
      await old.create(recursive: true);
      for (var i = 0; i < 128; i++) {
        await File('${old.path}/video-$i').writeAsBytes(List.filled(16, i));
      }
      final snapshots = List.generate(12, (_) => repository.cacheBytes());
      final clear = repository.clearCache();
      final sizes = await Future.wait(snapshots);
      await clear;
      expect(sizes.every((size) => size >= 0 && size <= 128 * 16), isTrue);
      expect(await repository.cacheBytes(), 0);
    },
  );

  test(
    'clear cancels in-flight transfer and generation prevents late cache resurrection',
    () async {
      final fixture = _Fixture();
      final started = Completer<void>();
      final release = Completer<void>();
      final server = await serve((r) async {
        r.response.contentLength = fixture.extraVideo.length;
        r.response.add(fixture.extraVideo.sublist(0, 128));
        await r.response.flush();
        started.complete();
        await release.future;
        try {
          r.response.add(fixture.extraVideo.sublist(128));
          await r.response.close();
        } catch (_) {
          /* Expected: client was cancelled. */
        }
      });
      final repository = await fixture.create(temp, mirrors: [base(server)]);
      repositories.add(repository);
      final pending = repository.ensureVideo('extra');
      final failure = expectLater(pending, throwsA(anything));
      await started.future;
      final clear = repository.clearCache();
      expect(identical(repository.clearCache(), clear), isTrue);
      await clear;
      release.complete();
      await failure;
      expect(await repository.cacheBytes(), 0);
      expect(repository.readyActionIds, {'builtin'});
      expect(await repository.availableVideo('extra'), isNull);
      final remaining = await temp
          .list(recursive: true)
          .where((e) => e is File)
          .toList();
      expect(remaining, isEmpty);
    },
  );

  test(
    'wifi-only blocks cellular and a mid-stream change drops the partial file',
    () async {
      final fixture = _Fixture();
      var network = TrainingMediaNetwork.mobile;
      var hits = 0;
      final server = await serve((r) async {
        hits++;
        r.response.contentLength = fixture.extraVideo.length;
        r.response.add(fixture.extraVideo.sublist(0, 128));
        await r.response.flush();
        network = TrainingMediaNetwork.mobile;
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        try {
          r.response.add(fixture.extraVideo.sublist(128));
          await r.response.close();
        } catch (_) {
          /* Policy cancelled socket. */
        }
      });
      final repository = await fixture.create(
        temp,
        mirrors: [base(server)],
        probe: () async => network,
      );
      repositories.add(repository);
      await expectLater(repository.ensureVideo('extra'), throwsStateError);
      expect(
        repository.stateFor('extra').phase,
        TrainingMediaPhase.waitingForWifi,
      );
      expect(hits, 0);
      network = TrainingMediaNetwork.wifi;
      await expectLater(repository.ensureVideo('extra'), throwsStateError);
      expect(hits, 1);
      expect(await repository.cacheBytes(), 0);
      expect(await repository.availableVideo('extra'), isNull);
    },
  );

  test(
    'policy-blocked requests resume on Wi-Fi and HTTP failures do not retry',
    () async {
      final fixture = _Fixture();
      var network = TrainingMediaNetwork.mobile;
      var hits = 0;
      final server = await serve((r) async {
        hits++;
        await respond(r, fixture);
      });
      final repository = await fixture.create(
        temp,
        mirrors: [base(server)],
        probe: () async => network,
      );
      repositories.add(repository);
      await repository.prefetchActions(['extra']);
      expect(
        repository.stateFor('extra').phase,
        TrainingMediaPhase.waitingForWifi,
      );
      network = TrainingMediaNetwork.wifi;
      await repository.canDownload();
      await repository.ensureVideo('extra');
      expect(hits, 1);
      expect(repository.readyActionIds, contains('extra'));
      await repository.clearCache();
      fixture.remote.clear();
      await expectLater(repository.ensureVideo('extra'), throwsA(anything));
      expect(repository.stateFor('extra').phase, TrainingMediaPhase.failed);
      network = TrainingMediaNetwork.mobile;
      await repository.canDownload();
      network = TrainingMediaNetwork.wifi;
      await repository.canDownload();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(hits, 2);
    },
  );

  test(
    'stalled body times out, removes partials, and attempts the second mirror',
    () async {
      final fixture = _Fixture();
      final release = Completer<void>();
      var stalledHits = 0;
      final stalled = await serve((r) async {
        stalledHits++;
        r.response.contentLength = fixture.extraVideo.length;
        r.response.add(fixture.extraVideo.sublist(0, 128));
        await r.response.flush();
        await release.future;
        try {
          await r.response.close();
        } catch (_) {
          // The timed out client has closed its socket.
        }
      });
      final good = await serve((r) => respond(r, fixture));
      final repository = await fixture.create(
        temp,
        mirrors: [base(stalled), base(good)],
        downloadTimeout: const Duration(milliseconds: 100),
      );
      repositories.add(repository);
      final result = await repository.ensureVideo('extra');
      release.complete();
      expect(stalledHits, 1);
      expect(await File(result.cachePath!).readAsBytes(), fixture.extraVideo);
      expect(
        await temp
            .list(recursive: true)
            .where((f) => f.path.endsWith('.part'))
            .toList(),
        isEmpty,
      );
    },
  );

  test(
    'startup removes a corrupt persistent cache before exposing ready ids',
    () async {
      final fixture = _Fixture();
      final server = await serve((r) => respond(r, fixture));
      final repository = await fixture.create(temp, mirrors: [base(server)]);
      repositories.add(repository);
      final result = await repository.ensureVideo('extra');
      await File(
        result.cachePath!,
      ).writeAsBytes(List.filled(fixture.extraVideo.length, 0));
      final restarted = await fixture.create(
        temp,
        probe: () async => TrainingMediaNetwork.offline,
      );
      repositories.add(restarted);
      expect(restarted.readyActionIds, {'builtin'});
      expect(await restarted.cacheBytes(), 0);
    },
  );

  test(
    'even correctly hashed submanifests must match package action ids',
    () async {
      final fixture = _Fixture();
      fixture.packages['realistic-dark'] = fixture._package(
        'realistic-dark',
        [
          fixture._file(
            '../v0.3.0/realistic/dark/wrong.mp4',
            fixture.extraVideo,
          ),
        ],
        ['extra'],
      );
      fixture.refreshMain();
      await expectLater(fixture.create(temp), throwsFormatException);
    },
  );

  test(
    'other package submanifest is fetched and verified before video lookup',
    () async {
      final fixture = _Fixture();
      final video = fixture._file(
        '../v0.3.0/neon-night/dark/extra.mp4',
        fixture.extraVideo,
      );
      fixture.packages['neon-night-dark'] = fixture._package(
        'neon-night-dark',
        [video],
        ['extra'],
      );
      fixture.assets.remove('${_Fixture.root}packages/neon-night-dark.json');
      fixture.refreshMain();
      fixture.remote['/v0.3.0/neon-night/dark/extra.mp4'] = fixture.extraVideo;
      final hits = <String>[];
      final server = await serve((r) async {
        hits.add(r.uri.path);
        await respond(r, fixture);
      });
      final repository = await fixture.create(temp, mirrors: [base(server)]);
      repositories.add(repository);
      final resource = await repository.ensureVideo(
        'extra',
        skin: 'neon-night',
      );
      expect(resource.cachePath, isNotNull);
      expect(hits, [
        '/v0.3.0-app/packages/neon-night-dark.json',
        '/v0.3.0/neon-night/dark/extra.mp4',
      ]);
      await repository.clearCache();
      fixture.remote['/v0.3.0-app/packages/neon-night-dark.json'] = utf8.encode(
        '{"files":[]}',
      );
      hits.clear();
      await expectLater(
        repository.ensureVideo('extra', skin: 'neon-night'),
        throwsA(anything),
      );
      expect(hits, ['/v0.3.0-app/packages/neon-night-dark.json']);
      expect(await repository.cacheBytes(), 0);
    },
  );

  test(
    'corrupt videos never activate; package progress and path allowlist are bounded',
    () async {
      final fixture = _Fixture();
      final server = await serve((r) async {
        r.response.contentLength = fixture.extraVideo.length;
        r.response.add(List.filled(fixture.extraVideo.length, 0));
        await r.response.close();
      });
      final repository = await fixture.create(temp, mirrors: [base(server)]);
      repositories.add(repository);
      await expectLater(repository.downloadPackage(), throwsFormatException);
      expect(
        repository.stateFor('realistic-dark').phase,
        TrainingMediaPhase.failed,
      );
      expect(await repository.availableVideo('extra'), isNull);
      expect(await repository.cacheBytes(), 0);
      for (final path in [
        '../../secret',
        '../v9.0.0/secret',
        '/secret',
        'a/%2e/x',
        'a/../x',
        'https://evil/x',
      ]) {
        expect(repository.manifest.permitsPath(path), isFalse, reason: path);
      }
      expect(
        repository.manifest.permitsPath('../v0.3.0/realistic/dark/extra.mp4'),
        isTrue,
      );
    },
  );

  test(
    'verified cache capability serves byte ranges without exposing arbitrary paths',
    () async {
      final fixture = _Fixture();
      final remote = await serve((r) => respond(r, fixture));
      final repository = await fixture.create(temp, mirrors: [base(remote)]);
      repositories.add(repository);
      final resource = await repository.ensureVideo('extra');
      final local = await AssetServer.start(
        resource: resource,
        router: AssetRouter(assets: [], load: (_) async => Uint8List(0)),
      );
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          local.origin.resolve(AssetServer.verifiedMediaPath),
        );
        request.headers.set('Range', 'bytes=3-15');
        final response = await request.close();
        expect(response.statusCode, 206);
        expect(
          await response.fold<List<int>>([], (a, b) => a..addAll(b)),
          fixture.extraVideo.sublist(3, 16),
        );
        expect(response.headers.value('Content-Range'), 'bytes 3-15/4096');
        final denied = await (await client.getUrl(
          local.origin.resolve('/verified-media/not-registered.mp4'),
        )).close();
        expect(denied.statusCode, 404);
        await denied.drain<void>();
        final invalid = await client.getUrl(
          local.origin.resolve(AssetServer.verifiedMediaPath),
        );
        invalid.headers.set('Range', 'bytes=0-1,3-4');
        final invalidResponse = await invalid.close();
        expect(invalidResponse.statusCode, 416);
        await invalidResponse.drain<void>();
        final head = await client.openUrl(
          'HEAD',
          local.origin.resolve(AssetServer.verifiedMediaPath),
        );
        head.headers.set('Range', 'bytes=3-15');
        final headResponse = await head.close();
        expect(headResponse.statusCode, 200);
        expect(headResponse.contentLength, fixture.extraVideo.length);
        expect(
          await headResponse.fold<List<int>>([], (a, b) => a..addAll(b)),
          isEmpty,
        );
      } finally {
        client.close(force: true);
        await local.close();
      }
    },
  );

  testWidgets(
    'declared still-only media never resolves and keeps separate host copy',
    (tester) async {
      late TrainingMediaRepository repository;
      var probes = 0;
      await tester.runAsync(() async {
        repository = await _Fixture().create(
          temp,
          probe: () async {
            probes++;
            return TrainingMediaNetwork.wifi;
          },
        );
        repositories.add(repository);
      });
      final before = probes;
      for (final playing in [true, false]) {
        await showMedia(
          tester,
          repository,
          playing: playing,
          media: const DrillMedia(
            id: 'extra',
            videoAsset: 'unused.mp4',
            posterAsset: 'cover.webp',
            duration: 5,
            videoAvailable: false,
          ),
        );
        await tester.pump();
        expect(find.text('Still illustration'), findsOneWidget);
        expect(find.text('Playback failed'), findsNothing);
        expect(find.text('正在加载动作视频'), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byType(DrillMediaPlatformView), findsNothing);
        expect(find.byType(Image), findsOneWidget);
        expect(repository.stateFor('extra').phase, TrainingMediaPhase.idle);
        expect(probes, before);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('availability changes for one move create and dispose playback', (
    tester,
  ) async {
    late TrainingMediaRepository repository;
    await tester.runAsync(() async {
      repository = await _Fixture().create(temp);
      repositories.add(repository);
    });
    Future<void> pump(bool available) => showMedia(
      tester,
      repository,
      media: DrillMedia(
        id: 'builtin',
        videoAsset: 'unused.mp4',
        posterAsset: 'cover.webp',
        duration: 5,
        videoAvailable: available,
      ),
    );
    await pump(false);
    expect(find.byType(DrillMediaPlatformView), findsNothing);
    await pump(true);
    await tester.pump();
    final playback = tester.widget<DrillMediaPlatformView>(
      find.byType(DrillMediaPlatformView),
    );
    // The desktop test platform reports unsupported playback after mounting;
    // the view still owns exactly one controller until availability changes.
    await pump(false);
    expect(playback.controller.wantsPlay, isFalse);
    expect(find.byType(DrillMediaPlatformView), findsNothing);
    expect(find.text('Still illustration'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'explicit theme handover drops the old frame while the next video resolves',
    (tester) async {
      final fixture = _Fixture();
      final light = utf8.encode('light-extra-video');
      fixture.packages['realistic-light'] = fixture._package(
        'realistic-light',
        [fixture._file('../v0.3.0/realistic/light/extra.mp4', light)],
        ['extra'],
      );
      fixture.assets['assets/training_media/v0.3.0/realistic/dark/extra.mp4'] =
          fixture.extraVideo;
      fixture.remote['/v0.3.0/realistic/light/extra.mp4'] = light;
      fixture.refreshMain();
      final responseGate = Completer<void>();
      final requested = <String>[];
      late TrainingMediaRepository repository;
      await tester.runAsync(() async {
        final server = await serve((request) async {
          requested.add(request.uri.path);
          await responseGate.future;
          await respond(request, fixture);
        });
        repository = await fixture.create(temp, mirrors: [base(server)]);
        repositories.add(repository);
      });
      Future<void> pump(String theme) => showMedia(
        tester,
        repository,
        brightness: theme == 'light' ? Brightness.light : Brightness.dark,
        media: DrillMedia(
          id: 'extra',
          theme: theme,
          videoAsset: 'dark.mp4',
          lightVideoAsset: 'light.mp4',
          posterAsset: 'dark.webp',
          lightPosterAsset: 'light.webp',
          duration: 5,
        ),
      );
      await pump('dark');
      await tester.pump();
      final dark = tester.widget<DrillMediaPlatformView>(
        find.byType(DrillMediaPlatformView),
      );
      expect(dark.resource!.assetKey, contains('/dark/extra.mp4'));
      dark.controller.failed = false;
      dark.controller.receive({'source': 'drill-media', 'type': 'first-frame'});
      await tester.pump();
      // The target poster stays underneath the first-frame-gated surface.
      expect(find.byType(Image), findsOneWidget);
      await pump('light');
      expect(dark.controller.wantsPlay, isFalse);
      expect(find.byType(DrillMediaPlatformView), findsNothing);
      expect(find.byType(Image), findsOneWidget);
      expect(
        (tester.widget<Image>(find.byType(Image)).image as AssetImage)
            .assetName,
        'light.webp',
      );
      for (var attempt = 0; attempt < 20 && requested.isEmpty; attempt++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        });
        await tester.pump();
      }
      expect(requested, ['/v0.3.0/realistic/light/extra.mp4']);
      responseGate.complete();
      for (
        var attempt = 0;
        attempt < 20 && find.byType(DrillMediaPlatformView).evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        });
        await tester.pump();
      }
      final current = tester.widget<DrillMediaPlatformView>(
        find.byType(DrillMediaPlatformView),
      );
      expect(current.controller, isNot(same(dark.controller)));
      expect(current.media.theme, 'light');
      expect(current.videoAsset, 'light.mp4');
      expect(current.resource!.cachePath, isNotNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('playing selection keeps only the chosen card controller alive', (
    tester,
  ) async {
    Future<void> pump(int selected) => tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            for (var index = 0; index < 2; index++)
              SizedBox(
                width: 150,
                height: 150,
                child: DrillMediaView(
                  key: ValueKey(index),
                  playing: selected == index,
                  media: DrillMedia(
                    id: 'card-$index',
                    videoAsset: 'video-$index.mp4',
                    posterAsset: 'cover-$index.webp',
                    duration: 5,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    await pump(0);
    final first = tester.widget<DrillMediaPlatformView>(
      find.byType(DrillMediaPlatformView),
    );
    expect(first.media.id, 'card-0');
    await pump(1);
    final second = tester.widget<DrillMediaPlatformView>(
      find.byType(DrillMediaPlatformView),
    );
    expect(second.media.id, 'card-1');
    expect(first.controller.wantsPlay, isFalse);
    await pump(-1);
    expect(find.byType(DrillMediaPlatformView), findsNothing);
    expect(second.controller.wantsPlay, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('declared video failures are not presented as missing media', (
    tester,
  ) async {
    late TrainingMediaRepository repository;
    await tester.runAsync(() async {
      repository = await _Fixture().create(temp);
      repositories.add(repository);
    });
    await showMedia(
      tester,
      repository,
      media: const DrillMedia(
        id: 'extra',
        videoAsset: 'unused.mp4',
        posterAsset: 'cover.webp',
        duration: 5,
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(repository.stateFor('extra').phase, TrainingMediaPhase.failed);
    expect(find.text('Playback failed'), findsOneWidget);
    expect(find.text('Still illustration'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'the current cover view follows Wi-Fi retry and cache clear invalidation',
    (tester) async {
      final fixture = _Fixture();
      var network = TrainingMediaNetwork.mobile;
      late TrainingMediaRepository repository;
      await tester.runAsync(() async {
        final server = await serve((r) => respond(r, fixture));
        repository = await fixture.create(
          temp,
          mirrors: [base(server)],
          probe: () async => network,
        );
        repositories.add(repository);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: TrainingMediaScope(
            repository: repository,
            child: const SizedBox(
              width: 200,
              height: 200,
              child: DrillMediaView(
                errorLabel: 'Video unavailable; training continues',
                media: DrillMedia(
                  id: 'extra',
                  videoAsset: 'unused.mp4',
                  posterAsset: 'unused.webp',
                  duration: 5,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
      expect(
        find.text('Video unavailable; training continues'),
        findsOneWidget,
      );
      await tester.runAsync(() async {
        network = TrainingMediaNetwork.wifi;
        await repository.canDownload();
        await repository.ensureVideo('extra');
      });
      await tester.pump();
      expect(repository.stateFor('extra').phase, TrainingMediaPhase.ready);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.runAsync(repository.clearCache);
      await tester.pump();
      expect(repository.stateFor('extra').phase, TrainingMediaPhase.idle);
      expect(
        find.text('Video unavailable; training continues'),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(await tester.runAsync(repository.cacheBytes), 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'media loading/failure leaves independent clock running and cover visible',
    (tester) async {
      final fixture = _Fixture();
      final gate = Completer<TrainingMediaNetwork>();
      var initialization = true;
      late TrainingMediaRepository repository;
      await tester.runAsync(() async {
        repository = await fixture.create(
          temp,
          probe: () => initialization
              ? Future.value(TrainingMediaNetwork.wifi)
              : gate.future,
        );
        repositories.add(repository);
        initialization = false;
      });
      var elapsed = 0;
      final timer = Timer.periodic(const Duration(seconds: 1), (_) {
        elapsed++;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 250,
            height: 250,
            child: TrainingMediaScope(
              repository: repository,
              child: const DrillMediaView(
                media: DrillMedia(
                  id: 'extra',
                  videoAsset: 'unused.mp4',
                  posterAsset: 'cover.webp',
                  duration: 5,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('正在加载动作视频'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(elapsed, 2);
      gate.complete(TrainingMediaNetwork.offline);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      expect(find.text('动作视频暂不可用，训练继续'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(Image), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(elapsed, 4);
      timer.cancel();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
