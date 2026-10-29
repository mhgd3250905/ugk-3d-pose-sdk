import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

const _longDose = '每侧完成十二次缓慢下放，最低位置停留三秒，再平稳回到起始位置，完成后保持均匀呼吸';

CoachRoutine _routine({bool changed = false, bool longDose = false}) =>
    CoachRoutine(
      id: 'export',
      title: changed ? '更新计划' : '训练计划',
      items: [
        CoachRoutineItem(
          exerciseId: changed ? 'c' : 'a',
          dose: '紧凑剂量',
          detailDose: longDose ? _longDose : '每侧 8 次 · 共 2 组',
        ),
        if (!changed)
          const CoachRoutineItem(
            exerciseId: 'b',
            dose: '30 秒',
            detailDose: '保持 30 秒 · 共 3 组',
          ),
      ],
      durationLabel: '6 分钟',
      gearLabel: '徒手',
      levelLabel: '入门',
      metaLabel: changed ? '1 个动作' : '2 个动作',
      adjustmentsLabel: '按舒适幅度完成',
    );

final _library = CoachExerciseLibrary([
  for (final (id, name) in [('a', '训练动作甲'), ('b', '训练动作乙'), ('c', '更新后的动作')])
    CoachExercise(
      id: id,
      name: name,
      poster: '$id-poster.webp',
      cutout: '$id-motion.webp',
      stillCutout: '$id-still.webp',
      stage: const CoachMediaPalette(
        mediaStage: Colors.white,
        onStage: Colors.black,
        onStageMuted: Colors.grey,
      ),
    ),
]);

class _Fixture {
  _Fixture({
    bool expanded = true,
    CoachRoutine? plan,
    this.actionEnabled = true,
    this.actionIcon = CoachGlyph.bookmark,
    this.actionLabel,
  }) : expanded = ValueNotifier(expanded),
       plan = ValueNotifier(plan ?? _routine());

  final ValueNotifier<bool> expanded;
  final ValueNotifier<CoachRoutine> plan;
  final bool actionEnabled;
  final CoachGlyph actionIcon;
  final String? actionLabel;
  final mediaRequests = <CoachMediaRequest>[];
  int collapses = 0;
  int actions = 0;
  int starts = 0;
  Rect? startOrigin;

