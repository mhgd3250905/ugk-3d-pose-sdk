import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' as foundation;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/src/ui/trainer_completion.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

class _EntranceVoiceSource extends VoiceSource {
  const _EntranceVoiceSource();

  @override
  Set<String> get languages => const {'en'};
  @override
  String asset(String key, {required String lang}) => key;
  @override
  String? call(VoiceCall call) => 'call.${call.name}';
  @override
  String? drill(String exerciseId, DrillLine line) => null;
  @override
  bool has(String key, {required String lang}) => true;
  @override
  String? line(String key, {required String lang}) => key;
  @override
  List<String> minutesPhrase(int n) => const [];
  @override
  List<String> secondsPhrase(int n) => const [];
  @override
  double seconds(String key, {required String lang}) =>
      key.startsWith('chime.') ? 0 : .05;
}

class _EntranceOutput extends RecordingOutput {
  int begins = 0;
  int ends = 0;

  @override
  Future<void> begin() async {
    begins++;
  }

  @override
  Future<void> end() async {
    ends++;
  }
}

class _RestFirstBuilder extends SessionBuilder {
  @override
  List<SessionPhase> phases(TrainingPlan plan) => [
    SessionPhase(
      kind: PhaseKind.rest,
      seconds: 10,
      exerciseId: plan.items.first.exerciseId,
      item: plan.items.first,
      itemIndex: 0,
      nextExerciseId: plan.items.first.exerciseId,
    ),
    ...super.phases(plan).where((phase) => phase.kind != PhaseKind.prep),
  ];
}

class _EntranceFixture {
  final saved = <SessionResult>[];
  final receipts = <SessionResult>[];
  final popped = <SessionResult>[];
  final media = <TrainerMediaRequest>[];
  final events = <String>[];
  final exitFrames = <int>[];
  final output = _EntranceOutput();
  int beforeCalls = 0;
  int routeReturns = 0;
  int frames = 0;
  bool watchingFrames = true;
}

