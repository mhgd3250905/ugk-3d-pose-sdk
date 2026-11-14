import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer_runtime/src/ui/trainer_player_v1_prep_mark.dart';
import 'package:ugk_trainer_runtime/src/ui/trainer_theme.dart';

const _ring = ValueKey('player-v1-prep-ring');
const _opacity = ValueKey('player-v1-prep-opacity');
const _scale = ValueKey('player-v1-prep-scale');
const _startLabel = ValueKey('player-v1-start-label');
const _startCircle = ValueKey('player-v1-start-circle');
const _startSweep = ValueKey('player-v1-start-sweep');
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

double _startZoom(WidgetTester tester) =>
    tester.widget<Transform>(find.byKey(_startScale)).transform.entry(0, 0);

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

TrainerV1PrepRingPainter _painter(
  WidgetTester tester, [
  ValueKey<String> key = _ring,
]) =>
    tester.widget<CustomPaint>(find.byKey(key)).painter!
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

  testWidgets('start circle continues the countdown sweep at the same center', (
    tester,
  ) async {
    await _show(tester, label: '1');
    await tester.pump(const Duration(milliseconds: 910));
    final countdownRing = tester.getRect(find.byKey(_ring));
    final sweepProgress = _painter(tester).progress;
    await _show(tester, label: '开始', starting: true);
    final label = tester.widget<Text>(find.byKey(_startLabel));
    expect(label.data, '开始');
    expect(label.style?.fontSize, closeTo(countdownRing.width * .26, .001));
    expect(label.style?.fontWeight, FontWeight.w800);
    expect(label.style?.color, Colors.white);
    expect(label.style?.letterSpacing, 2);
    final circle = find.byKey(_startCircle);
    final decoration =
        tester.widget<DecoratedBox>(circle).decoration as BoxDecoration;
    final gradient = decoration.gradient! as RadialGradient;
    expect(decoration.shape, BoxShape.circle);
    expect(gradient.center, Alignment.center);
    expect(gradient.colors, [const Color(0xFF22B086), const Color(0xFF1E9E78)]);
    expect((decoration.border! as Border).top.width, 2);
    expect(
      (decoration.border! as Border).top.color,
      Colors.white.withValues(alpha: .7),
    );
    expect(decoration.boxShadow?.single.offset, const Offset(0, 12));
    expect(decoration.boxShadow?.single.blurRadius, 32);
    expect(find.byKey(_ring), findsNothing);
    expect(_startZoom(tester), 0);
    expect(tester.getRect(find.byKey(_startSweep)), countdownRing);
    expect(
      _painter(tester, _startSweep).progress,
      closeTo(sweepProgress, .001),
    );
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      _painter(tester, _startSweep).progress,
      closeTo((sweepProgress + 1) / 2, .001),
    );
    expect(_startZoom(tester), 0);
    await tester.pump(const Duration(milliseconds: 60));
    expect(_painter(tester, _startSweep).progress, 1);
    expect(_startZoom(tester), 0);
    await tester.pump(const Duration(milliseconds: 160));
    expect(_startZoom(tester), closeTo(Curves.easeOutBack.transform(.5), .001));
    await tester.pump(const Duration(milliseconds: 160));
    expect(_startAlpha(tester), 1);
    expect(_startZoom(tester), 1);
    expect(tester.getRect(circle), countdownRing);
    expect(tester.getCenter(find.byKey(_startLabel)), countdownRing.center);
    expect(find.byKey(_startSweep), findsNothing);
    await tester.pump(const Duration(milliseconds: 450));
    expect(_startAlpha(tester), 1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_startAlpha(tester), inExclusiveRange(0, 1));
    expect(_startZoom(tester), inExclusiveRange(1, 1.1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(circle, findsNothing);
  });

  testWidgets('start pulse plays once for 600 ms after the fill', (
    tester,
  ) async {
    await _show(tester, label: '开始', starting: true);
    final pulse = find.byKey(_startPulse);
    await tester.pump(const Duration(milliseconds: 439));
    expect(pulse, findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(pulse, findsOneWidget);
    final decoration =
        tester.widget<DecoratedBox>(pulse).decoration as BoxDecoration;
    expect(decoration.shape, BoxShape.circle);
    expect((decoration.border! as Border).top.width, 2);
    expect(tester.getSize(pulse), tester.getSize(find.byKey(_startCircle)));
    expect(_pulseAlpha(tester), .5);
    expect(_pulseScale(tester), 1);
    await tester.pump(const Duration(milliseconds: 300));
    final halfwayScale = _pulseScale(tester);
    final halfwayAlpha = _pulseAlpha(tester);
    expect(halfwayScale, inExclusiveRange(1, 1.35));
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
    expect(_startAlpha(tester), inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(_startCircle), findsNothing);
    await _show(tester, label: '开始', starting: true, reduced: true);
    expect(find.byKey(_startCircle), findsNothing);
  });

  testWidgets('reduced start uses only 150 ms fades around the hold', (
    tester,
  ) async {
    await _show(tester, label: '开始', starting: true, reduced: true);
    expect(find.byKey(_startScale), findsNothing);
    expect(find.byKey(_startPulse), findsNothing);
    expect(find.byKey(_startSweep), findsNothing);
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
    expect(find.byKey(_startCircle), findsNothing);
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
