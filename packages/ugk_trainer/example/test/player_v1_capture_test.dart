import 'dart:io';
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/ugk_trainer.dart';
import 'package:ugk_trainer_showcase/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final output = Platform.environment['SHOWCASE_CAPTURE_DIR'];
  final captureFiles = Platform.environment['SHOWCASE_CAPTURE_FILES']
      ?.split(',')
      .map((name) => name.trim())
      .toSet();
  String? fontFamily;
  setUpAll(() async {
    if (output == null || output.isEmpty) return;
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
          rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
        ))
        .load();
    final fontPath = Platform.environment['SHOWCASE_FONT'];
    if (fontPath != null && fontPath.isNotEmpty) {
      final bytes = await File(fontPath).readAsBytes();
      await (FontLoader(
        'PlayerV1Capture',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      fontFamily = 'PlayerV1Capture';
    }
  });

  Future<void> capture(WidgetTester tester, String name) async {
    if (output == null ||
        output.isEmpty ||
        (captureFiles != null && !captureFiles.contains(name))) {
      return;
    }
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('showcase-player-capture')),
    );
    expect(boundary.size, const Size(360, 800));
    await tester.runAsync(() async {
      await Directory(output).create(recursive: true);
      final image = await boundary.toImage(pixelRatio: 3);
      try {
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$output/$name.png').writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      } finally {
        image.dispose();
      }
    });
  }

  void expectCuePages(WidgetTester tester, int count) {
    final cue = find.byKey(const ValueKey('trainer-cue-container'));
    final pill = find.byKey(const ValueKey('trainer-cue-step-pill'));
    final label = find.byKey(const ValueKey('trainer-cue-count'));
    final firstDot = find.byKey(const ValueKey('trainer-cue-dot-0'));
    final secondDot = find.byKey(const ValueKey('trainer-cue-dot-1'));
    expect(tester.getSize(cue).height, greaterThanOrEqualTo(64));
    expect(firstDot, findsNothing);
    expect(secondDot, findsNothing);
    if (count == 1) {
      final text = find.byKey(const ValueKey('trainer-cue-text'));
      expect(pill, findsNothing);
      expect(label, findsNothing);
      expect(tester.getCenter(text).dx, closeTo(tester.getCenter(cue).dx, .01));
      expect(tester.getCenter(text).dy, closeTo(tester.getCenter(cue).dy, .01));
    } else {
      expect(tester.getSize(pill).height, 22);
      expect(tester.widget<Text>(label).data, '1/$count');
    }
  }

  for (final (name, mode) in [
    ('hip', ThemeMode.light),
    ('flare', ThemeMode.dark),
  ]) {
    testWidgets('$name Player V1 renders work, rest and saved completion', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(tester.view.reset);
      final previousShadows = debugDisableShadows;
      debugDisableShadows = false;
      try {
        final warmupKey = GlobalKey();
        await tester.pumpWidget(MaterialApp(home: Scaffold(key: warmupKey)));
        final warmed = await tester.runAsync(
          () => Future.wait([
            for (final asset in playerV1PosterAssets.values)
              TrainingPosterImages.prepareAsset(
                warmupKey.currentContext!,
                asset,
                timeout: const Duration(seconds: 3),
              ),
          ]),
        );
        expect(warmed, everyElement(isTrue));
        await tester.runAsync(() async {
          for (final asset in playerV1PosterAssets.values) {
            await precacheImage(AssetImage(asset), warmupKey.currentContext!);
          }
        });

        for (final (file, state, elapsed) in [
          ('work', ShowcaseState.training, const Duration(seconds: 1)),
          ('rest', ShowcaseState.rest, const Duration(seconds: 1)),
          ('done', ShowcaseState.result, const Duration(seconds: 6)),
        ]) {
          final results = <SessionResult>[];
          await withClock(Clock(tester.binding.clock.now), () async {
            await tester.pumpWidget(
              ShowcaseApp(
                key: ValueKey('$name-$file'),
                initialState: state,
                initialTheme: mode,
                playerV1: true,
                showControls: false,
                fontFamily: fontFamily,
                onSaved: results.add,
              ),
            );
            for (var ms = 0; ms < elapsed.inMilliseconds; ms += 100) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            await tester.pump();
          });

          final player = tester.widget<TrainerPlayer>(
            find.byType(TrainerPlayer),
          );
          expect(player.theme.usePlayerV1, isTrue);
          expect(player.theme.isDark, mode == ThemeMode.dark);
          if (state == ShowcaseState.result) {
            expect(
              find.byKey(const ValueKey('finish')).hitTestable(),
              findsOneWidget,
            );
            expect(results.single.full, isTrue);
            expect(find.text('本次展示记录已保存'), findsOneWidget);
            final hero = tester.widget<DecoratedBox>(
              find.byKey(const ValueKey('completion-hero')),
            );
            final gradient = (hero.decoration as BoxDecoration).gradient!;
            final dark = mode == ThemeMode.dark;
            expect(
              gradient.colors,
              dark
                  ? [const Color(0xFF2A1810), const Color(0xFF7A2C0E)]
                  : [const Color(0xFF0A5341), const Color(0xFF0E6F56)],
            );
            final feeling = find.byKey(
              const ValueKey('completion-feeling-justRight'),
            );
            final check = find.descendant(
              of: feeling,
              matching: find.byIcon(Icons.check_rounded),
            );
            expect(check, findsNothing);
            await tester.tap(feeling);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 250));
            expect(tester.getSize(check), const Size(14, 14));
            final button = tester.widget<TextButton>(
              find.descendant(of: feeling, matching: find.byType(TextButton)),
            );
            expect(
              button.style!.foregroundColor!.resolve({}),
              dark ? const Color(0xFF111214) : Colors.white,
            );
          } else {
            final close = find.byKey(const ValueKey('close'));
            final track = find.byKey(const ValueKey('progress'));
            final pause = find.byKey(const ValueKey('pause'));
            final dock = find.byKey(const ValueKey('player-v1-dock'));
            final rest = state == ShowcaseState.rest;
            expect(pause, findsOneWidget);
            expect(tester.getRect(track).height, 4);
            expect(tester.getRect(dock).bottom, 800);
            expect(tester.getRect(dock).height, rest ? 300 : 172);
            expect(
              tester.getRect(close).bottom,
              lessThan(tester.getTopLeft(track).dy),
            );
            expect(
              tester.getRect(track).bottom,
              lessThan(tester.getTopLeft(dock).dy),
            );
            expect(
              tester.getRect(dock).contains(tester.getCenter(pause)),
              isTrue,
            );
            final poster = find.descendant(
              of: find.byType(TrainerPoster),
              matching: find.byType(RawImage),
            );
            expect(
              poster,
              findsOneWidget,
              reason: 'Decoded bundled $file pose',
            );
            expect(tester.widget<RawImage>(poster).image, isNotNull);
            expect(find.text('刚才感觉怎么样？'), rest ? findsOneWidget : findsNothing);
          }
          expect(tester.takeException(), isNull, reason: '$name $file');

          await capture(tester, '$name-$file');
          if (state == ShowcaseState.training) {
            expectCuePages(tester, 2);
            if (mode == ThemeMode.light) {
              await capture(tester, 'training-multi-cue');
            }
          }
          if (state == ShowcaseState.rest) {
            final choice = mode == ThemeMode.light
                ? TrainerRestFeedbackChoice.comfortable
                : TrainerRestFeedbackChoice.tight;
            final button = find.byKey(
              ValueKey('player-v1-rest-${choice.name}'),
            );
            final panel = find.byType(TrainerRestFeedbackPanel);
            final check = find.descendant(
              of: button,
              matching: find.byIcon(Icons.check_rounded),
            );
            expect(
              tester.widget<TrainerRestFeedbackPanel>(panel).selected,
              isNull,
            );
            expect(check, findsNothing);
            await tester.tap(button);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 250));
            expect(
              tester.widget<TrainerRestFeedbackPanel>(panel).selected,
              choice,
            );
            expect(tester.getSize(check), const Size(14, 14));
            expect(find.text('已记录'), findsOneWidget);
            await capture(tester, 'rest-${mode.name}-selected');

            if (mode == ThemeMode.light) {
              await tester.tap(find.byKey(const ValueKey('skip')));
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 500));
              await tester.pump();
              expect(panel, findsNothing);
              expectCuePages(tester, 1);
              expect(find.text('放松肩颈，保持均匀呼吸'), findsOneWidget);
              expect(tester.takeException(), isNull);
              await capture(tester, 'training-single-cue');
            }
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          expect(results, hasLength(1));
          expect(results.single.full, state == ShowcaseState.result);
        }
      } finally {
        debugDisableShadows = previousShadows;
      }
    });
  }
}
