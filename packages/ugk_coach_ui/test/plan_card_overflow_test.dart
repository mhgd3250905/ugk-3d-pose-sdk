import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

const _longDose = '每侧完成十二次缓慢下放，最低位置停留三秒，再平稳回到起始位置';
const _circuitDose = '每轮每侧十二次，缓慢下放三秒，完成后休息三十秒，共循环四轮';
const _segmentsDose = '第一段每侧八次并停留两秒；第二段保持三十秒；第三段每侧十二次';

CoachRoutine _routine(List<String> doses) => CoachRoutine(
  id: 'overflow',
  title: '训练套路',
  items: [
    for (var i = 0; i < doses.length; i++)
      CoachRoutineItem(
        exerciseId: 'exercise-$i',
        dose: '紧凑剂量$i',
        detailDose: doses[i],
      ),
  ],
  durationLabel: '20 分钟',
  gearLabel: '徒手',
  levelLabel: '入门',
  metaLabel: '3 个动作',
);

CoachExerciseLibrary _library(int count, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return CoachExerciseLibrary([
    for (var i = 0; i < count; i++)
      CoachExercise(
        id: 'exercise-$i',
        name: '训练动作${i + 1}',
        poster: 'missing-test-poster-$i',
        stage: CoachMediaPalette(
          mediaStage: dark ? Colors.black : Colors.white,
          onStage: dark ? Colors.white : Colors.black,
          onStageMuted: Colors.grey,
        ),
      ),
  ]);
}

