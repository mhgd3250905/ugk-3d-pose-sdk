// Route-only cases from SmartFit 13c0bb4; app diagnostics are intentionally absent.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

const _open = ValueKey('slide-probe-open');
const _otherNavigation = ValueKey('slide-probe-other-navigation');
const _sourceAnchor = ValueKey('slide-probe-source-anchor');
const _page = ValueKey('slide-probe-complete-page');
const _poster = ValueKey('slide-probe-poster');
const _controls = ValueKey('slide-probe-complete-controls');
const _media = ValueKey('slide-probe-mounted-media');
const _retry = ValueKey('slide-probe-retry-view');
const _slide = ValueKey('training-slide');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final brightness in Brightness.values) {
    testWidgets(
      '${brightness.name}: opaque slide has complete first frame and a 300ms start gate',
      (tester) async {
        final fixture = _SlideFixture(brightness: brightness);
        await fixture.mountAndOpen(tester);
        final route = fixture.route;
        expect(route.opaque, isTrue);
        expect(route.allowSnapshotting, isFalse);
        expect(route.transitionDuration, const Duration(milliseconds: 300));
        expect(
          route.reverseTransitionDuration,
          const Duration(milliseconds: 280),
        );

        _expectCompleteFrame(tester, fixture);
        _expectEntryPosition(tester, fixture);
        expect(route.animation!.value, 0);
        expect(route.control.entered, isFalse);
        expect(fixture.gateStarts, 0);
        expect(fixture.mediaCreated, 0);
        _expectSystemBars(tester, brightness);

        await tester.pump(const Duration(milliseconds: 150));
        _expectCompleteFrame(tester, fixture);
        _expectEntryPosition(tester, fixture);
        expect(route.animation!.value, closeTo(.5, .001));
        expect(route.control.entered, isFalse);
        expect(fixture.gateStarts, 0);
        expect(fixture.mediaCreated, 0);

        await tester.pump(const Duration(milliseconds: 149));
        expect(route.control.entered, isFalse);
        expect(fixture.gateStarts, 0);
        expect(fixture.mediaCreated, 0);
        await tester.pump(const Duration(milliseconds: 1));
        expect(route.animation!.value, 1);
        _expectEntryPosition(tester, fixture);
        // The controller can reach its endpoint value one simulation tick
        // before it emits completed. No extra design duration is introduced.
        await tester.pump(const Duration(microseconds: 1));
        await tester.pump();
        _expectCompleteFrame(tester, fixture);
        _expectEntryPosition(tester, fixture);
        expect(route.control.entered, isTrue);
        expect(route.animation!.status, AnimationStatus.completed);
        expect(fixture.gateStarts, 1);
        expect(fixture.mediaCreated, 1);
        expect(find.byKey(_media), findsOneWidget);
      },
    );

    testWidgets(
      '${brightness.name}: removed animations retain a complete frame with zero-duration routing',
      (tester) async {
        final fixture = _SlideFixture(
          brightness: brightness,
          reducedMotion: true,
        );
        await fixture.mountAndOpen(tester);
        _expectCompleteFrame(tester, fixture);
        expect(fixture.route.transitionDuration, Duration.zero);
        expect(fixture.route.reverseTransitionDuration, Duration.zero);
        expect(_slideOf(tester).position.value, Offset.zero);
        await tester.pump();
        expect(fixture.route.control.entered, isTrue);
        expect(fixture.gateStarts, 1);

        final exiting = fixture.finishLikeSdk(Future<void>.value());
        await tester.pump();
        await exiting;
        await tester.pump();
        expect(fixture.returnedReceipt, 'saved-receipt');
        expect(fixture.pageDisposed, isTrue);
      },
    );

    testWidgets(
      '${brightness.name}: exit starts immediately, follows easeInCubic, and retires media after 280ms',
      (tester) async {
        final fixture = _SlideFixture(brightness: brightness);
        await fixture.mountAndOpen(tester);
        await fixture.finishEntry(tester);

        fixture.route.control.beginExit();
        await tester.pump();
        expect(fixture.route.animation!.status, AnimationStatus.reverse);
        expect(fixture.route.control.exiting, isTrue);
        expect(fixture.route.control.mediaRetired, isFalse);
        expect(fixture.mediaDisposed, 0);
        expect(fixture.mediaPaused, isTrue);
        _expectExitPosition(tester, fixture);

        await tester.pump(const Duration(milliseconds: 140));
        _expectExitPosition(tester, fixture);
        expect(fixture.route.animation!.value, closeTo(.5, .001));
        expect(fixture.route.control.mediaRetired, isFalse);
        expect(fixture.mediaDisposed, 0);
        await tester.pump(const Duration(milliseconds: 139));
        expect(fixture.route.control.mediaRetired, isFalse);
        expect(fixture.mediaDisposed, 0);

        await tester.pump(const Duration(milliseconds: 1));
        expect(fixture.route.animation!.value, 0);
        expect(_slideOf(tester).position.value, const Offset(1, 0));
        await tester.pump(const Duration(microseconds: 1));
        await tester.pump();
        expect(fixture.route.animation!.status, AnimationStatus.dismissed);
        expect(_slideOf(tester).position.value, const Offset(1, 0));
        expect(fixture.route.control.mediaRetired, isTrue);
        expect(fixture.mediaDisposed, 1);
        expect(fixture.pageDisposed, isFalse);
        expect(fixture.route.isActive, isTrue);
        expect(fixture.gateStarts, 1);

        // The SDK may now commit its already-saved receipt and perform pop.
        fixture.navigator.currentState!.pop('saved-receipt');
        await tester.pump();
        expect(fixture.returnedReceipt, 'saved-receipt');
        expect(fixture.pageDisposed, isTrue);
      },
    );
  }

  testWidgets('fast save waits for the full exit before SDK pop', (
    tester,
  ) async {
    final fixture = _SlideFixture();
    await fixture.mountAndOpen(tester);
    await fixture.finishEntry(tester);
    final exited = fixture.finishLikeSdk(Future<void>.value());
    await tester.pump();
    expect(fixture.saveCalls, 1);
    expect(fixture.route.control.exiting, isTrue);
    expect(fixture.returnedReceipt, isNull);

    await tester.pump(const Duration(milliseconds: 279));
    expect(fixture.route.isActive, isTrue);
    expect(fixture.pageDisposed, isFalse);
    expect(fixture.returnedReceipt, isNull);
    await tester.pump(const Duration(milliseconds: 1));
    expect(fixture.route.animation!.value, 0);
    await tester.pump(const Duration(microseconds: 1));
    await tester.pump();
    await exited;
    expect(fixture.returnedReceipt, 'saved-receipt');
    expect(fixture.pageDisposed, isTrue);
    expect(fixture.saveCalls, 1);
    expect(fixture.completionCalls, 1);
  });

  testWidgets(
    'slow save slides out first and blocks underlying navigation until the SDK late pop',
    (tester) async {
      final fixture = _SlideFixture();
      await fixture.mountAndOpen(tester);
      await fixture.finishEntry(tester);
      final saved = Completer<void>();
      final exited = fixture.finishLikeSdk(saved.future);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 280));
      expect(fixture.route.animation!.value, 0);
      await tester.pump(const Duration(microseconds: 1));
      await tester.pump();
      expect(fixture.route.animation!.status, AnimationStatus.dismissed);
      expect(fixture.route.isActive, isTrue);
      expect(fixture.pageDisposed, isFalse);
      expect(fixture.mediaDisposed, 1);
      expect(fixture.returnedReceipt, isNull);
      _expectSourceStill(tester, fixture);

      await tester.tap(
        find.byKey(_otherNavigation, skipOffstage: false),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(fixture.otherNavigationAttempts, 0);
      expect(find.text('unrelated-page'), findsNothing);

      saved.complete();
      await tester.pump();
      await exited;
      await tester.pump();
      expect(fixture.returnedReceipt, 'saved-receipt');
      expect(fixture.pageDisposed, isTrue);
      expect(fixture.saveCalls, 1);
      expect(fixture.completionCalls, 1);
      _expectSourceStill(tester, fixture);

      // Input shielding belongs only to the route being retired.
      await tester.tap(find.byKey(_otherNavigation));
      await tester.pump();
      expect(fixture.otherNavigationAttempts, 1);
    },
  );

  testWidgets(
    'failed save restores the retry view; explicit finish exits without another SDK notification',
    (tester) async {
      final fixture = _SlideFixture();
      await fixture.mountAndOpen(tester);
      await fixture.finishEntry(tester);
      fixture.route.control.beginExit();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 280));
      await tester.pump(const Duration(microseconds: 1));
      await tester.pump();
      expect(fixture.route.control.mediaRetired, isTrue);

      fixture.route.control.exitSaveFailed();
      await tester.pump();
      expect(fixture.route.control.saveFailed, isTrue);
      expect(fixture.route.control.exiting, isFalse);
      expect(find.byKey(_retry), findsOneWidget);
      // Recovery starts in the route's post-frame callback. Prime its first
      // ticker at the current timestamp before measuring the next 300ms.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(fixture.route.animation!.value, 1);
      await tester.pump(const Duration(microseconds: 1));
      await tester.pump();
      expect(fixture.route.animation!.status, AnimationStatus.completed);
      expect(_slideOf(tester).position.value, Offset.zero);
      _expectCompleteFrame(tester, fixture);
      expect(fixture.pageDisposed, isFalse);
      expect(fixture.gateStarts, 1);

      // SDK sends onExitStarted once per session. A later explicit finish
      // reaches beforeExitPop after the successful retry, without that event.
      final readyToPop = fixture.route.control.beforeExitPop();
      await tester.pump();
      expect(fixture.route.control.exiting, isTrue);
      expect(fixture.route.control.saveFailed, isFalse);
      expect(fixture.route.animation!.status, AnimationStatus.reverse);
      await tester.pump(const Duration(milliseconds: 280));
      await tester.pump(const Duration(microseconds: 1));
      await readyToPop;
      fixture.navigator.currentState!.pop('retry-receipt');
      await tester.pump();
      expect(fixture.returnedReceipt, 'retry-receipt');
      expect(fixture.gateStarts, 1);
      expect(fixture.pageDisposed, isTrue);
    },
  );

  testWidgets('system back during entrance never opens the start gate', (
    tester,
  ) async {
    final fixture = _SlideFixture();
    await fixture.mountAndOpen(tester);
    await tester.pump(const Duration(milliseconds: 150));
    expect(fixture.route.control.entered, isFalse);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(fixture.pageDisposed, isTrue);
    expect(fixture.gateStarts, 0);
    expect(fixture.mediaCreated, 0);
    expect(fixture.saveCalls, 0);
    expect(find.byKey(_slide), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'backgrounding during entrance aborts without starting a session',
    (tester) async {
      final fixture = _SlideFixture();
      await fixture.mountAndOpen(tester);
      await tester.pump(const Duration(milliseconds: 150));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(fixture.pageDisposed, isTrue);
      expect(fixture.gateStarts, 0);
      expect(fixture.mediaCreated, 0);
      expect(fixture.saveCalls, 0);
      expect(find.byKey(_slide), findsNothing);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'disposing an in-flight route releases motion without late startup',
    (tester) async {
      final fixture = _SlideFixture();
      await fixture.mountAndOpen(tester);
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      expect(fixture.pageDisposed, isTrue);
      expect(fixture.gateStarts, 0);
      expect(fixture.mediaCreated, 0);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );
}

SlideTransition _slideOf(WidgetTester tester) =>
    tester.widget<SlideTransition>(find.byKey(_slide));

void _expectEntryPosition(WidgetTester tester, _SlideFixture fixture) {
  final expected =
      1 - Curves.easeOutCubic.transform(fixture.route.animation!.value);
  expect(_slideOf(tester).position.value.dx, closeTo(expected, .00001));
  expect(_slideOf(tester).position.value.dy, 0);
  final page = tester.getRect(find.byKey(_page));
  expect(page.left, closeTo(fixture.viewport.width * expected, .01));
  expect(page.top, closeTo(0, .01));
  expect(page.size, fixture.viewport);
  _expectSourceStill(tester, fixture);
}

void _expectExitPosition(WidgetTester tester, _SlideFixture fixture) {
  // animation.value decreases on reverse; easeInCubic applies to elapsed exit
  // progress, not directly to that decreasing value.
  final elapsed = 1 - fixture.route.animation!.value;
  final expected = Curves.easeInCubic.transform(elapsed);
  expect(_slideOf(tester).position.value.dx, closeTo(expected, .00001));
  expect(_slideOf(tester).position.value.dy, 0);
  final page = tester.getRect(find.byKey(_page));
  expect(page.left, closeTo(fixture.viewport.width * expected, .01));
  expect(page.top, closeTo(0, .01));
  expect(page.size, fixture.viewport);
  _expectSourceStill(tester, fixture);
}

void _expectSourceStill(WidgetTester tester, _SlideFixture fixture) {
  expect(
    tester.getRect(find.byKey(_sourceAnchor, skipOffstage: false)),
    fixture.sourceRect,
  );
}

void _expectCompleteFrame(
  WidgetTester tester,
  _SlideFixture fixture, {
  bool includeOffstage = false,
}) {
  final skipOffstage = !includeOffstage;
  final page = find.byKey(_page, skipOffstage: skipOffstage);
  expect(page, findsOneWidget);
  expect(find.byKey(_poster, skipOffstage: skipOffstage), findsOneWidget);
  expect(find.byKey(_controls, skipOffstage: skipOffstage), findsOneWidget);
  expect(find.text('Top progress', skipOffstage: skipOffstage), findsOneWidget);
  expect(find.text('Next action', skipOffstage: skipOffstage), findsOneWidget);
  expect(find.text('How to move', skipOffstage: skipOffstage), findsOneWidget);
  expect(
    find.text('Transport and countdown', skipOffstage: skipOffstage),
    findsOneWidget,
  );
  expect(find.byType(CircularProgressIndicator), findsNothing);
  expect(
    find.ancestor(of: page, matching: find.byType(FadeTransition)),
    findsNothing,
  );
  expect(
    find.ancestor(of: page, matching: find.byType(ScaleTransition)),
    findsNothing,
  );
  expect(fixture.pageDisposed, isFalse);
}

void _expectSystemBars(WidgetTester tester, Brightness brightness) {
  final background = find.byKey(const ValueKey('training-route-background'));
  final box = tester.widget<ColoredBox>(background);
  final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
    find
        .ancestor(
          of: background,
          matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
        )
        .first,
  );
  final iconBrightness = brightness == Brightness.dark
      ? Brightness.light
      : Brightness.dark;
  expect(region.value.statusBarColor, box.color);
  expect(region.value.systemNavigationBarColor, box.color);
  expect(region.value.statusBarIconBrightness, iconBrightness);
  expect(region.value.systemNavigationBarIconBrightness, iconBrightness);
  expect(region.value.systemStatusBarContrastEnforced, isFalse);
  expect(region.value.systemNavigationBarContrastEnforced, isFalse);
}

class _SlideFixture {
  _SlideFixture({
    this.brightness = Brightness.light,
    this.reducedMotion = false,
  });

  final Brightness brightness;
  final bool reducedMotion;
  final navigator = GlobalKey<NavigatorState>();
  late TrainerSlideRoute<String> route;
  late Rect sourceRect;
  late Size viewport;
  int gateStarts = 0;
  int mediaCreated = 0;
  int mediaDisposed = 0;
  int saveCalls = 0;
  int completionCalls = 0;
  int otherNavigationAttempts = 0;
  bool mediaPaused = false;
  bool pageDisposed = false;
  String? returnedReceipt;

  Future<void> mountAndOpen(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: ThemeData(
          brightness: brightness,
          platform: TargetPlatform.android,
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reducedMotion),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Stack(
              children: [
                const Positioned(
                  top: 20,
                  left: 20,
                  child: SizedBox(key: _sourceAnchor, width: 8, height: 8),
                ),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        key: _open,
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          route = TrainerSlideRoute<String>(
                            context: context,
                            builder: (_) => _CompleteProbePage(fixture: this),
                          );
                          unawaited(
                            navigator.currentState!.push(route).then((value) {
                              returnedReceipt = value;
                            }),
                          );
                        },
                        child: const SizedBox(
                          width: 240,
                          height: 48,
                          child: Center(child: Text('Open training')),
                        ),
                      ),
                      GestureDetector(
                        key: _otherNavigation,
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          otherNavigationAttempts++;
                          unawaited(
                            navigator.currentState!.push<void>(
                              MaterialPageRoute<void>(
                                builder: (_) => const Scaffold(
                                  body: Text('unrelated-page'),
                                ),
                              ),
                            ),
                          );
                        },
                        child: const SizedBox(
                          width: 240,
                          height: 48,
                          child: Center(child: Text('Open another page')),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    sourceRect = tester.getRect(find.byKey(_sourceAnchor));
    viewport = tester.getSize(find.byType(Scaffold));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    await tester.tap(find.byKey(_open));
    await tester.pump();
    // MaterialApp's HeroController performs a zero-time offstage preflight
    // even though this route does not use a Hero. Its tree must already be
    // complete; then clear that preflight without advancing animation time.
    _expectCompleteFrame(tester, this, includeOffstage: true);
    await tester.pump();
  }

  Future<void> finishEntry(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    expect(route.animation!.value, 1);
    expect(_slideOf(tester).position.value, Offset.zero);
    await tester.pump(const Duration(microseconds: 1));
    await tester.pump();
    expect(route.control.entered, isTrue);
    expect(gateStarts, 1);
  }

  Future<void> finishLikeSdk(Future<void> save) async {
    route.control.beginExit();
    saveCalls++;
    await save;
    completionCalls++;
    await route.control.beforeExitPop();
    navigator.currentState!.pop('saved-receipt');
  }
}

class _CompleteProbePage extends StatefulWidget {
  const _CompleteProbePage({required this.fixture});
  final _SlideFixture fixture;

  @override
  State<_CompleteProbePage> createState() => _CompleteProbePageState();
}

class _CompleteProbePageState extends State<_CompleteProbePage> {
  TrainerSlideRouteControl? _control;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final control = TrainerSlideRouteScope.maybeOf(context)!;
    if (identical(control, _control)) return;
    _control = control;
    unawaited(
      control.startGate.then((_) {
        if (mounted) widget.fixture.gateStarts++;
      }),
    );
  }

  @override
  void dispose() {
    widget.fixture.pageDisposed = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final control = TrainerSlideRouteScope.maybeOf(context)!;
    return PopScope(
      canPop: false,
      child: Scaffold(
        key: _page,
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(key: _poster, color: Color(0xff567890)),
            if (control.entered && !control.mediaRetired)
              _MediaProbe(
                key: _media,
                fixture: widget.fixture,
                paused: control.exiting,
              ),
            Column(
              key: _controls,
              children: [
                const Text('Top progress'),
                const Text('Next action'),
                const Text('How to move'),
                const Spacer(),
                if (control.saveFailed) const Text('Retry save', key: _retry),
                const Text('Transport and countdown'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaProbe extends StatefulWidget {
  const _MediaProbe({super.key, required this.fixture, required this.paused});
  final _SlideFixture fixture;
  final bool paused;

  @override
  State<_MediaProbe> createState() => _MediaProbeState();
}

class _MediaProbeState extends State<_MediaProbe> {
  @override
  void initState() {
    super.initState();
    widget.fixture.mediaCreated++;
    widget.fixture.mediaPaused = widget.paused;
  }

  @override
  void didUpdateWidget(_MediaProbe oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.fixture.mediaPaused = widget.paused;
  }

  @override
  void dispose() {
    widget.fixture.mediaDisposed++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