  Future<void> mount(
    WidgetTester tester, {
    double width = 390,
    double scale = 1,
    bool reduced = false,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1600);
    addTearDown(tester.view.reset);
    final theme = ThemeData(brightness: brightness);
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
        collapse: '收起',
        collapseDetails: '收起详情',
        save: '保存',
        start: '开始训练',
      ),
      builders: CoachUiBuilders(
        media: (context, request) {
          mediaRequests.add(request);
          return ColoredBox(
            key: ValueKey('export-media-${request.exercise.id}'),
            color: Theme.of(context).colorScheme.surface,
          );
        },
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
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: CoachUiTheme(
                style: style,
                child: ValueListenableBuilder<CoachRoutine>(
                  valueListenable: plan,
                  builder: (context, routine, _) =>
                      ValueListenableBuilder<bool>(
                        valueListenable: expanded,
                        builder: (context, open, _) => CoachPlanExpanded(
                          key: const ValueKey('public-expanded'),
                          plan: routine,
                          library: _library,
                          expanded: open,
                          onCollapse: () {
                            collapses++;
                            expanded.value = false;
                          },
                          actionIcon: actionIcon,
                          actionLabel: actionLabel,
                          onAction: actionEnabled ? () => actions++ : null,
                          onStart: (origin) {
                            starts++;
                            startOrigin = origin();
                          },
                        ),
                      ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    expanded.dispose();
    plan.dispose();
  }
}

Finder get _widget => find.byKey(const ValueKey('public-expanded'));
Finder get _collapse => find.byKey(const ValueKey('plan-expand-export'));
Finder get _action => find.byKey(const ValueKey('plan-save-export'));
Finder get _start => find.byKey(const ValueKey('plan-start-export'));
double _height(WidgetTester tester) => tester.getSize(_widget).height;
double _fade(WidgetTester tester) => tester
    .widget<FadeTransition>(find.byKey(const ValueKey('plan-expanded-fade')))
    .opacity
    .value;

void main() {
  testWidgets(
    'public export resolves the complete routine and still thumbnails',
    (tester) async {
      final fixture = _Fixture();
      await fixture.mount(tester);
      expect(find.byType(CoachPlanExpanded), findsOneWidget);
      for (final text in [
        '训练计划',
        '2 个动作',
        '训练动作甲',
        '训练动作乙',
        '每侧 8 次 · 共 2 组',
        '保持 30 秒 · 共 3 组',
        '1',
        '2',
        '按舒适幅度完成',
        '保存',
        '收起',
      ]) {
        expect(find.text(text), findsOneWidget, reason: text);
      }
      expect(
        find.text('紧凑剂量'),
        findsNothing,
        reason: 'expanded rows use detailDose',
      );
      expect(find.byKey(const ValueKey('export-media-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('export-media-b')), findsOneWidget);
      expect(fixture.mediaRequests.map((request) => request.asset).toSet(), {
        'a-still.webp',
        'b-still.webp',
      });
      expect(
        fixture.mediaRequests.every(
          (request) => request.still && request.cutout,
        ),
        isTrue,
      );
      expect(tester.widget<CoachTextAction>(_action).icon, CoachGlyph.bookmark);
      expect(tester.takeException(), isNull);
      await fixture.dispose(tester);
    },
  );

  testWidgets(
    'custom action, start origin and collapse callbacks are independent',
    (tester) async {
      final fixture = _Fixture(
        actionIcon: CoachGlyph.stop,
        actionLabel: '使用计划',
      );
      await fixture.mount(tester);
      expect(find.text('保存'), findsNothing);
      expect(tester.widget<CoachTextAction>(_action).icon, CoachGlyph.stop);
      await tester.tap(_action);
      expect(fixture.actions, 1);
      expect(fixture.starts, 0);
      expect(fixture.collapses, 0);
      await tester.tap(_start);
      expect(fixture.starts, 1);
      expect(fixture.startOrigin, isNotNull);
      expect(fixture.startOrigin!.isEmpty, isFalse);
      expect(fixture.actions, 1);
      await tester.tap(_collapse);
      await tester.pumpAndSettle();
      expect(fixture.collapses, 1);
      expect(_height(tester), 0);
      expect(fixture.actions, 1);
      expect(fixture.starts, 1);
      await fixture.dispose(tester);
    },
  );

  testWidgets('expansion owns a 280 ms cubic height and 180 ms fade', (
    tester,
  ) async {
    final fixture = _Fixture(expanded: false);
    await fixture.mount(tester);
    expect(_height(tester), 0);
    fixture.expanded.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(_fade(tester), closeTo(.5, .01));
    await tester.pump(const Duration(milliseconds: 50));
    final middle = _height(tester);
    await tester.pump(const Duration(milliseconds: 40));
    expect(_fade(tester), 1);
    await tester.pump(const Duration(milliseconds: 100));
    final full = _height(tester);
    expect(full, greaterThan(0));
    expect(middle / full, closeTo(Curves.easeOutCubic.transform(.5), .01));
    fixture.expanded.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    expect(
      _height(tester) / full,
      closeTo(1 - Curves.easeOutCubic.transform(.5), .01),
    );
    await tester.pump(const Duration(milliseconds: 140));
    expect(_height(tester), 0);
    expect(_fade(tester), 0);
    await fixture.dispose(tester);
  });

  testWidgets('collapsed content has no accessible or hittable actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final fixture = _Fixture(expanded: false);
    await fixture.mount(tester);
    expect(_start.hitTestable(), findsNothing);
    expect(_action.hitTestable(), findsNothing);
    expect(_collapse.hitTestable(), findsNothing);
    expect(find.bySemanticsLabel('开始训练'), findsNothing);
    expect(find.bySemanticsLabel('保存'), findsNothing);
    expect(find.bySemanticsLabel('收起详情'), findsNothing);
    await fixture.dispose(tester);
    semantics.dispose();
  });

  testWidgets('omitting the action callback keeps Save visibly disabled', (
    tester,
  ) async {
    final fixture = _Fixture(actionEnabled: false);
    await fixture.mount(tester);
    expect(find.text('保存'), findsOneWidget);
    expect(tester.widget<CoachTextAction>(_action).onPressed, isNull);
    await tester.tap(_action);
    expect(fixture.actions, 0);
    await tester.tap(_start);
    expect(fixture.starts, 1);
    await fixture.dispose(tester);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      '320px at 2x text keeps the full detail dose ${brightness.name}',
      (tester) async {
        final fixture = _Fixture(plan: _routine(longDose: true));
        await fixture.mount(
          tester,
          width: 320,
          scale: 2,
          brightness: brightness,
        );
        expect(find.text(_longDose), findsOneWidget);
        final text = tester.widget<Text>(find.text(_longDose));
        expect(text.maxLines, isNull);
        expect(text.overflow, TextOverflow.visible);
        final dose = tester.getRect(find.text(_longDose));
        final card = tester.getRect(_widget);
        expect(dose.left, greaterThanOrEqualTo(card.left));
        expect(dose.right, lessThanOrEqualTo(card.right));
        expect(dose.bottom, lessThanOrEqualTo(card.bottom));
        expect(dose.height, greaterThan(2 * 13));
        expect(tester.takeException(), isNull);
        await fixture.dispose(tester);
      },
    );
  }

  testWidgets(
    'data changes and interrupted reversals settle to the latest expanded value',
    (tester) async {
      final fixture = _Fixture(expanded: false);
      await fixture.mount(tester);
      fixture.expanded.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      fixture.expanded.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      fixture.plan.value = _routine(changed: true);
      fixture.expanded.value = true;
      await tester.pumpAndSettle();
      expect(_height(tester), greaterThan(0));
      expect(find.text('更新计划'), findsOneWidget);
      expect(find.text('更新后的动作'), findsOneWidget);
      expect(find.text('训练动作甲'), findsNothing);
      expect(find.text('训练动作乙'), findsNothing);
      expect(find.byKey(const ValueKey('plan-row-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('plan-row-1')), findsNothing);
      expect(tester.takeException(), isNull);
      await fixture.dispose(tester);
    },
  );

  testWidgets(
    'reduced motion reaches the requested endpoint without a height flight',
    (tester) async {
      final fixture = _Fixture(expanded: false);
      await fixture.mount(tester, reduced: true);
      fixture.expanded.value = true;
      await tester.pumpAndSettle();
      expect(_height(tester), greaterThan(0));
      expect(_fade(tester), 1);
      fixture.expanded.value = false;
      await tester.pumpAndSettle();
      expect(_height(tester), 0);
      expect(tester.takeException(), isNull);
      await fixture.dispose(tester);
    },
  );
}
