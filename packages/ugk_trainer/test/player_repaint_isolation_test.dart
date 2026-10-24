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

void main() {
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
      expect(find.byType(BackdropFilter), findsNothing);

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
            matching: find.byType(CustomPaint),
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
