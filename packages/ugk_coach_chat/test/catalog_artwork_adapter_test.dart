import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_coach_chat/src/theme/chat_theme.dart';
import 'package:ugk_coach_chat/src/ui/coach_ui_adapter.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

const _host = CoachExercise(
  id: 'host-id',
  name: 'Host localized name',
  poster:
      'packages/ugk_trainer/assets/pose_hub/app-pack-r2-v1/standing/old-standing.webp',
  stage: CoachMediaPalette(
    mediaStage: Colors.white,
    onStage: Colors.black,
    onStageMuted: Colors.grey,
  ),
  cues: ['Host cue'],
  levelLabel: 'Host level',
);

void main() {
  late coach.PoseHubPackAction action;
  late coach.Drill drill;
  setUpAll(() async {
    const root = '../ugk_trainer/assets/pose_hub/app-pack-r2-v10/';
    final catalog = coach.PoseHubAppTestCatalog.fromBytes(
      await File('${root}catalog.json').readAsBytes(),
      semanticCatalogBytes: await File(
        '${root}catalog/catalog.json',
      ).readAsBytes(),
    );
    action = catalog.tryGet('s-kneel-hipflex')!;
    drill = catalog.toAiCatalog()[action.id]!;
  });

  testWidgets(
    'current catalogue replaces SDK artwork and keeps host metadata',
    (tester) async {
      late CoachExercise resolved;
      late PoseHubCatalogImage image;
      await tester.pumpWidget(
        MaterialApp(
          home: CoachChatTheme(
            visual: CoachChatVisuals(exerciseFor: (_, _) => _host),
            child: Builder(
              builder: (context) {
                resolved = toCoachExercise(context, drill);
                image =
                    resolved.artworkBuilder!(context, thumbnail: true)
                        as PoseHubCatalogImage;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(resolved.name, _host.name);
      expect(resolved.cues, _host.cues);
      expect(resolved.stage, same(_host.stage));
      expect(resolved.levelLabel, _host.levelLabel);
      expect(image.id, action.id);
      expect(image.video.sha256, action.video.sha256);
      expect(image.cover.sha256, action.cover.sha256);
      expect(image.thumbnailFile.sha256, action.thumbnail.sha256);
      expect(image.thumbnail, isTrue);
    },
  );

  testWidgets('host theme covers and cutouts follow platform brightness', (
    tester,
  ) async {
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    late CoachExercise host;
    late CoachExercise resolved;
    for (final cutout in [false, true]) {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        await tester.pumpWidget(
          MaterialApp(
            themeMode: ThemeMode.system,
            theme: ThemeData.light(),
            darkTheme: ThemeData.dark(),
            home: CoachChatTheme(
              visual: CoachChatVisuals(
                exerciseFor: (id, selectedBrightness) {
                  final root = 'theme-lossy/${selectedBrightness.name}';
                  host = CoachExercise(
                    id: id,
                    name: _host.name,
                    poster: '$root/covers/$id.webp',
                    cutout: cutout ? '$root/cutouts/$id.webp' : null,
                    stillCutout: cutout ? '$root/stills/$id.webp' : null,
                    stage: _host.stage,
                  );
                  return host;
                },
              ),
              child: Builder(
                builder: (context) {
                  resolved = toCoachExercise(context, drill);
                  return withCoachChatUi(
                    context,
                    CoachRecommendCard(
                      actionIds: [drill.id],
                      note: '',
                      library: CoachExerciseLibrary([resolved]),
                      onOpenAction: (_) {},
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pump(kThemeAnimationDuration);
        await tester.pump();
        expect(resolved, same(host));
        expect(resolved.artworkBuilder, isNull);
        expect(
          resolved.poster,
          'theme-lossy/${brightness.name}/covers/${drill.id}.webp',
        );
        final image = tester.widget<Image>(find.byType(Image));
        expect(
          (image.image as AssetImage).assetName,
          resolved.stillCutout ?? resolved.poster,
        );
        expect(find.byType(PoseHubCatalogImage), findsNothing);
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('empty or SDK PoseHub poster opts into current catalogue artwork', (
    tester,
  ) async {
    late CoachExercise resolved;
    late PoseHubCatalogImage image;
    for (final poster in [
      '',
      'packages/ugk_trainer/assets/pose_hub/app-pack-r2-v1/standing/${drill.id}.webp',
      'packages/ugk_trainer/assets/pose_hub/app-pack-r2-v10/standing/${drill.id}.webp',
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: CoachChatTheme(
            visual: CoachChatVisuals(
              exerciseFor: (id, _) => CoachExercise(
                id: id,
                name: _host.name,
                poster: poster,
                stage: _host.stage,
              ),
            ),
            child: Builder(
              builder: (context) {
                resolved = toCoachExercise(context, drill);
                image =
                    resolved.artworkBuilder!(context, thumbnail: true)
                        as PoseHubCatalogImage;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(image.id, action.id);
      expect(image.video.sha256, action.video.sha256);
      expect(image.cover.sha256, action.cover.sha256);
      expect(image.thumbnailFile.sha256, action.thumbnail.sha256);
    }
  });

  testWidgets(
    'non-PoseHub host artwork keeps the original exercise unchanged',
    (tester) async {
      final raw = {...drill.raw}..remove('poseHubMedia');
      final legacy = coach.Drill.tryParse(raw, <String>[])!;
      late CoachExercise resolved;
      await tester.pumpWidget(
        MaterialApp(
          home: CoachChatTheme(
            visual: CoachChatVisuals(exerciseFor: (_, _) => _host),
            child: Builder(
              builder: (context) {
                resolved = toCoachExercise(context, legacy);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(resolved, same(_host));
    },
  );
}
