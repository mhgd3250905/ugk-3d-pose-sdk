import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

const _fixtures = 'test/fixtures/pose_hub/flare-published-plan';
const _planUrl =
    'https://media.uuugk.win/pack/r2-v1/plans/flare-plans-r1/flare-plans.json';
const _voiceUrl =
    'https://media.uuugk.win/pack/r2-v1/plan-voice/flare-plan-voice-r1/manifest.json';
const _planSha =
    '6f41ac281805f615d1a62691f16bacd4c9793342efc69d918d2a62d1260f44c9';
const _voiceSha =
    '6c5d81a9b80e9565729ee003825b72b6a8c04ce44c57a6b9af5b3468b043c3f4';
const _catalogPack = 'r2-v22';
const _config = PoseHubCatalogUpdateConfig(
  channel: PoseHubCatalogChannel.stable,
);

Uint8List _encode(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));
String _sha(List<int> bytes) => sha256.convert(bytes).toString();

class _Http implements PoseHubCatalogHttpClient {
  final routes = <Uri, Uint8List>{};
  final requests = <Uri>[];

  @override
  Future<PoseHubCatalogHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    int maxBytes = 64 * 1024 * 1024,
  }) async {
    requests.add(uri);
    final bytes = routes[uri];
    if (bytes == null) throw const SocketException('Fixture is offline');
    if (bytes.length > maxBytes) {
      throw const FormatException('Fixture exceeds HTTP limits');
    }
    return PoseHubCatalogHttpResponse(200, bytes);
  }
}

Uri _mediaUrl(Object? key) =>
    Uri.parse('https://media.uuugk.win/').resolve(key! as String);

