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

  // Exercise the existing generic parser without the v2 snapshot gate. The
  // original 142 definitions are unchanged by the approved semantic revision.
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
    return legacy;
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

  test('AI view requires explicit canonical and excludes every pending ID', () {
    final browsingOnly = PoseHubAppTestCatalog.fromJson(original);
    expect(browsingOnly.allActions, hasLength(219));
    expect(browsingOnly.toAiCatalog, throwsStateError);
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

  test('the pinned revision rejects value, flag and provenance tampering', () {
    for (final mutation in <void Function(Map<String, Object?>)>[
      (data) =>
          (_actionById(data, 'g-cable-hip-abduction')['defaultDose']!
                  as Map<String, Object?>)['restSeconds'] =
              null,
      (data) =>
          _actionById(data, 'g-cable-hip-abduction')['availableForTraining'] =
              true,
      (data) =>
          (data['trainingSemantics']!
                  as Map<String, Object?>)['revisionSha256'] =
              '0' * 64,
      (data) => _actionById(data, 'h-towel-isometric-curl')['level'] = 1,
    ]) {
      final data = fresh();
      mutation(data);
      expect(
        () => PoseHubAppTestCatalog.fromJson(data, semanticCatalog: canonical),
        throwsFormatException,
      );
      expect(
        () => PoseHubAppTestCatalog.fromBytes(
          utf8.encode(jsonEncode(data)),
          semanticCatalogBytes: File(
            '$_pack/catalog/catalog.json',
          ).readAsBytesSync(),
        ),
        throwsFormatException,
      );
    }
    final disguised = fresh();
    (disguised['trainingSemantics']! as Map<String, Object?>).remove(
      'semanticRevision',
    );
    for (final raw
        in (disguised['actions']! as List<Object?>)
            .cast<Map<String, Object?>>()) {
      if (raw['trainingDefinitionComplete'] != true) continue;
      raw['availableForTraining'] = true;
      (raw['trainingSemantics']! as Map<String, Object?>)['unknownFields'] =
          <Object?>[];
    }
    final browsing = PoseHubAppTestCatalog.fromJson(disguised);
    expect(browsing.allActions, hasLength(219));
    expect(browsing.semanticCompleteActions, hasLength(211));
    expect(browsing.toAiCatalog, throwsStateError);
    expect(
      () => browsing.toAiCatalog(semanticCatalog: Catalog.fromJson(canonical)),
      throwsFormatException,
      reason: 'Removing the revision label cannot add definitions to canonical',
    );
    expect(
      () =>
          PoseHubAppTestCatalog.fromJson(disguised, semanticCatalog: canonical),
      throwsFormatException,
    );
  });

  test(
    'object-key order is harmless, but the original canonical is pinned',
    () {
      final reordered = Map<String, Object?>.fromEntries(
        original.entries.toList().reversed,
      );
      expect(
        PoseHubAppTestCatalog.fromJson(
          reordered,
          semanticCatalog: canonical,
        ).toAiCatalog().length,
        211,
      );
      final changed = deepCopy(canonical)..['unrecognizedMetadata'] = 'changed';
      expect(
        () =>
            PoseHubAppTestCatalog.fromJson(original, semanticCatalog: changed),
        throwsFormatException,
        reason: 'Even non-definition edits break the fixed canonical snapshot',
      );
    },
  );

  test(
    'legacy 142 definitions retain strict flags and unknown-field checks',
    () {
      final legacy = legacyFixture();
      expect(
        PoseHubAppTestCatalog.fromJson(
          legacy,
          semanticCatalog: canonical,
        ).toAiCatalog().length,
        142,
      );
      final changedFlag = deepCopy(legacy);
      _action(changedFlag)['availableForTraining'] = false;
      expect(
        () => PoseHubAppTestCatalog.fromJson(changedFlag),
        throwsFormatException,
      );
      final changedUnknown = deepCopy(legacy);
      (_action(changedUnknown)['trainingSemantics']!
          as Map<String, Object?>)['unknownFields'] = [
        {'field': 'contraindications', 'reason': 'legacy cannot waive this'},
      ];
      expect(
        () => PoseHubAppTestCatalog.fromJson(changedUnknown),
        throwsFormatException,
      );
    },
  );

  test(
    'legacy explicit matching canonical may contain more than 142 actions',
    () {
      final legacy = legacyFixture();
      final added = deepCopy(_actionById(original, 'g-cable-hip-abduction'));
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
      expect(browsing.toAiCatalog, throwsStateError);
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
      final next = pack.toAiCatalog();
      expect(next['abs-A']!.scenes, pack.tryGet('abs-A')!.raw['scenes']);
      expect(next['abs-A']!.scenes, isNotEmpty);
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