Future<_EntranceFixture> _mountEntrance(
  WidgetTester tester, {
  Future<void>? gate,
  Animation<double>? chrome,
  Future<void> Function()? beforeExit,
  VoidCallback? exitStarted,
  Future<void> Function(SessionResult)? save,
  Future<void> Function(SessionResult)? receipt,
  TrainingPlan? plan,
  TrainerStartMode startMode = TrainerStartMode.training,
  bool keepAlive = false,
  int prepSeconds = 10,
  bool soundControl = false,
  bool restControl = false,
  SessionBuilder? sessionBuilder,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final fixture = _EntranceFixture();
  tester.binding.addPersistentFrameCallback((_) {
    if (fixture.watchingFrames) fixture.frames++;
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async {
              final result = await Navigator.of(context).push<SessionResult>(
                MaterialPageRoute(
                  builder: (_) => TrainerPlayer(
                    plan: plan ?? planOf([timed('a', 60), timed('b', 60)]),
                    drillOf: (id) => TrainerDrill(
                      id: id,
                      name: 'Move $id',
                      cues: const ['Keep breathing.', 'Move slowly.'],
                    ),
                    strings: TrainerStrings.en(),
                    theme: TrainerTheme.light,
                    startMode: startMode,
                    startGate: gate,
                    chromeAnimation: chrome,
                    beforeExitPop: () async {
                      fixture.beforeCalls++;
                      fixture.events.add('before');
                      await beforeExit?.call();
                      fixture.events.add('before-done');
                    },
                    onExitStarted: () {
                      fixture.events.add('exit-start');
                      fixture.exitFrames.add(fixture.frames);
                      exitStarted?.call();
                    },
                    prepSeconds: prepSeconds,
                    keepAlive: keepAlive,
                    showSoundToggle: soundControl,
                    showExtendRest: restControl,
                    sessionBuilder: sessionBuilder,
                    voice: TrainerVoice(
                      source: const _EntranceVoiceSource(),
                      output: fixture.output,
                      settings: const VoiceSettings(language: 'en'),
                    ),
                    mediaBuilder: (_, request) {
                      fixture.media.add(request);
                      return const SizedBox(
                        key: ValueKey('entrance-media'),
                        height: 50,
                      );
                    },
                    onFinished: (result) async {
                      fixture.saved.add(result);
                      fixture.events.add('save');
                      await save?.call(result);
                      fixture.events.add('saved');
                    },
                    onCompleted: (result) async {
                      fixture.receipts.add(result);
                      fixture.events.add('receipt');
                      await receipt?.call(result);
                      fixture.events.add('received');
                    },
                  ),
                ),
              );
              fixture.routeReturns++;
              if (result != null) fixture.popped.add(result);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  addTearDown(() async {
    fixture.watchingFrames = false;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return fixture;
}

Future<void> _advance(WidgetTester tester, int milliseconds) async {
  for (var remaining = milliseconds; remaining > 0;) {
    final step = remaining < 20 ? remaining : 20;
    await tester.pump(Duration(milliseconds: step));
    remaining -= step;
  }
}

String _counter(WidgetTester tester) => tester
    .widget<TrainerCountdownDigits>(find.byType(TrainerCountdownDigits))
    .value;

Future<void> _requestClose(WidgetTester tester, {bool back = false}) async {
  if (back) {
    await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
  } else {
    await tester.tap(find.byKey(const ValueKey('close')));
  }
  await tester.pumpAndSettle();
}

Future<int> _confirmClose(
  WidgetTester tester,
  _EntranceFixture fixture, {
  bool back = false,
}) async {
  await _requestClose(tester, back: back);
  expect(find.byKey(const ValueKey('close-confirm')), findsOneWidget);
  final frame = fixture.frames;
  await tester.tap(find.byKey(const ValueKey('close-confirm')));
  await tester.pump();
  return frame;
}

double _effectiveOpacity(Finder finder) {
  var opacity = 1.0;
  finder.evaluate().single.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is Opacity) opacity *= widget.opacity;
    if (widget is FadeTransition) opacity *= widget.opacity.value;
    return true;
  });
  return opacity;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platformCalls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late bool Function() wasAndroid;

  setUp(() {
    platformCalls.clear();
    wasAndroid = TrainingKeepAlive.isAndroid;
    TrainingKeepAlive.isAndroid = () => true;
    messenger.setMockMethodCallHandler(TrainingKeepAlive.channel, (call) async {
      platformCalls.add(call);
      return true;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(TrainingKeepAlive.channel, null);
    TrainingKeepAlive.isAndroid = wasAndroid;
  });

  testWidgets(
    'gate holds countdown, media, voice and hold until completion; recorder starts then',
    (tester) async {
      final gate = Completer<void>();
      final fixture = await _mountEntrance(
        tester,
        gate: gate.future,
        keepAlive: true,
        soundControl: true,
      );
      expect(_counter(tester), '10');
      expect(fixture.media.last.paused, isTrue);
      expect(fixture.output.begins, 0);
      expect(platformCalls.where((call) => call.method == 'start'), isEmpty);
      await _advance(tester, 5000);
      expect(_counter(tester), '10');
      expect(fixture.saved, isEmpty);
      expect(fixture.output.spoken, isEmpty);
      expect(fixture.output.chimes, isEmpty);
      expect(fixture.output.begins, 0);
      expect(platformCalls.where((call) => call.method == 'start'), isEmpty);

      for (final name in ['pause', 'skip', 'prev', 'sound-toggle']) {
        await tester.tap(find.byKey(ValueKey(name)), warnIfMissed: false);
        await tester.pump();
      }
      expect(_counter(tester), '10');
      expect(fixture.media.last.paused, isTrue);
      expect(fixture.output.begins, 0);
      expect(fixture.output.spoken, isEmpty);
      expect(fixture.output.chimes, isEmpty);

      final releasedAt = clock.now();
      gate.complete();
      await tester.pump();
      expect(fixture.output.begins, 1);
      expect(
        platformCalls.where((call) => call.method == 'start'),
        hasLength(1),
      );
      expect(fixture.media.last.paused, isFalse);
      await _advance(tester, 2100);
      expect(int.parse(_counter(tester)), lessThan(10));
      await _confirmClose(tester, fixture);
      await tester.pumpAndSettle();
      expect(fixture.saved, hasLength(1));
      final result = fixture.saved.single;
      expect(result.startedAt, releasedAt);
      expect(result.activeSeconds, greaterThanOrEqualTo(2.1));
      expect(result.activeSeconds, lessThan(4));
      expect(result.endedEarly, isTrue);
      expect(fixture.popped, hasLength(1));
    },
  );

  testWidgets('a throwing gate still starts normally once', (tester) async {
    final gate = Completer<void>();
    final fixture = await _mountEntrance(
      tester,
      gate: gate.future,
      keepAlive: true,
    );
    expect(fixture.output.begins, 0);
    gate.completeError(StateError('host transition failed'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(fixture.output.begins, 1);
    expect(platformCalls.where((call) => call.method == 'start'), hasLength(1));
    expect(fixture.media.last.paused, isFalse);
    await _advance(tester, 2100);
    expect(int.parse(_counter(tester)), lessThan(10));
  });

  testWidgets('custom initial rest cannot be extended before the gate opens', (
    tester,
  ) async {
    final gate = Completer<void>();
    final fixture = await _mountEntrance(
      tester,
      gate: gate.future,
      sessionBuilder: _RestFirstBuilder(),
      restControl: true,
    );
    expect(_counter(tester), '10');
    await tester.tap(
      find.byKey(const ValueKey('extend-rest')),
      warnIfMissed: false,
    );
    await _advance(tester, 1500);
    expect(_counter(tester), '10');
    expect(fixture.output.begins, 0);
    expect(fixture.output.spoken, isEmpty);
    expect(fixture.output.chimes, isEmpty);
    gate.complete();
    await tester.pump();
    await _advance(tester, 1000);
    expect(_counter(tester), '9');
    await tester.tap(find.byKey(const ValueKey('extend-rest')));
    await tester.pump();
    expect(_counter(tester), '24');
  });

  testWidgets(
    'an already synchronous gate starts safely after initialization',
    (tester) async {
      final fixture = await _mountEntrance(
        tester,
        gate: foundation.SynchronousFuture<void>(null),
        keepAlive: true,
      );
      expect(tester.takeException(), isNull);
      expect(fixture.output.begins, 1);
      expect(
        platformCalls.where((call) => call.method == 'start'),
        hasLength(1),
      );
      expect(fixture.media.last.paused, isFalse);
      await _advance(tester, 2100);
      expect(int.parse(_counter(tester)), lessThan(10));
    },
  );

  for (final fails in [false, true]) {
    testWidgets(
      'disposed gate never starts or records on late ${fails ? 'error' : 'completion'}',
      (tester) async {
        final gate = Completer<void>();
        final fixture = await _mountEntrance(
          tester,
          gate: gate.future,
          keepAlive: true,
        );
        await _advance(tester, 3000);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(fixture.saved, isEmpty);
        expect(fixture.receipts, isEmpty);
        if (fails) {
          gate.completeError(StateError('late host failure'));
        } else {
          gate.complete();
        }
        await _advance(tester, 10000);
        expect(fixture.output.begins, 0);
        expect(platformCalls.where((call) => call.method == 'start'), isEmpty);
        expect(fixture.saved, isEmpty);
        expect(fixture.output.spoken, isEmpty);
        expect(fixture.output.chimes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final back in [false, true]) {
    testWidgets(
      '${back ? 'back' : 'close'} before gate leaves without a result',
      (tester) async {
        final gate = Completer<void>();
        final fixture = await _mountEntrance(
          tester,
          gate: gate.future,
          keepAlive: true,
        );
        if (back) {
          await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
        } else {
          await tester.tap(find.byKey(const ValueKey('close')));
        }
        await tester.pump();
        if (find.byKey(const ValueKey('close-confirm')).evaluate().isNotEmpty) {
          await tester.tap(find.byKey(const ValueKey('close-confirm')));
          await tester.pump();
        }
        expect(fixture.routeReturns, 1);
        expect(fixture.popped, isEmpty);
        expect(fixture.saved, isEmpty);
        expect(fixture.receipts, isEmpty);
        // The pop transition still retains the route's mounted player here.
        // A gate released now must not start a session on the outgoing page.
        gate.complete();
        await tester.pump();
        expect(fixture.output.begins, 0);
        expect(platformCalls.where((call) => call.method == 'start'), isEmpty);
        await tester.pumpAndSettle();
        expect(find.text('open'), findsOneWidget);
        await _advance(tester, 3000);
        expect(fixture.output.begins, 0);
        expect(platformCalls.where((call) => call.method == 'start'), isEmpty);
        expect(fixture.saved, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('preview ignores gate and close hooks', (tester) async {
    final gate = Completer<void>();
    final chrome = AnimationController(vsync: tester, value: 0);
    addTearDown(chrome.dispose);
    final fixture = await _mountEntrance(
      tester,
      gate: gate.future,
      chrome: chrome,
      startMode: TrainerStartMode.preview,
      beforeExit: () => Completer<void>().future,
    );
    await _advance(tester, 1500);
    expect(fixture.media.last.paused, isFalse);
    expect(find.byKey(const ValueKey('start-training')), findsOneWidget);
    expect(fixture.output.begins, 0);
    await tester.tap(find.byKey(const ValueKey('close')));
    await tester.pumpAndSettle();
    expect(fixture.routeReturns, 1);
    expect(fixture.saved, isEmpty);
    expect(fixture.receipts, isEmpty);
    expect(fixture.beforeCalls, 0);
    expect(fixture.exitFrames, isEmpty);
    gate.complete();
    await tester.pump();
    expect(fixture.output.begins, 0);
  });

  for (final back in [false, true]) {
    testWidgets(
      '${back ? 'system back' : 'early close'} starts exit immediately, then awaits receipt and hook once',
      (tester) async {
        final save = Completer<void>();
        final receipt = Completer<void>();
        final exit = Completer<void>();
        final fixture = await _mountEntrance(
          tester,
          prepSeconds: 2,
          save: (_) => save.future,
          receipt: (_) => receipt.future,
          beforeExit: () => exit.future,
        );
        await _advance(tester, 2500);
        final exitFrame = await _confirmClose(tester, fixture, back: back);
        expect(fixture.exitFrames, [exitFrame]);
        expect(fixture.events, ['exit-start', 'save']);
        expect(fixture.beforeCalls, 0);
        expect(fixture.saved, hasLength(1));
        save.complete();
        await tester.pump();
        expect(fixture.events, ['exit-start', 'save', 'saved', 'receipt']);
        expect(fixture.beforeCalls, 0);
        receipt.complete();
        await tester.pump();
        expect(fixture.events, [
          'exit-start',
          'save',
          'saved',
          'receipt',
          'received',
          'before',
        ]);
        expect(fixture.popped, isEmpty);
        for (var repeat = 0; repeat < 3; repeat++) {
          await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
          await tester.tap(
            find.byKey(const ValueKey('close')),
            warnIfMissed: false,
          );
          await tester.pump();
        }
        await _advance(tester, 300);
        expect(fixture.exitFrames, hasLength(1));
        expect(fixture.beforeCalls, 1);
        expect(fixture.saved, hasLength(1));
        expect(fixture.receipts, hasLength(1));
        expect(fixture.popped, isEmpty);
        exit.complete();
        await tester.pumpAndSettle();
        expect(fixture.popped, hasLength(1));
        expect(
          identical(fixture.popped.single, fixture.receipts.single),
          isTrue,
        );
        expect(
          identical(fixture.saved.single, fixture.receipts.single),
          isTrue,
        );
      },
    );
  }

  testWidgets('natural Finish awaits the hook and notifies exit only on tap', (
    tester,
  ) async {
    final exit = Completer<void>();
    final fixture = await _mountEntrance(
      tester,
      prepSeconds: 0,
      plan: planOf([timed('a', 1)]),
      beforeExit: () => exit.future,
    );
    await _advance(tester, 3000);
    expect(find.byType(TrainerCompletion), findsOneWidget);
    expect(fixture.saved, hasLength(1));
    expect(fixture.beforeCalls, 0);
    expect(fixture.exitFrames, isEmpty);
    final frame = fixture.frames;
    await tester.tap(find.byKey(const ValueKey('finish')));
    await tester.pump();
    expect(fixture.exitFrames, [frame]);
    expect(fixture.beforeCalls, 1);
    expect(fixture.popped, isEmpty);
    expect(fixture.receipts, hasLength(1));
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(const ValueKey('finish')));
      await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await tester.pump();
    }
    expect(fixture.exitFrames, hasLength(1));
    expect(fixture.beforeCalls, 1);
    expect(fixture.saved, hasLength(1));
    exit.complete();
    await tester.pumpAndSettle();
    expect(fixture.popped, hasLength(1));
    expect(fixture.saved, hasLength(1));
  });

  testWidgets('host exit animation starts while saving is still pending', (
    tester,
  ) async {
    final save = Completer<void>();
    final chrome = AnimationController(
      vsync: tester,
      value: 1,
      duration: const Duration(milliseconds: 280),
    );
    addTearDown(chrome.dispose);
    final fixture = await _mountEntrance(
      tester,
      chrome: chrome,
      prepSeconds: 2,
      save: (_) => save.future,
      exitStarted: () => chrome.reverse(),
    );
    await _advance(tester, 2500);
    await _confirmClose(tester, fixture);
    await tester.pump(const Duration(milliseconds: 140));
    expect(chrome.value, closeTo(.5, .01));
    expect(fixture.saved, hasLength(1));
    expect(fixture.beforeCalls, 0);
    expect(fixture.popped, isEmpty);
    save.complete();
    await tester.pumpAndSettle();
    expect(fixture.popped, hasLength(1));
  });

  for (final stage in ['save', 'receipt']) {
    testWidgets('$stage failure skips pop hook and completion ignores chrome', (
      tester,
    ) async {
      var saveCalls = 0;
      var receiptCalls = 0;
      final chrome = AnimationController(vsync: tester, value: 1);
      addTearDown(chrome.dispose);
      final fixture = await _mountEntrance(
        tester,
        chrome: chrome,
        prepSeconds: 2,
        exitStarted: () => chrome.value = 0,
        save: (_) async {
          if (stage == 'save' && saveCalls++ == 0) throw StateError('offline');
        },
        receipt: (_) async {
          if (stage == 'receipt' && receiptCalls++ == 0) {
            throw StateError('receipt offline');
          }
        },
      );
      await _advance(tester, 2500);
      await _confirmClose(tester, fixture);
      await tester.pumpAndSettle();
      expect(chrome.value, 0);
      expect(find.byType(TrainerCompletion), findsOneWidget);
      expect(_effectiveOpacity(find.byType(TrainerCompletion)), 1);
      expect(find.byKey(const ValueKey('save-retry')), findsOneWidget);
      expect(fixture.beforeCalls, 0);
      expect(fixture.popped, isEmpty);
      expect(fixture.saved, hasLength(1));
      expect(fixture.exitFrames, hasLength(1));
      await tester.ensureVisible(find.byKey(const ValueKey('save-retry')));
      await tester.tap(find.byKey(const ValueKey('save-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('save-retry')), findsNothing);
      expect(_effectiveOpacity(find.byType(TrainerCompletion)), 1);
      await tester.tap(find.byKey(const ValueKey('finish')));
      await tester.pumpAndSettle();
      expect(fixture.beforeCalls, 1);
      expect(fixture.popped, hasLength(1));
      expect(fixture.saved, hasLength(stage == 'save' ? 2 : 1));
    });
  }

  testWidgets('a failed pop hook does not strand a successfully saved route', (
    tester,
  ) async {
    final fixture = await _mountEntrance(
      tester,
      beforeExit: () async => throw StateError('host exit failed'),
    );
    await _confirmClose(tester, fixture);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(fixture.beforeCalls, 1);
    expect(fixture.exitFrames, hasLength(1));
    expect(fixture.saved, hasLength(1));
    expect(fixture.receipts, hasLength(1));
    expect(fixture.popped, hasLength(1));
  });

  testWidgets('the pop hook times out at one second without a duplicate save', (
    tester,
  ) async {
    final neverFinishes = Completer<void>();
    final fixture = await _mountEntrance(
      tester,
      beforeExit: () => neverFinishes.future,
    );
    await _confirmClose(tester, fixture);
    expect(fixture.beforeCalls, 1);
    await tester.pump(const Duration(milliseconds: 999));
    expect(fixture.popped, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(fixture.popped, hasLength(1));
    await tester.pumpAndSettle();
    expect(fixture.saved, hasLength(1));
    expect(fixture.receipts, hasLength(1));
    expect(fixture.exitFrames, hasLength(1));
    neverFinishes.complete();
    await tester.pump();
    expect(fixture.popped, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing a route with a pending pop hook cancels its timeout', (
    tester,
  ) async {
    final exit = Completer<void>();
    final fixture = await _mountEntrance(tester, beforeExit: () => exit.future);
    await _confirmClose(tester, fixture);
    expect(fixture.beforeCalls, 1);
    final player = tester.element(find.byType(TrainerPlayer));
    final route = ModalRoute.of(player)!;
    Navigator.of(player).removeRoute(route);
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
    expect(fixture.routeReturns, 1);
    expect(fixture.saved, hasLength(1));
    expect(tester.takeException(), isNull);
    // Leave the host Future unresolved: WidgetTester's end-of-test timer
    // assertion verifies that disposal did not retain the 1s timeout timer.
  });

  testWidgets('a late pop hook cannot pop the next host route after removal', (
    tester,
  ) async {
    final exit = Completer<void>();
    final fixture = await _mountEntrance(tester, beforeExit: () => exit.future);
    await _confirmClose(tester, fixture);
    final player = tester.element(find.byType(TrainerPlayer));
    final nav = Navigator.of(player);
    nav.removeRoute(ModalRoute.of(player)!);
    await tester.pumpAndSettle();
    unawaited(
      nav.push<void>(
        MaterialPageRoute(
          builder: (_) =>
              const Scaffold(body: Center(child: Text('host-next'))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    exit.complete();
    await tester.pumpAndSettle();
    expect(find.text('host-next'), findsOneWidget);
    expect(fixture.routeReturns, 1);
    expect(fixture.saved, hasLength(1));
    expect(fixture.receipts, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
