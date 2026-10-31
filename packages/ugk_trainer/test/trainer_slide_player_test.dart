import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/src/ui/trainer_completion.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

class _SlideVoice extends VoiceSource {
  const _SlideVoice();
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
  double seconds(String key, {required String lang}) => .05;
}

class _SlideOutput extends RecordingOutput {
  int begins = 0;
  @override
  Future<void> begin() async => begins++;
}

class _PlayerFixture {
  final navigator = GlobalKey<NavigatorState>();
  final output = _SlideOutput();
  final events = <String>[];
  final media = <TrainerMediaRequest>[];
  final saved = <SessionResult>[];
  final receipts = <SessionResult>[];
  SessionResult? popped;
  late TrainerSlideRoute<SessionResult> route;

  Future<void> mount(
    WidgetTester tester, {
    bool reduced = false,
    Future<void> Function(SessionResult)? save,
    Future<void> Function(SessionResult)? complete,
    int prep = 10,
    int seconds = 60,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                route = TrainerSlideRoute<SessionResult>(
                  context: context,
                  trainerTheme: TrainerTheme.light,
                  builder: (context) {
                    final control = TrainerSlideRouteScope.maybeOf(context)!;
                    return TrainerPlayer(
                      plan: planOf([timed('a', seconds)]),
                      drillOf: (id) => TrainerDrill(id: id, name: 'Move $id'),
                      strings: TrainerStrings.en(),
                      theme: TrainerTheme.light,
                      prepSeconds: prep,
                      startGate: control.startGate,
                      onExitStarted: () {
                        events.add('exit');
                        control.beginExit();
                      },
                      beforeExitPop: () async {
                        events.add('before');
                        await control.beforeExitPop();
                        events.add('before-done');
                      },
                      voice: TrainerVoice(
                        source: const _SlideVoice(),
                        output: output,
                        settings: const VoiceSettings(language: 'en'),
                      ),
                      mediaBuilder: (_, request) {
                        media.add(request);
                        return const ColoredBox(
                          key: ValueKey('slide-player-poster'),
                          color: Colors.blue,
                        );
                      },
                      onFinished: (result) async {
                        saved.add(result);
                        events.add('save');
                        try {
                          await save?.call(result);
                          events.add('saved');
                        } on Object {
                          control.exitSaveFailed();
                          rethrow;
                        }
                      },
                      onCompleted: (result) async {
                        receipts.add(result);
                        events.add('receipt');
                        try {
                          await complete?.call(result);
                          events.add('received');
                        } on Object {
                          control.exitSaveFailed();
                          rethrow;
                        }
                      },
                    );
                  },
                );
                unawaited(
                  navigator.currentState!.push(route).then((result) {
                    popped = result;
                    events.add('pop');
                  }),
                );
              },
              child: const Text('open-slide-player'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-slide-player'));
    await tester.pump();
    await tester.pump();
  }

  Future<void> enter(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(microseconds: 1));
    await tester.pump();
    expect(route.control.entered, isTrue);
  }
}

Future<void> _confirm(WidgetTester tester, {bool back = false}) async {
  if (back) {
    await tester.binding.handlePopRoute();
  } else {
    await tester.tap(find.byKey(const ValueKey('close')));
  }
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('close-confirm')), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('close-confirm')));
  await tester.pump();
}

Future<void> _step(WidgetTester tester, int milliseconds) async {
  for (var remaining = milliseconds; remaining > 0;) {
    final interval = remaining < 20 ? remaining : 20;
    await tester.pump(Duration(milliseconds: interval));
    remaining -= interval;
  }
}

