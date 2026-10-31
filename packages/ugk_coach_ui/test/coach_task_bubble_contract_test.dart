import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/src/task_bubble_tokens.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

final _image = MemoryImage(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  ),
);

Future<void> _show(
  WidgetTester tester, {
  CoachUiColors? colors,
  CoachUiStrings strings = const CoachUiStrings(),
  CoachTaskBubble bubble = const CoachTaskBubble(waiting: true),
  bool reduced = false,
}) async {
  final theme = ThemeData.light();
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (context, child) => CoachUiTheme(
        style: CoachUiStyle(
          colors: colors ?? CoachUiColors.fromTheme(theme),
          typography: CoachUiTypography.fromTheme(theme),
          strings: strings,
        ),
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: child!,
        ),
      ),
      home: Scaffold(body: bubble),
    ),
  );
  await tester.pump();
}

T _nearest<T extends Widget>(WidgetTester tester, Finder child) =>
    tester.widget<T>(find.ancestor(of: child, matching: find.byType(T)).first);

void main() {
  test(
    'new task roles keep the approved palette without changing older roles',
    () {
      final light = CoachUiColors.fromTheme(ThemeData.light());
      final dark = CoachUiColors.fromTheme(ThemeData.dark());
      expect(light.taskAccent, const Color(0xFF0E7673));
      expect(dark.taskAccent, const Color(0xFF7AD4D5));
      expect(light.taskCardSurface, const Color(0xFFFFFFFF));
      expect(dark.taskCardSurface, const Color(0xFF19262B));
      expect(light.taskText, const Color(0xFF121614));
      expect(dark.taskText, const Color(0xFFF2F3F5));
      expect(light.taskMuted, const Color(0xFF5D6661));
      expect(dark.taskMuted, const Color(0xFFA0A4AC));
      final custom = light.copyWith(
        taskAccent: Colors.purple,
        taskCardSurface: Colors.indigo,
        taskGlow: Colors.pink,
      );
      expect(custom.accent, light.accent);
      expect(custom.surface, light.surface);
      expect(custom.text, light.text);
      expect(custom.cardSurface, light.cardSurface);
      expect(custom.taskAccent, Colors.purple);
      expect(custom.taskChipSurface, Colors.purple.withValues(alpha: .10));
      expect(custom.taskGlow, Colors.pink);
      final darkCustom = custom.copyWith(brightness: Brightness.dark);
      expect(darkCustom.taskCardSurface, Colors.indigo);
      expect(darkCustom.taskGlow, Colors.pink);
      expect(darkCustom.taskChipSurface, Colors.purple.withValues(alpha: .18));
    },
  );

  testWidgets(
    'four repaint boundaries and host colours/copy remain independent',
    (tester) async {
      final colors = CoachUiColors.light.copyWith(
        taskAccent: Colors.purple,
        taskCardSurface: Colors.indigo,
        taskCardBorder: Colors.amber,
        taskGlow: Colors.pink,
        taskText: Colors.orange,
        taskMuted: Colors.cyan,
        taskChipSurface: Colors.green,
      );
      await _show(
        tester,
        colors: colors,
        strings: const CoachUiStrings(
          taskThinkingTitle: 'Finding your workout',
          taskReadingStatus: 'Reading your preferences',
          taskCancel: 'Stop preparing',
        ),
        reduced: true,
        bubble: CoachTaskBubble(
          waiting: true,
          parameters: const [(field: 'goal', label: 'Mobility', user: true)],
          onCancel: () {},
        ),
      );
      expect(
        find.descendant(
          of: find.byType(CoachTaskBubble),
          matching: find.byType(RepaintBoundary),
        ),
        findsNWidgets(4),
      );
      final card = tester.widget<Container>(
        find.byKey(const ValueKey('generation-card')),
      );
      expect((card.decoration! as BoxDecoration).color, Colors.indigo);
      final outline = card.foregroundDecoration! as BoxDecoration;
      expect((outline.border! as Border).top.color, Colors.amber);
      final glow = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey('generation-glow')),
      );
      expect(
        ((glow.decoration as BoxDecoration).gradient! as RadialGradient)
            .colors
            .first,
        Colors.pink,
      );
      expect(
        tester.widget<Text>(find.text('Finding your workout')).style!.color,
        Colors.orange,
      );
      expect(
        tester.widget<Text>(find.text('Reading your preferences')).style!.color,
        Colors.cyan,
      );
      expect(find.text('Stop preparing'), findsOneWidget);
      final chip = tester.widget<Container>(
        find.byKey(const ValueKey('generation-chip-face-goal')),
      );
      expect((chip.decoration! as BoxDecoration).color, Colors.green);
      expect(
        tester.widget<Text>(find.text('Mobility')).style!.color,
        Colors.purple,
      );
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets('breathing core follows the exact 1200ms sine cubic', (
    tester,
  ) async {
    await _show(tester);
    final core = find.byKey(const ValueKey('generation-core'));
    double scale() => _nearest<Transform>(tester, core).transform.storage[0];
    double opacity() => _nearest<Opacity>(tester, core).opacity;
    expect(scale(), .8);
    expect(opacity(), .6);
    await tester.pump(const Duration(milliseconds: 300));
    final quarter = const Cubic(.37, 0, .63, 1).transform(.25);
    expect(scale(), closeTo(.8 + .2 * quarter, .0001));
    expect(opacity(), closeTo(.6 + .4 * quarter, .0001));
    await tester.pump(const Duration(milliseconds: 900));
    expect(scale(), closeTo(1, .0001));
    expect(opacity(), closeTo(1, .0001));
    await tester.pump(const Duration(milliseconds: 300));
    final returning = const Cubic(.37, 0, .63, 1).transform(.75);
    expect(scale(), closeTo(.8 + .2 * returning, .0001));
    expect(opacity(), closeTo(.6 + .4 * returning, .0001));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('first silhouette waits 180ms then reveals for 250ms', (
    tester,
  ) async {
    await _show(
      tester,
      bubble: CoachTaskBubble(
        waiting: true,
        picks: const ['move'],
        cutoutFor: (_) => _image,
      ),
    );
    final image = find.byKey(const ValueKey('generation-thumbnail-move'));
    final reveal = find
        .ancestor(of: image, matching: find.byType(Opacity))
        .last;
    double opacity() => tester.widget<Opacity>(reveal).opacity;
    expect(opacity(), 0);
    expect(
      _nearest<Transform>(tester, image).transform.storage[0],
      closeTo(.94, .0001),
    );
    await tester.pump(const Duration(milliseconds: 180));
    expect(opacity(), 0);
    await tester.pump(const Duration(milliseconds: 125));
    expect(opacity(), closeTo(.5, .0001));
    expect(
      _nearest<Transform>(tester, image).transform.storage[0],
      closeTo(.94 + .06 * Curves.easeOutCubic.transform(.5), .0001),
    );
    await tester.pump(const Duration(milliseconds: 125));
    expect(opacity(), 1);
    expect(_nearest<Transform>(tester, image).transform.storage[0], 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'missing cutouts use the orb and preserve supplied summary text',
    (tester) async {
      await _show(
        tester,
        reduced: true,
        bubble: CoachTaskBubble(
          waiting: true,
          title: 'A title supplied by the host',
          status: 'Two selected exercises',
          phase: 1,
          picks: const ['missing', 'other'],
          cutoutFor: (_) => null,
        ),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.byKey(const ValueKey('generation-core')), findsOneWidget);
      expect(find.text('Two selected exercises'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  test('approved motion values remain literal matches to the reference', () {
    expect(
      CoachTaskBubbleTokens.cardPadding,
      const EdgeInsets.fromLTRB(16, 14, 16, 16),
    );
    expect(CoachTaskBubbleTokens.cardRadius, 20);
    expect(CoachTaskBubbleTokens.cardEdgeWidth, .5);
    expect(CoachTaskBubbleTokens.glowRadius, 160);
    expect(CoachTaskBubbleTokens.animationSize, 44);
    expect(CoachTaskBubbleTokens.arcStroke, 1.5);
    expect(CoachTaskBubbleTokens.arcSweep, 300);
    expect(CoachTaskBubbleTokens.rotation, const Duration(milliseconds: 1400));
    expect(CoachTaskBubbleTokens.coreSize, 10);
    expect(CoachTaskBubbleTokens.haloSize, 20);
    expect(CoachTaskBubbleTokens.shimmer, const Duration(milliseconds: 1600));
    expect(CoachTaskBubbleTokens.shimmerSpan, 2.5);
    expect(
      CoachTaskBubbleTokens.progressBand,
      const Duration(milliseconds: 1200),
    );
    expect(CoachTaskBubbleTokens.progressBandFraction, .4);
    expect(CoachTaskBubbleTokens.checkStroke, 2.4);
    expect(CoachTaskBubbleTokens.back, const Cubic(.34, 1.56, .64, 1));
    expect(
      CoachTaskBubbleTokens.checkTransition,
      const Duration(milliseconds: 260),
    );
    expect(CoachTaskBubbleTokens.cancelTouchSize, 44);
  });
}
