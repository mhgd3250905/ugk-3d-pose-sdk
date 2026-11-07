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
  poster: 'old-standing.webp',
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
    const root = '../ugk_trainer/assets/pose_hub/app-pack-r2-v7/';
    final catalog = coach.PoseHubAppTestCatalog.fromBytes(
      await File('${root}catalog.json').readAsBytes(),
      semanticCatalogBytes: await File(
        '${root}catalog/catalog.json',
      ).readAsBytes(),
    );
    action = catalog.semanticCompleteActions.first;
    drill = catalog.toAiCatalog()[action.id]!;
  });

  testWidgets('current catalogue artwork replaces host asset selection only', (
    tester,
  ) async {
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
