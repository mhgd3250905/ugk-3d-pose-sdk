import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

const _capture = ValueKey('solid-capture');
const _card = ValueKey('solid-card');
const _control = ValueKey('solid-control');

Widget _host(CoachUiColors colors, VoidCallback onTap) => MaterialApp(
  // Deliberately different from the injected palette to reveal theme leaks.
  theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange)),
  home: Material(
    child: RepaintBoundary(
      key: _capture,
      child: ColoredBox(
        color: Colors.pink,
        child: CoachUiTheme(
          style: CoachUiStyle(
            colors: colors,
            typography: CoachUiTypography.fromTheme(ThemeData.light()),
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const CoachCardSurface(
                  key: _card,
                  width: 200,
                  padding: EdgeInsets.all(16),
                  child: SizedBox(height: 30),
                ),
                const SizedBox(height: 12),
                const CoachControlFace(
                  key: _control,
                  child: SizedBox(width: 70, height: 20),
                ),
                CoachOptionPill(label: 'Choose me', onTap: onTap),
                const CoachMessageBubble(
                  message: CoachBubbleData(id: 'body', text: 'Injected ink'),
                  optionsActive: false,
                  onOption: _ignoreOption,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
);

void _ignoreOption(int _) {}

Future<Color> _pixel(WidgetTester tester, Offset point) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_capture),
  );
  final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 1)))!;
  try {
    final bytes = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    final offset = (point.dy.floor() * image.width + point.dx.floor()) * 4;
    return Color.fromARGB(
      bytes.getUint8(offset + 3),
      bytes.getUint8(offset),
      bytes.getUint8(offset + 1),
      bytes.getUint8(offset + 2),
    );
  } finally {
    image.dispose();
  }
}

void main() {
  for (final colors in [CoachUiColors.light, CoachUiColors.dark]) {
    testWidgets('${colors.brightness.name} defaults have three opaque levels', (
      tester,
    ) async {
      await tester.pumpWidget(_host(colors, () {}));
      await tester.pumpAndSettle();
      expect({
        colors.background,
        colors.surface,
        colors.surfaceRaised,
      }, hasLength(3));
      for (final color in [
        colors.background,
        colors.surface,
        colors.surfaceRaised,
        colors.userBubble,
        colors.assistantBubble,
        colors.mediaLabelSurface,
      ]) {
        expect(color.a, 1);
      }
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(BackdropGroup), findsNothing);

      final card =
          tester
                  .widget<DecoratedBox>(
                    find.descendant(
                      of: find.byKey(_card),
                      matching: find.byType(DecoratedBox),
                    ),
                  )
                  .decoration
              as BoxDecoration;
      final control =
          tester
                  .widget<DecoratedBox>(
                    find.descendant(
                      of: find.byKey(_control),
                      matching: find.byType(DecoratedBox),
                    ),
                  )
                  .decoration
              as ShapeDecoration;
      expect(card.gradient, isNull);
      expect(control.gradient, isNull);
      expect(card.border!.top.width, 1);
      expect(card.border!.top.color, colors.outline);
      expect((control.shape as StadiumBorder).side.width, 1);
      expect((control.shape as StadiumBorder).side.color, colors.outline);
      expect(card.boxShadow, hasLength(1));
      expect(control.shadows, hasLength(1));
      expect(card.boxShadow!.single.color, colors.shadow);
      expect(control.shadows!.single.color, colors.shadow);
      expect(card.boxShadow!.single.offset.dy, greaterThan(0));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('injected surfaces stay opaque without changing hits or layout', (
    tester,
  ) async {
    var tapped = 0;
    await tester.pumpWidget(_host(CoachUiColors.light, () => tapped++));
    await tester.pumpAndSettle();
    final cardRect = tester.getRect(find.byKey(_card));
    final controlRect = tester.getRect(find.byKey(_control));
    expect(cardRect.size, const Size(200, 62));
    expect(controlRect.size, const Size(98, 44));
    final custom = CoachUiColors.light.copyWith(
      surface: const Color(0x40314253),
      surfaceRaised: const Color(0x40536475),
      text: const Color(0xFF123456),
      outline: const Color(0xFF718293),
      shadow: const Color(0x14010203),
    );
    await tester.pumpWidget(_host(custom, () => tapped++));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(_card)), cardRect);
    expect(tester.getRect(find.byKey(_control)), controlRect);
    expect(await _pixel(tester, cardRect.center), const Color(0xFF314253));
    expect(await _pixel(tester, controlRect.center), const Color(0xFF536475));
    expect(
      tester.widget<Text>(find.text('Injected ink')).style!.color,
      custom.text,
    );
    await tester.tap(find.text('Choose me'));
    await tester.pump();
    expect(tapped, 1);
    expect(tester.takeException(), isNull);
  });
}
