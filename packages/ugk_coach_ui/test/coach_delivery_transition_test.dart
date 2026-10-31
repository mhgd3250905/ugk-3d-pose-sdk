import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

// All delivery scenarios from Sport-Helper@13c0bb4, with plain SDK UI data.

class _DeliveryHost extends StatefulWidget {
  const _DeliveryHost({super.key, this.reduced = false});
  final bool reduced;

  @override
  State<_DeliveryHost> createState() => _DeliveryHostState();
}

class _DeliveryHostState extends State<_DeliveryHost> {
  final navigator = GlobalKey<NavigatorState>();
  final theme = ThemeData.light();
  bool complete = false;
  late bool reduced = widget.reduced;
  bool preparing = true;
  bool successful = true;
  bool interrupted = false;
  bool tickers = true;
  bool cancelled = false;
  int epoch = 0;

  void deliver({bool success = true}) => setState(() {
    successful = success;
    preparing = false;
  });

  void interrupt() => setState(() => interrupted = true);
  void cancel() => setState(() => cancelled = true);
  void completeSdkOutput() => setState(() => complete = true);
  void reduce() => setState(() => reduced = true);
  void mute() => setState(() => tickers = false);
  void unmute() => setState(() => tickers = true);
  void replaceSession() => setState(() {
    epoch++;
    preparing = false;
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigator,
    theme: theme,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
      child: child!,
    ),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 300,
          child: cancelled
              ? const SizedBox(key: ValueKey('cancelled'))
              : TickerMode(
                  enabled: tickers,
                  child: CoachDeliveryTransition(
                    key: ValueKey('delivery-$epoch'),
                    preparing: preparing,
                    successful: successful,
                    interrupted: interrupted,
                    child: preparing
                        ? CoachTaskBubble(
                            key: const ValueKey('preparation'),
                            phase: complete ? 4 : 3,
                            status: complete ? '马上就好' : '最后检查一遍',
                            complete: complete,
                            waiting: true,
                            onCancel: cancel,
                          )
                        : const SizedBox(
                            key: ValueKey('delivered'),
                            height: 260,
                            child: Text('已写入的计划'),
                          ),
                  ),
                ),
        ),
      ),
    ),
  );
}

Finder _key(String key, {bool offstage = false}) =>
    find.byKey(ValueKey(key), skipOffstage: !offstage);

