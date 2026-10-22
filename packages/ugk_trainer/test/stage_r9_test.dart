// sdk-stage-r9 regressions from the PR #6 review:
// - a self-paced set keeps its target visible next to 完成本组 (work, paused,
//   next set; host doseLabel respected);
// - large system text never overflows the top card or clips the countdown
//   number (1 / 1.5 / 2×, portrait and landscape);
// - glass buttons are reachable with Tab and activate with Enter / Space.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

Widget _player(
  TrainingPlan plan, {
  double scale = 1,
  TrainerStrings? strings,
  String? Function(SessionPhase)? doseLabel,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: TrainerPlayer(
    plan: plan,
    drillOf: (id) => TrainerDrill(id: id, name: 'name-$id', cue: 'cue-$id'),
    strings: strings ?? TrainerStrings.zh(),
    keepAlive: false,
    prepSeconds: 0,
    doseLabel: doseLabel,
    mediaBuilder: (_, _) => const SizedBox.expand(),
    onFinished: (_) async {},
  ),
);

Future<void> _until(WidgetTester tester, Finder f) async {
  for (var i = 0; i < 400 && f.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(f, findsOneWidget);
}

void _phone(WidgetTester tester, double w, double h) {
  tester.view.physicalSize = Size(w, h);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  final done = find.byKey(const ValueKey('complete-set-button'));

  group('self-paced target', () {
    testWidgets('target reps stay visible with 完成本组: work, paused, next '
        'set', (tester) async {
      _phone(tester, 390, 844);
      await tester.pumpWidget(
        _player(planOf([reps('a', 8, sets: 2, rest: 3)])),
      );
      await _until(tester, done);
      await tester.pump(const Duration(seconds: 1));
      expect(done, findsOneWidget);
      expect(find.textContaining('8 次'), findsWidgets);

      // Paused: still visible.
      await tester.tap(find.byKey(const ValueKey('pause')));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining('8 次'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('pause')));
      await tester.pump(const Duration(milliseconds: 600));

      // Next set: 完成本组 again, target again.
      await tester.tap(done);
      await tester.pump(const Duration(milliseconds: 100));
      await _until(tester, done);
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('8 次'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('host doseLabel is the target shown next to 完成本组', (
      tester,
    ) async {
      _phone(tester, 390, 844);
      await tester.pumpWidget(
        _player(
          planOf([reps('a', 8)]),
          doseLabel: (p) => p.isWork ? '8 次 · 慢放' : null,
        ),
      );
      await _until(tester, done);
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('8 次 · 慢放'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('large text', () {
    for (final scale in [1.0, 1.5, 2.0]) {
      for (final (w, h) in [(390.0, 844.0), (844.0, 390.0)]) {
        final tag = '${scale}x ${w.toInt()}x${h.toInt()}';
        testWidgets('timed set: no overflow, countdown not clipped $tag', (
          tester,
        ) async {
          _phone(tester, w, h);
          await tester.pumpWidget(
            _player(planOf([timed('a', 30)]), scale: scale),
          );
          final number = find.byKey(const ValueKey('counter'));
          await _until(tester, find.byKey(const ValueKey('media-a')));
          await tester.pump(const Duration(seconds: 2));
          expect(tester.takeException(), isNull);

          // Name and muted line sit inside the card.
          final card = tester.getRect(find.byKey(const ValueKey('info-card')));
          for (final t in [
            find.text('name-a'),
            find.byKey(const ValueKey('index')),
          ]) {
            final r = tester.getRect(t);
            expect(r.top, greaterThanOrEqualTo(card.top - .5), reason: '$t');
            expect(r.bottom, lessThanOrEqualTo(card.bottom + .5), reason: '$t');
          }
          // The countdown number fits whole above the pause button: its
          // painted box is not cut by a smaller slot (no clip parent) and
          // it stays legible (not scaled below its 1× size).
          final n = tester.getRect(number);
          final pause = tester.getRect(find.byKey(const ValueKey('pause')));
          expect(n.bottom, lessThanOrEqualTo(pause.top));
          expect(n.height, greaterThanOrEqualTo(32 * scale * .95));
          expect(
            find.ancestor(of: number, matching: find.byType(ClipRect)),
            findsNothing,
          );
          await tester.pumpWidget(const SizedBox.shrink());
        });

        testWidgets('self-paced set: no overflow, 完成本组 whole $tag', (
          tester,
        ) async {
          _phone(tester, w, h);
          await tester.pumpWidget(
            _player(planOf([reps('a', 8)]), scale: scale),
          );
          await _until(tester, done);
          await tester.pump(const Duration(seconds: 1));
          expect(tester.takeException(), isNull);
          final b = tester.getRect(done);
          final pause = tester.getRect(find.byKey(const ValueKey('pause')));
          expect(b.height, greaterThanOrEqualTo(44));
          expect(b.bottom, lessThanOrEqualTo(pause.top));
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  });

  group('keyboard', () {
    testWidgets('glass button: Tab focuses it, Enter / Space activate, focus '
        'ring shows', (tester) async {
      var glass = 0;
      var other = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TrainerGlassButton(
                  theme: TrainerTheme.light,
                  icon: const Icon(Icons.close),
                  tooltip: 'close',
                  onPressed: () => glass++,
                ),
                TextButton(onPressed: () => other++, child: const Text('x')),
              ],
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(find.byKey(const ValueKey('glass-button-focus')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect((glass, other), (1, 0));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect((glass, other), (2, 0));
      // Tab moves on to the next control.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(find.byKey(const ValueKey('glass-button-focus')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect((glass, other), (2, 1));
    });

    testWidgets('disabled glass button is skipped by Tab', (tester) async {
      var other = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TrainerGlassButton(
                  theme: TrainerTheme.light,
                  icon: const Icon(Icons.close),
                  tooltip: 'close',
                  onPressed: null,
                ),
                TextButton(onPressed: () => other++, child: const Text('x')),
              ],
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(other, 1);
    });

    testWidgets('player: Tab reaches pause, Space pauses and resumes', (
      tester,
    ) async {
      _phone(tester, 390, 844);
      await tester.pumpWidget(
        _player(planOf([timed('a', 30)]), strings: TrainerStrings.en()),
      );
      await _until(tester, find.byKey(const ValueKey('media-a')));
      await tester.pump(const Duration(seconds: 1));
      final pause = find.byKey(const ValueKey('pause'));
      bool pauseFocused() {
        final ctx = FocusManager.instance.primaryFocus?.context;
        if (ctx == null) return false;
        var hit = false;
        ctx.visitAncestorElements((e) {
          if (e.widget.key == const ValueKey('pause')) hit = true;
          return !hit;
        });
        return hit;
      }

      for (var i = 0; i < 12 && !pauseFocused(); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(pauseFocused(), isTrue);
      expect(
        find.descendant(
          of: pause,
          matching: find.byKey(const ValueKey('glass-button-focus')),
        ),
        findsOneWidget,
      );
      expect(find.byTooltip('Pause'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byTooltip('Resume'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byTooltip('Pause'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
