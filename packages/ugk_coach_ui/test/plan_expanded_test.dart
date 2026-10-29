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

class _HeaderProbe extends StatefulWidget {
  const _HeaderProbe({
    required this.onBuild,
    required this.onInit,
    required this.onDispose,
  });
  final VoidCallback onBuild, onInit, onDispose;
  @override
  State<_HeaderProbe> createState() => _HeaderProbeState();
}

class _HeaderProbeState extends State<_HeaderProbe> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) {
    widget.onBuild();
    return const SizedBox(
      key: ValueKey('test-header-slot'),
      height: 54,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text('Stable header'),
      ),
    );
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }
}

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
    this.slots = false,
    this.toggleEnabled = true,
    this.mutateOnToggle = true,
    this.summaryHeight = 48,
    this.toggleWithoutSlots = false,
  }) : expanded = ValueNotifier(expanded),
       plan = ValueNotifier(plan ?? _routine());

  final ValueNotifier<bool> expanded;
  final ValueNotifier<CoachRoutine> plan;
  final bool actionEnabled;
  final CoachGlyph actionIcon;
  final String? actionLabel;
  final bool slots, toggleEnabled, mutateOnToggle, toggleWithoutSlots;
  final double summaryHeight;
  int headerBuilds = 0, headerInits = 0, headerDisposals = 0;
  int toggles = 0;
  late final Widget header = _HeaderProbe(
    onBuild: () => headerBuilds++,
    onInit: () => headerInits++,
    onDispose: () => headerDisposals++,
  );
  late final Widget summary = SizedBox(
    key: const ValueKey('test-summary-slot'),
    height: summaryHeight,
    child: const Align(
      alignment: Alignment.centerLeft,
      child: Text('Collapsed summary'),
    ),
  );
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
                          header: slots ? header : null,
                          collapsedSummary: slots ? summary : null,
                          onToggle:
                              (slots || toggleWithoutSlots) && toggleEnabled
                              ? () {
                                  toggles++;
                                  if (mutateOnToggle) {
                                    expanded.value = !expanded.value;
                                  }
                                }
                              : null,
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

Finder get _headerSlot => find.byKey(const ValueKey('test-header-slot'));
Finder get _summarySlot => find.byKey(const ValueKey('test-summary-slot'));
Finder get _widget => find.byKey(const ValueKey('public-expanded'));
Finder get _collapse => find.byKey(const ValueKey('plan-expand-export'));
Finder get _action => find.byKey(const ValueKey('plan-save-export'));
Finder get _start => find.byKey(const ValueKey('plan-start-export'));
double _height(WidgetTester tester) => tester.getSize(_widget).height;
double _fade(WidgetTester tester) => tester
    .widget<FadeTransition>(find.byKey(const ValueKey('plan-expanded-fade')))
    .opacity
    .value;

double _slotFade(WidgetTester tester, String key) =>
    tester.widget<FadeTransition>(find.byKey(ValueKey(key))).opacity.value;

double _bodyY(WidgetTester tester) => tester
    .widget<Transform>(find.byKey(const ValueKey('plan-expanded-motion')))
    .transform
    .storage[13];

Finder get _shell =>
    find.descendant(of: _widget, matching: find.byType(CoachCardSurface));

