import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer_runtime/src/pose_hub/pose_hub_catalog_io_types.dart';
import 'package:ugk_trainer_runtime/src/pose_hub/pose_hub_plan_pack.dart';

final _stable = Uri.parse('https://assets.example/pack/channels/stable.json');
final _beta = Uri.parse('https://assets.example/pack/channels/beta.json');
const _voiceUrl = 'https://assets.example/plans/voice.json';

List<int> _json(Object? value) => utf8.encode(jsonEncode(value));

final _voiceBytes = _json({'schema': 1, 'files': <Object?>[]});
final _plans = [
  {
    'id': 'strength-01',
    'unknown_app_fields': {
      'segments': [3, true, null, 'deep squat'],
    },
  },
  ['another', 1.25],
];

Map<String, Object?> _pack({
  String app = 'hip',
  String version = '2026.11.21',
  String catalogPack = 'r2-v18',
}) => {
  'schema': 1,
  'app': app,
  'version': version,
  'min_catalog_pack': catalogPack,
  'voice_manifest': {
    'url': _voiceUrl,
    'bytes': _voiceBytes.length,
    'sha256': sha256.convert(_voiceBytes).toString(),
  },
  'plans': _plans,
  'also_app_owned': [true, null],
};

PoseHubPlanSnapshot _snapshot({
  String app = 'hip',
  String version = '2026.11.21',
  String catalogPack = 'r2-v18',
  String minSdk = '1.0.2',
}) => PoseHubPlanSnapshot.fromBytes(
  _json(_pack(app: app, version: version, catalogPack: catalogPack)),
  _voiceBytes,
  minSdk: minSdk,
);

