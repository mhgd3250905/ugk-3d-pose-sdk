import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

void main() {
  test('paused palette defaults and copies preserve host colours', () {
    for (final theme in [TrainerTheme.light, TrainerTheme.dark]) {
      expect(theme.pausedColor, theme.accent);
      expect(theme.onPaused, theme.onAccent);
      final custom = theme.copyWith(
        pausedColor: const Color(0xFFB00020),
        onPaused: Colors.white,
      );
      expect(custom.pausedColor, const Color(0xFFB00020));
      expect(custom.onPaused, Colors.white);
      expect(custom.copyWith(radius: 10).pausedColor, custom.pausedColor);
      expect(custom.copyWith(radius: 10).onPaused, custom.onPaused);
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      '${brightness.name}: next move stays top-left and pause uses primary colour at 320px/1.5x',
      (tester) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final strings = TrainerStrings.zh();
        final theme =
            (brightness == Brightness.dark
                    ? TrainerTheme.dark
                    : TrainerTheme.light)
                .copyWith(
                  pausedColor: const Color(0xFFB00020),
                  onPaused: Colors.white,
                );
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: const EdgeInsets.only(top: 24),
                textScaler: TextScaler.linear(1.5),
              ),
              child: child!,
            ),
            home: TrainerPlayer(
              plan: planOf([timed('a', 30), timed('b', 30)]),
              drillOf: (id) => TrainerDrill(
                id: id,
                name: id == 'a' ? '当前动作' : '仰卧雨刷式 · 放松髋部',
              ),
              strings: strings,
              theme: theme,
              prepSeconds: 0,
              keepAlive: false,
              mediaBuilder: (_, _) => const SizedBox.expand(),
              onFinished: (_) async {},
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
        final next = find.byKey(const ValueKey('next-b'));
        final pause = find.byKey(const ValueKey('pause'));
        final card = tester.getRect(find.byKey(const ValueKey('info-card')));
        final safety = tester.getRect(find.byKey(const ValueKey('discomfort')));
        final nextRect = tester.getRect(next);
        expect(nextRect.top, greaterThan(card.bottom));
        expect(nextRect.top - safety.top, inInclusiveRange(0, 6));
        expect(nextRect.right, lessThanOrEqualTo(safety.left - 4));
        expect(nextRect.left, closeTo(12, .5));
        expect(nextRect.bottom, lessThan(tester.getRect(pause).top));
        expect(find.byKey(const ValueKey('tag-paused')), findsNothing);
        final running = tester.widget<UgkPlayPauseButton>(pause);
        expect(running.theme.accent, theme.accent);
        expect(running.isPlaying, isTrue);
        expect(running.strings.pause, strings.pause);

        await tester.tap(pause);
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byKey(const ValueKey('tag-paused')), findsNothing);
        expect(find.text(strings.paused), findsNothing);
        expect(next, findsOneWidget);
        expect(tester.getRect(next), nextRect);
        final paused = tester.widget<UgkPlayPauseButton>(pause);
        expect(paused.isPlaying, isFalse);
        expect(paused.theme.pausedColor, theme.accent);
        expect(paused.theme.onPaused, theme.onPaused);
        expect(paused.strings.resume, strings.resume);
        expect(tester.takeException(), isNull);

        await tester.tap(pause);
        await tester.pump(const Duration(milliseconds: 600));
        final resumed = tester.widget<UgkPlayPauseButton>(pause);
        expect(resumed.theme.accent, theme.accent);
        expect(resumed.theme.onAccent, theme.onAccent);
        expect(resumed.isPlaying, isTrue);
        expect(resumed.strings.pause, strings.pause);
        expect(tester.getRect(next), nextRect);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
