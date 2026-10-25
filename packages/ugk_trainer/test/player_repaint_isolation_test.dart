import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

/// Watches leaves inside boundaries: paintChild also visits a boundary when
/// only its cached layer is reused, so counting boundary visits gives false
/// positives. These CustomPaint/paragraph leaves are not repaint boundaries.
class _PaintCounts {
  final targets = <RenderObject, String>{};
  final values = <String, int>{};
  int media = 0;

  void watch(WidgetTester tester, Finder finder, String name) {
    expect(finder, findsWidgets, reason: 'The $name paint probe must exist.');
    values[name] = 0;
    for (final element in finder.evaluate()) {
      final object = element.findRenderObject()!;
      expect(object.isRepaintBoundary, isFalse);
      targets[object] = name;
    }
  }

  void painted(RenderObject object) {
    final name = targets[object];
    if (name != null) values[name] = values[name]! + 1;
  }

  void reset() {
    media = 0;
    values.updateAll((_, _) => 0);
  }

  Map<String, int> snapshot() => {'media': media, ...values};
}

class _MediaFramePainter extends CustomPainter {
  _MediaFramePainter(this.frame, this.counts) : super(repaint: frame);

  final ValueNotifier<int> frame;
  final _PaintCounts counts;

  @override
  void paint(Canvas canvas, Size size) {
    counts.media++;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = frame.value.isEven ? Colors.grey : Colors.blueGrey,
    );
  }

  @override
  bool shouldRepaint(_MediaFramePainter oldDelegate) => false;
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void _expectNoBackdropSampling(WidgetTester tester) {
  expect(find.byType(BackdropFilter), findsNothing);
  // A renderer can push a filter layer directly without a BackdropFilter
  // widget. Inspect the composited output as well as the widget tree.
  expect(tester.layers.whereType<BackdropFilterLayer>(), isEmpty);
}

void _expectLocalBackdropBounds(WidgetTester tester) {
  final viewport = tester.getSize(find.byType(Scaffold).first);
  // Native premium and software fallback may use different sampling paths.
  // Constrain whichever path is actually present; this does not assert that
  // the test renderer proves native refraction.
  for (final filter in find.byType(BackdropFilter).evaluate()) {
    final size = filter.size!;
    expect(size.width, lessThanOrEqualTo(viewport.width));
    expect(size.height, lessThan(viewport.height / 2));
  }
  for (final layer in tester.layers.whereType<BackdropFilterLayer>()) {
    Layer? ancestor = layer.parent;
    Rect? clip;
    while (ancestor != null && clip == null) {
      clip = ancestor.describeClipBounds();
      ancestor = ancestor.parent;
    }
    expect(clip, isNotNull, reason: 'A live glass pass needs a local clip.');
    expect(clip!.width, lessThanOrEqualTo(viewport.width));
    expect(clip.height, lessThan(viewport.height / 2));
  }
  for (final name in ['info-card', 'prev', 'skip']) {
    final size = tester.getSize(find.byKey(ValueKey(name)));
    expect(size.width, greaterThan(0));
    expect(size.width, lessThan(viewport.width));
    expect(size.height, lessThan(viewport.height / 2));
  }
}

