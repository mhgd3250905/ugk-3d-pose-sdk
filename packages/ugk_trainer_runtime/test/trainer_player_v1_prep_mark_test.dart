import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer_runtime/src/ui/trainer_player_v1_prep_mark.dart';
import 'package:ugk_trainer_runtime/src/ui/trainer_theme.dart';

const _ring = ValueKey('player-v1-prep-ring');
const _opacity = ValueKey('player-v1-prep-opacity');
const _scale = ValueKey('player-v1-prep-scale');

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

  testWidgets('start cue fades in, holds 400 ms and fades out', (tester) async {
    await _show(tester, label: '开始', starting: true);
    final text = tester.widget<Text>(
      find.byKey(const ValueKey('player-v1-start-label')),
    );
    expect(text.style?.fontSize, 72);
    expect(text.style?.fontWeight, FontWeight.w900);
    expect(find.byKey(_ring), findsNothing);
    await tester.pump(const Duration(milliseconds: 320));
    expect(_alpha(tester), 1);
    await tester.pump(const Duration(milliseconds: 400));
    expect(_alpha(tester), 1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(_alpha(tester), inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(_alpha(tester), 0);
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
