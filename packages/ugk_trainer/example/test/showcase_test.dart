import 'dart:io';
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/ugk_trainer.dart';
import 'package:ugk_trainer_showcase/main.dart';

// Optional local-only capture: SHOWCASE_CAPTURE_DIR and SHOWCASE_FONT (TTF/TTC).
// No system font is copied into the source tree or distributed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? captureFont;
  setUpAll(() async {
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final path = Platform.environment['SHOWCASE_FONT'];
    if (path != null && path.isNotEmpty) {
      final bytes = await File(path).readAsBytes();
      final font = FontLoader('ShowcaseCapture')
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await font.load();
      captureFont = 'ShowcaseCapture';
    }
  });
  Future<void> mount(
    WidgetTester tester, {
    ShowcaseState state = ShowcaseState.training,
    ThemeMode mode = ThemeMode.light,
    ValueChanged<SessionResult>? saved,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 932);
    await withClock(Clock(tester.binding.clock.now), () async {
      await tester.pumpWidget(
        ShowcaseApp(
          key: UniqueKey(),
          initialState: state,
          initialTheme: mode,
          fontFamily: captureFont,
          onSaved: saved,
        ),
      );
    });
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    tester.view.reset();
  }

  testWidgets('four fixtures use real player and result callback', (
    tester,
  ) async {
    final results = <SessionResult>[];
    for (final state in ShowcaseState.values) {
      await mount(tester, state: state, saved: results.add);
      expect(find.byType(TrainerPlayer), findsOneWidget);
      expect(tester.takeException(), isNull, reason: state.name);
      if (state == ShowcaseState.result) {
        expect(find.byKey(const ValueKey('finish')), findsOneWidget);
        expect(results.last.sessionId, 'showcase-result-0');
        expect(results.last.full, isTrue);
      } else {
        expect(find.byType(DemoFigure), findsOneWidget);
      }
    }
    await dispose(tester);
  });
  testWidgets('theme switch preserves active player and pause state', (
    tester,
  ) async {
    await mount(tester);
    final playerState = tester.state(find.byType(TrainerPlayer));
    await tester.tap(find.byKey(const ValueKey('pause')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('showcase-theme')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<ThemeMode>, '深色'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      identical(tester.state(find.byType(TrainerPlayer)), playerState),
      true,
    );
    expect(
      tester.widget<TrainerPlayer>(find.byType(TrainerPlayer)).theme.isDark,
      true,
    );
    expect(
      tester
          .widget<UgkPlayPauseButton>(find.byKey(const ValueKey('pause')))
          .isPlaying,
      false,
    );
    expect(tester.takeException(), isNull);
    await dispose(tester);
  });
  testWidgets('system brightness follows only while system mode is selected', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await mount(tester, mode: ThemeMode.system);
    final playerState = tester.state(find.byType(TrainerPlayer));
    expect(
      tester.widget<TrainerPlayer>(find.byType(TrainerPlayer)).theme.isDark,
      false,
    );
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      tester.widget<TrainerPlayer>(find.byType(TrainerPlayer)).theme.isDark,
      true,
    );
    await tester.tap(find.byKey(const ValueKey('showcase-theme')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<ThemeMode>, '浅色'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      tester.widget<TrainerPlayer>(find.byType(TrainerPlayer)).theme.isDark,
      false,
    );
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pump();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    expect(
      tester.widget<TrainerPlayer>(find.byType(TrainerPlayer)).theme.isDark,
      false,
    );
    expect(
      identical(tester.state(find.byType(TrainerPlayer)), playerState),
      true,
    );
    expect(tester.takeException(), isNull);
    await dispose(tester);
  });
  testWidgets('capture four states in matched light and dark viewports', (
    tester,
  ) async {
    final oldShadows = debugDisableShadows;
    debugDisableShadows = false;
    final output = Platform.environment['SHOWCASE_CAPTURE_DIR'];
    try {
      for (final state in ShowcaseState.values) {
        for (final mode in [ThemeMode.light, ThemeMode.dark]) {
          await mount(tester, state: state, mode: mode);
          expect(
            tester.takeException(),
            isNull,
            reason: '${state.name}/${mode.name}',
          );
          if (output != null && output.isNotEmpty) {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('showcase-player-capture')),
            );
            await tester.runAsync(() async {
              final image = await boundary.toImage(pixelRatio: 2);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await Directory(output).create(recursive: true);
              await File(
                '$output/${state.name}-${mode.name}.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
        }
      }
    } finally {
      debugDisableShadows = oldShadows;
    }
    await dispose(tester);
  });
}
