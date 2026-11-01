import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import '../tool/trainer_asset_closure.dart';

const _primary = 's-butterfly';
const _other = 'h-adductor-rock';
const _pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
const _kitFixtures =
    'packages/ugk_trainer/test/fixtures/hiplab/executed-duration';

Map<String, Object?> _map(Object? value) => value! as Map<String, Object?>;
List<Object?> _list(Object? value) => value! as List<Object?>;
String _hash(List<int> bytes) => sha256.convert(bytes).toString();
Map<String, Object?> _receipt(List<int> bytes) => {
  'sha256': _hash(bytes),
  'bytes': bytes.length,
};

Matcher _configuration(String code) => isA<TrainerAssetConfigurationException>()
    .having((error) => error.code, 'code', code);

// These payloads are deliberately synthetic. Real downloaded PoseHub files are
// independently checked by the runtime-only APK gate, not by this unit fixture.
class _Fixture {
  _Fixture() {
    temporary = Directory.systemTemp.createTempSync('trainer-asset-closure-');
    source = Directory.fromUri(temporary.uri.resolve('source/'))..createSync();
    output = Directory.fromUri(temporary.uri.resolve('out/'));
    manifestFile = File.fromUri(temporary.uri.resolve('scope.json'));
    catalog = _map(jsonDecode(File('$_pack/catalog.json').readAsStringSync()));
    final semanticBytes = File('$_pack/catalog/catalog.json').readAsBytesSync();
    put('catalog/catalog.json', semanticBytes);
    for (final id in [_primary, _other]) {
      final action = actionFor(id);
      for (final entry in _map(action['files']).entries) {
        final file = _map(entry.value);
        final bytes = utf8.encode('unit-fixture:$id:${entry.key}');
        put(file['path']! as String, bytes);
        file.addAll(_receipt(bytes));
      }
      put('standing/$id.webp', utf8.encode('unit-standing:$id'));
    }
    final distribution = _map(catalog['mediaDistribution']);
    distribution['mediaBytes'] = _list(catalog['actions']).fold<int>(
      0,
      (sum, action) =>
          sum +
          _map(_map(action)['files']).values.fold<int>(
            0,
            (sum, file) => sum + (_map(file)['bytes']! as int),
          ),
    );
    writeCatalog();
    manifest = {
      'schemaVersion': 1,
      'appId': 'unit-test',
      'adapter': 'pose-hub-delivery@1',
      'voicePolicy': 'silent',
      'kitPolicy': 'none',
      'allowedActionIds': [_primary],
      'catalog': 'catalog.json',
      'catalogSha256': _hash(file('catalog.json').readAsBytesSync()),
      'sourceRoots': [source.absolute.path],
      'includeStanding': true,
      'integrity': {
        for (final id in [_primary, _other])
          'standing/$id.webp': _receipt(
            file('standing/$id.webp').readAsBytesSync(),
          ),
      },
    };
  }

  late Directory temporary;
  late Directory source;
  late Directory output;
  late File manifestFile;
  late Map<String, Object?> manifest;
  late Map<String, Object?> catalog;

  File file(String path) => File.fromUri(source.uri.resolve(path));
  File generated(String path) => File.fromUri(output.uri.resolve(path));
  Map<String, Object?> actionFor(String id) => _list(
    catalog['actions'],
  ).map(_map).singleWhere((action) => action['id'] == id);
  Map<String, Object?> get integrity => _map(manifest['integrity']);

  void put(String path, List<int> bytes) {
    final target = file(path);
    target.parent.createSync(recursive: true);
    target.writeAsBytesSync(bytes);
  }

  void pinned(String path, List<int> bytes) {
    put(path, bytes);
    integrity[path] = _receipt(bytes);
  }

  void json(String path, Object? value) =>
      pinned(path, utf8.encode(jsonEncode(value)));

  void writeCatalog() {
    put('catalog.json', utf8.encode(jsonEncode(catalog)));
  }