void main() {
  for (final theme in [TrainerTheme.light, TrainerTheme.dark]) {
    for (final highContrast in [false, true]) {
      testWidgets(
        highContrast
            ? 'high-contrast HUD has no backdrop sampling: '
                  '${theme.brightness.name}'
            : 'live glass sampling stays within local controls: '
                  '${theme.brightness.name}',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          try {
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(brightness: theme.brightness),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(highContrast: highContrast),
                  child: child!,
                ),
                home: TrainerPlayer(
                  plan: planOf([timed('a', 60)]),
                  drillOf: (id) => TrainerDrill(
                    id: id,
                    name: 'Standing stretch',
                    cue: 'Keep breathing',
                  ),
                  theme: theme,
                  strings: TrainerStrings.en(),
                  prepSeconds: 0,
                  keepAlive: false,
                  tick: const Duration(seconds: 10),
                  mediaBuilder: (_, _) => const ColoredBox(color: Colors.grey),
                  onFinished: (_) async {},
                ),
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 600));
            expect(find.byKey(const ValueKey('info-card')), findsOneWidget);
            if (highContrast) {
              _expectNoBackdropSampling(tester);
            } else {
              _expectLocalBackdropBounds(tester);
            }

            await tester.tap(find.byKey(const ValueKey('pause')));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 600));
            if (highContrast) {
              _expectNoBackdropSampling(tester);
            } else {
              _expectLocalBackdropBounds(tester);
            }
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            tester.view.reset();
          }
        },
      );
    }
  }

  testWidgets('player isolates button, media and progress paints at 390px', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    final counts = _PaintCounts();
    final frame = ValueNotifier(0);
    final mediaPainter = _MediaFramePainter(frame, counts);
    final previousPaintCallback = debugOnProfilePaint;

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: TrainerPlayer(
            plan: planOf([timed('a', 60)]),
            drillOf: (id) => TrainerDrill(id: id, name: 'Standing stretch'),
            strings: TrainerStrings.en(),
            prepSeconds: 0,
            keepAlive: false,
            // Each observation is shorter than a tick: no concurrent clock
            // update should obscure which independently dirty layer painted.
            tick: const Duration(seconds: 10),
            mediaBuilder: (_, _) => CustomPaint(
              painter: mediaPainter,
              child: const SizedBox.expand(),
            ),
            onFinished: (_) async {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      _expectLocalBackdropBounds(tester);

      for (final entry in {
        'buttonDisc': 'button-color',
        'buttonGlyph': 'morph-icon',
        'ring': 'ring',
      }.entries) {
        counts.watch(tester, find.byKey(ValueKey(entry.value)), entry.key);
      }
      counts.watch(
        tester,
        find.descendant(
          of: find.byType(TrainerStageFloor),
          matching: find.byType(CustomPaint),
        ),
        'floor',
      );
      counts.watch(
        tester,
        find.descendant(
          of: find.byType(TrainerCountdownDigits),
          matching: find.byType(RichText),
        ),
        'countdown',
      );
      for (final name in ['prev', 'skip']) {
        counts.watch(
          tester,
          find.descendant(
            of: find.byKey(ValueKey(name)),
            // Observe the icon's paragraph, independent of whether its
            // surrounding material uses a painter or a library renderer.
            matching: find.byType(RichText),
          ),
          name,
        );
      }
      debugOnProfilePaint = (object) {
        previousPaintCallback?.call(object);
        counts.painted(object);
      };

      // Positive control: every observed leaf must reach the real paint path.
      // This prevents a missing hook from making all isolation assertions pass.
      for (final object in counts.targets.keys) {
        object.markNeedsPaint();
      }
      frame.value++;
      await tester.pump();
      for (final entry in counts.snapshot().entries) {
        expect(entry.value, greaterThan(0), reason: '${entry.key} paint probe');
      }

      final pause = find.byKey(const ValueKey('pause'));
      await tester.tap(pause);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(tester.widget<UgkPlayPauseButton>(pause).isPlaying, isFalse);
      counts.reset();
      // The normal paused breath is intentionally active; do not settle it.
      await _frames(tester);
      final breathing = counts.snapshot();

      await tester.tap(pause);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(tester.widget<UgkPlayPauseButton>(pause).isPlaying, isTrue);
      counts.reset();
      for (var i = 0; i < 6; i++) {
        frame.value++;
        await tester.pump(const Duration(milliseconds: 16));
      }
      final mediaFrames = counts.snapshot();

      final progress = tester.widget<UgkPlayPauseButton>(pause).progress;
      expect(progress, isA<ValueNotifier<double>>());
      final progressNotifier = progress as ValueNotifier<double>;
      counts.reset();
      for (var i = 1; i <= 6; i++) {
        progressNotifier.value = i / 10;
        await tester.pump(const Duration(milliseconds: 16));
      }
      final progressFrames = counts.snapshot();

      // Keep the complete baseline evidence even when an assertion fails.
      debugPrint('repaint isolation: button breath $breathing');
      debugPrint('repaint isolation: media frames $mediaFrames');
      debugPrint('repaint isolation: ring progress $progressFrames');
      expect(breathing['buttonGlyph'], greaterThan(0));
      for (final name in ['media', 'floor', 'countdown', 'prev', 'skip']) {
        expect(breathing[name], 0, reason: 'Button breath repainted $name.');
      }
      expect(mediaFrames['media'], 6);
      for (final name in counts.values.keys) {
        expect(mediaFrames[name], 0, reason: 'Media frames repainted $name.');
      }
      expect(progressFrames['ring'], 6);
      for (final name in [
        'media',
        'buttonDisc',
        'buttonGlyph',
        'floor',
        'countdown',
        'prev',
        'skip',
      ]) {
        expect(
          progressFrames[name],
          0,
          reason: 'Ring progress repainted $name.',
        );
      }
      expect(tester.takeException(), isNull);
    } finally {
      // Restore debug globals before the test body's invariant checks.
      debugOnProfilePaint = previousPaintCallback;
      await tester.pumpWidget(const SizedBox.shrink());
      frame.dispose();
      tester.view.reset();
    }
  });
}
