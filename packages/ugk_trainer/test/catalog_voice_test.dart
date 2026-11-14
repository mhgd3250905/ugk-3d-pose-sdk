// Catalogue voice (2026-11-06): every Pose-Hub action carries its own
// recorded name / primaryCue in `voice.files`; the SDK now plays them for
// actions without a local pack (download + SHA check + cache), so every one
// of the 249 r2-v3 actions is introduced (name + primary key point) before
// it starts and coached while it runs. Actions whose catalogue voice is
// still pending fall back to the generic calls with their written intro.
//
// Fixtures: test/fixtures/pose_hub/r2-v3-voice.json (trimmed copy of the
// live https://media.uuugk.win/pack/r2-v3/catalog.json, voice metadata
// only) and test/fixtures/smartfit/sf-packs-voice.json (SF's 93 bundled
// drill packs, voice part). The download layer is mocked.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart';
import 'package:ugk_trainer/ugk_trainer.dart'
    show
        isVoiceFilePath,
        MemoryPoseHubCatalogStore,
        PoseHubCatalogHttpClient,
        PoseHubCatalogHttpResponse;

import 'support.dart';

Map<String, dynamic> _json(String path) =>
    jsonDecode(File('test/fixtures/$path').readAsStringSync())
        as Map<String, dynamic>;

/// Download layer mock: every listed clip counts as fetched and verified.
class _AllReadyCache extends CatalogVoiceCache {
  _AllReadyCache()
    : super(
        store: MemoryPoseHubCatalogStore(),
        pathOf: (n) => '/cache/$n',
        http: _Http(const {}),
      );
  @override
  bool isReady(CatalogVoiceClip c) => true;
  @override
  Future<bool> ensure(CatalogVoiceClip c) async => true;
}

class _Http implements PoseHubCatalogHttpClient {
  _Http(this.bodies);
  final Map<String, List<int>> bodies;
  final asked = <Uri>[];
  @override
  Future<PoseHubCatalogHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    int maxBytes = 64 * 1024 * 1024,
  }) async {
    asked.add(uri);
    final b = bodies['$uri'];
    if (b == null) throw const SocketException('offline');
    return PoseHubCatalogHttpResponse(200, Uint8List.fromList(b));
  }
}