  void provideMedia(String id) {
    final distribution = _map(catalog['mediaDistribution']);
    for (final entry in _map(actionFor(id)['files']).entries) {
      final receipt = _map(entry.value);
      final bytes = utf8.encode('unit-fixture:$id:${entry.key}');
      distribution['mediaBytes'] =
          (distribution['mediaBytes']! as int) -
          (receipt['bytes']! as int) +
          bytes.length;
      put(receipt['path']! as String, bytes);
      receipt.addAll(_receipt(bytes));
    }
    pinned('standing/$id.webp', utf8.encode('unit-standing:$id'));
    writeCatalog();
    manifest['catalogSha256'] = _hash(file('catalog.json').readAsBytesSync());
  }

  Future<TrainerAssetClosureResult> run({String prefix = 'assets/trainer'}) {
    manifestFile.writeAsStringSync(jsonEncode(manifest));
    return generateTrainerAssetClosure(
      manifestFile: manifestFile,
      outputDirectory: output,
      assetPrefix: prefix,
    );
  }

  Map<String, Object?> read(String path) =>
      _map(jsonDecode(generated(path).readAsStringSync()));

  void voiceAndKit({String id = _primary}) {
    manifest['allowedActionIds'] = [id];
    manifest['voicePolicy'] = 'manifest';
    manifest['kitPolicy'] = 'index';
    manifest['actionKitIndex'] = 'assets/action_kits/index.json';
    manifest['voice'] = {
      'manifest': 'assets/voice/manifest.json',
      'root': 'assets/voice',
      'languages': ['zh'],
      'sharedKeys': ['p.welcome'],
      'chimes': ['end'],
    };
    final kit = _map(
      jsonDecode(File('$_kitFixtures/action_kits/$id.json').readAsStringSync()),
    );
    final media = _map(actionFor(id)['files']);
    final poster = _map(media['cover'])['path']! as String;
    final video = _map(media['video'])['path']! as String;
    _map(kit['display'])['poster'] = {'dark': poster, 'light': poster};
    _map(kit['media'])['video'] = {
      'dark': {'asset': video, 'loopSeconds': 8},
      'light': {'asset': video, 'loopSeconds': 8},
    };
    for (final kind in ['cover', 'video']) {
      final asset = _map(media[kind]);
      integrity[asset['path']! as String] = {
        'sha256': asset['sha256'],
        'bytes': asset['bytes'],
      };
    }
    json('assets/action_kits/$id.json', kit);
    // The nonselected kit intentionally has no file: index filtering must use
    // exact declared IDs instead of requiring or packaging the entire source.
    json('assets/action_kits/index.json', {
      'schema': 'action-kit-index@1',
      'kits': [
        'assets/action_kits/$id.json',
        'assets/action_kits/${id == _primary ? _other : _primary}.json',
      ],
    });
    final voice = _map(
      jsonDecode(File('$_kitFixtures/voice-manifest.json').readAsStringSync()),
    );
    json('assets/voice/manifest.json', voice);
    for (final key in _map(_map(voice['clips'])['zh']).keys) {
      pinned('assets/voice/zh/$key.m4a', utf8.encode('unit-voice:$key'));
    }
    for (final key in _map(voice['chimes']).keys) {
      pinned('assets/voice/chime/$key.m4a', utf8.encode('unit-chime:$key'));
    }
  }

  void dispose() {
    // Delete only this test's independently created temporary directory.
    final resolved = temporary.resolveSymbolicLinksSync();
    final parent = Directory.systemTemp.resolveSymbolicLinksSync();
    if (!resolved.startsWith('$parent${Platform.pathSeparator}') ||
        !temporary.uri.pathSegments.any(
          (part) => part.startsWith('trainer-asset-closure-'),
        )) {
      throw StateError('unexpected temporary path');
    }
    temporary.deleteSync(recursive: true);
  }
}