void main() {
  late Uint8List planBytes;
  late Uint8List voiceBytes;
  late Uint8List catalogBytes;
  late coach.PoseHubAppTestCatalog catalog;
  late List<Map<String, Object?>> receipts;
  late List<String> warmupPaths;
  late Map<String, Uint8List> audioByPath;

  setUpAll(() async {
    planBytes = await File('$_fixtures/flare-plans.json').readAsBytes();
    voiceBytes = await File('$_fixtures/manifest.json').readAsBytes();
    expect(planBytes.length, 41572);
    expect(_sha(planBytes), _planSha);
    expect(voiceBytes.length, 159943);
    expect(_sha(voiceBytes), _voiceSha);

    final publishedPlan =
        jsonDecode(utf8.decode(planBytes)) as Map<String, Object?>;
    final publishedVoice =
        jsonDecode(utf8.decode(voiceBytes)) as Map<String, Object?>;
    receipts = (publishedVoice['lines']! as List<Object?>)
        .cast<Map<String, Object?>>();
    final warmup = (publishedPlan['plans']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .singleWhere((plan) => plan['id'] == 'general-warmup');
    final firstItems = (warmup['items']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .take(3);
    warmupPaths = [
      for (final item in firstItems)
        receipts.singleWhere(
              (line) => line['text'] == item['voiceCue'],
            )['file']!
            as String,
    ];
    expect(warmupPaths, [
      for (var index = 1; index <= 3; index++)
        'assets/flutter_assets/assets/trainer_voice/_common/voice/zh/'
            'supplemental.general-warmup.$index.m4a',
    ]);
    audioByPath = {
      for (final path in warmupPaths)
        path: await File('$_fixtures/$path').readAsBytes(),
    };
    for (final entry in audioByPath.entries) {
      final receipt = receipts.singleWhere((line) => line['file'] == entry.key);
      expect(entry.value.length, receipt['bytes']);
      expect(_sha(entry.value), receipt['sha256']);
    }

    // Only the plan and voice fixtures are live originals. Model an already
    // installed compatible catalogue without bundling another catalogue file.
    final localBytes = await File(
      'test/fixtures/pose_hub/r2-v1/catalog.json',
    ).readAsBytes();
    final localRaw =
        jsonDecode(utf8.decode(localBytes)) as Map<String, Object?>;
    localRaw['pack'] = _catalogPack;
    catalogBytes = _encode(localRaw);
    catalog = coach.PoseHubAppTestCatalog.fromBytes(catalogBytes);
  });

  PoseHubCatalogUpdater updater(_Http http) =>
      PoseHubCatalogUpdater.withPersistentAssets(
        config: _config,
        store: MemoryPoseHubCatalogStore(),
        http: http,
        loadLocal: () async => catalog,
      );

  void expectWarmupAudio(
    Map<String, Uri?> ready,
    MemoryPoseHubCatalogStore audio,
  ) {
    expect(ready.keys, orderedEquals(warmupPaths));
    for (final path in warmupPaths) {
      final uri = ready[path];
      expect(uri, isNotNull, reason: path);
      expect(audio.values[uri!.path.substring(1)], audioByPath[path]);
    }
  }

  test(
    'published Flare snapshot resolves 151 voice files and fetches warmup audio',
    () async {
      final catalogueUrl =
          'https://media.uuugk.win/pack/$_catalogPack/catalog.json';
      final planUri = Uri.parse(_planUrl);
      final voiceUri = Uri.parse(_voiceUrl);
      final http = _Http();
      http.routes.addAll({
        _config.pointerUri: _encode({
          'schema': 1,
          'pack': _catalogPack,
          'catalog': catalogueUrl,
          'catalog_bytes': catalogBytes.length,
          'catalog_sha256': _sha(catalogBytes),
          'min_sdk': '1.0.1',
          'plans': {
            'version': 'flare-plans-r1',
            'url': _planUrl,
            'bytes': planBytes.length,
            'sha256': _planSha,
            'min_sdk': '1.0.2',
          },
        }),
        planUri: planBytes,
        voiceUri: voiceBytes,
        for (final receipt in receipts)
          if (audioByPath.containsKey(receipt['file']))
            _mediaUrl(receipt['objectKey']): audioByPath[receipt['file']]!,
      });
      final updates = updater(http);
      expect(await updates.checkNow(), PoseHubCatalogUpdateOutcome.unchanged);
      final snapshot = (await updates.planSnapshotFor('flare'))!;
      expect(snapshot.id, _planSha);
      expect(snapshot.planPack.jsonBytes, planBytes);
      expect(snapshot.voiceManifest.files, hasLength(151));
      for (final receipt in receipts) {
        final path = receipt['file']! as String;
        final file = snapshot.voiceManifest.files[path]!;
        expect(file.path, path);
        expect(file.sha256, receipt['sha256']);
        expect(file.bytes, receipt['bytes']);
        expect(file.url, _mediaUrl(receipt['objectKey']));
      }
      expect(http.requests, [_config.pointerUri, planUri, voiceUri]);

      final audio = MemoryPoseHubCatalogStore();
      final voiceCache = PoseHubPlanVoiceCache(
        store: audio,
        uriOf: (name) => Uri(scheme: 'memory', path: '/$name'),
        http: http,
      );
      expectWarmupAudio(
        await voiceCache.prefetchFiles(snapshot.voiceManifest, warmupPaths),
        audio,
      );
      expect(
        http.requests.skip(3),
        unorderedEquals(
          warmupPaths.map((path) => snapshot.voiceManifest.files[path]!.url),
        ),
      );
    },
  );

  test(
    'bundled Flare snapshot and warmup audio load offline by manifest file path',
    () async {
      final http = _Http();
      final updates = updater(http);
      final snapshot = (await updates.planSnapshotFor(
        'flare',
        loadBundled: () async => PoseHubPlanSnapshot.fromBytes(
          planBytes,
          voiceBytes,
          minSdk: '1.0.2',
        ),
      ))!;
      expect(snapshot.id, _planSha);
      expect(snapshot.voiceManifest.files, hasLength(151));
      expect(
        (await updates.restorePlanSnapshot('flare', snapshot.id))?.id,
        _planSha,
      );

      final audio = MemoryPoseHubCatalogStore();
      final bundleReads = <String>[];
      final voiceCache = PoseHubPlanVoiceCache(
        store: audio,
        uriOf: (name) => Uri(scheme: 'memory', path: '/$name'),
        http: http,
        loadBundledFile: (path) {
          bundleReads.add(path);
          return File('$_fixtures/$path').readAsBytes();
        },
      );
      expectWarmupAudio(
        await voiceCache.prefetchFiles(snapshot.voiceManifest, warmupPaths),
        audio,
      );
      expect(bundleReads, unorderedEquals(warmupPaths));
      expect(http.requests, isEmpty);
    },
  );
}
