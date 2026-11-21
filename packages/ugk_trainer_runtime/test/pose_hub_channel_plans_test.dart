import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

const _config = PoseHubCatalogUpdateConfig(
  channel: PoseHubCatalogChannel.stable,
);
const _pointerUrl = 'https://media.uuugk.win/pack/channels/stable.json';
const _voiceUrl = 'https://media.uuugk.win/plans/hip/voice.json';
const _pack = 'r2-v1';

Uint8List _json(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));
String _sha(List<int> bytes) => sha256.convert(bytes).toString();
String _planUrl(String version) =>
    'https://media.uuugk.win/plans/hip/$version.json';

class _Http implements PoseHubCatalogHttpClient {
  final routes = <String, PoseHubCatalogHttpResponse>{};
  final requests = <String>[];
  final headersSeen = <Map<String, String>>[];

  void serve(String url, Uint8List body, {String? etag}) {
    routes[url] = PoseHubCatalogHttpResponse(200, body, etag: etag);
  }

  @override
  Future<PoseHubCatalogHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    int maxBytes = 64 * 1024 * 1024,
  }) async {
    final url = uri.toString();
    requests.add(url);
    headersSeen.add(headers);
    final response = routes[url];
    if (response == null) throw const SocketException('offline');
    if (response.body.length > maxBytes) throw StateError('Response too large');
    if (response.etag != null && headers['If-None-Match'] == response.etag) {
      return PoseHubCatalogHttpResponse(304, Uint8List(0), etag: response.etag);
    }
    return response;
  }
}

class _Plans {
  _Plans(
    this.version, {
    this.minCatalog = _pack,
    this.minSdk = poseHubChannelPlansMinSdkVersion,
    this.app = 'hip',
  });

  final String version;
  final String minCatalog;
  final String minSdk;
  final String app;
  final voice = _json({
    'schema': 1,
    'files': <Object?>[],
    'plans': <String, Object?>{},
  });

  List<Object?> get plans => [
    {
      'plan': 'welcome',
      'blocks': [
        {
          'host_field': [version, null, 4, true],
        },
      ],
    },
  ];

  late final bytes = _json({
    'schema': 1,
    'app': app,
    'version': version,
    'min_catalog_pack': minCatalog,
    'voice_manifest': {
      'url': _voiceUrl,
      'bytes': voice.length,
      'sha256': _sha(voice),
    },
    'plans': plans,
  });

  Map<String, Object?> get pointer => {
    'version': version,
    'url': _planUrl(version),
    'bytes': bytes.length,
    'sha256': _sha(bytes),
    'min_sdk': minSdk,
  };

  PoseHubPlanSnapshot get bundled =>
      PoseHubPlanSnapshot.fromBytes(bytes, voice, minSdk: minSdk);
}