void main() {
  late _Fixture fixture;
  setUp(() => fixture = _Fixture());
  tearDown(() => fixture.dispose());

  test(
    'one allowlisted action has a complete verified, loadable projection',
    () async {
      final sourceBefore = {
        for (final entity
            in fixture.source.listSync(recursive: true).whereType<File>())
          entity.path: _hash(entity.readAsBytesSync()),
      };
      final result = await fixture.run();
      expect(result.allowedActionIds, [_primary]);
      expect(result.files, hasLength(6));
      final projected = PoseHubAppTestCatalog.fromBytes(
        fixture.generated('catalog.json').readAsBytesSync(),
        semanticCatalogBytes: fixture
            .generated('catalog/catalog.json')
            .readAsBytesSync(),
      );
      expect(projected.allActions.map((action) => action.id), [_primary]);
      final semantic = fixture.read('catalog/catalog.json');
      expect(_list(semantic['drills']).map((drill) => _map(drill)['id']), [
        _primary,
      ]);
      final drill = _map(_list(semantic['drills']).single);
      expect(drill['alternative'], isNull);
      expect(_map(_map(drill['assets'])['voice'])['status'], 'missing');
      final proof = fixture.read('asset-closure.json');
      final projection = _map(proof['projection']);
      expect(projection['voicePolicy'], 'silent');
      expect(projection['kitPolicy'], 'none');
      expect(projection['omittedLegacyBindings'], isNotEmpty);
      expect(_list(proof['generatedMetadata']), hasLength(2));
      final pubspec = fixture
          .generated('pubspec-assets.yaml')
          .readAsStringSync();
      for (final receipt in result.files) {
        final bytes = fixture
            .generated(receipt['path']! as String)
            .readAsBytesSync();
        expect(bytes.length, receipt['bytes']);
        expect(_hash(bytes), receipt['sha256']);
        expect(receipt['assetKey'], 'assets/trainer/${receipt['path']}');
        expect(pubspec, contains('    - ${receipt['assetKey']}\n'));
        expect((receipt['path']! as String), isNot(contains(_other)));
      }
      expect(pubspec, isNot(contains('asset-closure.json')));
      for (final entry in sourceBefore.entries) {
        expect(_hash(File(entry.key).readAsBytesSync()), entry.value);
      }
    },
  );

  test('dose, rhythm and first usable repSeconds survive projection', () async {
    final sourceSemantic = _map(
      jsonDecode(fixture.file('catalog/catalog.json').readAsStringSync()),
    );
    final before = _list(sourceSemantic['drills']).map(_map).firstWhere((
      drill,
    ) {
      final sources = _list(_map(_map(drill['assets'])['video'])['sources']);
      return sources
          .map(_map)
          .any(
            (source) =>
                source['repSeconds'] is num &&
                (source['repSeconds']! as num) > 0,
          );
    });
    final id = before['id']! as String;
    fixture.provideMedia(id);
    fixture.manifest['allowedActionIds'] = [id];
    await fixture.run();
    final after = _map(
      _list(fixture.read('catalog/catalog.json')['drills']).single,
    );
    for (final field in ['defaultDose', 'doseRange', 'rhythm']) {
      expect(after[field], before[field]);
    }
    final originalSources = _list(
      _map(_map(before['assets'])['video'])['sources'],
    );
    final firstSeconds = originalSources
        .map(_map)
        .map((source) => source['repSeconds'])
        .whereType<num>()
        .firstWhere((value) => value > 0);
    expect(
      _map(
        _list(_map(_map(after['assets'])['video'])['sources']).single,
      )['repSeconds'],
      firstSeconds,
    );
  });

  for (final entry in <String, (Object, String)>{
    'empty': (<String>[], 'empty_allowlist'),
    'duplicate': ([_primary, _primary], 'duplicate_value'),
    'unknown': (['not-a-catalog-id'], 'unknown_action_id'),
    'blank': ([' '], 'invalid_text'),
  }.entries) {
    test('${entry.key} allowlist rejects atomically', () async {
      fixture.manifest['allowedActionIds'] = entry.value.$1;
      await expectLater(fixture.run(), throwsA(_configuration(entry.value.$2)));
      expect(fixture.output.existsSync(), isFalse);
    });
  }

  test('missing video fails instead of emitting a partial bundle', () async {
    final video =
        _map(_map(fixture.actionFor(_primary)['files'])['video'])['path']!
            as String;
    fixture.file(video).deleteSync();
    await expectLater(fixture.run(), throwsA(_configuration('missing_asset')));
    expect(fixture.output.existsSync(), isFalse);
  });

  test('incorrect media hash fails with no output', () async {
    final video =
        _map(_map(fixture.actionFor(_primary)['files'])['video'])['path']!
            as String;
    final bytes = fixture.file(video).readAsBytesSync();
    bytes[0] ^= 1;
    fixture.put(video, bytes);
    await expectLater(fixture.run(), throwsA(_configuration('hash_mismatch')));
    expect(fixture.output.existsSync(), isFalse);
  });

  test('incorrect media length fails', () async {
    final video =
        _map(_map(fixture.actionFor(_primary)['files'])['video'])['path']!
            as String;
    fixture.put(video, [...fixture.file(video).readAsBytesSync(), 0]);
    await expectLater(fixture.run(), throwsA(_configuration('size_mismatch')));
  });

  test('unreceipted standing is a configuration error', () async {
    fixture.integrity.remove('standing/$_primary.webp');
    await expectLater(
      fixture.run(),
      throwsA(_configuration('missing_integrity')),
    );
  });

  for (final path in [
    '../escape.bin',
    '/absolute.bin',
    r'folder\escape.bin',
    'folder/%2e%2e/x',
    'C:/escape',
  ]) {
    test('unsafe resource path $path is refused before writes', () async {
      fixture.integrity[path] = {'bytes': 1, 'sha256': '0' * 64};
      await expectLater(
        fixture.run(),
        throwsA(_configuration('unsafe_relative_path')),
      );
      expect(fixture.output.existsSync(), isFalse);
    });
  }

  test('output asset prefix cannot traverse directories', () async {
    await expectLater(
      fixture.run(prefix: '../outside'),
      throwsA(_configuration('unsafe_relative_path')),
    );
  });

  test('case-colliding output paths are rejected', () async {
    fixture.voiceAndKit();
    fixture.pinned('posters/Light.webp', [1, 2, 3]);
    fixture.pinned('posters/light.webp', [1, 2, 3]);
    final kit = _map(
      jsonDecode(
        fixture.file('assets/action_kits/$_primary.json').readAsStringSync(),
      ),
    );
    _map(kit['display'])['poster'] = {
      'dark': 'posters/Light.webp',
      'light': 'posters/light.webp',
    };
    fixture.json('assets/action_kits/$_primary.json', kit);
    await expectLater(
      fixture.run(),
      throwsA(_configuration('duplicate_output_path')),
    );
  });

  test('ambiguous source mirrors are refused', () async {
    final second = Directory.fromUri(fixture.temporary.uri.resolve('second/'))
      ..createSync();
    File.fromUri(second.uri.resolve('catalog.json')).writeAsStringSync('{}');
    fixture.manifest['sourceRoots'] = [fixture.source.path, second.path];
    await expectLater(
      fixture.run(),
      throwsA(_configuration('ambiguous_source_asset')),
    );
  });

  test('existing nonempty output is preserved', () async {
    fixture.output.createSync();
    final existing = fixture.generated('keep.txt')..writeAsStringSync('keep');
    await expectLater(
      fixture.run(),
      throwsA(_configuration('output_not_empty')),
    );
    expect(existing.readAsStringSync(), 'keep');
  });

  for (final policy in ['adapter', 'voicePolicy', 'kitPolicy']) {
    test('projection requires an explicit $policy declaration', () async {
      fixture.manifest.remove(policy);
      await expectLater(
        fixture.run(),
        throwsA(isA<TrainerAssetConfigurationException>()),
      );
      expect(fixture.output.existsSync(), isFalse);
    });
  }

  for (final path in [
    'catalog.json',
    'catalog/catalog.json',
    'assets/action_kits/$_other.json',
    'assets/voice/zh/drill.$_other.m4a',
  ]) {
    test('sharedAssets cannot smuggle $path', () async {
      fixture.manifest['sharedAssets'] = [
        {'path': path},
      ];
      await expectLater(
        fixture.run(),
        throwsA(_configuration('unsupported_shared_assets')),
      );
      expect(fixture.output.existsSync(), isFalse);
    });
  }

  test('duplicate source action IDs are rejected before indexing', () async {
    _list(fixture.catalog['actions']).add(fixture.actionFor(_primary));
    fixture.writeCatalog();
    fixture.manifest['catalogSha256'] = _hash(
      fixture.file('catalog.json').readAsBytesSync(),
    );
    await expectLater(
      fixture.run(),
      throwsA(_configuration('invalid_source_catalog')),
    );
    expect(fixture.output.existsSync(), isFalse);
  });

  test('kit cannot reference another action delivery video', () async {
    fixture.voiceAndKit();
    final kit = _map(
      jsonDecode(
        fixture.file('assets/action_kits/$_primary.json').readAsStringSync(),
      ),
    );
    final outside = _map(_map(fixture.actionFor(_other)['files'])['video']);
    _map(_map(kit['media'])['video'])['light'] = {
      ...outside,
      'asset': outside['path'],
    };
    fixture.json('assets/action_kits/$_primary.json', kit);
    await expectLater(
      fixture.run(),
      throwsA(_configuration('asset_owner_outside_allowlist')),
    );
  });

  test(
    'kit, named voice, phase cues and explicit shared voice form one closure',
    () async {
      fixture.voiceAndKit(id: _other);
      final result = await fixture.run();
      final paths = result.files.map((file) => file['path']).toSet();
      expect(paths, contains('assets/voice/zh/drill.$_other.m4a'));
      expect(paths, contains('assets/voice/zh/point.$_other.m4a'));
      expect(paths, contains('assets/voice/zh/w.sit_back.m4a'));
      expect(paths, contains('assets/voice/zh/p.welcome.m4a'));
      expect(paths, contains('assets/voice/chime/end.m4a'));
      expect(paths, isNot(contains('assets/voice/zh/drill.$_primary.m4a')));
      expect(paths, isNot(contains('assets/action_kits/$_primary.json')));
      expect(fixture.read('assets/action_kits/index.json')['kits'], [
        'assets/trainer/assets/action_kits/$_other.json',
      ]);
      final kit = fixture.read('assets/action_kits/$_other.json');
      expect(
        _map(_map(kit['display'])['poster'])['dark'],
        startsWith('assets/trainer/media/$_other/'),
      );
      expect(
        _map(_map(_map(kit['media'])['video'])['light'])['asset'],
        startsWith('assets/trainer/media/$_other/'),
      );
      final voice = fixture.read('assets/voice/manifest.json');
      expect(_map(voice['clips']).keys, ['zh']);
      expect(
        _map(_map(voice['clips'])['zh']).containsKey('drill.$_primary'),
        isFalse,
      );
      expect(jsonEncode(voice), isNot(contains('drill.$_primary')));
      expect(
        _map(fixture.read('asset-closure.json')['projection'])['voicePolicy'],
        'manifest',
      );
    },
  );

  test(
    'named clip declared in voice metadata cannot be silently missing',
    () async {
      fixture.voiceAndKit();
      fixture.file('assets/voice/zh/drill.$_primary.m4a').deleteSync();
      await expectLater(
        fixture.run(),
        throwsA(_configuration('missing_asset')),
      );
      expect(fixture.output.existsSync(), isFalse);
    },
  );

  test('declared named clip must exist in every selected language', () async {
    fixture.voiceAndKit();
    final voice = _map(
      jsonDecode(fixture.file('assets/voice/manifest.json').readAsStringSync()),
    );
    _map(_map(voice['clips'])['zh']).remove('point.$_primary');
    fixture.json('assets/voice/manifest.json', voice);
    await expectLater(
      fixture.run(),
      throwsA(_configuration('missing_voice_key')),
    );
  });

  test('voice hash failures are not replaced by silent output', () async {
    fixture.voiceAndKit();
    fixture.integrity['assets/voice/zh/drill.$_primary.m4a'] = {
      ..._map(fixture.integrity['assets/voice/zh/drill.$_primary.m4a']),
      'sha256': '0' * 64,
    };
    await expectLater(fixture.run(), throwsA(_configuration('hash_mismatch')));
  });

  test(
    'kit references are strict even if no bundled catalog file uses them',
    () async {
      fixture.voiceAndKit();
      final kit = _map(
        jsonDecode(
          fixture.file('assets/action_kits/$_primary.json').readAsStringSync(),
        ),
      );
      _map(_map(kit['display'])['poster'])['light'] = 'assets/kit-poster.webp';
      fixture.json('assets/action_kits/$_primary.json', kit);
      await expectLater(
        fixture.run(),
        throwsA(_configuration('missing_asset')),
      );
    },
  );

  test('shared named voice cannot include an outside action', () async {
    fixture.voiceAndKit();
    _map(fixture.manifest['voice'])['sharedKeys'] = ['drill.$_other'];
    await expectLater(
      fixture.run(),
      throwsA(_configuration('voice_owner_outside_allowlist')),
    );
  });

  test('legacy action aliases cannot masquerade as shared voice', () async {
    fixture.voiceAndKit();
    _map(fixture.manifest['voice'])['sharedKeys'] = ['a.item.butterfly'];
    await expectLater(
      fixture.run(),
      throwsA(_configuration('unsupported_shared_voice_key')),
    );
  });

  test('kit voice cannot silently opt out of required files', () async {
    fixture.voiceAndKit();
    fixture.manifest['voicePolicy'] = 'silent';
    fixture.manifest.remove('voice');
    await expectLater(
      fixture.run(),
      throwsA(_configuration('missing_voice_configuration')),
    );
  });

  test('a selected kit must have an index entry', () async {
    fixture.voiceAndKit();
    fixture.json('assets/action_kits/index.json', {'kits': []});
    await expectLater(
      fixture.run(),
      throwsA(_configuration('missing_action_kit')),
    );
  });

  test('duplicate kit IDs are a configuration error', () async {
    fixture.voiceAndKit();
    fixture.json('assets/action_kits/index.json', {
      'kits': [
        'assets/action_kits/$_primary.json',
        'assets/action_kits/$_primary.json',
      ],
    });
    await expectLater(
      fixture.run(),
      throwsA(_configuration('duplicate_action_kit')),
    );
  });

  test('kit index identity must match the actual file', () async {
    fixture.voiceAndKit();
    final kit = _map(
      jsonDecode(
        fixture.file('assets/action_kits/$_primary.json').readAsStringSync(),
      ),
    )..['id'] = _other;
    fixture.json('assets/action_kits/$_primary.json', kit);
    await expectLater(
      fixture.run(),
      throwsA(_configuration('invalid_action_kit')),
    );
  });

  test('invalid voice durations cannot enter a projected manifest', () async {
    fixture.voiceAndKit();
    final voice = _map(
      jsonDecode(fixture.file('assets/voice/manifest.json').readAsStringSync()),
    );
    _map(_map(voice['clips'])['zh'])['p.go'] = -1;
    fixture.json('assets/voice/manifest.json', voice);
    await expectLater(
      fixture.run(),
      throwsA(_configuration('invalid_voice_duration')),
    );
  });
}
