import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

class _FocusHost extends StatefulWidget {
  const _FocusHost({
    super.key,
    this.title,
    this.dark = false,
    this.reduced = false,
    this.bottomGap = 0,
    this.style,
    this.clearEnabled = true,
  });

  final String? title;
  final bool dark, reduced, clearEnabled;
  final double bottomGap;
  final CoachUiStyle? style;

  @override
  State<_FocusHost> createState() => _FocusHostState();
}

class _FocusHostState extends State<_FocusHost> {
  late String? title = widget.title;
  var clears = 0;

  void setTitle(String? next) => setState(() => title = next);

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData(
      brightness: widget.dark ? Brightness.dark : Brightness.light,
      fontFamily: 'HostFont',
    ),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: widget.reduced),
      child: child!,
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => CoachUiTheme(
          style: widget.style ?? CoachUiStyle.fromTheme(Theme.of(context)),
          child: Align(
            alignment: Alignment.topLeft,
            child: PlanFocusLabel(
              title: title,
              bottomGap: widget.bottomGap,
              icon: Icons.star_outline,
              clearIcon: Icons.cancel_outlined,
              onClear: widget.clearEnabled
                  ? () {
                      clears++;
                      setTitle(null);
                    }
                  : null,
            ),
          ),
        ),
      ),
    ),
  );
}

