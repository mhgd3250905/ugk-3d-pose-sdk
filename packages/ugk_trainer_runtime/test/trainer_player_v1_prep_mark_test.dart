import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer_runtime/src/ui/trainer_player_v1_prep_mark.dart';
import 'package:ugk_trainer_runtime/src/ui/trainer_theme.dart';

const _ring = ValueKey('player-v1-prep-ring');
const _opacity = ValueKey('player-v1-prep-opacity');
const _scale = ValueKey('player-v1-prep-scale');
const _startLabel = ValueKey('player-v1-start-label');
const _startPill = ValueKey('player-v1-start-pill');
const _startPulse = ValueKey('player-v1-start-pulse');
const _startOpacity = ValueKey('player-v1-start-opacity');
const _startScale = ValueKey('player-v1-start-scale');

Future<void> _show(
  WidgetTester tester, {
  required String label,
  bool starting = false,
  bool reduced = false,
  TrainerTheme theme = TrainerTheme.playerV1,
}) => tester.pumpWidget(
  MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Scaffold(
        body: TrainerV1PrepMark(label: label, starting: starting, theme: theme),
      ),
    ),
  ),
);

double _alpha(WidgetTester tester) =>
    tester.widget<Opacity>(find.byKey(_opacity)).opacity;

double _glyphScale(WidgetTester tester) =>
    tester.widget<Transform>(find.byKey(_scale)).transform.entry(0, 0);

double _startAlpha(WidgetTester tester) =>
    tester.widget<Opacity>(find.byKey(_startOpacity)).opacity;

double _pulseAlpha(WidgetTester tester) => tester
    .widgetList<Opacity>(
      find.ancestor(
        of: find.byKey(_startPulse),
        matching: find.byType(Opacity),
      ),
    )
    .first
    .opacity;

double _pulseScale(WidgetTester tester) => tester
    .widgetList<Transform>(
      find.ancestor(
        of: find.byKey(_startPulse),
        matching: find.byType(Transform),
      ),
    )
    .first
    .transform
    .entry(0, 0);

TrainerV1PrepRingPainter _painter(WidgetTester tester) =>
    tester.widget<CustomPaint>(find.byKey(_ring)).painter!
        as TrainerV1PrepRingPainter;

