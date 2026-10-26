import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

const _pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';

Map<String, Object?> _read(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

Map<String, Object?> _action(Map<String, Object?> catalog, [int index = 0]) =>
    (catalog['actions']! as List<Object?>)[index]! as Map<String, Object?>;

Map<String, Object?> _files(Map<String, Object?> action) =>
    action['files']! as Map<String, Object?>;

Iterable<Map<String, Object?>> _mediaFiles(Map<String, Object?> catalog) sync* {
  for (final value in catalog['actions']! as List<Object?>) {
    final action = value! as Map<String, Object?>;
    for (final file in _files(action).values) {
      yield file! as Map<String, Object?>;
    }
  }
}

Map<String, Object?> _actionById(Map<String, Object?> catalog, String id) =>
    (catalog['actions']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .firstWhere((action) => action['id'] == id);

void main() {
  late Map<String, Object?> original;
  late Map<String, Object?> canonical;
  late PoseHubAppTestCatalog pack;
  setUpAll(() {
    original = _read('$_pack/catalog.json');
    canonical = _read('$_pack/catalog/catalog.json');
    pack = PoseHubAppTestCatalog.fromJson(original, semanticCatalog: canonical);
  });

  Map<String, Object?> fresh() => _read('$_pack/catalog.json');

  Map<String, Object?> downloadFile([Object? url]) => {
    'path': 'media/demo-A/demo-A.rgb-alpha.mp4',
    'bytes': 123,
    'sha256': 'a' * 64,
    'downloadUrl': ?url,
  };

  test('legacy file records retain null download locations', () {
    final raw = downloadFile();
    final file = PoseHubPackFile.fromJson(raw);
    expect(file.downloadUri, isNull);
    expect(file.path, raw['path']);
    expect(file.bytes, 123);
    expect(file.sha256, 'a' * 64);
    expect(
      PoseHubPackFile.fromJson({...raw, 'downloadUrl': null}).downloadUri,
      isNull,
    );
  });

  test(
    'per-file HTTPS download leaves installed-path resolution unchanged',
    () {
      const url =
          'https://github.com/mhgd3250905/ugk-3d-pose-sdk/releases/download/'
          'posehub-app-test-pack-r1-v3/demo-A.rgb-alpha.mp4';
      final raw = downloadFile(url);
      final file = PoseHubPackFile.fromJson(raw);
      expect(file.downloadUri, Uri.parse(url));
      raw['downloadUrl'] = 'https://changed.example.test/other.mp4';
      expect(file.downloadUri, Uri.parse(url));
      expect(
        file.resolve(Uri.parse('https://app.example.test/installed/v3/')),
        Uri.parse(
          'https://app.example.test/installed/v3/'
          'media/demo-A/demo-A.rgb-alpha.mp4',
        ),
      );
      expect(
        file.resolve(Uri.parse('file:///verified/v3/')),
        Uri.parse('file:///verified/v3/media/demo-A/demo-A.rgb-alpha.mp4'),
      );
    },
  );

  test('download locations reject non-HTTPS and credential-bearing URLs', () {
    for (final url in <Object?>[
      '',
      42,
      '/media/demo-A.mp4',
      '//cdn.example.test/demo-A.mp4',
      'http://cdn.example.test/demo-A.mp4',
      'file:///verified/demo-A.mp4',
      'data:video/mp4,test',
      'javascript:alert(1)',
      'https:/demo-A.mp4',
      'https://user:secret@example.test/demo-A.mp4',
      'https://example.test/demo-A.mp4?token=secret',
      'https://example.test/demo-A.mp4?',
      'https://example.test/demo-A.mp4#frame',
      'https://example.test/demo-A.mp4#',
      'https://[invalid/demo-A.mp4',
    ]) {
      expect(
        () => PoseHubPackFile.fromJson(downloadFile(url)),
        throwsFormatException,
        reason: '$url',
      );
    }
  });

  // Exercise the original canonical subset without assuming a fixed count
  // in the parser. The supplied source still has 142 original definitions.
  Map<String, Object?> legacyFixture() {
    final legacy = fresh();
    final baseIds = (canonical['drills']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .map((drill) => drill['id'])
        .toSet();
    final actions = (legacy['actions']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .where((action) => baseIds.contains(action['id']))
        .toList();
    legacy['actions'] = actions;
    legacy['totalCount'] = actions.length;
    legacy['readyCount'] = actions.length;
    final summary = legacy['trainingSemantics']! as Map<String, Object?>;
    summary.remove('semanticRevision');
    summary['definitionCompleteCount'] = actions.length;
    summary['definitionCompleteIds'] = [
      for (final action in actions) action['id'],
    ];
    summary['incompleteActionIds'] = <Object?>[];
    legacy.remove('mediaDistribution');
    for (final file in _mediaFiles(legacy)) {
      file.remove('assetName');
      file.remove('downloadUrl');
    }
    return legacy;
  }

  Map<String, Object?> releaseFixture(String version) {
    final data = fresh();
    final base =
        'https://github.com/mhgd3250905/ugk-3d-pose-sdk/releases/download/'
        '$version/';
    var count = 0;
    var bytes = 0;
    for (final file in _mediaFiles(data)) {
      final name = (file['path']! as String).split('/').last;
      file['assetName'] = name;
      file['downloadUrl'] = '$base$name';
      count++;
      bytes += file['bytes']! as int;
    }
    data['mediaDistribution'] = {
      'version': version,
      'kind': 'github-release-assets@1',
      'baseUrl': base,
      'assetNameRule': 'basename(path)',
      'sourceCatalogSha256': 'b' * 64,
      'mediaFiles': count,
      'mediaBytes': bytes,
    };
    return data;
  }

  Map<String, Object?> objectFixture(String version, String prefix) {
    final data = releaseFixture(version);
    final base = 'https://objects.example.test/$prefix';
    final distribution = data['mediaDistribution']! as Map<String, Object?>;
    distribution
      ..remove('assetNameRule')
      ..['kind'] = 'r2-objects@1'
      ..['baseUrl'] = base
      ..['pathRule'] = 'relative-path'
      ..['objectKeyPrefix'] = prefix;
    for (final file in _mediaFiles(data)) {
      file['downloadUrl'] = '$base${file['path']}';
    }
    return data;
  }

  test(
    'all 219 load in exact source order, with 657 intact file references',
    () {
      expect(pack.id, 'app-test-pack-r1');
      expect(pack.allActions, hasLength(219));
      expect(pack.allActions.map((a) => a.id).toSet(), hasLength(219));
      expect(pack.allActions.map((a) => a.id), [
        for (final raw in original['actions']! as List<Object?>)
          (raw! as Map<String, Object?>)['id'],
      ]);
      final allFiles = [
        for (final action in pack.allActions) ...action.files.values,
      ];
      expect(allFiles, hasLength(657));
      expect(allFiles.map((f) => f.path).toSet(), hasLength(657));
      expect(
        allFiles.fold<int>(0, (sum, f) => sum + f.bytes),
        _mediaFiles(
          original,
        ).fold<int>(0, (sum, file) => sum + (file['bytes']! as int)),
      );
      expect(pack.tryGet('abs-A'), same(pack.allActions.first));
      expect(
        pack.tryGet('abs-a'),
        isNull,
        reason: 'IDs are case-sensitive and never renamed',
      );
      expect(pack.tryGet('missing-action'), isNull);
      for (final action in pack.allActions) {
        expect(action.availableForApp, isTrue);
        expect(action.video, same(action.files['video']));
        expect(action.cover, same(action.files['cover']));
        expect(action.thumbnail, same(action.files['thumbnail']));
        expect(action.raw['id'], action.id);
        expect(action.raw['nameZh'], action.nameZh);
        expect(action.raw['reviewed'], isFalse);
        expect(action.raw['releaseEligible'], isFalse);
      }
    },
  );

  test(
    '211 complete / 8 pending retain original availability and review flags',
    () {
      expect(pack.semanticCompleteActions, hasLength(211));
      expect(pack.pendingActions, hasLength(8));
      expect(
        pack.semanticCompleteActions.where((a) => a.availableForTraining),
        hasLength(142),
      );
      expect(
        pack.semanticCompleteActions.where((a) => !a.availableForTraining),
        hasLength(69),
      );
      expect(pack.pendingActions.every((a) => !a.availableForTraining), isTrue);
      expect(
        pack.semanticCompleteActions.map((a) => a.trainingStatusLabel).toSet(),
        {'训练说明完整'},
      );
      expect(pack.pendingActions.map((a) => a.trainingStatusLabel).toSet(), {
        '训练说明待补',
      });
      // Source readyCount is media readiness, not training completeness.
      expect(pack.raw['readyCount'], 219);
      expect(pack.raw['pendingCount'], 0);
      expect(pack.raw['reviewed'], isFalse);
      expect(pack.raw['releaseEligible'], isFalse);
    },
  );

  test('pending fields including null stay unchanged and deeply read-only', () {
    final pending = pack.tryGet('h-towel-isometric-curl')!;
    expect(pending.rawTrainingDefinition['level'], isNull);
    final dose =
        pending.rawTrainingDefinition['defaultDose']! as Map<String, Object?>;
    expect(dose['mode'], 'time');
    expect(dose['seconds'], isNull);
    expect(dose['sets'], isNull);
    expect(dose['restSeconds'], isNull);
    expect(pending.rawTrainingSemantics['definitionComplete'], isFalse);
    final source = (original['actions']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .firstWhere((a) => a['id'] == pending.id);
    expect(pending.raw, source);
    expect(() => pack.raw['status'] = 'reviewed', throwsUnsupportedError);
    expect(
      () => pending.rawTrainingDefinition['level'] = 1,
      throwsUnsupportedError,
    );
    expect(() => dose['sets'] = 3, throwsUnsupportedError);
    expect(
      () => (pending.raw['cautions']! as List<Object?>).add('invented'),
      throwsUnsupportedError,
    );
    expect(() => pending.files.clear(), throwsUnsupportedError);
    expect(() => pending.video.raw['bytes'] = 1, throwsUnsupportedError);
    expect(() => pack.allActions.clear(), throwsUnsupportedError);
  });

  test(
    'source objects may mutate later without changing the validated snapshot',
    () {
      final input = fresh();
      final copy = PoseHubAppTestCatalog.fromJson(input);
      _action(input)['nameZh'] = 'changed externally';
      _files(_action(input)).clear();
      expect(copy.allActions.first.nameZh, pack.allActions.first.nameZh);
      expect(copy.allActions.first.files, hasLength(3));
    },
  );

  test('AI view is self-contained and excludes every pending ID', () {
    final browsingOnly = PoseHubAppTestCatalog.fromJson(original);
    expect(browsingOnly.allActions, hasLength(219));
    final standalone = browsingOnly.toAiCatalog();
    expect(standalone.length, 211);
    expect(standalone.ids, pack.semanticCompleteActions.map((a) => a.id));
    expect(
      standalone['abs-A']!.defaultDose.toJson(),
      pack.tryGet('abs-A')!.raw['defaultDose'],
    );
    final ai = pack.toAiCatalog();
    expect(ai.length, 211);
    expect(ai.problems, isEmpty);
    expect(ai.version, canonical['version']);
    expect(ai.taxonomy.categoryLabel('strength'), isNotEmpty);
    expect(ai.ids, pack.semanticCompleteActions.map((a) => a.id));
    final profile = loadProfile('smartfit');
    final whitelist = CoachTools.whitelist(profile, ai);
    expect(whitelist, hasLength(211));
    for (final action in pack.pendingActions) {
      expect(ai.contains(action.id), isFalse);
      expect(standalone.contains(action.id), isFalse);
      expect(profile.scope(ai).any((d) => d.id == action.id), isFalse);
      expect(whitelist, isNot(contains(action.id)));
    }
    final complete = ai['abs-A']!;
    expect(complete.name.of('zh'), pack.tryGet('abs-A')!.nameZh);
    expect(
      complete.raw['defaultDose'],
      pack.tryGet('abs-A')!.raw['defaultDose'],
    );
    expect(
      browsingOnly
          .toAiCatalog(semanticCatalog: Catalog.fromJson(canonical))
          .ids,
      ai.ids,
    );
  });

  test(
    'exact original canonical bytes verify, reserialized bytes fail integrity',
    () {
      final bytes = File('$_pack/catalog.json').readAsBytesSync();
      final canonicalBytes = File(
        '$_pack/catalog/catalog.json',
      ).readAsBytesSync();
      expect(
        PoseHubAppTestCatalog.fromBytes(
          bytes,
          semanticCatalogBytes: canonicalBytes,
        ).toAiCatalog().length,
        211,
      );
      final rewritten = utf8.encode(jsonEncode(canonical));
      expect(
        () => PoseHubAppTestCatalog.fromBytes(
          bytes,
          semanticCatalogBytes: rewritten,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'base 142 stay canonical; all 69 additions keep their own exact dose',
    () {
      final ai = pack.toAiCatalog();
      final base = (canonical['drills']! as List<Object?>)
          .cast<Map<String, Object?>>();
      final baseIds = base.map((d) => d['id']).toSet();
      expect(base, hasLength(142));
      for (final drill in base) {
        expect(ai[drill['id']! as String]!.raw, drill);
      }
      final additions = pack.semanticCompleteActions.where(
        (action) => !baseIds.contains(action.id),
      );
      expect(additions, hasLength(69));
      for (final action in additions) {
        final drill = ai[action.id]!;
        expect(action.availableForTraining, isFalse);
        expect(drill.name.of('zh'), action.nameZh);
        expect(drill.defaultDose.toJson(), action.raw['defaultDose']);
        expect(drill.doseRange.toJson(), action.raw['doseRange']);
        expect(drill.cues, action.raw['cues']);
        for (final field in action.raw.entries) {
          expect(
            drill.raw[field.key],
            field.value,
            reason: '${action.id}.${field.key} must retain source metadata',
          );
        }
      }
      // These defaults differ by design; a generic strength fallback is invalid.
      expect(ai['h-slider-body-saw']!.defaultDose.toJson(), {
        'mode': 'reps',
        'sets': 1,
        'reps': 4,
        'restSeconds': 45,
      });
      expect(ai['g-cable-hip-abduction']!.defaultDose.toJson(), {
        'mode': 'reps',
        'sets': 3,
        'reps': 12,
        'restSeconds': 30,
      });
    },
  );

  test(
    'future releases accept self-consistent files and complete definitions',
    () {
      for (final version in [
        'posehub-app-test-pack-r1-v3',
        'posehub-app-test-pack-r1-v4',
        'release-2028.1',
      ]) {
        final data = releaseFixture(version);
        final firstFile = _mediaFiles(data).first;
        firstFile['bytes'] = (firstFile['bytes']! as int) + 7;
        firstFile['sha256'] = 'c' * 64;
        final distribution = data['mediaDistribution']! as Map<String, Object?>;
        distribution['mediaBytes'] = (distribution['mediaBytes']! as int) + 7;
        final semantics = data['trainingSemantics']! as Map<String, Object?>;
        semantics['semanticRevision'] = '$version-definitions';
        semantics['revisionSha256'] = 'd' * 64;
        final action = _actionById(data, 'g-cable-hip-abduction');
        (action['defaultDose']! as Map<String, Object?>)['restSeconds'] = 31;
        (action['doseRange']! as Map<String, Object?>)['restSeconds'] = [
          31,
          31,
        ];
        final future = PoseHubAppTestCatalog.fromJson(data);
        expect(future.allActions, hasLength(219));
        expect(future.semanticCompleteActions, hasLength(211));
        expect(future.pendingActions, hasLength(8));
        expect(future.toAiCatalog().length, 211);
        expect(
          future
              .toAiCatalog()['g-cable-hip-abduction']!
              .defaultDose
              .restSeconds,
          31,
        );
        expect(
          future
              .toAiCatalog(semanticCatalog: Catalog.fromJson(canonical))
              .length,
          211,
        );
        expect(
          future.allActions.first.video.downloadUri,
          Uri.parse(firstFile['downloadUrl']! as String),
        );
      }
    },
  );

  test(
    'complete declarations require actual values rather than dose defaults',
    () {
      for (final mutation in <void Function(Map<String, Object?>)>[
        (data) =>
            (_actionById(data, 'g-cable-hip-abduction')['defaultDose']!
                    as Map<String, Object?>)['restSeconds'] =
                null,
        (data) =>
            (_actionById(data, 'g-cable-hip-abduction')['defaultDose']!
                    as Map<String, Object?>)['sets'] =
                null,
        (data) =>
            (_actionById(data, 'g-cable-hip-abduction')['defaultDose']!
                    as Map<String, Object?>)['reps'] =
                null,
        (data) =>
            (_action(data)['defaultDose']! as Map<String, Object?>)['seconds'] =
                null,
        (data) => _actionById(data, 'g-cable-hip-abduction')['level'] = null,
        (data) =>
            _actionById(data, 'g-cable-hip-abduction')['scenes'] = <Object?>[],
        (data) =>
            (_actionById(data, 'g-cable-hip-abduction')['cues']!
                    as Map<String, Object?>)['zh'] =
                <Object?>[],
        (data) =>
            (_actionById(data, 'g-cable-hip-abduction')['trainingSemantics']!
                as Map<String, Object?>)['missingRequiredFields'] = [
              'level',
            ],
        (data) =>
            (_actionById(data, 'g-cable-hip-abduction')['trainingSemantics']!
                    as Map<String, Object?>)['definitionComplete'] =
                false,
        (data) => _action(data)['availableForApp'] = false,
      ]) {
        final data = fresh();
        mutation(data);
        expect(
          () => PoseHubAppTestCatalog.fromJson(data),
          throwsFormatException,
        );
      }
      final updatedPartial = fresh();
      _actionById(updatedPartial, 'h-towel-isometric-curl')['level'] = 1;
      final partial = PoseHubAppTestCatalog.fromJson(updatedPartial);
      expect(partial.pendingActions, hasLength(8));
      expect(partial.toAiCatalog().contains('h-towel-isometric-curl'), isFalse);
    },
  );

  test(
    'object distributions preserve relative paths across future versions',
    () {
      for (final (version, prefix) in [
        ('posehub-app-test-pack-r1-v3', 'pack/r1-v3/'),
        ('posehub-app-test-pack-r1-v4', 'pack/r1-v4/'),
        ('future-release', 'archive/next-generation/'),
      ]) {
        final data = objectFixture(version, prefix);
        final objects = PoseHubAppTestCatalog.fromJson(data);
        expect(objects.allActions, hasLength(219));
        expect(objects.semanticCompleteActions, hasLength(211));
        expect(objects.pendingActions, hasLength(8));
        expect(objects.toAiCatalog().length, 211);
        for (final action in objects.allActions) {
          for (final file in action.files.values) {
            expect(
              file.downloadUri,
              Uri.parse('https://objects.example.test/$prefix${file.path}'),
            );
          }
        }
      }
    },
  );

  test(
    'object manifests reject unsafe prefixes and mismatched download paths',
    () {
      for (final mutation in <void Function(Map<String, Object?>)>[
        (data) =>
            (data['mediaDistribution']! as Map<String, Object?>)['pathRule'] =
                'basename(path)',
        (data) =>
            (data['mediaDistribution']!
                    as Map<String, Object?>)['objectKeyPrefix'] =
                '../',
        (data) =>
            (data['mediaDistribution']!
                    as Map<String, Object?>)['objectKeyPrefix'] =
                '/pack/r1-v4/',
        (data) =>
            (data['mediaDistribution']!
                    as Map<String, Object?>)['objectKeyPrefix'] =
                'pack/r1-v4',
        (data) =>
            (data['mediaDistribution']!
                    as Map<String, Object?>)['objectKeyPrefix'] =
                'pack/other/',
        (data) =>
            (data['mediaDistribution']! as Map<String, Object?>)['baseUrl'] =
                'https://objects.example.test/another/',
        (data) => _mediaFiles(data).first['downloadUrl'] =
            'https://objects.example.test/pack/r1-v4/abs-A.rgb-alpha.mp4',
        (data) => _mediaFiles(data).first.remove('downloadUrl'),
        (data) =>
            (data['mediaDistribution']! as Map<String, Object?>)['mediaFiles'] =
                656,
        (data) =>
            (data['mediaDistribution']! as Map<String, Object?>)['mediaBytes'] =
                1,
      ]) {
        final data = objectFixture(
          'posehub-app-test-pack-r1-v4',
          'pack/r1-v4/',
        );
        mutation(data);
        expect(
          () => PoseHubAppTestCatalog.fromJson(data),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'object keys may reuse basenames while optional asset names stay descriptive',
    () {
      final data = objectFixture('posehub-app-test-pack-r1-v4', 'pack/r1-v4/');
      final first = _files(_action(data))['video']! as Map<String, Object?>;
      final second = _files(_action(data, 1))['video']! as Map<String, Object?>;
      second['path'] =
          'media/${_action(data, 1)['id']}/copy/${first['assetName']}';
      second['assetName'] = first['assetName'];
      second['downloadUrl'] =
          'https://objects.example.test/pack/r1-v4/${second['path']}';
      expect(PoseHubAppTestCatalog.fromJson(data).toAiCatalog().length, 211);
      for (final file in _mediaFiles(data)) {
        file.remove('assetName');
      }
      expect(PoseHubAppTestCatalog.fromJson(data).toAiCatalog().length, 211);
    },
  );

  test('media manifests reject inconsistent totals, versions and receipts', () {
    for (final mutation in <void Function(Map<String, Object?>)>[
      (data) => data.remove('mediaDistribution'),
      (data) =>
          (data['mediaDistribution']! as Map<String, Object?>)['mediaFiles'] =
              656,
      (data) =>
          (data['mediaDistribution']! as Map<String, Object?>)['mediaBytes'] =
              1,
      (data) =>
          (data['mediaDistribution']! as Map<String, Object?>)['version'] = '',
      (data) =>
          (data['mediaDistribution']! as Map<String, Object?>)['version'] =
              '../v4',
      (data) =>
          (data['mediaDistribution']! as Map<String, Object?>)['version'] =
              'v5',
      (data) => (data['mediaDistribution']! as Map<String, Object?>)['kind'] =
          'unknown@1',
      (data) =>
          (data['mediaDistribution']!
                  as Map<String, Object?>)['assetNameRule'] =
              'path',
      (data) =>
          (data['mediaDistribution']! as Map<String, Object?>)['baseUrl'] =
              'http://example.test/v4/',
      (data) =>
          (data['mediaDistribution']!
                  as Map<String, Object?>)['sourceCatalogSha256'] =
              'bad',
      (data) => _mediaFiles(data).first['assetName'] = '../outside.mp4',
      (data) => _mediaFiles(data).first['assetName'] = 'wrong-name.mp4',
      (data) => _mediaFiles(data).first.remove('assetName'),
      (data) => _mediaFiles(data).first['downloadUrl'] =
          'https://elsewhere.test/abs-A.rgb-alpha.mp4',
      (data) => _mediaFiles(data).first['downloadUrl'] = null,
      (data) => _mediaFiles(data).first['downloadUrl'] =
          'https://example.test/file.mp4?token=secret',
      (data) => _mediaFiles(data).first['sha256'] = 'not-a-sha256',
      (data) => _mediaFiles(data).first['bytes'] = 0,
      (data) => _mediaFiles(data).first['bytes'] =
          (_mediaFiles(data).first['bytes']! as int) + 1,
    ]) {
      final data = releaseFixture('posehub-app-test-pack-r1-v4');
      mutation(data);
      expect(() => PoseHubAppTestCatalog.fromJson(data), throwsFormatException);
    }
  });

  test('release asset basenames must remain unique across original paths', () {
    final data = releaseFixture('posehub-app-test-pack-r1-v4');
    final first = _files(_action(data))['video']! as Map<String, Object?>;
    final second = _files(_action(data, 1))['video']! as Map<String, Object?>;
    second['path'] =
        'media/${_action(data, 1)['id']}/copy/${first['assetName']}';
    second['assetName'] = first['assetName'];
    second['downloadUrl'] = first['downloadUrl'];
    expect(() => PoseHubAppTestCatalog.fromJson(data), throwsFormatException);
  });

  test(
    'canonical byte integrity follows each catalogue reference, not a fixed hash',
    () {
      final changed = deepCopy(canonical)..['unrecognizedMetadata'] = 'future';
      final bytes = utf8.encode(jsonEncode(changed));
      final data = releaseFixture('posehub-app-test-pack-r1-v4');
      final reference = data['semanticCatalog']! as Map<String, Object?>;
      reference['bytes'] = bytes.length;
      reference['sha256'] = crypto.sha256.convert(bytes).toString();
      expect(
        PoseHubAppTestCatalog.fromJson(
          data,
          semanticCatalog: changed,
        ).toAiCatalog().length,
        211,
      );
      expect(
        PoseHubAppTestCatalog.fromBytes(
          utf8.encode(jsonEncode(data)),
          semanticCatalogBytes: bytes,
        ).toAiCatalog().length,
        211,
      );
      expect(
        () => PoseHubAppTestCatalog.fromBytes(
          utf8.encode(jsonEncode(data)),
          semanticCatalogBytes: [...bytes, 32],
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'object-key order and extra canonical metadata do not gate versions',
    () {
      final reordered = Map<String, Object?>.fromEntries(
        original.entries.toList().reversed,
      );
      final changed = deepCopy(canonical)..['unrecognizedMetadata'] = 'changed';
      expect(
        PoseHubAppTestCatalog.fromJson(
          reordered,
          semanticCatalog: changed,
        ).toAiCatalog().length,
        211,
      );
    },
  );

  test(
    'legacy availability and optional unknowns are separate from completeness',
    () {
      final legacy = legacyFixture();
      _action(legacy)['availableForTraining'] = false;
      (_action(legacy)['trainingSemantics']!
          as Map<String, Object?>)['unknownFields'] = [
        {'field': 'contraindications', 'reason': 'optional and retained'},
      ];
      expect(
        PoseHubAppTestCatalog.fromJson(
          legacy,
          semanticCatalog: canonical,
        ).toAiCatalog().length,
        142,
      );
      (_action(legacy)['trainingSemantics']!
          as Map<String, Object?>)['missingRequiredFields'] = [
        'level',
      ];
      expect(
        () => PoseHubAppTestCatalog.fromJson(legacy),
        throwsFormatException,
      );
    },
  );

  test(
    'legacy explicit matching canonical may contain more than 142 actions',
    () {
      final legacy = legacyFixture();
      final added = deepCopy(_actionById(original, 'g-cable-hip-abduction'));
      for (final value in _files(added).values) {
        final file = value! as Map<String, Object?>;
        file.remove('assetName');
        file.remove('downloadUrl');
      }
      added['availableForTraining'] = true;
      (added['trainingSemantics']! as Map<String, Object?>)['unknownFields'] =
          <Object?>[];
      final actions = legacy['actions']! as List<Object?>;
      actions.add(added);
      legacy['totalCount'] = actions.length;
      legacy['readyCount'] = actions.length;
      final summary = legacy['trainingSemantics']! as Map<String, Object?>;
      summary['definitionCompleteCount'] = actions.length;
      (summary['definitionCompleteIds']! as List<Object?>).add(added['id']);
      final expandedCanonical = deepCopy(canonical);
      (expandedCanonical['drills']! as List<Object?>).add({
        ...added,
        'name': {'zh': added['nameZh']},
      });

      final browsing = PoseHubAppTestCatalog.fromJson(legacy);
      expect(browsing.allActions, hasLength(143));
      expect(browsing.toAiCatalog().length, 143);
      final ai = browsing.toAiCatalog(
        semanticCatalog: Catalog.fromJson(expandedCanonical),
      );
      expect(ai.length, 143);
      expect(
        ai['g-cable-hip-abduction']!.defaultDose.toJson(),
        added['defaultDose'],
      );
      expect(
        PoseHubAppTestCatalog.fromJson(
          legacy,
          semanticCatalog: expandedCanonical,
        ).toAiCatalog().ids,
        ai.ids,
      );
    },
  );

  test(
    'mutating an existing Catalog view cannot change future AI projections',
    () {
      final first = pack.toAiCatalog();
      first['abs-A']!.scenes.clear();
      first['g-cable-hip-abduction']!.cues['zh']!.clear();
      final next = pack.toAiCatalog();
      expect(next['abs-A']!.scenes, pack.tryGet('abs-A')!.raw['scenes']);
      expect(next['abs-A']!.scenes, isNotEmpty);
      final sourceCues =
          pack.tryGet('g-cable-hip-abduction')!.raw['cues']!
              as Map<String, Object?>;
      expect(next['g-cable-hip-abduction']!.cues['zh'], sourceCues['zh']);
      final standalone = PoseHubAppTestCatalog.fromJson(original);
      standalone.toAiCatalog()['g-cable-hip-abduction']!.scenes.clear();
      expect(
        standalone.toAiCatalog()['g-cable-hip-abduction']!.scenes,
        isNotEmpty,
      );
    },
  );

  test(
    'canonical must match complete definitions exactly and keep unique IDs',
    () {
      final legacy = legacyFixture();
      final changed = _read('$_pack/catalog/catalog.json');
      final first =
          (changed['drills']! as List<Object?>).first! as Map<String, Object?>;
      (first['defaultDose']! as Map<String, Object?>)['sets'] = 99;
      expect(
        () => PoseHubAppTestCatalog.fromJson(legacy, semanticCatalog: changed),
        throwsFormatException,
      );
      final duplicated = _read('$_pack/catalog/catalog.json');
      (duplicated['drills']! as List<Object?>).add(
        (duplicated['drills']! as List<Object?>).first,
      );
      expect(
        () =>
            PoseHubAppTestCatalog.fromJson(legacy, semanticCatalog: duplicated),
        throwsFormatException,
      );
      final absent = _read('$_pack/catalog/catalog.json');
      (absent['drills']! as List<Object?>).removeAt(0);
      expect(
        () => PoseHubAppTestCatalog.fromJson(legacy, semanticCatalog: absent),
        throwsFormatException,
      );
    },
  );

  test('duplicate pack IDs are rejected instead of silently keeping one', () {
    final data = legacyFixture();
    _action(data, 1)['id'] = _action(data)['id'];
    expect(() => PoseHubAppTestCatalog.fromJson(data), throwsFormatException);
  });

  test(
    'unsafe original media paths and unsafe directory bases are rejected',
    () {
      for (final path in [
        '../outside.mp4',
        '/media/abs-A/demo.mp4',
        '//evil.test/demo.mp4',
        r'media\abs-A\demo.mp4',
        'media/abs-A/%2e%2e/demo.mp4',
        'media/abs-A/rev/../demo.mp4',
        'media/abs-A//demo.mp4',
        'media/abs-A/rev/.hidden.mp4',
        'media/abs-A/rev/demo.mp4?x=1',
        'media/abs-A/rev/demo.mp4#fragment',
        'https://evil.test/demo.mp4',
      ]) {
        final data = legacyFixture();
        (_files(_action(data))['video']! as Map<String, Object?>)['path'] =
            path;
        expect(
          () => PoseHubAppTestCatalog.fromJson(data),
          throwsFormatException,
          reason: path,
        );
      }
      final file = pack.allActions.first.video;
      for (final base in [
        'https://user:pass@example.test/pack/',
        'https://example.test/pack',
        'https://example.test/pack/?token=1',
        'https://example.test/pack/#a',
        'javascript:alert(1)',
        '//evil.test/pack/',
      ]) {
        expect(
          () => file.resolve(Uri.parse(base)),
          throwsFormatException,
          reason: base,
        );
      }
      expect(
        file.resolve(Uri.parse('https://example.test/r1/')).toString(),
        'https://example.test/r1/${file.path}',
      );
      expect(
        file.resolve(Uri.parse('assets/pose_hub/r1/')).path,
        'assets/pose_hub/r1/${file.path}',
      );
      // Uri has normalized the host's directory input. Original file paths
      // remain strict, and resolution stays under this supplied base.
      final normalizedBase = Uri.parse('https://example.test/pack/../other/');
      expect(normalizedBase.path, '/other/');
      expect(file.resolve(normalizedBase).path, '/other/${file.path}');
      final fileBase = Directory('local-pack/').absolute.uri;
      expect(
        file.resolve(fileBase).toString(),
        fileBase.resolve(file.path).toString(),
      );
    },
  );

  test(
    'malformed file metadata, counts and contradictory flags fail closed',
    () {
      for (final mutation in <void Function(Map<String, Object?>)>[
        (data) =>
            (_files(_action(data))['video']! as Map<String, Object?>)['bytes'] =
                0,
        (data) =>
            (_files(_action(data))['video']!
                    as Map<String, Object?>)['sha256'] =
                'bad',
        (data) => _files(_action(data)).remove('cover'),
        (data) => data['totalCount'] = 218,
        (data) => _action(data)['availableForApp'] = false,
        (data) => _action(data)['trainingDefinitionComplete'] = false,
        (data) => _action(data)['releaseEligible'] = true,
        (data) =>
            (_action(data)['trainingSemantics']!
                    as Map<String, Object?>)['videoLoopIsTrainingDose'] =
                true,
        (data) =>
            (_action(data)['defaultDose']!
                    as Map<String, Object?>)['restSeconds'] =
                null,
        (data) =>
            (data['trainingSemantics']!
                    as Map<String, Object?>)['definitionCompleteCount'] =
                143,
      ]) {
        final data = legacyFixture();
        mutation(data);
        expect(
          () => PoseHubAppTestCatalog.fromJson(data),
          throwsFormatException,
        );
      }
    },
  );
}