String _digits(WidgetTester tester) => tester
    .widget<TrainerCountdownDigits>(find.byType(TrainerCountdownDigits))
    .value;

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
    TrainingKeepAlive.isAndroid = wasAndroid;
    messenger.setMockMethodCallHandler(TrainingKeepAlive.channel, null);
  });

  testWidgets(
    'the actual player has no clock, voice or hold during the slide',
    (tester) async {
      final fixture = _PlayerFixture();
      await fixture.mount(tester);
      expect(find.byKey(const ValueKey('slide-player-poster')), findsOneWidget);
      expect(_digits(tester), '10');
      await tester.pump(const Duration(milliseconds: 150));
      expect(_digits(tester), '10');
      expect(fixture.media.last.paused, isTrue);
      expect(fixture.output.begins, 0);
      expect(fixture.output.spoken, isEmpty);
      expect(fixture.output.chimes, isEmpty);
      expect(platformCalls.where((call) => call.method == 'start'), isEmpty);
      await tester.pump(const Duration(milliseconds: 149));
      expect(fixture.output.begins, 0);
      expect(fixture.route.control.entered, isFalse);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(microseconds: 1));
      await tester.pump();
      expect(fixture.output.begins, 1);
      expect(fixture.media.last.paused, isFalse);
      expect(
        platformCalls.where((call) => call.method == 'start'),
        hasLength(1),
      );
      await _step(tester, 2100);
      expect(int.parse(_digits(tester)), lessThan(10));
    },
  );

  for (final back in [false, true]) {
    testWidgets(
      '${back ? 'system back' : 'close'} exits after save and receipt without a completion frame',
      (tester) async {
        final save = Completer<void>();
        final receipt = Completer<void>();
        final fixture = _PlayerFixture();
        await fixture.mount(
          tester,
          save: (_) => save.future,
          complete: (_) => receipt.future,
        );
        await fixture.enter(tester);
        await _step(tester, 100);
        await _confirm(tester, back: back);
        expect(fixture.events, ['exit', 'save']);
        expect(fixture.route.control.exiting, isTrue);
        expect(fixture.media.last.paused, isTrue);
        for (var frame = 0; frame < 20; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(find.byType(TrainerCompletion), findsNothing);
        }
        expect(fixture.route.animation!.value, 0);
        expect(fixture.route.control.mediaRetired, isTrue);
        expect(fixture.route.isActive, isTrue);
        expect(fixture.popped, isNull);
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(fixture.saved, hasLength(1));
        save.complete();
        await tester.pump();
        expect(fixture.events, ['exit', 'save', 'saved', 'receipt']);
        expect(fixture.route.isActive, isTrue);
        receipt.complete();
        await tester.pumpAndSettle();
        expect(fixture.saved, hasLength(1));
        expect(fixture.receipts, hasLength(1));
        expect(fixture.popped, same(fixture.receipts.single));
        expect(fixture.popped!.endedEarly, isTrue);
        expect(fixture.events, [
          'exit',
          'save',
          'saved',
          'receipt',
          'received',
          'before',
          'before-done',
          'pop',
        ]);
      },
    );
  }

  testWidgets('back during entry never begins or saves the player', (
    tester,
  ) async {
    final fixture = _PlayerFixture();
    await fixture.mount(tester);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await _step(tester, 1000);
    expect(fixture.output.begins, 0);
    expect(fixture.output.spoken, isEmpty);
    expect(fixture.saved, isEmpty);
    expect(fixture.receipts, isEmpty);
    expect(fixture.events, ['pop']);
    expect(platformCalls.where((call) => call.method == 'start'), isEmpty);
  });

  testWidgets('failed save restores the real completion and allows retry', (
    tester,
  ) async {
    var failures = 1;
    final fixture = _PlayerFixture();
    await fixture.mount(
      tester,
      save: (_) async {
        if (failures-- > 0) throw StateError('fixture save failure');
      },
    );
    await fixture.enter(tester);
    await _confirm(tester);
    await tester.pumpAndSettle();
    expect(fixture.route.control.saveFailed, isTrue);
    expect(fixture.route.animation!.value, 1);
    expect(find.byType(TrainerCompletion), findsOneWidget);
    expect(find.byKey(const ValueKey('save-retry')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('save-retry')));
    await tester.pumpAndSettle();
    expect(fixture.saved, hasLength(2));
    expect(fixture.saved[0], same(fixture.saved[1]));
    await tester.tap(find.byKey(const ValueKey('finish')));
    await tester.pumpAndSettle();
    expect(fixture.events.where((event) => event == 'exit'), hasLength(1));
    expect(fixture.popped, isNotNull);
    expect(fixture.popped!.endedEarly, isTrue);
  });

  testWidgets('natural completion remains visible until Finish starts exit', (
    tester,
  ) async {
    final fixture = _PlayerFixture();
    await fixture.mount(tester, prep: 0, seconds: 1);
    await fixture.enter(tester);
    await _step(tester, 1600);
    expect(find.byType(TrainerCompletion), findsOneWidget);
    expect(fixture.route.control.exiting, isFalse);
    expect(fixture.saved, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('finish')));
    await tester.pump();
    expect(fixture.route.control.exiting, isTrue);
    expect(fixture.popped, isNull);
    await tester.pump(const Duration(milliseconds: 279));
    expect(fixture.popped, isNull);
    await tester.pumpAndSettle();
    expect(fixture.popped!.endedEarly, isFalse);
    expect(fixture.saved, hasLength(1));
  });
}