void main() {
  final catalogJson = _json('pose_hub/r2-v3-voice.json');
  final sf = _json('smartfit/sf-packs-voice.json');
  final local = DrillPackVoiceSource.fromPacks(
    common: Map<String, dynamic>.from(sf['common'] as Map),
    packs: {
      for (final e in (sf['packs'] as Map).entries)
        e.key as String: Map<String, dynamic>.from(e.value as Map),
    },
  );
  final index = CatalogVoiceIndex.fromCatalogJson(catalogJson);

  test(
    'ready guide prefers verified common audio with local fallback per key',
    () async {
      final bytes = utf8.encode('r2-v14 common');
      final authoredBytes = utf8.encode('r2-v14 coaching');
      final sha = crypto.sha256.convert(bytes).toString();
      const common = 'voice/_common/r2-v14/zh/n.1.m4a';
      const guide = 'voice/abs-A/r2-v14/zh/g.set.1.m4a';
      final metadata = <String, Object?>{
        'language': 'zh',
        'bytes': bytes.length,
        'sha256': sha,
        'durationSeconds': .5,
      };
      final index = CatalogVoiceIndex.fromCatalogJson({
        'mediaDistribution': {'baseUrl': 'https://test.example/pack/'},
        'voiceCommon': {
          'format': 'pose-hub-voice-common@1',
          'files': [
            {...metadata, 'key': 'n.1', 'path': common},
          ],
        },
        'actions': [
          {
            'id': 'abs-A',
            'training': {
              'sideSwitchSeconds': 10,
              'perSide': 'each-side-separately',
            },
            'voiceGuide': {
              'format': 'pose-hub-voice-guide@1',
              'status': 'ready',
              'mode': 'hold',
              'set': [
                {'at': 0, 'key': 'p.go'},
                {'at': 4, 'clipId': 'g.set.1', 'zh': '腰贴地', 'en': 'Back down'},
              ],
            },
            'voice': {
              'files': [
                {
                  ...metadata,
                  'clipId': 'g.set.1',
                  'path': guide,
                  'bytes': authoredBytes.length,
                  'sha256': crypto.sha256.convert(authoredBytes).toString(),
                },
              ],
            },
          },
        ],
      });
      final http = _Http({
        'https://test.example/pack/$common': bytes,
        'https://test.example/pack/$guide': authoredBytes,
      });
      final source = LayeredVoiceSource(
        primary: local,
        catalog: index,
        cache: CatalogVoiceCache(
          store: MemoryPoseHubCatalogStore(),
          pathOf: (name) => '/cache/$name',
          http: http,
        ),
      );
      expect(source.voiceGuide('abs-A')!.sides!.eachSideSeparately, isTrue);
      expect(source.sideSwitchSecondsFor('abs-A'), 10);
      expect(source.voiceGuideCommonKeys('n.1', lang: 'zh'), ['n.1']);
      await source.prepare(['abs-A'], lang: 'zh');
      final packed = source.voiceGuideCommonKeys('n.1', lang: 'zh').single;
      expect(packed, 'catalog:_common/n.1');
      expect(
        source.asset(packed, lang: 'zh'),
        startsWith('/cache/catalog-voice/'),
      );
      expect(source.voiceGuideCommonKeys('n.2', lang: 'zh'), ['n.2']);
      final clip = source.voiceGuideClipKey('abs-A', 'g.set.1', lang: 'zh')!;
      expect(source.line(clip, lang: 'zh'), '腰贴地');
      expect(source.voiceGuideClipKey('abs-A', 'g.set.1', lang: 'en'), isNull);
      expect(http.asked, isNotEmpty);
    },
  );

  test('live r2-v3: 222 actions list name + primaryCue, 27 are pending', () {
    expect(index.pending, hasLength(27));
    expect(index.pending, contains('h-supine-cactus-chest'));
    expect(index.pending, isNot(contains('o-seated-catcow')));
    final abs = index.clip('abs-A', 'primaryCue', 'zh')!;
    expect(
      '${abs.url}',
      'https://media.uuugk.win/pack/r2-v1/voice/abs-A/zh/primaryCue.m4a',
    );
    expect(abs.seconds, closeTo(3.30, .01));
    expect(index.primaryCue('abs-A', 'zh'), '腰压住地面，上背和双腿抬离地面');
  });

  test('cache: downloads, checks size + SHA-256, never throws', () async {
    final good = utf8.encode('m4a-good');
    final sha = crypto.sha256.convert(good).toString();
    Map<String, Object?> cat(String s, int bytes) => {
      'mediaDistribution': {'baseUrl': 'https://media.example/pack/x/'},
      'actions': [
        {
          'id': 'a',
          'nameZh': '甲',
          'cues': {
            'zh': ['要点'],
          },
          'primaryCue': 0,
          'voice': {
            'files': [
              {
                'language': 'zh',
                'clipId': 'name',
                'path': 'voice/a/zh/name.m4a',
                'bytes': bytes,
                'sha256': s,
                'durationSeconds': 1.0,
              },
            ],
          },
        },
      ],
    };
    final url = 'https://media.example/pack/x/voice/a/zh/name.m4a';
    final store = MemoryPoseHubCatalogStore();
    final http = _Http({url: good});
    final cache = CatalogVoiceCache(
      store: store,
      pathOf: (n) => '/data/$n',
      http: http,
    );
    final clip = CatalogVoiceIndex.fromCatalogJson(
      cat(sha, good.length),
    ).clip('a', 'name', 'zh')!;
    expect(cache.isReady(clip), isFalse);
    expect(await cache.ensure(clip), isTrue);
    expect(cache.isReady(clip), isTrue);
    expect(store.values[clip.cacheName], good);
    expect(isVoiceFilePath(cache.path(clip)), isTrue);
    // A second cache over the same store verifies the copy, no download.
    final again = CatalogVoiceCache(
      store: store,
      pathOf: (n) => '/data/$n',
      http: _Http(const {}),
    );
    expect(await again.ensure(clip), isTrue);

    // Wrong hash: rejected, nothing cached.
    final bad = CatalogVoiceIndex.fromCatalogJson(
      cat('0' * 64, good.length),
    ).clip('a', 'name', 'zh')!;
    final store2 = MemoryPoseHubCatalogStore();
    final c2 = CatalogVoiceCache(
      store: store2,
      pathOf: (n) => '/d/$n',
      http: _Http({url: good}),
    );
    expect(await c2.ensure(bad), isFalse);
    expect(store2.values, isEmpty);
    // Offline: prefetch reports, never throws.
    final c3 = CatalogVoiceCache(
      store: MemoryPoseHubCatalogStore(),
      pathOf: (n) => '/d/$n',
      http: _Http(const {}),
    );
    final r = await c3.prefetch([clip]);
    expect(r.ready, 0);
    expect(r.failed, ['a/zh/name']);
  });

  test('player plays downloaded files, bundled clips stay assets', () {
    expect(isVoiceFilePath('/data/user/0/app/catalog-voice/ab/x.m4a'), isTrue);
    expect(isVoiceFilePath(r'C:\cache\x.m4a'), isTrue);
    expect(isVoiceFilePath('file:///tmp/x.m4a'), isTrue);
    expect(isVoiceFilePath('assets/packs/h-squat/voice/zh/cue1.m4a'), isFalse);
    expect(isVoiceFilePath('packages/ugk_trainer/assets/silence.m4a'), isFalse);
  });

  test('prepare fetches only the catalogue lines the plan needs', () async {
    final http = _Http(const {});
    final source = LayeredVoiceSource(
      primary: local,
      catalog: index,
      cache: CatalogVoiceCache(
        store: MemoryPoseHubCatalogStore(),
        pathOf: (n) => '/d/$n',
        http: http,
      ),
    );
    // h-squat has a local pack: nothing to fetch; abs-A has none.
    await source.prepare(['h-squat', 'abs-A'], lang: 'zh');
    expect(http.asked.map((u) => u.path).toSet(), {
      '/pack/r2-v1/voice/abs-A/zh/name.m4a',
      '/pack/r2-v1/voice/abs-A/zh/primaryCue.m4a',
    });
    // Failed downloads leave the action on the fallback, not silent.
    expect(
      source.has(LayeredVoiceSource.keyOf('abs-A', 'name'), lang: 'zh'),
      isFalse,
    );
  });

  test('all 249 r2-v3 actions: name + primaryCue before the move (first and '
      'next), a key point while it runs; pending ones use the fallback', () {
    final source = LayeredVoiceSource(
      primary: local,
      catalog: index,
      cache: _AllReadyCache(),
    );
    final script = SessionScript(source: source);
    final actions = [
      for (final a in catalogJson['actions'] as List)
        Map<String, dynamic>.from(a as Map),
    ];
    expect(actions, hasLength(249));
    final kinds = <String, String>{};
    final failures = <String>[];
    final bySource = <String, List<String>>{
      'local': [],
      'catalog': [],
      'fallback': [],
    };
    bool nameKey(String id, String k) =>
        k == '$id/name' ||
        k == '$id/intro' ||
        k == LayeredVoiceSource.keyOf(id, 'name');
    bool pointKey(String id, String k) =>
        const [
          'cue1',
          'cue2',
          'cue3',
          'side_switch',
        ].any((l) => k == '$id/$l') ||
        k == LayeredVoiceSource.keyOf(id, 'primaryCue');
    PlanItem itemOf(Map<String, dynamic> a) {
      final id = a['id'] as String;
      final dose = Map<String, dynamic>.from(a['defaultDose'] as Map);
      final perSide = a['unilateral'] == true;
      return dose['mode'] == 'reps'
          ? reps(id, dose['reps'] as int, perSide: perSide)
          : timed(id, dose['seconds'] as int, perSide: perSide);
    }

    Rhythm rhythmOf(Map<String, dynamic> a) {
      final e = Map<String, dynamic>.from(
        (a['rhythm'] as Map)['execution'] as Map,
      );
      return Rhythm.fromJson(e, startingSide: e['startingSide'] as String?);
    }

    final filler = actions.firstWhere((a) => a['id'] == 'h-squat');
    for (final a in actions) {
      final id = a['id'] as String;
      kinds[id] = ((a['rhythm'] as Map)['execution'] as Map)['kind'] as String;
      final hasLocal = local.has('$id/name', lang: 'zh');
      final pending = index.pending.contains(id);
      final kind = hasLocal
          ? 'local'
          : pending
          ? 'fallback'
          : 'catalog';
      bySource[kind]!.add(id);
      final name = index.name(id, 'zh')!;
      final cue = index.primaryCue(id, 'zh')!;

      bool introduced(List<VoiceCue> cues) => kind == 'fallback'
          ? cues.any(
              (c) =>
                  c.priority == CuePriority.info &&
                  c.clips.isNotEmpty &&
                  (c.subtitle ?? '').contains(name) &&
                  (c.subtitle ?? '').contains(cue),
            )
          : cues.any((c) => c.clips.any((k) => nameKey(id, k))) &&
                cues.any((c) => c.clips.any((k) => pointKey(id, k)));
      bool coached(List<VoiceCue> cues) => kind == 'fallback'
          ? cues.any((c) => c.subtitle == cue)
          : cues.any((c) => c.clips.any((k) => pointKey(id, k)));

      // First move: the prep before it.
      final rhythms = {id: rhythmOf(a), 'h-squat': rhythmOf(filler)};
      final b = SessionBuilder(
        rhythms: rhythms,
        switchSecondsFor: script.switchSecondsFor,
        prepSecondsFor: script.prepSecondsFor,
      );
      final plan = planOf([itemOf(a)]);
      final phases = b.phases(plan);
      final total = b.planSeconds(plan);
      final prep = phases.first;
      expect(prep.kind, PhaseKind.prep);
      final prepCues = script.cues(prep, planSeconds: total);
      final work = phases.firstWhere((p) => p.isWork);
      final workCues = script.cues(work, planSeconds: total);
      // Welcome only on the first move, and it still plays.
      final welcome = prepCues.any((c) => c.clips.contains('p.welcome'));
      // Next move: the rest before it.
      final plan2 = planOf([itemOf(filler), itemOf(a)]);
      final rest = b
          .phases(plan2)
          .firstWhere(
            (p) => p.kind == PhaseKind.rest && p.nextExerciseId == id,
          );
      final restCues = script.cues(rest, planSeconds: b.planSeconds(plan2));
      final ok = [
        introduced(prepCues),
        introduced(restCues),
        coached(workCues),
        welcome,
        !restCues.any((c) => c.clips.contains('p.welcome')),
      ];
      if (ok.contains(false)) {
        failures.add(
          '$id [$kind ${kinds[id]}] prep/rest/work/welcome/noWelcomeInRest=$ok '
          'prep(${prep.seconds}s)=$prepCues rest=$restCues work=$workCues',
        );
      }
    }
    // ignore: avoid_print
    print(
      'catalog voice sweep: local ${bySource['local']!.length}, catalog '
      '${bySource['catalog']!.length}, fallback ${bySource['fallback']!.length}'
      ' ${bySource['fallback']}',
    );
    expect(failures, isEmpty, reason: failures.join('\n'));
    expect(bySource['local'], hasLength(93));
    expect(bySource['catalog'], hasLength(139));
    expect(bySource['fallback']!.toSet(), {
      'h-chair-progressive-front-split-native',
      'h-donkey-kick',
      'h-floor-nordic-hand-reset',
      'h-kneeling-instep-stretch',
      'h-kneeling-pushup',
      'h-kneeling-thread-needle',
      'h-open-book',
      'h-quadruped-open',
      'h-quadruped-rockback',
      'h-short-side-plank',
      'h-supine-bilateral-leg-raise',
      'h-supine-cactus-chest',
      'h-supine-heel-slide',
      'hip-abductors-A',
      'o-supported-hip-hitch',
      'rotator-cuff-B',
      'scapular-A',
    });
  });

  test('prep grows to fit welcome + intro, never shrinks', () {
    final source = LayeredVoiceSource(
      primary: local,
      catalog: index,
      cache: _AllReadyCache(),
    );
    final script = SessionScript(source: source);
    final item = timed('abs-A', 20);
    final s = script.prepSecondsFor(
      item,
      'abs-A',
      minimum: 10,
      planSeconds: 300,
    );
    expect(s, greaterThan(10));
    final none = SessionScript(source: DrillPackVoiceSource.empty);
    expect(
      none.prepSecondsFor(item, 'abs-A', minimum: 10, planSeconds: 300),
      10,
    );
  });
}
