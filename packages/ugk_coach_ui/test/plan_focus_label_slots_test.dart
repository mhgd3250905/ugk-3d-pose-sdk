import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

const _leading = ValueKey('host-bookmark');
const _trailing = ValueKey('host-close');
const _clear = ValueKey('plan-focus-clear');

// Like SF's SfIcon, this glyph uses a painter rather than an icon font and can
// take its size and colour directly from the builder's inherited IconTheme.
class _HostGlyph extends StatelessWidget {
  const _HostGlyph({required this.paintKey});

  final Key paintKey;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 80,
    child: CustomPaint(
      key: paintKey,
      painter: _HostGlyphPainter(IconTheme.of(context).color!),
    ),
  );
}

class _HostGlyphPainter extends CustomPainter {
  const _HostGlyphPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..moveTo(size.width * .25, size.height * .15)
        ..lineTo(size.width * .75, size.height * .15)
        ..lineTo(size.width * .75, size.height * .85)
        ..lineTo(size.width * .5, size.height * .65)
        ..lineTo(size.width * .25, size.height * .85)
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_HostGlyphPainter oldDelegate) =>
      oldDelegate.color != color;
}

Future<void> _show(
  WidgetTester tester, {
  bool dark = false,
  String? title = '晨间舒展',
  CoachUiStyle? style,
  CoachPlanFocusIconBuilder? iconBuilder,
  CoachPlanFocusIconBuilder? clearIconBuilder,
  VoidCallback? onClear,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => CoachUiTheme(
            style: style ?? CoachUiStyle.fromTheme(Theme.of(context)),
            child: Align(
              alignment: Alignment.topLeft,
              child: PlanFocusLabel(
                title: title,
                onClear: onClear,
                icon: Icons.star_outline,
                clearIcon: Icons.cancel_outlined,
                iconBuilder: iconBuilder,
                clearIconBuilder: clearIconBuilder,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Widget _leadingBuilder(BuildContext context, double size, Color color) =>
    const _HostGlyph(paintKey: _leading);

Widget _clearBuilder(BuildContext context, double size, Color color) =>
    const _HostGlyph(paintKey: _trailing);

void main() {
  for (final mode in ['light', 'dark', 'custom']) {
    testWidgets('painter slots receive current $mode size and palette', (
      tester,
    ) async {
      final dark = mode == 'dark';
      final base = CoachUiStyle.fromTheme(
        ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
      );
      final style = mode == 'custom'
          ? CoachUiStyle(
              colors: base.colors.copyWith(
                taskAccent: Colors.purple,
                taskMuted: Colors.brown,
              ),
              typography: base.typography,
            )
          : base;
      final calls = <({double size, Color color, IconThemeData theme})>[];
      Widget glyph(BuildContext context, double size, Color color, Key key) {
        calls.add((size: size, color: color, theme: IconTheme.of(context)));
        return _HostGlyph(paintKey: key);
      }

      await _show(
        tester,
        dark: dark,
        style: style,
        iconBuilder: (context, size, color) =>
            glyph(context, size, color, _leading),
        clearIconBuilder: (context, size, color) =>
            glyph(context, size, color, _trailing),
      );
      expect(calls.length, greaterThanOrEqualTo(2));
      expect(calls.map((call) => call.size), everyElement(14));
      expect(calls.first.color, style.colors.taskAccent);
      expect(calls.last.color, style.colors.taskMuted);
      for (final call in calls) {
        expect(call.theme.size, call.size);
        expect(call.theme.color, call.color);
      }
      for (final (key, color) in [
        (_leading, style.colors.taskAccent),
        (_trailing, style.colors.taskMuted),
      ]) {
        expect(tester.getSize(find.byKey(key)), const Size(14, 14));
        expect(
          (tester.widget<CustomPaint>(find.byKey(key)).painter!
                  as _HostGlyphPainter)
              .color,
          color,
        );
      }
      expect(find.byIcon(Icons.star_outline), findsNothing);
      expect(find.byIcon(Icons.cancel_outlined), findsNothing);
      expect(tester.getSize(find.byKey(_clear)), const Size(28, 28));
      expect(
        tester.getSize(find.byKey(const ValueKey('plan-focus-label'))).height,
        28,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('each slot independently takes precedence over its IconData', (
    tester,
  ) async {
    await _show(tester);
    expect(find.byIcon(Icons.star_outline), findsOneWidget);
    expect(find.byIcon(Icons.cancel_outlined), findsOneWidget);
    await _show(tester, iconBuilder: _leadingBuilder);
    expect(find.byKey(_leading), findsOneWidget);
    expect(find.byIcon(Icons.star_outline), findsNothing);
    expect(find.byIcon(Icons.cancel_outlined), findsOneWidget);
    await _show(tester, clearIconBuilder: _clearBuilder);
    expect(find.byIcon(Icons.star_outline), findsOneWidget);
    expect(find.byIcon(Icons.cancel_outlined), findsNothing);
    expect(find.byKey(_trailing), findsOneWidget);
  });

  testWidgets('clear slot keeps its full hit area and keyboard activation', (
    tester,
  ) async {
    var clears = 0;
    await _show(
      tester,
      iconBuilder: _leadingBuilder,
      clearIconBuilder: _clearBuilder,
      onClear: () => clears++,
    );
    final clear = find.byKey(_clear);
    expect(tester.getSize(clear), const Size(28, 28));
    expect(find.bySemanticsLabel('取消讨论计划'), findsOneWidget);
    await tester.tapAt(tester.getTopLeft(clear) + const Offset(1, 14));
    await tester.pump();
    expect(clears, 1);
    final focus = tester.element(
      find.descendant(of: clear, matching: find.byType(GestureDetector)),
    );
    Focus.of(focus).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(clears, 2);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('a painted clear slot preserves disabled button semantics', (
    tester,
  ) async {
    await _show(tester, clearIconBuilder: _clearBuilder);
    final clear = find.byKey(_clear);
    final semantics = tester.widget<Semantics>(
      find.descendant(of: clear, matching: find.byType(Semantics)).first,
    );
    expect(semantics.properties.button, isTrue);
    expect(semantics.properties.enabled, isFalse);
    expect(semantics.properties.onTap, isNull);
    final detector = tester.widget<GestureDetector>(
      find.descendant(of: clear, matching: find.byType(GestureDetector)),
    );
    expect(detector.onTap, isNull);
    await tester.tap(clear);
    await tester.pump();
    expect(find.text('正在讨论：晨间舒展'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('theme updates rebuild painters without replacing label state', (
    tester,
  ) async {
    await _show(tester, iconBuilder: _leadingBuilder);
    final state = tester.state(find.byType(PlanFocusLabel));
    final light =
        tester.widget<CustomPaint>(find.byKey(_leading)).painter!
            as _HostGlyphPainter;
    await _show(tester, dark: true, iconBuilder: _leadingBuilder);
    final dark =
        tester.widget<CustomPaint>(find.byKey(_leading)).painter!
            as _HostGlyphPainter;
    expect(tester.state(find.byType(PlanFocusLabel)), same(state));
    expect(dark.color, isNot(light.color));
    expect(
      dark.color,
      CoachUiTheme.of(tester.element(find.byKey(_leading))).colors.taskAccent,
    );
  });

  testWidgets('empty focus does not invoke either renderer', (tester) async {
    var calls = 0;
    Widget render(BuildContext context, double size, Color color) {
      calls++;
      return const SizedBox.shrink();
    }

    await _show(
      tester,
      title: ' ',
      iconBuilder: render,
      clearIconBuilder: render,
    );
    expect(calls, 0);
    expect(find.byKey(const ValueKey('plan-focus-label')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.binding.transientCallbackCount, 0);
  });
}
