import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/src/ui/trainer_cue_carousel.dart';
import 'package:ugk_trainer/src/ui/trainer_theme.dart';

void main() {
  const cues = ['放松肩颈', '保持均匀呼吸', '慢慢回到起始位置'];
  final container = find.byKey(const ValueKey('trainer-cue-container'));
  final text = find.byKey(const ValueKey('trainer-cue-text'));

  Future<void> mount(
    WidgetTester tester, {
    List<String> steps = cues,
    List<String> precautions = const [],
    bool preparing = false,
    String? prepCaption,
    bool reduced = false,
    double width = 360,
    double scale = 1,
    TrainerTheme theme = TrainerTheme.light,
    ValueChanged<bool>? onExpandedChanged,
  }) => tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(400, 800),
          textScaler: TextScaler.linear(scale),
          disableAnimations: reduced,
        ),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: TrainerCueCarousel(
                key: const ValueKey('carousel'),
                cues: steps,
                precautions: precautions,
                preparing: preparing,
                prepCaption: prepCaption,
                theme: theme,
                onExpandedChanged: onExpandedChanged,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> clean(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox.shrink());

  double opacity(Finder finder) {
    final element = finder.evaluate().singleOrNull;
    var value = element == null ? 0.0 : 1.0;
    RenderObject? object = element?.renderObject;
    while (object != null) {
      value *= switch (object) {
        RenderOpacity(:final opacity) => opacity,
        RenderAnimatedOpacity(:final opacity) => opacity.value,
        RenderOffstage(offstage: true) => 0.0,
        _ => 1.0,
      };
      object = object.parent;
    }
    return value;
  }

  test('legacy punctuation becomes distinct, clean steps', () {
    expect(
      normalizeTrainerCues([' 1. 放松肩颈。；保持均匀呼吸；；\n• 慢慢回到起始位置。 ', '；， ']),
      cues,
    );
    expect(normalizeTrainerCues(['腹部收紧，双脚与肩同宽']), ['腹部收紧，双脚与肩同宽']);
  });

  testWidgets('changes every 4.5 seconds and wraps through every step', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text(cues[0]), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 4499));
    expect(find.text(cues[1]), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 221));
    expect(find.text(cues[0]), findsNothing);
    expect(find.text(cues[1]), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 4279));
    await tester.pump(const Duration(milliseconds: 221));
    expect(find.text(cues[2]), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 4279));
    await tester.pump(const Duration(milliseconds: 221));
    expect(find.text(cues[0]), findsOneWidget);
    await clean(tester);
  });

  testWidgets('manual swipes hold autoplay for a full eight seconds', (
    tester,
  ) async {
    await mount(tester);
    await tester.drag(container, const Offset(-160, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 221));
    expect(find.text(cues[1]), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 7778));
    expect(find.text(cues[1]), findsOneWidget);
    expect(find.text(cues[2]), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 221));
    expect(find.text(cues[2]), findsOneWidget);
    await tester.drag(container, const Offset(160, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 221));
    expect(find.text(cues[1]), findsOneWidget);
    await clean(tester);
  });

  testWidgets('V1 pushes both cues through one clipped line area', (
    tester,
  ) async {
    const steps = ['夹紧臀部，身体慢慢往前推', '呼气，再沉一点', '放松肩颈', '慢慢回到起始位置'];
    final oldCue = find.text(steps[0]);
    final newCue = find.text(steps[1]);
    final pill = find.byKey(const ValueKey('trainer-cue-step-pill'));
    final count = find.byKey(const ValueKey('trainer-cue-count'));

    await mount(tester, steps: steps, theme: TrainerTheme.playerV1);
    final pillElement = tester.element(pill);
    final pillRect = tester.getRect(pill);
    final cardRect = tester.getRect(container);
    final oldCenter = tester.getCenter(oldCue);
    final lineArea = find.ancestor(of: oldCue, matching: find.byType(ClipRect));
    expect(lineArea, findsOneWidget);
    final height = tester.getSize(lineArea).height;
    expect(tester.widget<Text>(count).data, '1/4');
    expect(opacity(oldCue), 1);

    void expectOnePill() {
      expect(pill, findsOneWidget);
      expect(count, findsOneWidget);
      expect(tester.element(pill), same(pillElement));
      expect(tester.getRect(pill), pillRect);
      expect(tester.getRect(container), cardRect);
      expect(opacity(pill), 1);
    }

    void expectPush(double progress) {
      final offset = height * Curves.easeInOutCubic.transform(progress);
      expect(tester.getCenter(oldCue).dy, closeTo(oldCenter.dy - offset, .02));
      expect(
        tester.getCenter(newCue).dy,
        closeTo(oldCenter.dy + height - offset, .02),
      );
      expect(tester.getRect(oldCue).overlaps(tester.getRect(newCue)), isFalse);
      expectOnePill();
    }

    await tester.drag(container, const Offset(-160, 0));
    await tester.pump();
    Future<void> advanceSegment() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 8));
        final clip = tester.getRect(
          find.ancestor(of: newCue, matching: find.byType(ClipRect)),
        );
        final visible = [
          for (final cue in [oldCue, newCue])
            if (opacity(cue) > 0) tester.getRect(cue),
        ];
        expect(
          visible.where(
            (rect) => clip.top <= rect.top && clip.bottom >= rect.bottom,
          ),
          hasLength(lessThanOrEqualTo(1)),
        );
        if (visible.length == 2) {
          expect(visible[0].overlaps(visible[1]), isFalse);
        }
      }
    }

    await advanceSegment();
    expectPush(.25);
    expect(opacity(oldCue), 1);
    expect(opacity(newCue), closeTo(.5, .002));
    expect(opacity(count), closeTo(.5, .002));

    await advanceSegment();
    expectPush(.5);
    expect(opacity(oldCue), 1);
    expect(opacity(newCue), 1);
    expect(opacity(count), 1);
    expect(tester.widget<Text>(count).data, '2/4');

    await advanceSegment();
    expectPush(.75);
    expect(opacity(oldCue), closeTo(.5, .002));
    expect(opacity(newCue), 1);

    await advanceSegment();
    expect(opacity(oldCue), 0);
    expect(opacity(newCue), 1);
    expect(tester.getCenter(newCue).dy, closeTo(oldCenter.dy, .02));
    expectOnePill();
    expect(tester.takeException(), isNull);
    await clean(tester);
  });

  testWidgets('V1 finishes an interrupted push before starting the next', (
    tester,
  ) async {
    await mount(tester, theme: TrainerTheme.playerV1);
    final oldCue = find.text(cues[0]);
    final secondCue = find.text(cues[1]);
    final thirdCue = find.text(cues[2]);
    final settledCenter = tester.getCenter(oldCue);

    await tester.drag(container, const Offset(-160, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(opacity(oldCue), 1);
    expect(opacity(secondCue), closeTo(.5, .002));

    await tester.drag(container, const Offset(-160, 0));
    await tester.pump();
    expect(oldCue, findsNothing);
    expect(opacity(secondCue), 1);
    expect(tester.getCenter(secondCue), settledCenter);
    expect(opacity(thirdCue), 0);
    await tester.pump(const Duration(milliseconds: 320));
    expect(secondCue, findsNothing);
    expect(opacity(thirdCue), 1);
    expect(tester.getCenter(thirdCue), settledCenter);
    await clean(tester);
  });

  testWidgets('V1 enlarges the card over 320 ms for a two-line caption', (
    tester,
  ) async {
    const short = 'First line';
    const twoLines = 'Keep breathing\nand stay balanced';
    Future<void> show(String caption) => mount(
      tester,
      preparing: true,
      prepCaption: caption,
      theme: TrainerTheme.playerV1,
    );
    await show(short);
    final cardElement = tester.element(container);
    final initial = tester.getSize(container);
    await show(twoLines);
    expect(tester.getSize(container), initial);
    await tester.pump(const Duration(milliseconds: 160));
    final halfway = tester.getSize(container);
    await tester.pump(const Duration(milliseconds: 160));
    final grown = tester.getSize(container);
    expect(halfway.height, inExclusiveRange(initial.height, grown.height));
    expect(halfway.width, initial.width);
    expect(grown.width, initial.width);
    expect(tester.element(container), same(cardElement));
    expect(find.text(short), findsNothing);
    expect(opacity(find.text(twoLines)), 1);
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: find.text(twoLines), matching: find.byType(RichText)),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    await clean(tester);
  });

  testWidgets('V1 reduced motion crossfades for 150 ms without shifting', (
    tester,
  ) async {
    await mount(tester, theme: TrainerTheme.playerV1, reduced: true);
    final oldCue = find.text(cues[0]);
    final newCue = find.text(cues[1]);
    final center = tester.getCenter(oldCue);
    await tester.drag(container, const Offset(-160, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 75));
    expect(tester.getCenter(oldCue), center);
    expect(tester.getCenter(newCue), center);
    expect(opacity(oldCue), closeTo(.5, .002));
    expect(opacity(newCue), closeTo(.5, .002));
    await tester.pump(const Duration(milliseconds: 75));
    expect(oldCue, findsNothing);
    expect(tester.getCenter(newCue), center);
    expect(opacity(newCue), 1);
    await clean(tester);
  });

  testWidgets('V1 balances the same protected phrase in prep and work', (
    tester,
  ) async {
    const caption = '第一个动作 半跪髋屈肌拉伸 每侧 40 秒 先做右边';
    const expected = '第一个动作 半跪髋屈肌拉伸\n每侧 40 秒 先做右边';
    for (final preparing in [true, false]) {
      await mount(
        tester,
        theme: TrainerTheme.playerV1,
        width: 340,
        steps: const [caption],
        preparing: preparing,
        prepCaption: caption,
      );
      await tester.pump(const Duration(milliseconds: 320));
      final displayed = tester.widget<Text>(text);
      expect(displayed.data, expected);
      expect(displayed.style!.height, 1.35);
      expect(displayed.textAlign, TextAlign.center);
    }
    await clean(tester);
  });

  testWidgets('V1 shrinks before adding a third line', (tester) async {
    Future<Text> display(double width) async {
      await mount(
        tester,
        theme: TrainerTheme.playerV1,
        preparing: true,
        prepCaption: 'AAAA BBBB CCCC',
        width: width,
      );
      await tester.pump(const Duration(milliseconds: 320));
      return tester.widget<Text>(text);
    }

    final smaller = await display(174);
    expect(smaller.style!.fontSize, 15);
    expect(smaller.data!.split('\n'), hasLength(2));
    final taller = await display(145);
    expect(taller.style!.fontSize, 15);
    expect(taller.data, 'AAAA\nBBBB\nCCCC');
    expect(taller.maxLines, 3);
    await clean(tester);
  });

  testWidgets('V1 splits an oversized unbroken fragment without an orphan', (
    tester,
  ) async {
    const caption = '甲乙丙丁戊己庚辛壬癸';
    await mount(
      tester,
      theme: TrainerTheme.playerV1,
      preparing: true,
      prepCaption: caption,
      width: 135,
    );
    final displayed = tester.widget<Text>(text);
    final lines = displayed.data!.split('\n');
    expect(lines, hasLength(2));
    expect(lines.join(), caption);
    expect(lines.last.characters.length, greaterThanOrEqualTo(3));
    await clean(tester);
  });

  testWidgets('preparation resets and pins the first step, including swipes', (
    tester,
  ) async {
    await mount(tester);
    await tester.pump(const Duration(milliseconds: 4500));
    await tester.pump(const Duration(milliseconds: 221));
    expect(find.text(cues[1]), findsOneWidget);
    await mount(tester, preparing: true);
    await tester.pump(const Duration(milliseconds: 221));
    expect(find.text(cues[0]), findsOneWidget);
    await tester.drag(container, const Offset(-160, 0));
    await tester.pump(const Duration(seconds: 20));
    expect(find.text(cues[0]), findsOneWidget);
    expect(find.text(cues[1]), findsNothing);
    await mount(tester);
    await tester.pump(const Duration(milliseconds: 4500));
    await tester.pump(const Duration(milliseconds: 221));
    expect(find.text(cues[1]), findsOneWidget);
    await clean(tester);
  });

  testWidgets(
    'expands full steps and separate cautions in a half-height sheet',
    (tester) async {
      final expanded = <bool>[];
      await mount(
        tester,
        steps: const ['放松肩颈。；保持均匀呼吸'],
        precautions: const ['不强迫手触地。'],
        onExpandedChanged: expanded.add,
      );
      await tester.tap(container);
      await tester.pumpAndSettle();
      expect(expanded, [true]);
      final sheet = find.byKey(const ValueKey('trainer-cue-sheet'));
      expect(tester.getSize(sheet).height, 400);
      expect(
        find.descendant(of: sheet, matching: find.text('怎么做')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('保持均匀呼吸')),
        findsOneWidget,
      );
      final precaution = find.byKey(const ValueKey('trainer-cue-precautions'));
      expect(
        find.descendant(of: precaution, matching: find.text('不强迫手触地')),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 10));
      final behindSheet = tester.widgetList<Text>(text).single;
      expect(behindSheet.data, '放松肩颈');
      await tester.tap(find.byKey(const ValueKey('trainer-cue-sheet-close')));
      await tester.pumpAndSettle();
      expect(expanded, [true, false]);
      expect(sheet, findsNothing);
      await clean(tester);
    },
  );

  testWidgets('shrinks a two-line cue to 14 before introducing extra slides', (
    tester,
  ) async {
    await mount(tester, width: 260, steps: const ['123456789012345678901234']);
    expect(tester.widget<Text>(text).style!.fontSize, 14);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('trainer-cue-count'))).data,
      '1/1',
    );
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: text, matching: find.byType(RichText)),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    await clean(tester);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('long copy stays readable without ellipses at scale $scale', (
      tester,
    ) async {
      const original = '双脚与肩同宽慢慢向前弯曲，保持背部自然舒展不要突然用力，慢慢回到起始位置';
      await mount(tester, width: 220, scale: scale, steps: const [original]);
      final total = int.parse(
        tester
            .widget<Text>(find.byKey(const ValueKey('trainer-cue-count')))
            .data!
            .split('/')
            .last,
      );
      expect(total, greaterThan(1));
      final collected = <String>[];
      for (var index = 0; index < total; index++) {
        final current = tester.widget<Text>(text);
        expect(current.overflow, isNot(TextOverflow.ellipsis));
        expect(current.maxLines, 2);
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: text, matching: find.byType(RichText)),
        );
        expect(paragraph.didExceedMaxLines, isFalse);
        collected.add(current.data!);
        await tester.drag(container, const Offset(-120, 0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 221));
      }
      expect(
        collected.join().replaceAll('，', ''),
        original.replaceAll('，', ''),
      );
      expect(tester.takeException(), isNull);
      await clean(tester);
    });
  }

  testWidgets('changed content resets to its own first step', (tester) async {
    await mount(tester);
    await tester.drag(container, const Offset(-160, 0));
    await tester.pumpAndSettle();
    await mount(tester, steps: const ['新的第一个步骤', '新的第二个步骤']);
    await tester.pumpAndSettle();
    expect(find.text('新的第一个步骤'), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget);
    await clean(tester);
  });

  testWidgets('reduced motion changes content without an animated remnant', (
    tester,
  ) async {
    await mount(tester, reduced: true);
    await tester.drag(container, const Offset(-160, 0));
    await tester.pump();
    expect(find.text(cues[0]), findsNothing);
    expect(find.text(cues[1]), findsOneWidget);
    await clean(tester);
  });

  testWidgets('empty or punctuation-only copy has no tappable empty card', (
    tester,
  ) async {
    await mount(tester, steps: const ['；。；']);
    expect(container, findsNothing);
    await clean(tester);
    await tester.pump(const Duration(seconds: 20));
    expect(tester.takeException(), isNull);
  });
}
