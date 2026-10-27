import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

Future<Uint8List> _paintFloor(
  WidgetTester tester,
  TrainerTheme theme, {
  TrainerFloorGeometry geometry = const TrainerFloorGeometry(),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SizedBox(
        width: 400,
        height: 500,
        child: TrainerStageFloor(
          theme: theme,
          clipSize: 300,
          clipLeft: 50,
          geometry: geometry,
        ),
      ),
    ),
  );
  final paint = tester.widget<CustomPaint>(
    find.descendant(
      of: find.byType(TrainerStageFloor),
      matching: find.byType(CustomPaint),
    ),
  );
  final recorder = ui.PictureRecorder();
  paint.painter!.paint(Canvas(recorder), const Size(400, 500));
  final picture = recorder.endRecording();
  final pixels = await tester.runAsync(() async {
    final image = await picture.toImage(400, 500);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    picture.dispose();
    return bytes!.buffer.asUint8List();
  });
  return pixels!;
}

int _changedPixels(Uint8List rgba, int y, Color background) {
  var changed = 0;
  for (var x = 60; x < 340; x++) {
    final i = (y * 400 + x) * 4;
    if (rgba[i] != (background.r * 255).round() ||
        rgba[i + 1] != (background.g * 255).round() ||
        rgba[i + 2] != (background.b * 255).round()) {
      changed++;
    }
  }
  return changed;
}

void main() {
  for (final theme in [TrainerTheme.light, TrainerTheme.dark]) {
    testWidgets('floor grid fades behind media in ${theme.brightness.name}', (
      tester,
    ) async {
      final pixels = await _paintFloor(tester, theme);
      // Entire rows above the default horizon remain the flat stage color.
      expect(_changedPixels(pixels, 170, theme.mediaStage), 0);
      // The rays fade in below the horizon instead of meeting in a bright tip.
      expect(_changedPixels(pixels, 180, theme.mediaStage), 0);
      // The ground anchor spans the image, unlike individual perspective rays.
      expect(_changedPixels(pixels, 243, theme.mediaStage), greaterThan(150));
      expect(_changedPixels(pixels, 238, theme.mediaStage), lessThan(70));
    });

    testWidgets(
      'real PoseHub still reveals floor in ${theme.brightness.name}',
      (tester) async {
        final catalog = PoseHubAppTestCatalog.fromBytes(
          File(
            'assets/pose_hub/app-test-pack-r1/catalog.json',
          ).readAsBytesSync(),
        );
        final action = catalog.allActions.first;
        await tester.pumpWidget(
          MaterialApp(
            home: TrainerPlayer(
              plan: planOf([timed(action.id, 60)]),
              drillOf: (id) => TrainerDrill(id: id, name: id),
              strings: TrainerStrings.zh(),
              poseHubCatalog: catalog,
              keepAlive: false,
              prepSeconds: 0,
              theme: theme,
              onFinished: (_) async {},
            ),
          ),
        );
        await tester.pump();
        expect(find.byType(TrainerStageFloor), findsOneWidget);
        expect(find.byType(PoseHubStandingImage), findsOneWidget);
        final cover = tester.widget<ColoredBox>(
          find.byKey(const ValueKey('pose-hub-pack-cover')),
        );
        expect(cover.color, Colors.transparent);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('light floor remains visible at the contact plane', (
    tester,
  ) async {
    final pixels = await _paintFloor(tester, TrainerTheme.light);
    final redAtGround = pixels[(243 * 400 + 200) * 4];
    final backgroundRed = (TrainerTheme.light.mediaStage.r * 255).round();
    expect(backgroundRed - redAtGround, greaterThan(10));
  });

  testWidgets('calibrated contact line changes grid position', (tester) async {
    final pixels = await _paintFloor(
      tester,
      TrainerTheme.light,
      geometry: const TrainerFloorGeometry(horizon: .60, ground: .80),
    );
    expect(
      _changedPixels(pixels, 240, TrainerTheme.light.mediaStage),
      greaterThan(150),
    );
    expect(
      _changedPixels(pixels, 270, TrainerTheme.light.mediaStage),
      lessThan(70),
    );
  });
}
