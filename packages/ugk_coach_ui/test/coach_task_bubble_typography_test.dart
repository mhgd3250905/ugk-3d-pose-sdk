import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

// The text-related setup from Sport-Helper@13c0bb4 buildTheme. Its task
// tokens use bare SfType TextStyles, rather than Material role TextStyles.
ThemeData _referenceTheme() {
  final base = ThemeData(useMaterial3: true, fontFamily: 'NotoSansSC');
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'NotoSansSC'),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        textStyle: const TextStyle(
          fontFamily: 'NotoSansSC',
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        shape: const StadiumBorder(),
      ),
    ),
  );
}

class _ReferenceText extends StatelessWidget {
  const _ReferenceText();

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Text(
        'Task title',
        style: TextStyle(
          fontSize: 15,
          height: 1.35,
          fontWeight: FontWeight.w600,
        ),
      ),
      const Text(
        'Task status',
        style: TextStyle(
          fontSize: 13,
          height: 18 / 13,
          fontWeight: FontWeight.w500,
        ),
      ),
      const Text(
        'Task chip',
        style: TextStyle(
          fontSize: 12,
          height: 1.4,
          fontWeight: FontWeight.w500,
        ),
      ),
      TextButton(
        onPressed: () {},
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size.square(44),
          backgroundColor: Colors.transparent,
          side: BorderSide.none,
          overlayColor: Colors.transparent,
        ),
        child: const Text(
          '取消',
          style: TextStyle(
            fontSize: 13,
            height: 1.4,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    ],
  );
}

Finder _rich(Finder scope, String text) => find.descendant(
  of: find.descendant(of: scope, matching: find.text(text)),
  matching: find.byType(RichText),
);

Map<String, Object?> _metrics(WidgetTester tester, Finder richFinder) {
  final rich = tester.widget<RichText>(richFinder);
  final style = (rich.text as TextSpan).style!;
  return {
    'fontFamily': style.fontFamily,
    'fontSize': style.fontSize,
    'height': style.height,
    'fontWeight': style.fontWeight,
    'letterSpacing': style.letterSpacing ?? 0,
    'wordSpacing': style.wordSpacing ?? 0,
    // Null and explicit alphabetic resolve to the same native baseline.
    'textBaseline': style.textBaseline ?? TextBaseline.alphabetic,
  };
}

void main() {
  for (final position in ['none', 'above-scaffold', 'inside-scaffold']) {
    testWidgets('effective task typography matches SF: theme $position', (
      tester,
    ) async {
      final theme = _referenceTheme();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          builder: (context, child) => position == 'above-scaffold'
              ? CoachUiTheme(
                  style: CoachUiStyle.fromTheme(Theme.of(context)),
                  child: child!,
                )
              : child!,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                Widget bubble = CoachTaskBubble(
                  title: 'Task title',
                  status: 'Task status',
                  parameters: const [
                    (field: 'goal', label: 'Task chip', user: true),
                  ],
                  waiting: true,
                  onCancel: () {},
                );
                if (position == 'inside-scaffold') {
                  bubble = CoachUiTheme(
                    style: CoachUiStyle.fromTheme(Theme.of(context)),
                    child: bubble,
                  );
                }
                return Column(children: [const _ReferenceText(), bubble]);
              },
            ),
          ),
        ),
      );
      await tester.pump();
      for (final text in const [
        'Task title',
        'Task status',
        'Task chip',
        '取消',
      ]) {
        final source = _rich(find.byType(_ReferenceText), text);
        final actual = _rich(find.byType(CoachTaskBubble), text);
        expect(
          _metrics(tester, actual),
          _metrics(tester, source),
          reason: 'Effective RichText metrics for $text',
        );
        final sourceParagraph = tester.renderObject<RenderParagraph>(source);
        final actualParagraph = tester.renderObject<RenderParagraph>(actual);
        expect(
          actualParagraph.getMaxIntrinsicWidth(double.infinity),
          closeTo(sourceParagraph.getMaxIntrinsicWidth(double.infinity), .001),
          reason: 'Same glyph width for $text',
        );
        expect(
          actualParagraph.size.height,
          closeTo(sourceParagraph.size.height, .001),
          reason: 'Same rendered line height for $text',
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
