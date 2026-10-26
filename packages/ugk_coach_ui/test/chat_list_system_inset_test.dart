import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

const _background = Color(0xFF102030);
const _marker = Color(0xFF00CC44);
const _fade = Color(0xFFFF00FF);
const _capture = ValueKey('capture');

Widget _host(
  ScrollController controller, {
  double topInset = 0,
  bool fadeTop = true,
}) {
  final entries = [
    for (var i = 0; i < 12; i++)
      CoachChatEntry(
        id: 'row-$i',
        at: DateTime(2026),
        isUser: false,
        child: SizedBox(
          key: ValueKey('paint-$i'),
          height: 100,
          width: double.infinity,
          child: const ColoredBox(color: _marker),
        ),
      ),
  ];
  return MaterialApp(
    home: Material(
      color: _background,
      child: RepaintBoundary(
        key: _capture,
        child: ColoredBox(
          color: _background,
          child: CoachUiTheme(
            style: CoachUiStyle(
              colors: CoachUiColors.light.copyWith(background: _fade),
              typography: CoachUiTypography.fromTheme(ThemeData.light()),
            ),
            child: CoachChatList(
              entries: entries,
              initiallySeen: {for (final entry in entries) entry.id},
              controller: controller,
              timeMarkBuilder: (_, _) => const SizedBox.shrink(),
              topInset: topInset,
              fadeTop: fadeTop,
            ),
          ),
        ),
      ),
    ),
  );
}

Finder _topFade() => find.byWidgetPredicate((widget) {
  if (widget is! DecoratedBox || widget.decoration is! BoxDecoration) {
    return false;
  }
  final gradient = (widget.decoration as BoxDecoration).gradient;
  return gradient is LinearGradient && gradient.colors.first == _fade;
});

Future<Color> _pixel(WidgetTester tester, int x, int y) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_capture),
  );
  final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 1)))!;
  try {
    final bytes = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    final offset = (y * image.width + x) * 4;
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
  testWidgets(
    'default host keeps 48 px content padding and established top fade',
    (tester) async {
      tester.view.physicalSize = const Size(320, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(controller));
      await tester.pumpAndSettle();

      final list = tester.widget<ListView>(find.byType(ListView));
      expect((list.padding! as EdgeInsets).top, 48);
      expect(tester.getRect(find.byType(Viewport)).top, 0);
      expect(_topFade(), findsOneWidget);
      expect(
        tester
            .widgetList<IgnorePointer>(
              find.ancestor(
                of: _topFade(),
                matching: find.byType(IgnorePointer),
              ),
            )
            .where((widget) => widget.ignoring),
        hasLength(1),
      );
      final gradient =
          (tester.widget<DecoratedBox>(_topFade()).decoration as BoxDecoration)
                  .gradient!
              as LinearGradient;
      expect(gradient.colors.first, _fade);
      expect(gradient.colors.last.a, 0);
    },
  );

  testWidgets(
    'safe inset stays in list content and rows paint into system-bar area',
    (tester) async {
      tester.view.physicalSize = const Size(320, 360);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 32);
      addTearDown(tester.view.reset);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(controller, topInset: 32, fadeTop: false));
      await tester.pumpAndSettle();

      final list = tester.widget<ListView>(find.byType(ListView));
      expect((list.padding! as EdgeInsets).top, 80);
      final viewport = tester.getRect(find.byType(Viewport));
      expect(viewport, const Rect.fromLTWH(0, 0, 320, 360));
      expect(_topFade(), findsNothing);
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final firstBefore = tester.getRect(find.byKey(const ValueKey('paint-0')));
      expect(
        firstBefore.top,
        96,
      ); // 80 safe/top padding plus the first-row gap.
      expect(await _pixel(tester, 24, 20), _background);

      controller.jumpTo(controller.position.maxScrollExtent - 80);
      await tester.pumpAndSettle();
      final firstAfter = tester.getRect(find.byKey(const ValueKey('paint-0')));
      expect(firstAfter.top, 16);
      expect(firstAfter.overlaps(const Rect.fromLTWH(0, 0, 320, 32)), isTrue);
      // Inspect actual painted pixels: a full-sized container alone is not enough
      // if a SafeArea/clip or opaque gradient still hides the scrolled row.
      expect(await _pixel(tester, 24, 20), _marker);
      expect(tester.takeException(), isNull);
    },
  );
}
