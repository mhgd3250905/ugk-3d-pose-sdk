import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/engine.dart' as legacy_engine;
import 'package:ugk_trainer/src/media/media_view.dart' as legacy_media;
import 'package:ugk_trainer/src/ui/trainer_completion.dart' as legacy_done;
import 'package:ugk_trainer/ugk_trainer.dart' as legacy;
import 'package:ugk_trainer_runtime/engine.dart' as runtime_engine;
import 'package:ugk_trainer_runtime/src/media/media_view.dart' as runtime_media;
import 'package:ugk_trainer_runtime/src/ui/trainer_completion.dart'
    as runtime_done;
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart' as runtime;

// Immutable abae72d common-resource bytes. A move must not replace the old
// resources with placeholders or approve a new baseline from the split itself.
const _commonDigests = {
  'assets/media_player/player.css':
      '8da43dbb8c62a1017164fa33bee53ada6d50173d16445b119fbd6aa2e77389be',
  'assets/media_player/player.html':
      '75891dbcc01688dd87cb50a9781ffb3d8ad543b1f4551687fb5fc4590600a3fa',
  'assets/media_player/player.js':
      '552a31bbf9d092aef1d378a9349cef04e60b15af81796daefdec0d45a1ed2ff1',
  'assets/pose_hub_player/player.html':
      '0899cb58357f10de91a16b2eaf38dcf0018632b86421c92c977decaf39c36b22',
  'assets/pose_hub_player/player.js':
      '3a8c10106444f2fd73034613401762265bb582235dc14f2072a8c0e45ce81063',
  'assets/silence.m4a':
      'b80cc7afb559176d65f24e95ef77a66a6730961eb15d3aba49cf879d761a8078',
};

List<int> _bytes(ByteData data) =>
    data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

class _UnsupportedPackedPlatform extends Fake
    implements runtime.PackedAlphaPlatform {
  @override
  bool get isSupported => false;
}