Future<_DeliveryHostState> _show(
  WidgetTester tester, {
  bool reduced = false,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  final host = GlobalKey<_DeliveryHostState>();
  await tester.pumpWidget(_DeliveryHost(key: host, reduced: reduced));
  await tester.pump();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  return host.currentState!;
}

double _heightFactor(WidgetTester tester) =>
    tester.widget<Align>(_key('coach-delivery-collapse')).heightFactor!;
double _opacity(WidgetTester tester) =>
    tester.widget<Opacity>(_key('coach-delivery-opacity')).opacity;

void main() {
  testWidgets(
    'success retains one bubble and reveals delivery at exactly 890ms',
    (tester) async {
      final host = await _show(tester);
      final bubble = find.byType(CoachTaskBubble);
      final originalState = tester.state(bubble);
      final before = tester.widget<CoachTaskBubble>(bubble);
      final height = tester
          .getSize(find.byType(CoachDeliveryTransition))
          .height;
      host.deliver();
      await tester.pump();
      final completed = tester.widget<CoachTaskBubble>(bubble);
      expect(tester.state(bubble), same(originalState));
      expect(completed.visualComplete, isTrue);
      expect(completed.waiting, before.waiting);
      expect(completed.title, before.title);
      expect(completed.status, before.status);
      expect(completed.phase, before.phase);
      expect(completed.parameters, same(before.parameters));
      expect(completed.picks, same(before.picks));
      expect(completed.cutoutFor, same(before.cutoutFor));
      expect(completed.complete, before.complete);
      expect(completed.onCancel, same(before.onCancel));
      expect(_key('delivered'), findsNothing);
      expect(_heightFactor(tester), 1);
      expect(find.byType(AnimatedCrossFade), findsNothing);
      expect(find.byType(AnimatedSize), findsNothing);
      await tester.pump(const Duration(milliseconds: 239));
      expect(_key('delivered'), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      expect(_key('generation-check'), findsOneWidget);
      expect(
        tester.getSize(_key('generation-cancel-target')),
        const Size(44, 44),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(_heightFactor(tester), 1);
      expect(_opacity(tester), 1);
      expect(
        tester.getSize(find.byType(CoachDeliveryTransition)).height,
        height,
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        _heightFactor(tester),
        closeTo(1 - Curves.easeOutCubic.transform(1 / 3), .0001),
      );
      expect(
        _opacity(tester),
        closeTo(1 - Curves.easeInCubic.transform(.5), .0001),
      );
      expect(TickerMode.valuesOf(tester.element(bubble)).enabled, isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      expect(_opacity(tester), 0);
      await tester.pump(const Duration(milliseconds: 99));
      expect(_key('delivered'), findsNothing);
      expect(TickerMode.valuesOf(tester.element(bubble)).enabled, isTrue);
      await tester.pump(const Duration(milliseconds: 1));
      expect(_key('delivered'), findsOneWidget);
      expect(bubble, findsNothing);
      expect(originalState.mounted, isFalse);
      expect(_key('generation-check'), findsNothing);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a first frame after 890ms cannot strand a collapsed preparation',
    (tester) async {
      final host = await _show(tester);
      host.deliver();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 906));
      expect(_key('delivered'), findsOneWidget);
      expect(find.byType(CoachTaskBubble), findsNothing);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failure retains the original 300ms crossfade without a success hold',
    (tester) async {
      final host = await _show(tester);
      host.completeSdkOutput();
      await tester.pump();
      expect(_key('generation-check'), findsNothing);
      final wrapper = find.byType(CoachDeliveryTransition);
      final height = tester.getSize(wrapper).height;
      host.deliver(success: false);
      await tester.pump();
      final fade = tester.widget<AnimatedCrossFade>(
        _key('coach-delivery-crossfade'),
      );
      expect(fade.duration, const Duration(milliseconds: 300));
      expect(fade.sizeCurve, Curves.easeOutCubic);
      expect(fade.crossFadeState, CrossFadeState.showSecond);
      expect(_key('delivered'), findsOneWidget);
      expect(tester.getSize(wrapper).height, height);
      final bubble = find.byType(CoachTaskBubble, skipOffstage: false);
      expect(tester.widget<CoachTaskBubble>(bubble).visualComplete, isFalse);
      expect(TickerMode.valuesOf(tester.element(bubble)).enabled, isFalse);
      expect(_key('generation-check'), findsNothing);
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        tester.getSize(wrapper).height,
        closeTo(
          height + (260 - height) * Curves.easeOutCubic.transform(.5),
          .001,
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.getSize(wrapper).height, 260);
      expect(_key('generation-check'), findsNothing);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancellation removes the preparation entry immediately', (
    tester,
  ) async {
    final host = await _show(tester);
    host.completeSdkOutput();
    await tester.pump();
    expect(_key('generation-check'), findsNothing);
    await tester.tap(_key('generation-cancel-target'));
    await tester.pump();
    expect(_key('cancelled'), findsOneWidget);
    expect(_key('delivered'), findsNothing);
    expect(find.byType(CoachDeliveryTransition), findsNothing);
    expect(find.byType(CoachTaskBubble), findsNothing);
    expect(_key('generation-check'), findsNothing);
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new round immediately finishes the previous visual delivery', (
    tester,
  ) async {
    final host = await _show(tester);
    final preparationState = tester.state(find.byType(CoachTaskBubble));
    host.deliver();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    host.interrupt();
    await tester.pump();
    expect(_key('delivered'), findsOneWidget);
    expect(find.byType(CoachTaskBubble), findsNothing);
    expect(preparationState.mounted, isFalse);
    await tester.pump(const Duration(seconds: 2));
    expect(_key('generation-check'), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TickerMode leave finishes immediately and does not restart', (
    tester,
  ) async {
    final host = await _show(tester);
    host.deliver();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    host.mute();
    await tester.pump();
    expect(_key('delivered'), findsOneWidget);
    expect(find.byType(CoachTaskBubble), findsNothing);
    host.unmute();
    await tester.pumpAndSettle();
    expect(_key('generation-check'), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a reply received after leaving does not queue a later check', (
    tester,
  ) async {
    final host = await _show(tester);
    host.mute();
    await tester.pump();
    host.deliver();
    await tester.pump();
    expect(_key('delivered'), findsOneWidget);
    host.unmute();
    await tester.pumpAndSettle();
    expect(_key('generation-check'), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'another route finishes the visual timeline as soon as it covers',
    (tester) async {
      final host = await _show(tester);
      host.deliver();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      unawaited(
        host.navigator.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('另一页')),
          ),
        ),
      );
      await tester.pump();
      expect(_key('delivered', offstage: true), findsOneWidget);
      expect(find.byType(CoachTaskBubble, skipOffstage: false), findsNothing);
      await tester.pumpAndSettle();
      host.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(_key('delivered'), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('backgrounding finishes the visual delivery without replay', (
    tester,
  ) async {
    final host = await _show(tester);
    host.deliver();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(_key('delivered'), findsOneWidget);
    expect(find.byType(CoachTaskBubble), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(_key('generation-check'), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'replacing the session tree disposes an in-flight sequence safely',
    (tester) async {
      final host = await _show(tester);
      host.deliver();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 650));
      host.replaceSession();
      await tester.pumpAndSettle();
      expect(_key('delivered'), findsOneWidget);
      expect(find.byType(CoachTaskBubble), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion starts no visual delivery clock or hold', (
    tester,
  ) async {
    final host = await _show(tester, reduced: true);
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    host.deliver();
    await tester.pump();
    expect(_key('delivered'), findsOneWidget);
    expect(find.byType(CoachTaskBubble), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(seconds: 2));
    expect(_key('generation-check'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'enabling reduced motion during completion finishes immediately',
    (tester) async {
      final host = await _show(tester);
      host.deliver();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 650));
      host.reduce();
      await tester.pump();
      expect(_key('delivered'), findsOneWidget);
      expect(find.byType(CoachTaskBubble), findsNothing);
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unmounting before any delivery never lazily creates a ticker', (
    tester,
  ) async {
    await _show(tester, reduced: true);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}
