import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/src/ui/ugk_play_pause_button.dart';
import 'package:ugk_trainer/ugk_trainer.dart'
    show TrainerRingPainter, TrainerStrings, TrainerTheme;

class _Fixture {
  _Fixture({
    required bool isPlaying,
    this.confirmTaps = true,
    this.reduced = false,
    this.theme = TrainerTheme.light,
    TrainerStrings? strings,
  }) : playing = ValueNotifier(isPlaying),
       strings = strings ?? TrainerStrings.en();

  final ValueNotifier<bool> playing;
  final progress = ValueNotifier<double>(.35);
  final bool confirmTaps;
  final bool reduced;
  TrainerTheme theme;
  TrainerStrings strings;
  int taps = 0;

  Future<void> show(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: Scaffold(
          body: Center(
            child: ValueListenableBuilder<bool>(
              valueListenable: playing,
              builder: (_, actual, _) => UgkPlayPauseButton(
                key: const ValueKey('subject'),
                isPlaying: actual,
                progress: progress,
                theme: theme,
                strings: strings,
                onTap: () {
                  taps++;
                  if (confirmTaps) playing.value = !playing.value;
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );

  void dispose() {
    playing.dispose();
    progress.dispose();
  }
}

Future<_Fixture> _mount(
  WidgetTester tester, {
  bool isPlaying = false,
  bool confirmTaps = true,
  bool reduced = false,
  TrainerTheme theme = TrainerTheme.light,
  TrainerStrings? strings,
}) async {
  final fixture = _Fixture(
    isPlaying: isPlaying,
    confirmTaps: confirmTaps,
    reduced: reduced,
    theme: theme,
    strings: strings,
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    fixture.dispose();
  });
  await fixture.show(tester);
  return fixture;
}

Finder get _button => find.byKey(const ValueKey('subject'));

CustomPainter _painter(WidgetTester tester, String key) =>
    tester.widget<CustomPaint>(find.byKey(ValueKey(key))).painter!;

double _morph(WidgetTester tester) {
  // Observe the private painter rather than adding test API to the widget.
  // ignore: avoid_dynamic_calls
  return (_painter(tester, 'morph-icon') as dynamic).morph as double;
}

double _scale(WidgetTester tester, String key) =>
    tester.widget<Transform>(find.byKey(ValueKey(key))).transform.entry(0, 0);

double _ringOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find.ancestor(
        of: find.byKey(const ValueKey('ring')),
        matching: find.byType(Opacity),
      ),
    )
    .opacity;

Future<List<int>> _paintPixels(
  WidgetTester tester,
  CustomPainter painter,
  double size,
) async => (await tester.runAsync(() async {
  // Supersample the ordinary-size icon so a one-pixel antialias fringe does
  // not obscure the pause gap when testing crossfade alpha.
  const ratio = 4;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(ratio.toDouble());
  painter.paint(canvas, Size.square(size));
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (size * ratio).round(),
    (size * ratio).round(),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final pixels = List<int>.of(bytes!.buffer.asUint8List());
  image.dispose();
  picture.dispose();
  return pixels;
}))!;

Future<int> _glyphCentreAlpha(WidgetTester tester) async {
  final pixels = await _paintPixels(tester, _painter(tester, 'morph-icon'), 38);
  const width = 38 * 4;
  return pixels[((width ~/ 2) * width + width ~/ 2) * 4 + 3];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final haptics = <String>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    haptics.clear();
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments as String);
      }
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('rapid reversals keep the current morph and colour composite', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    await tester.tap(_button);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    expect(_morph(tester), inExclusiveRange(0, 1));
    final beforeColor = await _paintPixels(
      tester,
      _painter(tester, 'button-color'),
      76,
    );
    for (var i = 0; i < 4; i++) {
      final before = _morph(tester);
      await tester.tap(_button);
      await tester.pump();
      expect(_morph(tester), closeTo(before, .00001));
      if (i == 0) {
        expect(
          await _paintPixels(tester, _painter(tester, 'button-color'), 76),
          orderedEquals(beforeColor),
          reason: 'Changing direction must keep the current colour reveal',
        );
      }
      await tester.pump(const Duration(milliseconds: 40));
      expect(
        _morph(tester),
        fixture.playing.value ? greaterThan(before) : lessThan(before),
      );
    }
    expect(fixture.taps, 5);
    expect(haptics, List.filled(5, 'HapticFeedbackType.lightImpact'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('paused breath stays live and playing settles to a full ring', (
    tester,
  ) async {
    final fixture = await _mount(tester, theme: TrainerTheme.dark);
    expect(_ringOpacity(tester), .5);
    expect(_scale(tester, 'button-breath'), 1);
    await tester.pump(const Duration(milliseconds: 600));
    expect(_scale(tester, 'button-breath'), inExclusiveRange(1, 1.031));
    expect(tester.hasRunningAnimations, isTrue);
    fixture.playing.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_scale(tester, 'button-breath'), 1);
    expect(_ringOpacity(tester), 1);
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.byKey(const ValueKey('button-ripple')), findsNothing);
    expect(fixture.taps, 0);
    expect(haptics, isEmpty);
  });

  testWidgets(
    'reduced motion crossfades in 150ms without press, ripple or breath',
    (tester) async {
      final fixture = await _mount(tester, reduced: true);
      await tester.pump(const Duration(milliseconds: 600));
      expect(_scale(tester, 'button-breath'), 1);
      expect(tester.hasRunningAnimations, isFalse);
      expect(await _glyphCentreAlpha(tester), 255);
      final pointer = await tester.startGesture(tester.getCenter(_button));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      expect(_scale(tester, 'button-press'), 1);
      await pointer.up();
      await tester.pump();
      expect(find.byKey(const ValueKey('button-ripple')), findsNothing);
      await tester.pump(const Duration(milliseconds: 75));
      expect(_morph(tester), closeTo(.5, .001));
      expect(await _glyphCentreAlpha(tester), closeTo(128, 2));
      await tester.pump(const Duration(milliseconds: 75));
      expect(_morph(tester), 1);
      expect(await _glyphCentreAlpha(tester), 0);
      await tester.pumpAndSettle();
      expect(_scale(tester, 'button-breath'), 1);
      expect(_scale(tester, 'button-press'), 1);
      expect(tester.hasRunningAnimations, isFalse);
      expect(fixture.taps, 1);
      expect(haptics, ['HapticFeedbackType.lightImpact']);
    },
  );

  testWidgets(
    'external playback changes animate without interaction feedback',
    (tester) async {
      final fixture = await _mount(tester, isPlaying: true);
      fixture.playing.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final before = _morph(tester);
      expect(before, inExclusiveRange(0, 1));
      fixture.playing.value = true;
      await tester.pump();
      expect(_morph(tester), closeTo(before, .00001));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_morph(tester), 1);
      expect(find.byKey(const ValueKey('button-ripple')), findsNothing);
      expect(_scale(tester, 'button-press'), 1);
      expect(fixture.taps, 0);
      expect(haptics, isEmpty);
    },
  );

  testWidgets(
    'unconfirmed optimistic changes reconcile on rebuild or bounded wait',
    (tester) async {
      final fixture = await _mount(tester, isPlaying: true, confirmTaps: false);
      await tester.tap(_button);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 140));
      final before = _morph(tester);
      expect(before, lessThan(1));
      await fixture.show(
        tester,
      ); // The host rejects the pause with its true state.
      expect(_morph(tester), closeTo(before, .00001));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_morph(tester), 1);
      await tester.tap(_button);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(_morph(tester), lessThan(1));
      // No host rebuild follows this request; the 320ms confirmation window
      // still prevents an optimistic pause from becoming a second truth source.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_morph(tester), 1);
      expect(fixture.playing.value, isTrue);
      expect(fixture.taps, 2);
      expect(haptics, List.filled(2, 'HapticFeedbackType.lightImpact'));
    },
  );

  testWidgets(
    'ordinary-size light and dark controls retain injected progress tokens',
    (tester) async {
      for (final theme in [TrainerTheme.light, TrainerTheme.dark]) {
        final fixture = await _mount(tester, isPlaying: true, theme: theme);
        expect(tester.getSize(_button), const Size(96, 96));
        expect(
          tester.getSize(find.byKey(const ValueKey('button-color'))),
          const Size(76, 76),
        );
        expect(
          tester.getSize(find.byKey(const ValueKey('morph-icon'))),
          const Size(38, 38),
        );
        final ring = _painter(tester, 'ring') as TrainerRingPainter;
        expect(ring.progress, same(fixture.progress));
        expect(ring.color, theme.accent);
        expect(ring.track, theme.isDark ? theme.surfaceHigh : theme.track);
        expect(ring.glowOpacity, 1);
        expect(ring.glowBlur, 4);
        fixture.progress.value = .8;
        await tester.pump();
        expect(
          (_painter(tester, 'ring') as TrainerRingPainter).progress.value,
          .8,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'localized button semantics follow actual playback, not optimism',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final fixture = await _mount(
          tester,
          isPlaying: true,
          confirmTaps: false,
        );
        expect(find.bySemanticsLabel('Pause'), findsOneWidget);
        final data = tester
            .getSemantics(find.bySemanticsLabel('Pause'))
            .getSemanticsData();
        expect(data.flagsCollection.isButton, isTrue);
        expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
        await tester.tap(_button);
        await tester.pump(const Duration(milliseconds: 90));
        expect(fixture.taps, 1);
        expect(find.bySemanticsLabel('Pause'), findsOneWidget);
        fixture.playing.value = false;
        await tester.pump();
        expect(find.bySemanticsLabel('Resume'), findsOneWidget);
        fixture.strings = TrainerStrings.zh();
        await fixture.show(tester);
        expect(find.bySemanticsLabel(fixture.strings.resume), findsOneWidget);
        fixture.playing.value = true;
        await tester.pump();
        expect(find.bySemanticsLabel(fixture.strings.pause), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'dragging a press out of bounds cancels without callback or haptic',
    (tester) async {
      final fixture = await _mount(tester, isPlaying: true);
      final rect = tester.getRect(_button);
      final pointer = await tester.startGesture(rect.center);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      expect(_scale(tester, 'button-press'), closeTo(.92, .001));
      expect(fixture.taps, 0);
      expect(haptics, isEmpty);
      expect(find.byKey(const ValueKey('button-ripple')), findsNothing);
      await pointer.moveTo(Offset(rect.right + 24, rect.center.dy));
      await tester.pump(const Duration(milliseconds: 30));
      await pointer.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(fixture.taps, 0);
      expect(haptics, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
