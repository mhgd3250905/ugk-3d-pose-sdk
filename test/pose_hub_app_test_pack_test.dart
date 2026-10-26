import 'dart:convert';
import 'dart:io';

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
      expect(allFiles.fold<int>(0, (sum, f) => sum + f.bytes), 587456377);
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
    '142 complete / 77 pending remain separate from media readiness and review',
    () {
      expect(pack.semanticCompleteActions, hasLength(142));
      expect(pack.pendingActions, hasLength(77));
      expect(
        pack.semanticCompleteActions.every((a) => a.availableForTraining),
        isTrue,
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
    final pending = pack.tryGet('g-cable-hip-abduction')!;
    expect(pending.rawTrainingDefinition['level'], isNull);
    final dose =
        pending.rawTrainingDefinition['defaultDose']! as Map<String, Object?>;
    expect(dose['reps'], isNull);
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

  test('AI view requires explicit canonical and excludes every pending ID', () {
    final browsingOnly = PoseHubAppTestCatalog.fromJson(original);
    expect(browsingOnly.allActions, hasLength(219));
    expect(browsingOnly.toAiCatalog, throwsStateError);
    final ai = pack.toAiCatalog();
    expect(ai.length, 142);
    expect(ai.problems, isEmpty);
    expect(ai.version, canonical['version']);
    expect(ai.taxonomy.categoryLabel('strength'), isNotEmpty);
    expect(ai.ids, pack.semanticCompleteActions.map((a) => a.id));
    final profile = loadProfile('smartfit');
    final whitelist = CoachTools.whitelist(profile, ai);
    expect(whitelist, hasLength(142));
    for (final action in pack.pendingActions) {
      expect(ai.contains(action.id), isFalse);
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
        142,
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
    'mutating an existing Catalog view cannot change future AI projections',
    () {
      final first = pack.toAiCatalog();
      first['abs-A']!.scenes.clear();
      final next = pack.toAiCatalog();
      expect(next['abs-A']!.scenes, pack.tryGet('abs-A')!.raw['scenes']);
      expect(next['abs-A']!.scenes, isNotEmpty);
    },
  );

  test(
    'canonical must match complete definitions exactly and keep unique IDs',
    () {
      final changed = _read('$_pack/catalog/catalog.json');
      final first =
          (changed['drills']! as List<Object?>).first! as Map<String, Object?>;
      (first['defaultDose']! as Map<String, Object?>)['sets'] = 99;
      expect(
        () =>
            PoseHubAppTestCatalog.fromJson(original, semanticCatalog: changed),
        throwsFormatException,
      );
      final duplicated = _read('$_pack/catalog/catalog.json');
      (duplicated['drills']! as List<Object?>).add(
        (duplicated['drills']! as List<Object?>).first,
      );
      expect(
        () => PoseHubAppTestCatalog.fromJson(
          original,
          semanticCatalog: duplicated,
        ),
        throwsFormatException,
      );
      final absent = _read('$_pack/catalog/catalog.json');
      (absent['drills']! as List<Object?>).removeAt(0);
      expect(
        () => PoseHubAppTestCatalog.fromJson(original, semanticCatalog: absent),
        throwsFormatException,
      );
    },
  );

  test('duplicate pack IDs are rejected instead of silently keeping one', () {
    final data = fresh();
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
        final data = fresh();
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
        (data) => _action(data)['availableForTraining'] = false,
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
        final data = fresh();
        mutation(data);
        expect(
          () => PoseHubAppTestCatalog.fromJson(data),
          throwsFormatException,
        );
      }
    },
  );
}
