import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

const _assetDir = '../ugk_trainer/assets/pose_hub/app-pack-r2-v1/';

/// Reads the SDK's real bundled r2-v1 catalogue from the sibling package.
class _PackBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final path = key.replaceFirst(
      'packages/ugk_trainer/assets/pose_hub/app-pack-r2-v1/',
      _assetDir,
    );
    return ByteData.sublistView(await File(path).readAsBytes());
  }
}

/// No network: every response is scripted per URL.
class _FakeHttp implements PoseHubCatalogHttpClient {
  final routes =
      <String, PoseHubCatalogHttpResponse Function(Map<String, String>)>{};
  final requests = <String>[];
  final requestHeaders = <Map<String, String>>[];

  void serve(String url, List<int> body, {String? etag}) =>
      routes[url] = (_) =>
          PoseHubCatalogHttpResponse(200, Uint8List.fromList(body), etag: etag);

  @override
  Future<PoseHubCatalogHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    int maxBytes = 64 * 1024 * 1024,
  }) async {
    requests.add(uri.toString());
    requestHeaders.add(headers);
    final route = routes[uri.toString()];
    if (route == null) throw const SocketException('offline');
    final response = route(headers);
    if (response.body.length > maxBytes) {
      throw const HttpException('Response exceeds its size limit');
    }
    return response;
  }
}

const _pointerUrl = 'https://media.uuugk.win/pack/channels/dev.json';
const _config = PoseHubCatalogUpdateConfig(channel: PoseHubCatalogChannel.dev);

Map<String, Object?> _pointer(
  String pack,
  List<int> catalog, {
  String? sha,
  int? bytes,
  String minSdk = '0.7.0',
}) => {
  'schema': 1,
  'pack': pack,
  'catalog': 'https://media.uuugk.win/pack/$pack/catalog.json',
  'catalog_sha256': sha ?? sha256.convert(catalog).toString(),
  'catalog_bytes': bytes ?? catalog.length,
  'min_sdk': minSdk,
  'published_at': '2026-11-04T17:47:00+08:00',
};

List<int> _json(Object value) => utf8.encode(jsonEncode(value));