void main() {
  test('plan JSON stays opaque and deeply immutable', () {
    final source = _json(_pack());
    final digest = sha256.convert(source).toString();
    final snapshot = PoseHubPlanSnapshot.fromBytes(
      source,
      _voiceBytes,
      minSdk: '1.0.2',
    );
    source[0] = 0;
    expect(snapshot.id, digest);
    expect(snapshot.planPack.plans, _plans);
    expect(snapshot.planPack.raw['also_app_owned'], [true, null]);
    expect(snapshot.planPack.voiceManifest.uri.toString(), _voiceUrl);
    expect(snapshot.planPack.byteLength, source.length);
    expect(snapshot.planPack.jsonBytes.first, 123);
    expect(() => snapshot.planPack.jsonBytes[0] = 0, throwsUnsupportedError);
    expect(() => snapshot.plans.clear(), throwsUnsupportedError);

    final first = snapshot.plans.first! as Map<String, Object?>;
    final nested = first['unknown_app_fields']! as Map<String, Object?>;
    final segments = nested['segments']! as List<Object?>;
    expect(() => segments.add('injection'), throwsUnsupportedError);
  });

  test('invalid envelopes and voice integrity mismatches are rejected', () {
    for (final fields in [
      {..._pack(), 'schema': 2},
      {..._pack(), 'app': ''},
      {..._pack(), 'version': null},
      {..._pack(), 'min_catalog_pack': 'unorderable'},
      {..._pack(), 'voice_manifest': 'https://assets.example/voice.json'},
      {
        ..._pack(),
        'voice_manifest': {
          ...(_pack()['voice_manifest']! as Map<String, Object?>),
          'url': 'http://assets.example/voice.json',
        },
      },
      {
        ..._pack(),
        'plans': {'id': 'not-an-array'},
      },
    ]) {
      expect(
        () => PoseHubPlanPack.fromBytes(_json(fields)),
        throwsFormatException,
      );
    }
    expect(
      () => PoseHubPlanSnapshot.fromBytes(
        _json(_pack()),
        _voiceBytes.take(_voiceBytes.length - 1).toList(),
        minSdk: '1.0.2',
      ),
      throwsFormatException,
    );
    final wrongHashBytes = Uint8List.fromList(_voiceBytes)..[0] = 32;
    expect(
      () => PoseHubPlanSnapshot.fromBytes(
        _json(_pack()),
        wrongHashBytes,
        minSdk: '1.0.2',
      ),
      throwsFormatException,
    );
  });

  test('offline selection respects compatibility, app and channel', () async {
    final cache = MemoryPoseHubCatalogStore();
    final writer = PoseHubChannelPlanStore(store: cache, channelUri: _stable);
    final previous = _snapshot(version: 'previous');
    final current = _snapshot(
      version: 'current',
      catalogPack: 'r2-v19',
      minSdk: '1.0.3',
    );
    final flare = _snapshot(app: 'flare');
    await writer.install(previous);
    await writer.install(current);
    await writer.install(flare);

    final stable = PoseHubChannelPlanStore(store: cache, channelUri: _stable);
    final beta = PoseHubChannelPlanStore(store: cache, channelUri: _beta);
    expect(
      (await stable.latestCompatible(
        'hip',
        catalogPack: 'r2-v19',
        sdkVersion: '1.0.3',
      ))?.id,
      current.id,
    );
    expect(
      (await stable.latestCompatible(
        'hip',
        catalogPack: 'r2-v18',
        sdkVersion: '1.0.3',
      ))?.id,
      previous.id,
    );
    expect(
      (await stable.latestCompatible(
        'hip',
        catalogPack: 'r2-v19',
        sdkVersion: '1.0.2',
      ))?.id,
      previous.id,
    );
    expect(
      (await stable.latestCompatible(
        'flare',
        catalogPack: 'r2-v19',
        sdkVersion: '1.0.3',
      ))?.id,
      flare.id,
    );
    expect(
      await beta.latestCompatible(
        'hip',
        catalogPack: 'r2-v19',
        sdkVersion: '1.0.3',
      ),
      isNull,
    );
    expect((await beta.restore('hip', previous.id))?.id, previous.id);
    expect(await beta.restore('flare', previous.id), isNull);
  });

  test(
    'damaged active bytes fall back without replacing a pinned snapshot',
    () async {
      final cache = MemoryPoseHubCatalogStore();
      final store = PoseHubChannelPlanStore(store: cache, channelUri: _stable);
      final prior = _snapshot(version: 'prior');
      final current = _snapshot(version: 'current');
      await store.install(prior);
      await store.install(current);
      expect((await store.restore('hip', prior.id))?.id, prior.id);

      final currentDocument = cache.values.entries.singleWhere(
        (entry) => entry.key.endsWith('/${current.id}/plan.json'),
      );
      currentDocument.value[0] = 0;
      expect(await store.restore('hip', current.id), isNull);
      expect(
        (await store.latestCompatible(
          'hip',
          catalogPack: 'r2-v18',
          sdkVersion: '1.0.2',
        ))?.id,
        prior.id,
      );
    },
  );

  test(
    'retaining a bundled snapshot does not select it for the channel',
    () async {
      final memory = MemoryPoseHubCatalogStore();
      final store = PoseHubChannelPlanStore(store: memory, channelUri: _stable);
      final bundle = _snapshot(version: 'bundled');
      await store.retain(bundle);
      expect((await store.restore('hip', bundle.id))?.version, 'bundled');
      expect(
        await store.latestCompatible(
          'hip',
          catalogPack: 'r2-v18',
          sdkVersion: '1.0.2',
        ),
        isNull,
      );

      final channelCopy = bundle.withMinSdk('1.0.3');
      await store.install(channelCopy);
      expect(
        await store.latestCompatible(
          'hip',
          catalogPack: 'r2-v18',
          sdkVersion: '1.0.2',
        ),
        isNull,
      );
      expect(
        (await store.latestCompatible(
          'hip',
          catalogPack: 'r2-v18',
          sdkVersion: '1.0.3',
        ))?.id,
        bundle.id,
      );
      expect((await store.restore('hip', bundle.id))?.minSdk, '1.0.2');
    },
  );

  test('failed active publication retains the previous selection', () async {
    final cache = _RejectSelectionStore();
    final store = PoseHubChannelPlanStore(store: cache, channelUri: _stable);
    final prior = _snapshot(version: 'prior');
    final next = _snapshot(version: 'next');
    await store.install(prior);

    cache.rejectSelection = true;
    await expectLater(store.install(next), throwsStateError);
    expect(
      (await store.latestCompatible(
        'hip',
        catalogPack: 'r2-v18',
        sdkVersion: '1.0.2',
      ))?.id,
      prior.id,
    );
    expect((await store.lookup(next.id))?.id, next.id);

    cache.rejectSelection = false;
    await store.install(next);
    expect(
      (await store.latestCompatible(
        'hip',
        catalogPack: 'r2-v18',
        sdkVersion: '1.0.2',
      ))?.id,
      next.id,
    );
  });
}

class _RejectSelectionStore extends MemoryPoseHubCatalogStore {
  bool rejectSelection = false;

  @override
  Future<void> writeAtomic(String name, List<int> bytes) async {
    if (rejectSelection && name.startsWith('channel-plans/channels/')) {
      throw StateError('disk write failed');
    }
    await super.writeAtomic(name, bytes);
  }
}