void main() {
  late Uint8List catalog;
  late coach.PoseHubAppTestCatalog local;
  late Map<String, Object?> pointer;
  late _Http http;
  late MemoryPoseHubCatalogStore store;

  setUpAll(() async {
    catalog = await File(
      'test/fixtures/pose_hub/r2-v1/catalog.json',
    ).readAsBytes();
    local = coach.PoseHubAppTestCatalog.fromBytes(catalog);
    pointer = {
      'schema': 1,
      'pack': _pack,
      'catalog': 'https://media.uuugk.win/pack/r2-v1/catalog.json',
      'catalog_sha256': _sha(catalog),
      'catalog_bytes': catalog.length,
      'min_sdk': '0.8.0',
    };
  });

  setUp(() {
    http = _Http();
    store = MemoryPoseHubCatalogStore();
  });

  PoseHubCatalogUpdater updater({
    void Function(PoseHubCatalogUpdateEvent)? notify,
  }) => PoseHubCatalogUpdater.withPersistentAssets(
    config: _config,
    store: store,
    http: http,
    loadLocal: () async => local,
    onEvent: notify,
  );

  void publish(_Plans plan) {
    http.serve(
      _pointerUrl,
      _json({...pointer, 'plans': plan.pointer}),
      etag: '"${plan.version}"',
    );
    http.serve(_planUrl(plan.version), plan.bytes);
    http.serve(_voiceUrl, plan.voice);
  }

  test('absence of plans preserves catalogue-only requests and ETag', () async {
    expect(PoseHubCatalogPointer.fromJson(pointer).plans, isNull);
    http.serve(_pointerUrl, _json(pointer), etag: '"catalogue"');
    final updates = updater();
    expect(await updates.checkNow(), PoseHubCatalogUpdateOutcome.unchanged);
    expect(await updates.checkNow(), PoseHubCatalogUpdateOutcome.notModified);
    expect(http.requests, [_pointerUrl, _pointerUrl]);
    expect(await updates.planSnapshotFor('hip'), isNull);
  });

  test(
    'same catalogue accepts new plans and keeps a pinned workout on the old snapshot',
    () async {
      final events = <PoseHubPlanSnapshot>[];
      final display = <PoseHubDisplayUpdateProgress>[];
      final first = _Plans('2026.11.21-1');
      final second = _Plans('2026.11.21-2');
      final updates = updater();
      final changes = updates.planChanges.listen(events.add);
      final visual = updates.displayProgress.listen(display.add);
      addTearDown(changes.cancel);
      addTearDown(visual.cancel);

      publish(first);
      expect(await updates.checkNow(), PoseHubCatalogUpdateOutcome.unchanged);
      final pinned = (await updates.planSnapshotFor('hip'))!;
      expect(pinned.plans, first.plans);
      expect(pinned.planPack.jsonBytes, first.bytes);
      expect(await updates.planSnapshotFor('flare'), isNull);
      publish(second);
      expect(await updates.checkNow(), PoseHubCatalogUpdateOutcome.unchanged);
      expect(events.map((snapshot) => snapshot.version), [
        first.version,
        second.version,
      ]);
      expect(display, isEmpty);
      expect(http.requests, [
        _pointerUrl,
        _planUrl(first.version),
        _voiceUrl,
        _pointerUrl,
        _planUrl(second.version),
        _voiceUrl,
      ]);

      final restarted = updater();
      expect((await restarted.planSnapshotFor('hip'))?.plans, second.plans);
      expect(
        (await restarted.restorePlanSnapshot('hip', pinned.id))?.plans,
        first.plans,
      );
      expect(await restarted.restorePlanSnapshot('flare', pinned.id), isNull);
      expect(
        await restarted.checkNow(),
        PoseHubCatalogUpdateOutcome.notModified,
      );
      expect(http.requests.last, _pointerUrl);
    },
  );

  test('each app keeps its own verified plans on the same channel', () async {
    final updates = updater();
    final hip = _Plans('hip-v1');
    final flare = _Plans('flare-v1', app: 'flare');
    publish(hip);
    await updates.checkNow();
    publish(flare);
    await updates.checkNow();
    expect((await updates.planSnapshotFor('hip'))?.version, hip.version);
    expect((await updates.planSnapshotFor('flare'))?.version, flare.version);
  });

  test(
    'a matching ETag from SDK 1.0.1 cannot hide new plans from the upgraded SDK',
    () async {
      final first = _Plans('v1');
      publish(first);
      await store.writeAtomic('state.json', _json({'etag': '"v1"'}));
      final updates = updater();
      expect(await updates.checkNow(), PoseHubCatalogUpdateOutcome.unchanged);
      expect(http.headersSeen.first['If-None-Match'], isNull);
      expect((await updates.planSnapshotFor('hip'))?.version, 'v1');
    },
  );

  test(
    'a stale ETag does not prevent repairing a lost cached snapshot',
    () async {
      final plan = _Plans('v1');
      publish(plan);
      final updates = updater();
      await updates.checkNow();
      final pinned = (await updates.planSnapshotFor('hip'))!;
      final voice = store.values.keys.singleWhere(
        (key) => key.endsWith('/voice.json'),
      );
      store.values.remove(voice);
      http.requests.clear();
      expect(await updater().checkNow(), PoseHubCatalogUpdateOutcome.unchanged);
      expect(http.requests, [_pointerUrl, _planUrl(plan.version), _voiceUrl]);
      expect((await updater().planSnapshotFor('hip'))?.id, pinned.id);
    },
  );

  test(
    'plan SHA mismatch leaves the last compatible plan available for offline use',
    () async {
      final first = _Plans('v1');
      final second = _Plans('v2');
      final events = <PoseHubCatalogUpdateEvent>[];
      final updates = updater(notify: events.add);
      publish(first);
      await updates.checkNow();

      publish(second);
      http.serve(
        _planUrl(second.version),
        Uint8List.fromList(second.bytes)..[0] = 0,
      );
      http.requests.clear();
      expect(await updates.checkNow(), PoseHubCatalogUpdateOutcome.unchanged);
      expect(events.last.name, PoseHubCatalogUpdateEvent.plansFailed);
      expect(http.requests, [_pointerUrl, _planUrl(second.version)]);
      expect((await updates.planSnapshotFor('hip'))?.version, first.version);
      http.routes.clear();
      final restarted = updater();
      expect(await restarted.checkNow(), PoseHubCatalogUpdateOutcome.failed);
      expect((await restarted.planSnapshotFor('hip'))?.version, first.version);
    },
  );

  test(
    'voice-manifest integrity is required before selecting a new plan',
    () async {
      final first = _Plans('v1');
      publish(first);
      http.serve(_voiceUrl, Uint8List.fromList(first.voice)..[0] = 0);
      final events = <PoseHubCatalogUpdateEvent>[];
      final updates = updater(notify: events.add);
      expect(await updates.checkNow(), PoseHubCatalogUpdateOutcome.unchanged);
      expect(events.single.name, PoseHubCatalogUpdateEvent.plansFailed);
      expect(await updates.planSnapshotFor('hip'), isNull);
      publish(first);
      expect(await updates.checkNow(), PoseHubCatalogUpdateOutcome.unchanged);
      expect((await updates.planSnapshotFor('hip'))?.version, first.version);
    },
  );

  test(
    'minimum SDK and catalogue gates prevent incompatible plan activation',
    () async {
      final events = <PoseHubCatalogUpdateEvent>[];
      final updates = updater(notify: events.add);
      publish(_Plans('new-sdk', minSdk: '1.1.0'));
      expect(await updates.checkNow(), PoseHubCatalogUpdateOutcome.unchanged);
      expect(http.requests, [_pointerUrl]);
      expect(events.last.name, PoseHubCatalogUpdateEvent.plansBlocked);

      final needsCatalog = _Plans('new-catalogue', minCatalog: 'r2-v36');
      publish(needsCatalog);
      http.requests.clear();
      expect(await updates.checkNow(), PoseHubCatalogUpdateOutcome.unchanged);
      expect(http.requests, [_pointerUrl, _planUrl(needsCatalog.version)]);
      expect(events.last.name, PoseHubCatalogUpdateEvent.plansBlocked);
      expect(await updates.planSnapshotFor('hip'), isNull);
    },
  );

  test(
    'first offline launch loads a compatible bundled snapshot and retains its pin',
    () async {
      final fallback = _Plans('bundled');
      final updates = updater();
      expect(await updates.maybeCheck(), PoseHubCatalogUpdateOutcome.failed);
      final active = await updates.planSnapshotFor(
        'hip',
        loadBundled: () async => fallback.bundled,
      );
      expect(active?.plans, fallback.plans);
      expect(
        (await updater().restorePlanSnapshot('hip', active!.id))?.version,
        fallback.version,
      );
      expect(
        await updates.planSnapshotFor(
          'flare',
          loadBundled: () async => fallback.bundled,
        ),
        isNull,
      );
      expect(http.requests, [_pointerUrl]);
    },
  );
}