void main() {
  testWidgets('each prep digit times its own sweep and exit', (tester) async {
    await _show(tester, label: '3');
    final text = tester.widget<Text>(
      find.byKey(const ValueKey('player-v1-prep-digit')),
    );
    expect(text.data, '3');
    expect(text.style?.fontSize, 160);
    expect(text.style?.fontWeight, FontWeight.w900);
    expect(tester.getSize(find.byKey(_ring)), const Size.square(220));
    expect(
      tester.getSize(find.byKey(const ValueKey('player-v1-prep-halo'))),
      const Size.square(200),
    );
    expect(_glyphScale(tester), closeTo(1.6, .001));
    expect(_alpha(tester), 0);
    expect(_painter(tester).progress, 0);

    await tester.pump(const Duration(milliseconds: 160));
    expect(_alpha(tester), closeTo(.5, .01));
    expect(_painter(tester).progress, closeTo(.16, .001));
    await _show(tester, label: '3', theme: TrainerTheme.playerV1Dark);
    expect(_painter(tester).progress, closeTo(.16, .001));
    expect(_painter(tester).color, TrainerTheme.playerV1Dark.accent);
    await tester.pump(const Duration(milliseconds: 160));
    expect(_glyphScale(tester), closeTo(1, .001));
    await tester.pump(const Duration(milliseconds: 440));
    expect(_alpha(tester), 1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_alpha(tester), inExclusiveRange(0, 1));
    expect(_glyphScale(tester), inExclusiveRange(.85, 1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_alpha(tester), closeTo(0, .001));
    expect(_glyphScale(tester), closeTo(.85, .001));
    await tester.pump(const Duration(milliseconds: 40));
    expect(_painter(tester).progress, 1);

    await _show(tester, label: '2');
    expect(find.text('3'), findsNothing);
    expect(find.text('2'), findsOneWidget);
    expect(_painter(tester).progress, 0);
    expect(_alpha(tester), 0);
  });

  testWidgets('start cue enters, holds 450 ms and fades out over 200 ms', (
    tester,
  ) async {
    await _show(tester, label: '开始', starting: true);
    final label = tester.widget<Text>(find.byKey(_startLabel));
    expect(label.data, '开始');
    expect(label.style?.fontSize, 56);
    expect(label.style?.fontWeight, FontWeight.w800);
    expect(label.style?.color, Colors.white);
    expect(label.style?.letterSpacing, 4);
    final pill = tester.widget<DecoratedBox>(find.byKey(_startPill));
    final decoration = pill.decoration as BoxDecoration;
    final gradient = decoration.gradient! as LinearGradient;
    expect(gradient.begin, Alignment.topLeft);
    expect(gradient.end, Alignment.bottomRight);
    expect(gradient.colors, [const Color(0xFF22B086), const Color(0xFF1E9E78)]);
    expect((decoration.border! as Border).top.width, 2);
    expect(
      (decoration.border! as Border).top.color,
      Colors.white.withValues(alpha: .7),
    );
    expect(decoration.boxShadow?.single.offset, const Offset(0, 12));
    expect(decoration.boxShadow?.single.blurRadius, 32);
    expect(find.byKey(_ring), findsNothing);
    expect(_startAlpha(tester), 0);
    await tester.pump(const Duration(milliseconds: 180));
    expect(_startAlpha(tester), inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 180));
    expect(_startAlpha(tester), 1);
    expect(
      tester.widget<Transform>(find.byKey(_startScale)).transform.entry(0, 0),
      closeTo(1, .001),
    );
    await tester.pump(const Duration(milliseconds: 450));
    expect(_startAlpha(tester), 1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_startAlpha(tester), inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_startAlpha(tester), 0);
  });

  testWidgets('start pulse ends 600 ms from entry despite a theme change', (
    tester,
  ) async {
    await _show(tester, label: '开始', starting: true);
    final pulse = find.byKey(_startPulse);
    expect(pulse, findsOneWidget);
    expect(_pulseAlpha(tester), .5);
    expect(_pulseScale(tester), 1);
    await tester.pump(const Duration(milliseconds: 300));
    final halfwayScale = _pulseScale(tester);
    final halfwayAlpha = _pulseAlpha(tester);
    expect(halfwayScale, inExclusiveRange(1, 1.5));
    expect(halfwayAlpha, inExclusiveRange(0, .5));
    await _show(
      tester,
      label: '开始',
      starting: true,
      theme: TrainerTheme.playerV1Dark,
    );
    expect(_pulseScale(tester), halfwayScale);
    expect(_pulseAlpha(tester), halfwayAlpha);
    await tester.pump(const Duration(milliseconds: 299));
    expect(pulse, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(pulse, findsNothing);
    expect(_startAlpha(tester), 1);
  });

  testWidgets('reduced start uses only 150 ms fades around the hold', (
    tester,
  ) async {
    await _show(tester, label: '开始', starting: true, reduced: true);
    expect(find.byKey(_startScale), findsNothing);
    expect(find.byKey(_startPulse), findsNothing);
    expect(find.byKey(_ring), findsNothing);
    expect(_startAlpha(tester), 0);
    await tester.pump(const Duration(milliseconds: 75));
    expect(_startAlpha(tester), inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 75));
    expect(_startAlpha(tester), 1);
    await tester.pump(const Duration(milliseconds: 450));
    expect(_startAlpha(tester), 1);
    await tester.pump(const Duration(milliseconds: 75));
    expect(_startAlpha(tester), inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 75));
    expect(_startAlpha(tester), 0);
  });

  testWidgets('reduced prep only fades without scale or sweep', (tester) async {
    await _show(tester, label: '1', reduced: true);
    expect(find.byKey(_scale), findsNothing);
    expect(find.byKey(_ring), findsNothing);
    await tester.pump(const Duration(milliseconds: 75));
    expect(_alpha(tester), closeTo(.5, .01));
    await tester.pump(const Duration(milliseconds: 75));
    expect(_alpha(tester), 1);
    await tester.pump(const Duration(milliseconds: 775));
    expect(_alpha(tester), closeTo(.5, .01));
    await tester.pump(const Duration(milliseconds: 75));
    expect(_alpha(tester), 0);
  });
}