Future<GlobalKey<_FocusHostState>> _show(
  WidgetTester tester, {
  String? title,
  bool dark = false,
  bool reduced = false,
  double bottomGap = 0,
  CoachUiStyle? style,
  bool clearEnabled = true,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final host = GlobalKey<_FocusHostState>();
  await tester.pumpWidget(
    _FocusHost(
      key: host,
      title: title,
      dark: dark,
      reduced: reduced,
      bottomGap: bottomGap,
      style: style,
      clearEnabled: clearEnabled,
    ),
  );
  await tester.pumpAndSettle();
  return host;
}

Finder get _label => find.byKey(const ValueKey('plan-focus-label'));
Finder get _clear => find.byKey(const ValueKey('plan-focus-clear'));
double _opacity(WidgetTester tester) => tester
    .widget<FadeTransition>(find.byKey(const ValueKey('plan-focus-visibility')))
    .opacity
    .value;
double _offset(WidgetTester tester) => tester
    .widget<Transform>(find.byKey(const ValueKey('plan-focus-motion')))
    .transform
    .storage[13];

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'focus preserves approved geometry and ${dark ? 'dark' : 'light'} tokens',
      (tester) async {
        const title = '一份名称很长很长很长很长很长很长很长的已保存训练计划';
        await _show(tester, title: title, dark: dark);
        final context = tester.element(_label);
        final colors = CoachUiTheme.of(context).colors;
        final label = tester.widget<Container>(_label);
        final decoration = label.decoration! as BoxDecoration;
        expect(tester.getSize(_label).height, 28);
        expect(tester.getSize(_label).width, lessThanOrEqualTo(350));
        expect(label.padding, const EdgeInsets.only(left: 10, right: 4));
        expect(decoration.borderRadius, BorderRadius.circular(14));
        expect(decoration.border, isNull);
        expect(
          decoration.color,
          colors.taskAccent.withValues(alpha: dark ? .18 : .10),
        );
        final text = tester.widget<Text>(find.text('正在讨论：$title'));
        expect(text.style!.fontSize, 13);
        expect(text.style!.fontWeight, FontWeight.w500);
        expect(text.style!.height, 1.4);
        expect(text.style!.color, colors.taskAccent);
        expect(text.maxLines, 1);
        expect(text.overflow, TextOverflow.ellipsis);
        final rendered = tester.widget<RichText>(
          find.descendant(
            of: find.text('正在讨论：$title'),
            matching: find.byType(RichText),
          ),
        );
        expect(rendered.text.style!.fontFamily, 'HostFont');
        expect(
          rendered.text.style!.letterSpacing,
          Theme.of(context).textTheme.bodyMedium!.letterSpacing,
        );
        final bookmark = tester.widget<Icon>(find.byIcon(Icons.star_outline));
        final close = tester.widget<Icon>(find.byIcon(Icons.cancel_outlined));
        expect(bookmark.size, 14);
        expect(bookmark.color, colors.taskAccent);
        expect(close.size, 14);
        expect(close.color, colors.taskMuted);
        expect(tester.getSize(_clear), const Size(28, 28));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('focus enters with 180ms fade and 8px upward motion', (
    tester,
  ) async {
    final host = await _show(tester);
    expect(_label, findsNothing);
    host.currentState!.setTitle('晨间舒展');
    await tester.pump();
    expect(_opacity(tester), 0);
    expect(_offset(tester), 8);
    final motion =
        tester
                .widget<FadeTransition>(
                  find.byKey(const ValueKey('plan-focus-visibility')),
                )
                .opacity
            as CurvedAnimation;
    expect(motion.curve, Curves.easeOutCubic);
    expect(motion.reverseCurve, Curves.easeInCubic);
    expect(
      (motion.parent as AnimationController).duration,
      const Duration(milliseconds: 180),
    );
    expect(
      (motion.parent as AnimationController).reverseDuration,
      const Duration(milliseconds: 120),
    );
    await tester.pump(const Duration(milliseconds: 90));
    expect(_opacity(tester), inExclusiveRange(0, 1));
    expect(_offset(tester), inExclusiveRange(0, 8));
    await tester.pump(const Duration(milliseconds: 90));
    expect(_opacity(tester), 1);
    expect(_offset(tester), 0);
  });

  testWidgets('focus title crossfades in the same label for 150ms', (
    tester,
  ) async {
    final host = await _show(tester, title: '原计划');
    final state = tester.state(find.byType(PlanFocusLabel));
    host.currentState!.setTitle('新版计划');
    await tester.pump();
    expect(tester.state(find.byType(PlanFocusLabel)), same(state));
    expect(find.text('正在讨论：原计划'), findsOneWidget);
    expect(find.text('正在讨论：新版计划'), findsOneWidget);
    expect(
      tester
          .widget<AnimatedSwitcher>(
            find.byKey(const ValueKey('plan-focus-title')),
          )
          .duration,
      const Duration(milliseconds: 150),
    );
    await tester.pump(const Duration(milliseconds: 75));
    final fades = tester.widgetList<FadeTransition>(
      find.descendant(
        of: find.byKey(const ValueKey('plan-focus-title')),
        matching: find.byType(FadeTransition),
      ),
    );
    expect(fades, hasLength(2));
    for (final fade in fades) {
      expect(fade.opacity.value, inExclusiveRange(0, 1));
    }
    await tester.pumpAndSettle();
    expect(find.text('正在讨论：原计划'), findsNothing);
    expect(_opacity(tester), 1);
  });

  testWidgets('clear retains label and bottom gap through 120ms exit', (
    tester,
  ) async {
    final host = await _show(tester, title: '晚间计划', bottomGap: 8);
    expect(tester.getSize(find.byType(PlanFocusLabel)).height, 36);
    await tester.tap(_clear);
    await tester.pump();
    expect(host.currentState!.clears, 1);
    expect(host.currentState!.title, isNull);
    expect(_opacity(tester), 1);
    expect(tester.getSize(find.byType(PlanFocusLabel)).height, 36);
    await tester.pump(const Duration(milliseconds: 60));
    expect(_opacity(tester), inExclusiveRange(0, 1));
    expect(_offset(tester), 0);
    await tester.pump(const Duration(milliseconds: 60));
    expect(_opacity(tester), 0);
    await tester.pump(const Duration(milliseconds: 1));
    expect(_label, findsNothing);
    expect(tester.getSize(find.byType(PlanFocusLabel)).height, 0);
  });

  testWidgets('reduced motion updates focus without pending ticker', (
    tester,
  ) async {
    final host = await _show(tester, reduced: true);
    host.currentState!.setTitle('计划');
    await tester.pumpAndSettle();
    expect(_opacity(tester), 1);
    await tester.tap(_clear);
    await tester.pumpAndSettle();
    expect(_label, findsNothing);
    expect(host.currentState!.clears, 1);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('host controls copy, palette and clear semantics', (
    tester,
  ) async {
    final base = CoachUiStyle.fromTheme(ThemeData.light());
    await _show(
      tester,
      title: 'Morning',
      style: CoachUiStyle(
        colors: base.colors.copyWith(
          taskAccent: Colors.purple,
          taskChipSurface: Colors.yellow,
        ),
        typography: base.typography,
        strings: CoachUiStrings(
          planFocusTitle: (title) => 'Discussing: $title',
          clearPlanFocus: 'Clear focus',
        ),
      ),
    );
    expect(find.text('Discussing: Morning'), findsOneWidget);
    expect(find.bySemanticsLabel('Clear focus'), findsOneWidget);
    final decoration =
        tester.widget<Container>(_label).decoration! as BoxDecoration;
    expect(decoration.color, Colors.yellow);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.star_outline)).color,
      Colors.purple,
    );
  });

  testWidgets('disabled clear does not call host', (tester) async {
    final host = await _show(tester, title: '计划', clearEnabled: false);
    await tester.tap(_clear);
    await tester.pump();
    expect(host.currentState!.clears, 0);
    expect(host.currentState!.title, '计划');
  });

  testWidgets(
    'press uses original scale and release timing; keyboard activates once',
    (tester) async {
      final host = await _show(tester, title: '计划');
      final gesture = await tester.startGesture(tester.getCenter(_clear));
      await tester.pump(const Duration(milliseconds: 100));
      final press = tester.widget<AnimatedScale>(
        find.descendant(of: _clear, matching: find.byType(AnimatedScale)),
      );
      expect(press.scale, .97);
      expect(press.duration, const Duration(milliseconds: 100));
      await gesture.cancel();
      await tester.pump();
      final release = tester.widget<AnimatedScale>(
        find.descendant(of: _clear, matching: find.byType(AnimatedScale)),
      );
      expect(release.scale, 1);
      expect(release.duration, const Duration(milliseconds: 180));
      final focus = tester.element(
        find.descendant(of: _clear, matching: find.byType(GestureDetector)),
      );
      Focus.of(focus).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(host.currentState!.clears, 1);
    },
  );

  testWidgets('empty focus never creates a late ticker on disposal', (
    tester,
  ) async {
    await _show(tester, title: '  ');
    expect(_label, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
  });
}