/// A small catalogue with only [count] fixture actions (missing all R1 IDs).
List<int> _smallCatalog(String pack, int count) {
  const flags = {
    'status': 'test-unreviewed',
    'reviewed': false,
    'releaseEligible': false,
  };
  final rows = [
    for (var i = 0; i < count; i++)
      {
        'id': 'action-$i',
        'nameZh': 'Fixture $i',
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
        'files': {
          for (final role in ['video', 'cover', 'thumbnail'])
            role: {
              'path':
                  'media/action-$i/$role.${role == 'video' ? 'mp4' : 'webp'}',
              'bytes': 4,
              'sha256': sha256.convert([i, 1, 2, role.length]).toString(),
            },
        },
      },
  ];
  return _json({
    'format': 'pose-hub-app-test-catalog@1',
    'id': 'fixture',
    'pack': pack,
    ...flags,
    'totalCount': count,
    'readyCount': count,
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
      'incompleteActionIds': [for (final r in rows) r['id']],
      'videoLoopIsTrainingDose': false,
    },
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List r1Bytes;
  late Uint8List semanticBytes;
  late coach.PoseHubAppTestCatalog bundled;

  /// The real R1 catalogue re-released as [pack] (same IDs, add-only OK).
  List<int> repack(String pack) {
    final raw = jsonDecode(utf8.decode(r1Bytes)) as Map<String, Object?>;
    return _json({...raw, 'pack': pack});
  }

  late _FakeHttp http;
  late MemoryPoseHubCatalogStore store;
  late List<PoseHubCatalogUpdateEvent> events;
  late DateTime now;

  PoseHubCatalogUpdater updater() => PoseHubCatalogUpdater(
    config: _config,
    store: store,
    http: http,
    now: () => now,
    loadLocal: () async => await readVerifiedPoseHubCatalog(store) ?? bundled,
    onEvent: events.add,
  );

  void publish(
    String pack,
    List<int> catalog, {
    Map<String, Object?>? pointer,
  }) {
    http.serve(_pointerUrl, _json(pointer ?? _pointer(pack, catalog)));
    http.serve('https://media.uuugk.win/pack/$pack/catalog.json', catalog);
    http.serve(
      'https://media.uuugk.win/pack/$pack/catalog/catalog.json',
      semanticBytes,
    );
  }

  Future<String> loadedPack() async => poseHubPackVersionOf(
    await PoseHubActionLibrary.load(
      bundle: _PackBundle(),
      verifiedCache: store,
    ),
  );

  setUpAll(() async {
    r1Bytes = await File('${_assetDir}catalog.json').readAsBytes();
    semanticBytes = await File(
      '${_assetDir}catalog/catalog.json',
    ).readAsBytes();
    bundled = await PoseHubActionLibrary.loadBundled(bundle: _PackBundle());
  });

  setUp(() {
    http = _FakeHttp();
    store = MemoryPoseHubCatalogStore();
    events = [];
    now = DateTime.utc(2026, 11, 4, 10);
  });

  test('bundled r2-v1 declares pack r2-v1, schema 1 and its media root', () {
    expect(bundled.raw['pack'], 'r2-v1');
    expect(bundled.raw['schema'], 1);
    expect(poseHubPackVersionOf(bundled), 'r2-v1');
    expect(PoseHubActionLibrary.packVersion, 'r2-v1');
    expect(sha256.convert(r1Bytes).toString(), PoseHubActionLibrary.catalogSha256);
    expect(bundled.allActions, hasLength(249));
    expect(bundled.raw['readyCount'], 249);
    expect(
      bundled.allActions.every(
        (a) => a.status == coach.PoseHubActionStatus.active,
      ),
      isTrue,
    );
    expect(
      PoseHubActionLibrary.mediaBaseUriFor(bundled).toString(),
      PoseHubActionLibrary.mediaReleaseBaseUri,
    );
    expect(
      TrainingMediaPolicy.publicBaseUrl,
      PoseHubActionLibrary.mediaReleaseBaseUri,
    );
    expect(_config.pointerUri.toString(), _pointerUrl);
  });

  test('the generated channel pointer and r2-v1 catalogue are accepted', () async {
    final pointer = await File(
      'test/fixtures/pose_hub/channels/dev.json',
    ).readAsBytes();
    final parsed = PoseHubCatalogPointer.fromBytes(pointer);
    expect(parsed.pack, 'r2-v1');
    expect(parsed.minSdk, '0.8.0');
    expect(parsed.catalogBytes, r1Bytes.length);
    expect(parsed.catalogSha256, PoseHubActionLibrary.catalogSha256);
    http.serve(_pointerUrl, pointer);
    http.serve('https://media.uuugk.win/pack/r2-v1/catalog.json', r1Bytes);
    http.serve(
      'https://media.uuugk.win/pack/r2-v1/catalog/catalog.json',
      semanticBytes,
    );
    // A host still on a pre-pack catalogue switches to r2-v1.
    final legacy = jsonDecode(utf8.decode(r1Bytes)) as Map<String, Object?>
      ..remove('pack');
    final u = PoseHubCatalogUpdater(
      config: _config,
      store: store,
      http: http,
      now: () => now,
      loadLocal: () async => coach.PoseHubAppTestCatalog.fromJson(legacy),
      onEvent: events.add,
    );
    expect(await u.checkNow(), PoseHubCatalogUpdateOutcome.updated);
    expect(await loadedPack(), 'r2-v1');
    // With r2-v1 bundled, the same pointer is a no-op.
    expect(await updater().checkNow(), PoseHubCatalogUpdateOutcome.unchanged);
  });

  test('pointer parsing rejects bad fields', () {
    final good = _pointer('r2-v2', [1, 2, 3]);
    final parsed = PoseHubCatalogPointer.fromJson(good);
    expect(parsed.pack, 'r2-v2');
    expect(parsed.catalogBytes, 3);
    for (final bad in [
      {...good, 'schema': 2},
      {...good, 'pack': 'R2 v1'},
      {...good, 'catalog': 'http://media.uuugk.win/x.json'},
      {...good, 'catalog_sha256': 'abc'},
      {...good, 'catalog_bytes': 0},
      {...good, 'min_sdk': '1.0'},
      {...good, 'published_at': 'soon'},
    ]) {
      expect(() => PoseHubCatalogPointer.fromJson(bad), throwsFormatException);
    }
    expect(comparePoseHubSdkVersions('0.10.0', '0.9.9'), greaterThan(0));
  });

  test('offline first launch uses the bundled baseline', () async {
    expect(await updater().maybeCheck(), PoseHubCatalogUpdateOutcome.failed);
    expect(events.single.name, PoseHubCatalogUpdateEvent.failed);
    expect(events.single.reason, startsWith('pointer_download_failed'));
    expect(await loadedPack(), 'r2-v1');
    final loaded = await PoseHubActionLibrary.load(
      bundle: _PackBundle(),
      verifiedCache: store,
    );
    expect(loaded.allActions, hasLength(249));
  });

  test('unchanged pointer ends; stored ETag then gets 304', () async {
    http.routes[_pointerUrl] = (headers) => headers['If-None-Match'] == '"e1"'
        ? PoseHubCatalogHttpResponse(304, Uint8List(0), etag: '"e1"')
        : PoseHubCatalogHttpResponse(
            200,
            Uint8List.fromList(_json(_pointer('r2-v1', r1Bytes))),
            etag: '"e1"',
          );
    final u = updater();
    expect(await u.checkNow(), PoseHubCatalogUpdateOutcome.unchanged);
    expect(http.requests, [_pointerUrl]);
    expect(await u.checkNow(), PoseHubCatalogUpdateOutcome.notModified);
    expect(http.requestHeaders.last['If-None-Match'], '"e1"');
    expect(events, isEmpty);
  });

  test('SHA-256 mismatch keeps the old catalogue', () async {
    final next = repack('r2-v2');
    publish('r2-v2', next, pointer: _pointer('r2-v2', next, sha: 'a' * 64));
    expect(await updater().checkNow(), PoseHubCatalogUpdateOutcome.failed);
    expect(events.single.reason, 'catalog_sha256_mismatch');
    expect(await store.read('current.json'), isNull);
    expect(await loadedPack(), 'r2-v1');
  });

  test('byte-count mismatch is rejected', () async {
    final next = repack('r2-v2');
    publish(
      'r2-v2',
      next,
      pointer: _pointer('r2-v2', next, bytes: next.length + 10),
    );
    expect(await updater().checkNow(), PoseHubCatalogUpdateOutcome.failed);
    expect(events.single.reason, startsWith('catalog_bytes_mismatch'));
    expect(await loadedPack(), 'r2-v1');
  });

  test('min_sdk above this SDK blocks without downloading', () async {
    final next = repack('r2-v2');
    publish('r2-v2', next, pointer: _pointer('r2-v2', next, minSdk: '9.0.0'));
    expect(await updater().checkNow(), PoseHubCatalogUpdateOutcome.blocked);
    expect(events.single.name, PoseHubCatalogUpdateEvent.blocked);
    expect(events.single.pack, 'r2-v2');
    expect(http.requests, [_pointerUrl]);
    expect(await loadedPack(), 'r2-v1');
  });

  test('from r2-v2 on, a catalogue missing an action ID is rejected', () async {
    publish('r2-v2', repack('r2-v2'));
    expect(await updater().checkNow(), PoseHubCatalogUpdateOutcome.updated);
    events.clear();
    publish('r2-v3', _smallCatalog('r2-v3', 3));
    expect(await updater().checkNow(), PoseHubCatalogUpdateOutcome.failed);
    expect(events.single.reason, startsWith('missing_action_ids: '));
    expect(events.single.reason, contains(bundled.allActions.first.id));
    expect(await loadedPack(), 'r2-v2');
  });

  test('a pre-pack catalogue is not a baseline for the add-only rule', () async {
    final legacy = jsonDecode(utf8.decode(r1Bytes)) as Map<String, Object?>
      ..remove('pack');
    publish('r2-v2', _smallCatalog('r2-v2', 3));
    final u = PoseHubCatalogUpdater(
      config: _config,
      store: store,
      http: http,
      now: () => now,
      loadLocal: () async => coach.PoseHubAppTestCatalog.fromJson(legacy),
      onEvent: events.add,
    );
    expect(await u.checkNow(), PoseHubCatalogUpdateOutcome.failed);
    // Passes the ID rule; this fixture then fails on its semantic file.
    expect(events.single.reason, startsWith('semantic_'));
  });

  test('action status is three-state and defaults to active', () {
    final raw =
        jsonDecode(utf8.decode(_smallCatalog('r2-v2', 4)))
            as Map<String, Object?>;
    final actions = raw['actions']! as List<Object?>;
    (actions[1]! as Map<String, Object?>)['status'] = 'active';
    (actions[2]! as Map<String, Object?>)
      ..['status'] = 'not_recommended'
      ..['status_since'] = 'r2-v3';
    (actions[3]! as Map<String, Object?>)['status'] = 'retired';
    final catalog = coach.PoseHubAppTestCatalog.fromJson(raw);
    expect(catalog.allActions.map((a) => a.status), [
      coach.PoseHubActionStatus.active, // fixture review label
      coach.PoseHubActionStatus.active,
      coach.PoseHubActionStatus.notRecommended,
      coach.PoseHubActionStatus.retired,
    ]);
    expect(catalog.allActions[2].statusSince, 'r2-v3');
    expect(catalog.allActions[0].statusSince, isNull);
    expect(
      bundled.allActions.every(
        (a) => a.status == coach.PoseHubActionStatus.active,
      ),
      isTrue,
    );
    (actions[3]! as Map<String, Object?>)['status'] = 'deleted';
    expect(
      () => coach.PoseHubAppTestCatalog.fromJson(raw),
      throwsFormatException,
    );
  });

  test('success applies on next load; an interrupted later download keeps '
      'it', () async {
    final before = await PoseHubActionLibrary.load(
      bundle: _PackBundle(),
      verifiedCache: store,
    );
    publish('r2-v2', repack('r2-v2'));
    expect(await updater().checkNow(), PoseHubCatalogUpdateOutcome.updated);
    expect(events.single.name, PoseHubCatalogUpdateEvent.updated);
    expect(
      http.requests.last,
      'https://media.uuugk.win/pack/r2-v2/catalog/catalog.json',
    );
    // The catalogue already in use is untouched; the next load switches.
    expect(poseHubPackVersionOf(before), 'r2-v1');
    final next = await PoseHubActionLibrary.load(
      bundle: _PackBundle(),
      verifiedCache: store,
    );
    expect(poseHubPackVersionOf(next), 'r2-v2');
    expect(next.allActions, hasLength(249));
    expect(
      PoseHubActionLibrary.mediaBaseUriFor(next).toString(),
      'https://media.uuugk.win/pack/r2-v2/',
    );

    // r2-v3 is announced but its catalogue download breaks off.
    events.clear();
    final v2 = repack('r2-v3');
    http.serve(_pointerUrl, _json(_pointer('r2-v3', v2)));
    http.routes['https://media.uuugk.win/pack/r2-v3/catalog.json'] = (_) =>
        throw const SocketException('connection reset');
    expect(await updater().checkNow(), PoseHubCatalogUpdateOutcome.failed);
    expect(events.single.reason, startsWith('catalog_download_failed'));
    expect(await loadedPack(), 'r2-v2');
  });

  test('a tampered cache falls back to the bundled baseline', () async {
    publish('r2-v2', repack('r2-v2'));
    expect(await updater().checkNow(), PoseHubCatalogUpdateOutcome.updated);
    final cached = store.values['packs/r2-v2/catalog.json']!;
    cached[cached.length - 2] ^= 1;
    expect(await loadedPack(), 'r2-v1');
  });

  test('checks on every launch, then at most once per 24 hours', () async {
    publish('r2-v1', r1Bytes);
    final launch = updater();
    expect(await launch.maybeCheck(), PoseHubCatalogUpdateOutcome.unchanged);
    now = now.add(const Duration(hours: 23));
    expect(await launch.maybeCheck(), PoseHubCatalogUpdateOutcome.throttled);
    expect(http.requests, hasLength(1));
    // A new App launch checks immediately, even within 24 hours.
    expect(await updater().maybeCheck(), PoseHubCatalogUpdateOutcome.unchanged);
    expect(http.requests, hasLength(2));
    now = now.add(const Duration(hours: 23, minutes: 59));
    expect(await launch.maybeCheck(), PoseHubCatalogUpdateOutcome.throttled);
    now = now.add(const Duration(minutes: 1));
    expect(await launch.maybeCheck(), PoseHubCatalogUpdateOutcome.unchanged);
    expect(http.requests, hasLength(3));
  });

  test('after a switch only the current and previous packs stay cached', () async {
    for (final pack in ['r2-v2', 'r2-v3']) {
      publish(pack, repack(pack));
      expect(await updater().checkNow(), PoseHubCatalogUpdateOutcome.updated);
    }
    Set<String> cachedPacks() => {
      for (final key in store.values.keys)
        if (key.startsWith('packs/')) key.split('/')[1],
    };
    expect(cachedPacks(), {'r2-v2', 'r2-v3'});
    publish('r2-v4', repack('r2-v4'));
    expect(await updater().checkNow(), PoseHubCatalogUpdateOutcome.updated);
    expect(cachedPacks(), {'r2-v3', 'r2-v4'});
    expect(await loadedPack(), 'r2-v4');
    // A failed update deletes nothing.
    http.serve(_pointerUrl, _json(_pointer('r2-v5', repack('r2-v5'))));
    expect(await updater().checkNow(), PoseHubCatalogUpdateOutcome.failed);
    expect(cachedPacks(), {'r2-v3', 'r2-v4'});
  });

  test('the SDK compares min_sdk against 0.8.0', () {
    expect(poseHubCatalogSdkVersion, '0.8.0');
    expect(_config.sdkVersion, '0.8.0');
  });

  test('file store writes atomically and reads back', () async {
    final dir = await Directory.systemTemp.createTemp('posehub-cache-');
    addTearDown(() => dir.delete(recursive: true));
    store = MemoryPoseHubCatalogStore();
    final files = createPoseHubCatalogFileStore(dir.path);
    await files.writeAtomic('packs/r2-v2/catalog.json', [1, 2, 3]);
    expect(await files.read('packs/r2-v2/catalog.json'), [1, 2, 3]);
    expect(await files.read('missing.json'), isNull);
    expect(
      dir.listSync(recursive: true).where((e) => e.path.contains('.tmp-')),
      isEmpty,
    );
    await expectLater(files.read('../x'), throwsFormatException);
    await files.writeAtomic('packs/r2-v3/semantic.json', [4]);
    expect((await files.list('packs'))..sort(), ['r2-v2', 'r2-v3']);
    await files.delete('packs/r2-v2');
    await files.delete('packs/never-there');
    expect(await files.list('packs'), ['r2-v3']);
    expect(await files.read('packs/r2-v2/catalog.json'), isNull);
    expect(await files.list('missing'), isEmpty);
  });
}
