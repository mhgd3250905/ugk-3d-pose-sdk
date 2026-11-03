import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

Widget _host(
  ScrollController controller, {
  int rows = 1,
  bool anchorTopWhenShort = false,
  WidgetBuilder? emptyBuilder,
}) {
  final entries = [
    for (var i = 0; i < rows; i++)
      CoachChatEntry(
        id: 'row-$i',
        at: DateTime(2026),
        isUser: false,
        child: SizedBox(key: ValueKey('paint-$i'), height: 100),
      ),
  ];
  return MaterialApp(
    home: Material(
      child: CoachUiTheme(
        style: CoachUiStyle(
          colors: CoachUiColors.light,
          typography: CoachUiTypography.fromTheme(ThemeData.light()),
        ),
        child: CoachChatList(
          entries: entries,
          initiallySeen: {for (final entry in entries) entry.id},
          controller: controller,
          timeMarkBuilder: (_, _) => const SizedBox.shrink(),
          topInset: 20,
          dockHeight: 100,
          anchorTopWhenShort: anchorTopWhenShort,
          emptyBuilder: emptyBuilder,
        ),
      ),
    ),
  );
}

void main() {
  Future<ScrollController> pump(
    WidgetTester tester,
    Widget Function(ScrollController) host,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(host(controller));
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('default: a short conversation rests on the dock', (
    tester,
  ) async {
    await pump(tester, (c) => _host(c));
    final top = tester.getTopLeft(find.byKey(const ValueKey('paint-0'))).dy;
    // 800 - dock 100 - x3 spacing - row 100 - x4 top padding: near the bottom.
    expect(top, greaterThan(400));
  });

  testWidgets('anchorTopWhenShort starts a short conversation at the top', (
    tester,
  ) async {
    await pump(tester, (c) => _host(c, anchorTopWhenShort: true));
    final top = tester.getTopLeft(find.byKey(const ValueKey('paint-0'))).dy;
    // 48 fade + 20 top inset + the row's own top spacing.
    expect(top, lessThan(120));
    expect(top, greaterThanOrEqualTo(68));
  });

  testWidgets('anchorTopWhenShort keeps long conversations bottom-first', (
    tester,
  ) async {
    final controller = await pump(
      tester,
      (c) => _host(c, rows: 20, anchorTopWhenShort: true),
    );
    expect(controller.offset, 0);
    expect(find.byKey(const ValueKey('paint-19')), findsOneWidget);
    final last = tester.getBottomLeft(find.byKey(const ValueKey('paint-19')));
    expect(last.dy, closeTo(800 - 100 - 12, .5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('emptyBuilder shows top-anchored content with no entries', (
    tester,
  ) async {
    await pump(
      tester,
      (c) => _host(
        c,
        rows: 0,
        emptyBuilder: (_) => const SizedBox(key: ValueKey('empty'), height: 60),
      ),
    );
    expect(find.byKey(const ValueKey('coach-chat-list-empty')), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const ValueKey('empty'))).dy, 68);
  });

  testWidgets('without emptyBuilder an empty list renders nothing extra', (
    tester,
  ) async {
    await pump(tester, (c) => _host(c, rows: 0));
    expect(find.byKey(const ValueKey('coach-chat-list-empty')), findsNothing);
    expect(find.byType(ListView), findsOneWidget);
  });
}