TrainingPlan _plan() => TrainingPlan(
  id: 'runtime-identity',
  source: 'template',
  title: 'Shared runtime identity',
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
          exerciseId: 'hold',
          mode: DoseMode.time,
          workSeconds: 20,
          sets: 1,
          perSide: false,
          restSeconds: 0,
        ),
      ],
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'legacy and runtime exports denote the same engine and result types',
    () {
      for (final types in <(Type, Type)>[
        (legacy_engine.SessionBuilder, runtime_engine.SessionBuilder),
        (legacy_engine.SessionEngine, runtime_engine.SessionEngine),
        (legacy_engine.SessionPhase, runtime_engine.SessionPhase),
        (legacy_engine.SessionResult, runtime_engine.SessionResult),
        (legacy_engine.SessionRecorder, runtime_engine.SessionRecorder),
        (legacy_engine.Rhythm, runtime_engine.Rhythm),
        (legacy_engine.SessionScript, runtime_engine.SessionScript),
        (legacy_engine.SessionRunner, runtime_engine.SessionRunner),
        (legacy_engine.VoiceOutput, runtime_engine.VoiceOutput),
        (legacy_engine.VoiceQueue, runtime_engine.VoiceQueue),
        (legacy_engine.ManifestVoiceSource, runtime_engine.ManifestVoiceSource),
      ]) {
        expect(identical(types.$1, types.$2), isTrue, reason: '${types.$1}');
      }
      expect(
        identical(legacy_engine.Side.left, runtime_engine.Side.left),
        isTrue,
      );
      expect(
        identical(
          legacy_engine.Rhythm.selfPacedReps,
          runtime_engine.Rhythm.selfPacedReps,
        ),
        isTrue,
      );
    },
  );

  test('legacy and runtime widgets, routes and media share type identity', () {
    for (final types in <(Type, Type)>[
      (legacy.TrainerPlayer, runtime.TrainerPlayer),
      (legacy.TrainerTheme, runtime.TrainerTheme),
      (legacy.TrainerStrings, runtime.TrainerStrings),
      (legacy.TrainerSlideRoute, runtime.TrainerSlideRoute),
      (legacy.TrainerSlideRouteControl, runtime.TrainerSlideRouteControl),
      (legacy.TrainingKeepAlive, runtime.TrainingKeepAlive),
      (legacy.DrillMedia, runtime.DrillMedia),
      (legacy.DrillMediaController, runtime.DrillMediaController),
      (legacy.JustAudioVoiceOutput, runtime.JustAudioVoiceOutput),
      (legacy.UgkPackedAlphaVideo, runtime.UgkPackedAlphaVideo),
      (legacy.PoseHubActionBrowser, runtime.PoseHubActionBrowser),
      (legacy.PoseHubStandingImage, runtime.PoseHubStandingImage),
      (legacy_done.TrainerCompletion, runtime_done.TrainerCompletion),
      (
        legacy_media.DrillMediaPlatformView,
        runtime_media.DrillMediaPlatformView,
      ),
    ]) {
      expect(identical(types.$1, types.$2), isTrue, reason: '${types.$1}');
    }
    expect(
      identical(
        legacy.TrainingKeepAlive.channel,
        runtime.TrainingKeepAlive.channel,
      ),
      isTrue,
    );
    expect(
      identical(legacy.TrainerTheme.dark, runtime.TrainerTheme.dark),
      isTrue,
    );
  });

  test(
    'old-created timeline runs in the new engine without DTO conversion',
    () {
      final runtime_engine.SessionBuilder builder =
          legacy_engine.SessionBuilder();
      final legacy_engine.SessionEngine engine = runtime_engine.SessionEngine(
        builder.phases(_plan()),
      );
      expect(engine.phase.kind, runtime_engine.PhaseKind.prep);
      expect(builder.executionTiming(_plan()).totalSeconds, 30);
      engine.update(30.001);
      expect(engine.done, isTrue);
      expect(engine.fullyCompletedExercises, 1);
      expect(
        engine.visits.fold<double>(0, (sum, visit) => sum + visit.seconds),
        30,
      );
    },
  );

  test(
    'platform override is shared across the old and runtime entry points',
    () {
      final previous = runtime.UgkPackedAlphaVideo.debugPlatform;
      addTearDown(() => runtime.UgkPackedAlphaVideo.debugPlatform = previous);
      final platform = _UnsupportedPackedPlatform();
      legacy.UgkPackedAlphaVideo.debugPlatform = platform;
      expect(runtime.UgkPackedAlphaVideo.debugPlatform, same(platform));
      expect(runtime.UgkPackedAlphaVideo.isSupported, isFalse);
      expect(legacy.UgkPackedAlphaVideo.isSupported, isFalse);
    },
  );

  test('old and new result codecs preserve the same completion receipt', () {
    final start = DateTime.utc(2026, 11, 1);
    final runtime_engine.SessionResult original = legacy_engine.SessionResult(
      sessionId: 'same-session-id',
      planId: 'same-plan-id',
      planTitle: 'same-plan',
      startedAt: start,
      endedAt: start.add(const Duration(seconds: 30)),
      activeSeconds: 30,
      endedEarly: false,
      completedExercises: 1,
      totalExercises: 1,
      items: const [],
      feeling: legacy_engine.TrainingFeeling.justRight,
    );
    final legacy_engine.SessionResult restored = runtime_engine
        .SessionResult.fromJson(Map<String, dynamic>.from(original.toJson()));
    expect(restored, isA<runtime_engine.SessionResult>());
    expect(restored.toJson(), original.toJson());
    expect(restored.sessionId, original.sessionId);
    expect(restored.feeling, legacy_engine.TrainingFeeling.justRight);
  });

  for (final entry in _commonDigests.entries) {
    test(
      'legacy common asset key preserves original bytes: ${entry.key}',
      () async {
        final original = _bytes(
          await rootBundle.load('packages/ugk_trainer/${entry.key}'),
        );
        final current = _bytes(
          await rootBundle.load('packages/ugk_trainer_runtime/${entry.key}'),
        );
        expect(sha256.convert(original).toString(), entry.value);
        expect(sha256.convert(current).toString(), entry.value);
      },
    );
  }

  test(
    'old public keep-alive, shader and player keys remain compatible',
    () async {
      expect(
        legacy.JustAudioVoiceOutput.defaultKeepAliveAsset,
        'packages/ugk_trainer/assets/silence.m4a',
      );
      expect(
        legacy.AssetRouter.playerPrefix,
        'packages/ugk_trainer/assets/media_player/',
      );
      expect(
        legacy.UgkPackedAlphaVideo.shaderAsset,
        'packages/ugk_trainer/shaders/packed_alpha.frag',
      );
      final shader = _bytes(
        await rootBundle.load(legacy.UgkPackedAlphaVideo.shaderAsset),
      );
      expect(shader, isNotEmpty);
      expect(
        _bytes(await rootBundle.load(runtime.TrainerRuntimeAssets.shader)),
        shader,
      );
      const shaderDigest =
          '466b60708a36e194a1a8b159e4fef8ca398cab717caa3270a94c279e9b306a39';
      for (final path in [
        'shaders/packed_alpha.frag',
        '../ugk_trainer_runtime/shaders/packed_alpha.frag',
      ]) {
        expect(
          sha256.convert(File(path).readAsBytesSync()).toString(),
          shaderDigest,
        );
      }
      final router = legacy.AssetRouter(
        assets: const ['packages/ugk_trainer/assets/media_player/player.html'],
        load: (key) async =>
            Uint8List.fromList(_bytes(await rootBundle.load(key))),
      );
      final page = await router.route(
        '/${legacy.AssetRouter.playerPrefix}player.html',
      );
      expect(page.statusCode, 200);
      expect(
        sha256.convert(page.body).toString(),
        _commonDigests['assets/media_player/player.html'],
      );
    },
  );

  testWidgets(
    'legacy bundled catalogue and default standing poster still render',
    (tester) async {
      final catalog = await legacy.PoseHubActionLibrary.load();
      expect(catalog.allActions, hasLength(249));
      final action = catalog.tryGet('s-butterfly')!;
      final key =
          '${legacy.PoseHubActionLibrary.standingAssetRoot}${action.id}.webp';
      final image = _bytes(await rootBundle.load(key));
      final standingIndex = await tester.runAsync(
        () async =>
            jsonDecode(
                  await rootBundle.loadString(
                    '${legacy.PoseHubActionLibrary.standingAssetRoot}index.json',
                  ),
                )
                as Map<String, dynamic>,
      );
      final record =
          (standingIndex!['actions'] as Map<String, dynamic>)[action.id]
              as Map<String, dynamic>;
      expect(sha256.convert(image).toString(), record['imageSha256']);
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 120,
            height: 120,
            child: legacy.PoseHubStandingImage(action: action),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final provider =
          tester.widget<Image>(find.byType(Image)).image as AssetImage;
      expect(provider.package, 'ugk_trainer');
      expect(
        provider.assetName,
        'assets/pose_hub/app-pack-r2-v10/standing/s-butterfly.webp',
      );
    },
  );

  test('legacy library paths contain forwarding only, never another engine', () {
    final declarations = RegExp(
      r'^\s*(?:abstract\s+|final\s+|base\s+)?class\s+(SessionBuilder|SessionEngine|SessionResult|SessionRecorder)\b',
      multiLine: true,
    );
    final duplicateImplementations = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .where((file) => declarations.hasMatch(file.readAsStringSync()))
        .map((file) => file.path)
        .toList();
    expect(duplicateImplementations, isEmpty);
  });
}