Future<void> _mount(
  WidgetTester tester, {
  required Brightness brightness,
  required List<String> doses,
  double width = 320,
  double? parentWidth,
  double scale = 2,
  bool reduced = false,
}) async {
  tester.view.physicalSize = Size(width, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final theme = ThemeData(
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.green,
      brightness: brightness,
    ),
  );
  final style = CoachUiStyle(
    colors: CoachUiColors.fromTheme(theme),
    typography: const CoachUiTypography(
      body: TextStyle(fontSize: 16, height: 1.5),
      callout: TextStyle(fontSize: 16, height: 1.3),
      label: TextStyle(fontSize: 13, height: 1.25),
      caption: TextStyle(fontSize: 12, height: 1.35),
      greeting: TextStyle(fontSize: 24, height: 1.2),
    ),
    strings: const CoachUiStrings(
      expand: '展开',
      collapse: '收起',
      expandDetails: '展开详情',
      collapseDetails: '收起详情',
      save: '保存',
      saved: '已保存',
      start: '开始训练',
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: reduced,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: parentWidth,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: CoachUiTheme(
                  style: style,
                  child: CoachPlanCard(
                    plan: _routine(doses),
                    library: _library(doses.length, brightness),
                    saved: false,
                    onStart: (_) {},
                    onSave: () {},
                    onOpen: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Finder _row(int i) => find.byKey(ValueKey('plan-row-$i'));

Finder _dose(int i, String text) =>
    find.descendant(of: _row(i), matching: find.text(text));

Rect _thumbRect(WidgetTester tester, int i) {
  final thumb = find.descendant(
    of: _row(i),
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is SizedBox && widget.width == 40 && widget.height == 40,
    ),
  );
  return tester.getRect(thumb.first);
}

Rect? _flyerRect(WidgetTester tester, String key) {
  final finder = find.byKey(ValueKey(key));
  if (finder.evaluate().isEmpty) return null;
  return tester.getRect(
    find.descendant(of: finder, matching: find.byType(ClipRRect)).first,
  );
}

double _textOpacity(WidgetTester tester, int i) => tester
    .widget<FadeTransition>(
      find.descendant(
        of: _row(i),
        matching: find.byKey(const ValueKey('row-text')),
      ),
    )
    .opacity
    .value;

void _expectAnimationFrame(WidgetTester tester, int rows) {
  expect(tester.takeException(), isNull);
  final flyers = [
    ?_flyerRect(tester, 'fly-hero'),
    for (var k = 0; k < rows; k++) ?_flyerRect(tester, 'fly-$k'),
  ];
  for (var i = 0; i < rows; i++) {
    if (_row(i).evaluate().isEmpty || _textOpacity(tester, i) <= 0) continue;
    final text = tester.getRect(
      find.descendant(
        of: _row(i),
        matching: find.byKey(const ValueKey('row-text')),
      ),
    );
    for (final flyer in flyers) {
      expect(
        flyer.deflate(.5).overlaps(text),
        isFalse,
        reason: 'flying media overlaps visible row $i text',
      );
    }
  }
  final header = find.byKey(const ValueKey('plan-header-fade'));
  if (header.evaluate().isNotEmpty &&
      tester.widget<FadeTransition>(header).opacity.value > 0) {
    final text = tester.getRect(
      find.descendant(of: header, matching: find.byType(Column)).first,
    );
    for (final flyer in flyers) {
      expect(
        flyer.deflate(.5).overlaps(text),
        isFalse,
        reason: 'flying media overlaps visible header text',
      );
    }
  }
}

Future<void> _frames(WidgetTester tester, int count, int rows) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
    _expectAnimationFrame(tester, rows);
  }
}

void _expectSameRect(Rect actual, Rect expected) {
  expect(actual.left, closeTo(expected.left, .01));
  expect(actual.top, closeTo(expected.top, .01));
  expect(actual.width, closeTo(expected.width, .01));
  expect(actual.height, closeTo(expected.height, .01));
}

void _expectDosesUnclipped(
  WidgetTester tester,
  List<String> doses, {
  required double scale,
}) {
  final card = tester.getRect(find.byType(CoachPlanCard));
  for (var i = 0; i < doses.length; i++) {
    final finder = _dose(i, doses[i]);
    expect(finder, findsOneWidget);
    final widget = tester.widget<Text>(finder);
    expect(widget.data, doses[i]);
    expect(widget.maxLines, isNull);
    expect(widget.overflow, isNot(TextOverflow.ellipsis));
    expect(widget.softWrap, isNot(false));
    expect(widget.style!.fontSize, 13);
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: finder, matching: find.byType(RichText)),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(paragraph.textScaler.scale(13), closeTo(13 * scale, .001));
    final textRect = tester.getRect(finder);
    final rowRect = tester.getRect(_row(i));
    expect(textRect.left, greaterThanOrEqualTo(rowRect.left));
    expect(textRect.right, lessThanOrEqualTo(rowRect.right + .01));
    expect(textRect.top, greaterThanOrEqualTo(rowRect.top - .01));
    expect(textRect.bottom, lessThanOrEqualTo(rowRect.bottom + .01));
    expect(textRect.right, lessThanOrEqualTo(card.right + .01));
    expect(rowRect.bottom, lessThanOrEqualTo(card.bottom + .01));
    expect(_thumbRect(tester, i).center.dy, closeTo(rowRect.center.dy, .01));
    expect(rowRect.height, greaterThan(48));
    expect(textRect.height, greaterThan(13 * scale * 1.25));
    if (i > 0) {
      expect(
        rowRect.top,
        greaterThanOrEqualTo(tester.getRect(_row(i - 1)).bottom - .01),
      );
    }
  }
  expect(tester.takeException(), isNull);
}

void main() {
  for (final brightness in Brightness.values) {
    for (final (label, text) in [
      ('long Chinese dose', _longDose),
      ('circuit detail dose', _circuitDose),
      ('segmented detail dose', _segmentsDose),
    ]) {
      testWidgets(
        '320px 2x ${brightness.name}: $label wraps without clipping',
        (tester) async {
          final doses = [text, '$text，左右两侧交替进行', '$text，最后保持呼吸平稳'];
          await _mount(tester, brightness: brightness, doses: doses);
          await tester.tap(find.byKey(const ValueKey('plan-expand-overflow')));
          await tester.pumpAndSettle();
          _expectDosesUnclipped(tester, doses, scale: 2);
        },
      );
    }

    testWidgets(
      '320px 2x ${brightness.name}: dynamic rows and flying media stay aligned',
      (tester) async {
        final doses = [
          _longDose,
          '$_circuitDose；$_segmentsDose',
          '$_segmentsDose；$_longDose；$_circuitDose',
        ];
        await _mount(tester, brightness: brightness, doses: doses);
        final toggle = find.byKey(const ValueKey('plan-expand-overflow'));
        final card = find.byType(CoachPlanCard);
        expect(tester.getSize(card).height, CoachPlanCard.setHeight);
        await tester.tap(toggle);
        await tester.pump();
        final growingHeights = <double>[];
        // At 512ms every flyer is at its destination, before its replacement
        // by the row thumbnail at the controller's 550ms endpoint.
        for (var frame = 0; frame < 32; frame++) {
          await _frames(tester, 1, doses.length);
          growingHeights.add(tester.getSize(card).height);
        }
        _expectSameRect(_flyerRect(tester, 'fly-hero')!, _thumbRect(tester, 0));
        _expectSameRect(_flyerRect(tester, 'fly-0')!, _thumbRect(tester, 1));
        await tester.pumpAndSettle();
        _expectDosesUnclipped(tester, doses, scale: 2);
        final rows = [
          for (var i = 0; i < doses.length; i++) tester.getRect(_row(i)),
        ];
        expect(rows[1].height, greaterThan(rows[0].height));
        expect(rows[2].height, greaterThan(rows[1].height));
        final fullHeight = tester.getSize(card).height;
        for (var i = 1; i < growingHeights.length; i++) {
          expect(
            growingHeights[i],
            greaterThanOrEqualTo(growingHeights[i - 1]),
          );
        }
        expect(growingHeights.last, closeTo(fullHeight, .01));
        // Fold from rest: thumbnails begin exactly at the same measured rows.
        await tester.tap(toggle);
        await tester.pump();
        await _frames(tester, 1, doses.length);
        _expectSameRect(_flyerRect(tester, 'fly-hero')!, _thumbRect(tester, 0));
        _expectSameRect(_flyerRect(tester, 'fly-0')!, _thumbRect(tester, 1));
        await _frames(tester, 30, doses.length);
        await tester.pumpAndSettle();
        expect(tester.getSize(card).height, CoachPlanCard.setHeight);
        // Reverse an in-flight expansion. Natural row geometry must not be
        // remeasured from the current clipped card height or stale 48px slots.
        await tester.tap(toggle);
        await tester.pump();
        await _frames(tester, 27, doses.length);
        await tester.tap(toggle);
        await tester.pump();
        await _frames(tester, 30, doses.length);
        await tester.pumpAndSettle();
        expect(tester.getSize(card).height, CoachPlanCard.setHeight);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.getSize(card).height, closeTo(fullHeight, .01));
        _expectDosesUnclipped(tester, doses, scale: 2);
        // Reverse a collapse after its media has started travelling back.
        // This exercises the separate collapse choreography, not only a
        // backwards expansion curve.
        await tester.tap(toggle);
        await tester.pump();
        await _frames(tester, 16, doses.length);
        await tester.tap(toggle);
        await tester.pump();
        await _frames(tester, 40, doses.length);
        await tester.pumpAndSettle();
        expect(tester.getSize(card).height, closeTo(fullHeight, .01));
        _expectDosesUnclipped(tester, doses, scale: 2);
      },
    );

    testWidgets(
      '400px viewport 320px parent 2x ${brightness.name}: uses parent constraints',
      (tester) async {
        final doses = [_longDose, _circuitDose, _segmentsDose];
        await _mount(
          tester,
          brightness: brightness,
          doses: doses,
          width: 400,
          parentWidth: 320,
        );
        await tester.tap(find.byKey(const ValueKey('plan-expand-overflow')));
        await tester.pump();
        await _frames(tester, 32, doses.length);
        _expectSameRect(_flyerRect(tester, 'fly-hero')!, _thumbRect(tester, 0));
        _expectSameRect(_flyerRect(tester, 'fly-0')!, _thumbRect(tester, 1));
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byType(CoachPlanCard)).width, 288);
        _expectDosesUnclipped(tester, doses, scale: 2);
      },
    );

    testWidgets(
      '320px 2x ${brightness.name}: reduced motion keeps full doses',
      (tester) async {
        final doses = [_longDose, _circuitDose, _segmentsDose];
        await _mount(
          tester,
          brightness: brightness,
          doses: doses,
          reduced: true,
        );
        await tester.tap(find.byKey(const ValueKey('plan-expand-overflow')));
        await tester.pumpAndSettle();
        _expectDosesUnclipped(tester, doses, scale: 2);
        expect(find.byKey(const ValueKey('fly-hero')), findsNothing);
        expect(find.byKey(const ValueKey('fly-0')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('plan-expand-overflow')));
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byType(CoachPlanCard)).height, 240);
      },
    );
  }

  testWidgets(
    '390px 1x: existing compact and short-dose row heights stay fixed',
    (tester) async {
      await _mount(
        tester,
        brightness: Brightness.light,
        doses: const ['12 次', '20 秒', '每侧 8 次'],
        width: 390,
        scale: 1,
      );
      final toggle = find.byKey(const ValueKey('plan-expand-overflow'));
      expect(tester.getSize(find.byType(CoachPlanCard)).height, 240);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        expect(tester.getSize(_row(i)).height, 48);
      }
      expect(tester.takeException(), isNull);
    },
  );
}
