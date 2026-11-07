import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

const _commonAssets = {
  'assets/media_player/player.css',
  'assets/media_player/player.html',
  'assets/media_player/player.js',
  'assets/pose_hub_player/player.html',
  'assets/pose_hub_player/player.js',
  'assets/silence.m4a',
};

class _Bundle extends CachingAssetBundle {
  _Bundle(this.assets, {this.manifestKeys});
  final Map<String, List<int>> assets;
  final Iterable<String>? manifestKeys;
  final requests = <String>[];

  @override
  Future<ByteData> load(String key) async {
    requests.add(key);
    if (key == 'AssetManifest.bin') {
      return const StandardMessageCodec().encodeMessage({
        for (final key in manifestKeys ?? assets.keys)
          key: [
            {'asset': key},
          ],
      })!;
    }
    final bytes = assets[key];
    if (bytes == null) throw FlutterError('Not bundled: $key');
    return ByteData.sublistView(Uint8List.fromList(bytes));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('runtime ships only the explicit generic playback asset set', () async {
    final actual = Directory('assets')
        .listSync(recursive: true)
        .whereType<File>()
        .map((file) => file.path.replaceAll(r'\', '/'))
        .toSet();
    expect(actual, _commonAssets);
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    // Flutter treats a package under test as the root application. Its own
    // assets therefore have root keys; dependency-host keys are covered by the
    // legacy compatibility suite and the standalone runtime host build gate.
    final runtimeAssets = manifest
        .listAssets()
        .where((asset) => asset.startsWith('assets/'))
        .toSet();
    expect(runtimeAssets, _commonAssets);
    expect(
      manifest.listAssets().where(
        (asset) => asset.startsWith('packages/ugk_trainer/assets/pose_hub/'),
      ),
      isEmpty,
    );
    for (final key in runtimeAssets) {
      expect(await rootBundle.load(key), isNotNull);
    }
  });

  test('only runtime registers the native plugins and Android service', () {
    final runtimePubspec = File('pubspec.yaml').readAsStringSync();
    final legacyPubspec = File(
      '../ugk_trainer/pubspec.yaml',
    ).readAsStringSync();
    final pluginDeclaration = RegExp(r'^\s{2}plugin:\s*$', multiLine: true);
    expect(pluginDeclaration.allMatches(runtimePubspec), hasLength(1));
    expect(pluginDeclaration.allMatches(legacyPubspec), isEmpty);
    expect(runtimePubspec, contains('pluginClass: UgkTrainerPlugin'));
    expect(runtimePubspec, contains('package: com.ugk.trainer'));
    expect(
      RegExp(r'ios:\s+pluginClass: UgkTrainerPlugin').hasMatch(runtimePubspec),
      isTrue,
    );
    expect(Directory('../ugk_trainer/android').existsSync(), isFalse);
    expect(Directory('../ugk_trainer/ios').existsSync(), isFalse);

    final kotlin = Directory('android')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.kt'))
        .toList();
    final plugin = kotlin
        .where(
          (file) => RegExp(
            r'class\s+UgkTrainerPlugin\b',
          ).hasMatch(file.readAsStringSync()),
        )
        .toList();
    final service = kotlin
        .where(
          (file) => RegExp(
            r'class\s+TrainingSessionService\b',
          ).hasMatch(file.readAsStringSync()),
        )
        .toList();
    expect(plugin, hasLength(1));
    expect(service, hasLength(1));
    expect(
      plugin.single.readAsStringSync(),
      contains('"ugk_trainer/training_session"'),
    );
    final manifest = File(
      'android/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(
      RegExp(
        'android:name="com.ugk.trainer.TrainingSessionService"',
      ).allMatches(manifest),
      hasLength(1),
    );
  });

  test('runtime has no dependency on the legacy full-assets package', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
      RegExp(r'^\s+ugk_trainer:\s*$', multiLine: true).hasMatch(pubspec),
      isFalse,
    );
    final reverseImports = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .where(
          (file) => RegExp(
            r'''^\s*(?:import|export)\s+['"]package:ugk_trainer/''',
            multiLine: true,
          ).hasMatch(file.readAsStringSync()),
        )
        .map((file) => file.path)
        .toList();
    expect(reverseImports, isEmpty);
  });

  test(
    'runtime public asset resolver preserves an available legacy key',
    () async {
      const legacy = 'packages/ugk_trainer/assets/silence.m4a';
      const current = 'packages/ugk_trainer_runtime/assets/silence.m4a';
      final bundle = _Bundle({
        legacy: [1],
        current: [2],
      });
      expect(
        await TrainerRuntimeAssets.resolveAsset(legacy, bundle: bundle),
        legacy,
      );
    },
  );

  for (final path in {..._commonAssets, 'shaders/packed_alpha.frag'}) {
    test('runtime-only host resolves legacy common key: $path', () async {
      final legacy = 'packages/ugk_trainer/$path';
      final current = 'packages/ugk_trainer_runtime/$path';
      final bundle = _Bundle({current: utf8.encode(path)});
      final resolved = await TrainerRuntimeAssets.resolveAsset(
        legacy,
        bundle: bundle,
      );
      expect(resolved, current);
      final loaded = await bundle.load(resolved);
      expect(
        sha256.convert(loaded.buffer.asUint8List()).toString(),
        sha256.convert(utf8.encode(path)).toString(),
      );
    });
  }

  test(
    'shader excluded from AssetManifest still resolves its actual key',
    () async {
      const legacy = 'packages/ugk_trainer/shaders/packed_alpha.frag';
      const current = 'packages/ugk_trainer_runtime/shaders/packed_alpha.frag';
      for (final available in [legacy, current]) {
        final bundle = _Bundle({
          available: [1, 2, 3],
        }, manifestKeys: const []);
        expect(
          await TrainerRuntimeAssets.resolveAsset(legacy, bundle: bundle),
          available,
        );
        expect(bundle.requests, contains(available));
      }
      final absent = _Bundle({});
      expect(
        await TrainerRuntimeAssets.resolveAsset(legacy, bundle: absent),
        legacy,
      );
    },
  );

  test('missing common asset is not substituted with a placeholder', () async {
    const key = 'packages/ugk_trainer/assets/silence.m4a';
    final bundle = _Bundle({});
    final resolved = await TrainerRuntimeAssets.resolveAsset(
      key,
      bundle: bundle,
    );
    expect(resolved, key);
    await expectLater(bundle.load(resolved), throwsA(isA<FlutterError>()));
  });

  test('compatibility mapping never rewrites a missing action asset', () async {
    const key =
        'packages/ugk_trainer/assets/pose_hub/standing/not-allowed.webp';
    const other =
        'packages/ugk_trainer_runtime/assets/pose_hub/standing/not-allowed.webp';
    final bundle = _Bundle({
      other: [1, 2, 3],
    });
    expect(await TrainerRuntimeAssets.resolveAsset(key, bundle: bundle), key);
    expect(bundle.requests, isEmpty);
  });

  test('engine and timeline adapter work with host-only plan data', () {
    final plan = TrainingPlan(
      id: 'host-plan',
      source: 'template',
      title: 'Host-defined plan',
      goal: 'relax',
      scene: 'home',
      equipment: const [],
      level: 1,
      targetMinutes: 1,
      blocks: const [
        PlanBlock(
          id: 'main',
          name: 'main',
          type: BlockType.main,
          items: [
            PlanItem(
              exerciseId: 'host-only-hold',
              mode: DoseMode.time,
              sets: 1,
              workSeconds: 20,
              perSide: false,
              restSeconds: 0,
            ),
          ],
        ),
      ],
    );
    final builder = SessionBuilder();
    final timeline = builder.phases(plan);
    final timing = evaluatePlanExecutionTiming(plan, builder.executionTiming);
    expect(timing.totalSeconds, 30);
    expect(timing.containsManualCounting, isFalse);
    expect(timing.blocks.single.blockId, 'main');
    final engine = SessionEngine(timeline)..update(timing.totalSeconds + .001);
    expect(engine.done, isTrue);
    expect(engine.fullyCompletedExercises, 1);
    expect(
      engine.visits.fold<double>(0, (sum, visit) => sum + visit.seconds),
      timing.totalSeconds,
    );
  });
}
