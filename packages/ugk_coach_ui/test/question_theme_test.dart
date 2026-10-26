import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoTheme, CupertinoThemeData;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

const _capture = ValueKey('question-theme-capture');
const _input = ValueKey('question-input-palette');

Widget _host({
  required CoachUiColors colors,
  required TargetPlatform platform,
  required Color hostTint,
  required Future<void> Function(String) onAnswer,
}) => MaterialApp(
  theme: ThemeData(
    platform: platform,
    colorScheme: ColorScheme.fromSeed(seedColor: hostTint),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: hostTint,
      hoverColor: hostTint,
      focusColor: hostTint,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: hostTint,
      selectionColor: hostTint,
      selectionHandleColor: hostTint,
    ),
  ),
  home: Material(
    child: RepaintBoundary(
      key: _capture,
      child: CupertinoTheme(
        data: CupertinoThemeData(
          primaryColor: hostTint,
          selectionHandleColor: hostTint,
        ),
        child: CoachUiTheme(
          style: CoachUiStyle(
            colors: colors,
            typography: CoachUiTypography.fromTheme(ThemeData.light()),
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: CoachQuestionBubble(
              question: const CoachQuestionData(
                id: 'palette',
                question: 'Where?',
                mode: CoachQuestionMode.text,
              ),
              enabled: true,
              onTextAnswer: onAnswer,
              onChoiceAnswer: (_) async {},
            ),
          ),
        ),
      ),
    ),
  ),
);

Future<Color> _inputBackground(WidgetTester tester) async {
  final origin = tester.getTopLeft(find.byKey(_capture));
  final rect = tester.getRect(find.byKey(_input)).shift(-origin);
  // Stay clear of the underline, cursor and text glyphs.
  final point = Offset(rect.right - 4, rect.top + 2);
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
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('${platform.name} input owns palette and preserves selection', (
      tester,
    ) async {
      final answers = <String>[];
      final palettes = [
        CoachUiColors.light.copyWith(
          surfaceRaised: const Color(0x20435162),
          accent: const Color(0xFF154576),
          accentSoft: const Color(0xFFBACDDD),
        ),
        CoachUiColors.dark.copyWith(
          surfaceRaised: const Color(0x20213243),
          accent: const Color(0xFFB4D6F8),
          accentSoft: const Color(0xFF345678),
        ),
      ];
      Future<void> mount(CoachUiColors colors, Color hostTint) async {
        await tester.pumpWidget(
          _host(
            colors: colors,
            platform: platform,
            hostTint: hostTint,
            onAnswer: (answer) async => answers.add(answer),
          ),
        );
        await tester.pumpAndSettle();
      }

      await mount(palettes.first, const Color(0xFFFF00FF));
      final input = find.byKey(_input);
      final originalRect = tester.getRect(input);
      final controller = tester.widget<TextField>(input).controller!;
      expect(await _inputBackground(tester), const Color(0xFF435162));
      await tester.enterText(input, '  hips  ');
      const selection = TextSelection(baseOffset: 2, extentOffset: 6);
      controller.selection = selection;
      await tester.pump();

      for (final colors in palettes) {
        await mount(colors, Colors.yellow);
        expect(tester.getRect(input), originalRect);
        expect(tester.widget<TextField>(input).controller, same(controller));
        expect(controller.text, '  hips  ');
        expect(controller.selection, selection);
        expect(
          await _inputBackground(tester),
          colors.surfaceRaised.withValues(alpha: 1),
        );
        final editable = tester.widget<EditableText>(find.byType(EditableText));
        expect(editable.cursorColor, colors.accent);
        expect(editable.selectionColor, colors.accentSoft);
        final context = tester.element(find.byType(EditableText));
        expect(
          TextSelectionTheme.of(context).selectionHandleColor,
          colors.accent,
        );
        expect(CupertinoTheme.of(context).selectionHandleColor, colors.accent);
      }

      await tester.tap(find.byKey(const ValueKey('question-submit-palette')));
      await tester.pump();
      expect(answers, ['hips']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