Finder get _roundedContent => find.descendant(
  of: _widget,
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is ClipRRect && widget.borderRadius == BorderRadius.circular(20),
  ),
);

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'one opaque shell and clipped content survive toggling ${brightness.name}',
      (tester) async {
        final fixture = _Fixture(expanded: false, slots: true);
        await fixture.mount(tester, brightness: brightness);
        expect(_shell, findsOneWidget);
        expect(_roundedContent, findsOneWidget);
        final originalShell = tester.element(_shell);
        final decorated = tester.widget<DecoratedBox>(
          find
              .descendant(of: _shell, matching: find.byType(DecoratedBox))
              .first,
        );
        final decoration = decorated.decoration as BoxDecoration;
        expect(
          decoration.color,
          brightness == Brightness.light
              ? const Color(0xFFFFFFFF)
              : const Color(0xFF1A2324),
        );
        expect(decoration.borderRadius, BorderRadius.circular(20));
        final border = decoration.border! as Border;
        expect(border.top.width, 1);
        expect(
          border.top.color,
          brightness == Brightness.light
              ? const Color(0xFFE3E8E6)
              : const Color.from(alpha: .08, red: 1, green: 1, blue: 1),
        );
        expect(
          find.ancestor(
            of: _shell,
            matching: find.descendant(
              of: _widget,
              matching: find.byType(FadeTransition),
            ),
          ),
          findsNothing,
        );
        expect(
          find.ancestor(
            of: _shell,
            matching: find.descendant(
              of: _widget,
              matching: find.byType(Opacity),
            ),
          ),
          findsNothing,
        );
        fixture.expanded.value = true;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 90));
        expect(identical(originalShell, tester.element(_shell)), isTrue);
        expect(_shell, findsOneWidget);
        expect(_roundedContent, findsOneWidget);
        expect(
          find.ancestor(
            of: _shell,
            matching: find.descendant(
              of: _widget,
              matching: find.byType(FadeTransition),
            ),
          ),
          findsNothing,
        );
        await fixture.dispose(tester);
      },
    );
  }

  testWidgets(
    'header state, build count and position stay fixed for the whole transition',
    (tester) async {
      final fixture = _Fixture(expanded: false, slots: true);
      await fixture.mount(tester);
      final state = tester.state(find.byType(_HeaderProbe));
      final headerRect = tester.getRect(_headerSlot);
      final builds = fixture.headerBuilds;
      expect(fixture.headerInits, 1);
      expect(
        find.ancestor(
          of: _headerSlot,
          matching: find.descendant(
            of: _widget,
            matching: find.byType(FadeTransition),
          ),
        ),
        findsNothing,
      );
      expect(
        find.ancestor(
          of: _headerSlot,
          matching: find.descendant(
            of: _widget,
            matching: find.byType(AnimatedSize),
          ),
        ),
        findsNothing,
      );
      for (final expanded in [true, false, true]) {
        fixture.expanded.value = expanded;
        await tester.pump();
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 40));
          expect(tester.getRect(_headerSlot), headerRect);
          expect(
            identical(state, tester.state(find.byType(_HeaderProbe))),
            isTrue,
          );
          expect(fixture.headerBuilds, builds);
          expect(fixture.headerDisposals, 0);
        }
      }
      await fixture.dispose(tester);
      expect(fixture.headerDisposals, 1);
    },
  );

  testWidgets('header and collapsed summary each request a controlled toggle', (
    tester,
  ) async {
    final fixture = _Fixture(expanded: false, slots: true);
    await fixture.mount(tester);
    await tester.tap(_summarySlot);
    await tester.pumpAndSettle();
    expect(fixture.toggles, 1);
    expect(fixture.expanded.value, isTrue);
    expect(fixture.collapses, 0);
    expect(_summarySlot.hitTestable(), findsNothing);
    await tester.tap(_headerSlot);
    await tester.pumpAndSettle();
    expect(fixture.toggles, 2);
    expect(fixture.expanded.value, isFalse);
    await tester.tap(_headerSlot);
    await tester.pumpAndSettle();
    expect(fixture.toggles, 3);
    await tester.tap(_collapse);
    await tester.pumpAndSettle();
    expect(fixture.collapses, 1);
    expect(
      fixture.toggles,
      3,
      reason: 'collapse does not also invoke the header toggle',
    );
    expect(fixture.actions, 0);
    expect(fixture.starts, 0);
    final headerInk = find
        .ancestor(of: _headerSlot, matching: find.byType(InkWell))
        .first;
    expect(
      find.ancestor(of: headerInk, matching: _roundedContent),
      findsOneWidget,
    );
    await fixture.dispose(tester);
  });

  testWidgets(
    'summary and collapse use their separate 120 ms visibility windows',
    (tester) async {
      final fixture = _Fixture(expanded: false, slots: true);
      await fixture.mount(tester);
      expect(_slotFade(tester, 'plan-expanded-summary-fade'), 1);
      expect(_slotFade(tester, 'plan-expanded-collapse-fade'), 0);
      fixture.expanded.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        _slotFade(tester, 'plan-expanded-summary-fade'),
        inExclusiveRange(0, 1),
      );
      expect(
        _slotFade(tester, 'plan-expanded-collapse-fade'),
        inExclusiveRange(0, 1),
      );
      await tester.pump(const Duration(milliseconds: 60));
      expect(_slotFade(tester, 'plan-expanded-summary-fade'), 0);
      expect(_slotFade(tester, 'plan-expanded-collapse-fade'), 1);
      await tester.pump(const Duration(milliseconds: 160));
      fixture.expanded.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 159));
      expect(_slotFade(tester, 'plan-expanded-summary-fade'), 0);
      expect(_slotFade(tester, 'plan-expanded-collapse-fade'), 0);
      expect(_summarySlot.hitTestable(), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        _slotFade(tester, 'plan-expanded-summary-fade'),
        inExclusiveRange(0, 1),
      );
      await tester.pump(const Duration(milliseconds: 60));
      expect(_slotFade(tester, 'plan-expanded-summary-fade'), 1);
      expect(_summarySlot.hitTestable(), findsOneWidget);
      await fixture.dispose(tester);
    },
  );

  testWidgets('onToggle requests a change and the host still owns expanded', (
    tester,
  ) async {
    final fixture = _Fixture(
      expanded: false,
      slots: true,
      mutateOnToggle: false,
    );
    await fixture.mount(tester);
    final closed = _height(tester);
    await tester.tap(_headerSlot);
    await tester.pumpAndSettle();
    expect(fixture.toggles, 1);
    expect(fixture.expanded.value, isFalse);
    expect(_height(tester), closed);
    expect(_start.hitTestable(), findsNothing);
    fixture.expanded.value = true;
    await tester.pumpAndSettle();
    expect(_height(tester), greaterThan(closed));
    expect(_start.hitTestable(), findsOneWidget);
    await tester.tap(find.text('训练动作甲'));
    await tester.pump();
    expect(
      fixture.toggles,
      1,
      reason: 'the expanded list is not a toggle target',
    );
    await fixture.dispose(tester);
  });

  testWidgets('optional onToggle can be omitted while collapse still works', (
    tester,
  ) async {
    final fixture = _Fixture(
      expanded: false,
      slots: true,
      toggleEnabled: false,
    );
    await fixture.mount(tester);
    expect(tester.widget<CoachPlanExpanded>(_widget).onToggle, isNull);
    await tester.tap(_summarySlot, warnIfMissed: false);
    await tester.tap(_headerSlot, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(fixture.toggles, 0);
    expect(fixture.expanded.value, isFalse);
    fixture.expanded.value = true;
    await tester.pumpAndSettle();
    await tester.tap(_collapse);
    await tester.pumpAndSettle();
    expect(fixture.collapses, 1);
    expect(fixture.toggles, 0);
    expect(fixture.expanded.value, isFalse);
    await fixture.dispose(tester);
  });

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

  testWidgets(
    'body height animates for 280 ms while header and shell stay visible',
    (tester) async {
      final fixture = _Fixture(expanded: false, slots: true);
      await fixture.mount(tester);
      final closed = _height(tester);
      expect(closed, greaterThan(0));
      final headerRect = tester.getRect(_headerSlot);
      final size = tester.widget<AnimatedSize>(
        find.descendant(of: _widget, matching: find.byType(AnimatedSize)).first,
      );
      expect(size.duration, const Duration(milliseconds: 280));
      expect(size.curve, Curves.easeOutCubic);
      expect(size.alignment, Alignment.topCenter);
      fixture.expanded.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(_fade(tester), 0);
      await tester.pump(const Duration(milliseconds: 80));
      final middle = _height(tester);
      expect(_fade(tester), inExclusiveRange(0, 1));
      expect(tester.getRect(_headerSlot), headerRect);
      await tester.pump(const Duration(milliseconds: 100));
      expect(_fade(tester), 1);
      await tester.pump(const Duration(milliseconds: 40));
      final full = _height(tester);
      expect(full, greaterThan(closed));
      expect(
        (middle - closed) / (full - closed),
        closeTo(Curves.easeOutCubic.transform(.5), .02),
      );
      fixture.expanded.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(_fade(tester), 0);
      await tester.pump(const Duration(milliseconds: 160));
      expect(_height(tester), closeTo(closed, .01));
      expect(tester.getRect(_headerSlot), headerRect);
      await fixture.dispose(tester);
    },
  );

  testWidgets('expanded body waits 60 ms then enters from eight pixels above', (
    tester,
  ) async {
    final fixture = _Fixture(expanded: false, slots: true);
    await fixture.mount(tester);
    fixture.expanded.value = true;
    await tester.pump();
    expect(_bodyY(tester), -8);
    await tester.pump(const Duration(milliseconds: 60));
    expect(_bodyY(tester), -8);
    expect(_fade(tester), 0);
    await tester.pump(const Duration(milliseconds: 90));
    expect(_bodyY(tester), inExclusiveRange(-8, 0));
    expect(_fade(tester), closeTo(.5, .01));
    await tester.pump(const Duration(milliseconds: 90));
    expect(_bodyY(tester), 0);
    expect(_fade(tester), 1);
    fixture.expanded.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      _bodyY(tester),
      0,
      reason: 'collapse fades out without another slide',
    );
    expect(_fade(tester), inExclusiveRange(0, 1));
    await fixture.dispose(tester);
  });

  testWidgets(
    'transparent body actions are gated even inside a taller summary clip',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final fixture = _Fixture(
        expanded: false,
        slots: true,
        summaryHeight: 480,
      );
      await fixture.mount(tester);
      fixture.expanded.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(_fade(tester), 0);
      expect(
        tester.getRect(_widget).contains(tester.getCenter(_start)),
        isTrue,
        reason:
            'the hidden action is inside the visible clip, not merely clipped away',
      );
      expect(_start.hitTestable(), findsNothing);
      expect(_action.hitTestable(), findsNothing);
      expect(find.bySemanticsLabel('开始训练'), findsNothing);
      expect(find.bySemanticsLabel('保存'), findsNothing);
      await tester.tap(_start, warnIfMissed: false);
      await tester.tap(_action, warnIfMissed: false);
      expect(fixture.starts, 0);
      expect(fixture.actions, 0);
      expect(fixture.toggles, 0);
      await tester.pump(const Duration(milliseconds: 30));
      expect(_fade(tester), 0);
      expect(_start.hitTestable(), findsNothing);
      await tester.pump(const Duration(milliseconds: 60));
      expect(_fade(tester), greaterThan(0));
      expect(_start.hitTestable(), findsOneWidget);
      await tester.tap(_start);
      expect(fixture.starts, 1);
      await fixture.dispose(tester);
      semantics.dispose();
    },
  );

  testWidgets(
    'cached default header refreshes its collapse gate across toggles',
    (tester) async {
      final fixture = _Fixture(expanded: false, toggleWithoutSlots: true);
      await fixture.mount(tester);
      expect(_headerSlot, findsNothing);
      expect(_summarySlot, findsNothing);
      expect(find.text('训练计划'), findsOneWidget);
      final header = tester.widget(find.byKey(const ValueKey('plan-header')));
      for (var i = 0; i < 2; i++) {
        expect(_collapse.hitTestable(), findsNothing);
        await tester.tap(find.text('训练计划'));
        await tester.pumpAndSettle();
        expect(fixture.expanded.value, isTrue);
        expect(_collapse.hitTestable(), findsOneWidget);
        expect(
          tester.widget(find.byKey(const ValueKey('plan-header'))),
          same(header),
        );
        await tester.tap(_collapse);
        await tester.pumpAndSettle();
        expect(fixture.expanded.value, isFalse);
        expect(fixture.collapses, i + 1);
        expect(
          fixture.toggles,
          i + 1,
          reason: 'the cached collapse button must not bubble into onToggle',
        );
      }
      await fixture.dispose(tester);
    },
  );

  testWidgets('collapsed card keeps its header but hides expanded actions', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final fixture = _Fixture(expanded: false, slots: true);
    await fixture.mount(tester);
    expect(_height(tester), greaterThan(0));
    expect(_headerSlot.hitTestable(), findsOneWidget);
    expect(_summarySlot.hitTestable(), findsOneWidget);
    expect(_start.hitTestable(), findsNothing);
    expect(_action.hitTestable(), findsNothing);
    expect(_collapse.hitTestable(), findsNothing);
    expect(find.bySemanticsLabel('开始训练'), findsNothing);
    expect(find.bySemanticsLabel('保存'), findsNothing);
    expect(find.bySemanticsLabel('收起详情'), findsNothing);
    await fixture.dispose(tester);
    semantics.dispose();
  });

  testWidgets(
    'omitting slots preserves the expanded-only zero-height contract',
    (tester) async {
      final fixture = _Fixture(expanded: false);
      await fixture.mount(tester);
      expect(_height(tester), 0);
      expect(_shell, findsOneWidget);
      expect(
        find.ancestor(
          of: _shell,
          matching: find.descendant(
            of: _widget,
            matching: find.byType(FadeTransition),
          ),
        ),
        findsNothing,
      );
      final shell = tester.element(_shell);
      fixture.expanded.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(_fade(tester), 0);
      await tester.pump(const Duration(milliseconds: 180));
      expect(_fade(tester), 1);
      await tester.pump(const Duration(milliseconds: 40));
      expect(_height(tester), greaterThan(0));
      expect(identical(shell, tester.element(_shell)), isTrue);
      fixture.expanded.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(_fade(tester), 0);
      await tester.pump(const Duration(milliseconds: 160));
      expect(_height(tester), 0);
      expect(fixture.toggles, 0);
      await fixture.dispose(tester);
    },
  );

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
      expect(_fade(tester), 0);
      expect(tester.takeException(), isNull);
      await fixture.dispose(tester);
    },
  );
}
