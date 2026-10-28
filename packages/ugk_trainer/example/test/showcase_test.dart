import 'dart:convert';
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
// SHOWCASE_LAYOUT_ONLY=1 exports widget geometry without replacing any PNGs.
// No system font is copied into the source tree or distributed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? captureFont;
  setUpAll(() async {
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final cupertinoIcons = FontLoader('packages/cupertino_icons/CupertinoIcons')
      ..addFont(
        rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
      );
    await cupertinoIcons.load();
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
        RepaintBoundary(
          key: const ValueKey('showcase-root-capture'),
          child: ShowcaseApp(
            key: UniqueKey(),
            initialState: state,
            initialTheme: mode,
            fontFamily: captureFont,
            onSaved: saved,
          ),
        ),
      );
    });
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (state == ShowcaseState.result) {
      await tester.pump(const Duration(milliseconds: 1200));
    }
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    tester.view.reset();
  }

  Map<String, Object?> layoutOf(
    WidgetTester tester,
    ShowcaseState state,
    ThemeMode mode,
  ) {
    final player = find.byKey(const ValueKey('showcase-player-capture'));
    final origin = tester.getTopLeft(player);
    final anchors = <String, Object?>{};
    void record(String name, Finder finder) {
      final count = finder.evaluate().length;
      expect(
        count,
        lessThanOrEqualTo(1),
        reason: 'Ambiguous layout anchor $name',
      );
      if (count == 0) {
        anchors[name] = null;
        return;
      }
      final rect = tester.getRect(finder).shift(-origin);
      anchors[name] = [rect.left, rect.top, rect.width, rect.height];
    }

    record('player', player);
    for (final key in const [
      'info-card',
      'close',
      'index',
      'progress',
      'top-hud',
      'discomfort',
      'pendant-slot',
      'subtitle-slot',
      'prev',
      'pause',
      'skip',
      'extend-rest',
      'complete-timed-phase',
      'sound-toggle',
      'done-card',
      'finish',
    ]) {
      record(key, find.byKey(ValueKey(key)));
    }
    record('figure', find.byType(DemoFigure));

    // Compare the countdown's allotted slot, not glyph metrics. A font weight
    // can legitimately change text width without moving the control's frame.
    final counter = find.byKey(const ValueKey('counter'));
    Finder counterSlot = find.byKey(const ValueKey('absent-counter-slot'));
    if (counter.evaluate().isNotEmpty) {
      Element? slot;
      counter.evaluate().single.visitAncestorElements((element) {
        final widget = element.widget;
        if (widget is SizedBox &&
            widget.height != null &&
            widget.child is Center) {
          slot = element;
          return false;
        }
        return true;
      });
      expect(
        slot,
        isNotNull,
        reason: 'Countdown layout slot must remain measurable',
      );
      counterSlot = find.byElementPredicate(
        (element) => identical(element, slot),
      );
    }
    record('counter-slot', counterSlot);

    for (final entry in const {
      'stat-minutes': '分钟',
      'stat-exercises': '完成动作',
    }.entries) {
      final label = find.descendant(
        of: player,
        matching: find.text(entry.value),
      );
      record(
        entry.key,
        find.ancestor(of: label, matching: find.byType(TrainerSurface)),
      );
    }
    return {
      'state': state.name,
      'theme': mode.name,
      'viewport': [430, 932],
      'capture_time_ms': state == ShowcaseState.result ? 2200 : 1000,
      'coordinate_space': 'logical pixels relative to player viewport',
      'rect_order': ['left', 'top', 'width', 'height'],
      'anchors': anchors,
    };
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
            final layout = layoutOf(tester, state, mode);
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('showcase-player-capture')),
            );
            await tester.runAsync(() async {
              await Directory(output).create(recursive: true);
              await File(
                '$output/layout-${state.name}-${mode.name}.json',
              ).writeAsString(
                const JsonEncoder.withIndent('  ').convert(layout),
              );
              if (Platform.environment['SHOWCASE_LAYOUT_ONLY'] == '1') return;
              final image = await boundary.toImage(pixelRatio: 2);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
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

  testWidgets('preview labels, cue sheet and start morph remain readable', (
    tester,
  ) async {
    final output = Platform.environment['SHOWCASE_CAPTURE_DIR'];
    Future<void> capture(String name, {bool root = false}) async {
      if (output == null || output.isEmpty) return;
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(
          ValueKey(root ? 'showcase-root-capture' : 'showcase-player-capture'),
        ),
      );
      await tester.runAsync(() async {
        await Directory(output).create(recursive: true);
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$output/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      await mount(tester, state: ShowcaseState.preview, mode: mode);
      final labels = tester.getRect(
        find.byKey(const ValueKey('preview-labels')),
      );
      final cues = tester.getRect(
        find.byKey(const ValueKey('trainer-cue-container')),
      );
      expect(labels.bottom, lessThan(cues.top));
      await tester.tap(find.byKey(const ValueKey('start-training')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      await capture('start-morph-${mode.name}');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('1/3'), findsOneWidget);
      await capture('preparation-${mode.name}');

      await mount(tester, mode: mode);
      await tester.drag(find.byType(TrainerCueCarousel), const Offset(-150, 0));
      await tester.pump(const Duration(milliseconds: 250));
      await capture('cue-manual-${mode.name}');
      await tester.tap(find.byType(TrainerCueCarousel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('怎么做'), findsOneWidget);
      expect(find.text('不强迫手触地'), findsOneWidget);
      await capture('cue-sheet-${mode.name}', root: true);
      expect(tester.takeException(), isNull);
    }
    await dispose(tester);
  });
}
