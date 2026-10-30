import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/src/ui/trainer_completion.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

class _PracticeVoiceSource extends VoiceSource {
  const _PracticeVoiceSource();

  @override
  Set<String> get languages => const {'zh'};
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

class _PracticeVoiceOutput extends RecordingOutput {
  int begins = 0;

  @override
  Future<void> begin() async => begins++;
}

class _PracticeVideoPlatform extends PackedAlphaPlatform
    implements PackedAlphaUriPlatform {
  final sources = <Uri>[];
  final commands = <(int, String, Object?)>[];
  final notifications = StreamController<Map<Object?, Object?>>.broadcast(
    sync: true,
  );

  @override
  bool get isSupported => true;
  @override
  Stream<Map<Object?, Object?>> get events => notifications.stream;
  @override
  Future<({int playerId, int textureId})> create(String asset) =>
      throw StateError('PoseHub practice must resolve a media URI');
  @override
  Future<({int playerId, int textureId})> createUri(Uri sourceUri) async {
    sources.add(sourceUri);
    return (playerId: sources.length, textureId: sources.length + 100);
  }

  @override
  Future<Object?> command(int playerId, String type, [Object? value]) async {
    commands.add((playerId, type, value));
    return null;
  }

  void ready() => notifications.add({'playerId': 1, 'type': 'ready'});
}

class _PracticeFixture {
  final output = _PracticeVoiceOutput();
  final saved = <PoseHubPracticeResult>[];
  final receipts = <SessionResult>[];
  final popped = <SessionResult>[];
  final requests = <TrainerMediaRequest>[];
  final events = <String>[];
  int returns = 0;
}

PoseHubPackAction _timedAction(int seconds) {
  final raw =
      jsonDecode(
            File(
              'assets/pose_hub/app-test-pack-r1/catalog.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final action = (raw['actions']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .firstWhere((action) => action['trainingDefinitionComplete'] == true);
  // Keep a real catalogue action and its media while making time deterministic.
  action['defaultDose'] = {
    'mode': 'time',
    'sets': 1,
    'seconds': seconds,
    'restSeconds': 0,
  };
  action['unilateral'] = false;
  return PoseHubAppTestCatalog.fromJson(raw).semanticCompleteActions.first;
}

Future<_PracticeFixture> _mountPractice(
  WidgetTester tester, {
  required PoseHubPackAction action,
  Future<void>? gate,
  Future<void> Function()? beforeExit,
  Future<void> Function(SessionResult)? complete,
  bool defaultMedia = false,
  bool exitHooks = true,
  TrainerStartMode mode = TrainerStartMode.training,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final fixture = _PracticeFixture();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                final result = await Navigator.of(context).push<SessionResult>(
                  MaterialPageRoute(
                    builder: (_) => PoseHubSinglePracticePage(
                      action: action,
                      mediaBaseUri: Uri.parse('file:///verified-practice/'),
                      startMode: mode,
                      startGate: gate,
                      voice: TrainerVoice(
                        source: const _PracticeVoiceSource(),
                        output: fixture.output,
                        settings: const VoiceSettings(language: 'zh'),
                      ),
                      mediaBuilder: defaultMedia
                          ? null
                          : (_, request) {
                              fixture.requests.add(request);
                              // Represents a host-owned, already loaded poster.
                              return const ColoredBox(
                                key: ValueKey('host-preloaded-poster'),
                                color: Colors.blue,
                              );
                            },
                      onFinished: (result) {
                        fixture.saved.add(result);
                        fixture.events.add('save');
                      },
                      onCompleted: (result) async {
                        fixture.receipts.add(result);
                        fixture.events.add('receipt');
                        await complete?.call(result);
                        fixture.events.add('received');
                      },
                      onExitStarted: !exitHooks
                          ? null
                          : () => fixture.events.add('exit-start'),
                      beforeExitPop: !exitHooks
                          ? null
                          : () async {
                              fixture.events.add('before');
                              await beforeExit?.call();
                              fixture.events.add('before-done');
                            },
                    ),
                  ),
                );
                fixture.returns++;
                fixture.events.add('pop');
                if (result != null) fixture.popped.add(result);
              },
              child: const Text('open-practice'),
            ),
          ),
        ),
      ),
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  await tester.tap(find.text('open-practice'));
  await tester.pump();
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

Future<void> _confirmExit(WidgetTester tester, {bool back = false}) async {
  if (back) {
    await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
  } else {
    await tester.tap(find.byKey(const ValueKey('close')));
  }
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('close-confirm')), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('close-confirm')));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platformCalls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late bool Function() wasAndroid;
  late PoseHubPackAction action;
  late PoseHubPackAction shortAction;
  late _PracticeVideoPlatform video;

  setUpAll(() {
    action = _timedAction(60);
    shortAction = _timedAction(1);
  });
  setUp(() {
    platformCalls.clear();
    wasAndroid = TrainingKeepAlive.isAndroid;
    TrainingKeepAlive.isAndroid = () => true;
    messenger.setMockMethodCallHandler(TrainingKeepAlive.channel, (call) async {
      platformCalls.add(call);
      return true;
    });
    video = _PracticeVideoPlatform();
    UgkPackedAlphaVideo.debugPlatform = video;
    UgkPackedAlphaVideo.debugFilterBuilder = (input) => input;
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(TrainingKeepAlive.channel, null);
    TrainingKeepAlive.isAndroid = wasAndroid;
    UgkPackedAlphaVideo.debugPlatform = null;
    UgkPackedAlphaVideo.debugFilterBuilder = null;
    await video.notifications.close();
  });

  testWidgets('custom poster is present on the first single-practice frame', (
    tester,
  ) async {
    final gate = Completer<void>();
    final requests = <TrainerMediaRequest>[];
    await tester.pumpWidget(
      MaterialApp(
        home: PoseHubSinglePracticePage(
          action: action,
          mediaBaseUri: Uri.parse('file:///verified-practice/'),
          startGate: gate.future,
          mediaBuilder: (_, request) {
            requests.add(request);
            return const ColoredBox(
              key: ValueKey('host-preloaded-poster'),
              color: Colors.blue,
            );
          },
        ),
      ),
    );
    expect(find.byKey(const ValueKey('host-preloaded-poster')), findsOneWidget);
    expect(requests.single.paused, isTrue);
    expect(video.sources, isEmpty);
    expect(platformCalls.where((call) => call.method == 'start'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('gate holds session and host media until completion', (
    tester,
  ) async {
    final gate = Completer<void>();
    final fixture = await _mountPractice(
      tester,
      action: action,
      gate: gate.future,
    );
    // Let the Navigator install the route before testing its first visible frame.
    await tester.pump();
    expect(find.byKey(const ValueKey('host-preloaded-poster')), findsOneWidget);
    expect(find.byType(PoseHubPackMedia), findsNothing);
    expect(video.sources, isEmpty);
    expect(fixture.requests.single.paused, isTrue);
    final initialCounter = _counter(tester);
    await _advance(tester, 5000);
    expect(_counter(tester), initialCounter);
    expect(fixture.output.begins, 0);
    expect(fixture.output.spoken, isEmpty);
    expect(fixture.output.chimes, isEmpty);
    expect(platformCalls.where((call) => call.method == 'start'), isEmpty);
    expect(fixture.saved, isEmpty);
    gate.complete();
    await tester.pump();
    expect(fixture.requests.last.paused, isFalse);
    expect(fixture.output.begins, 1);
    expect(platformCalls.where((call) => call.method == 'start'), hasLength(1));
    await _advance(tester, 2100);
    expect(int.parse(_counter(tester)), inInclusiveRange(57, 59));
    await _confirmExit(tester);
    await tester.pumpAndSettle();
    expect(fixture.saved, hasLength(1));
    expect(fixture.saved.single.activeDuration.inMilliseconds, lessThan(4000));
    expect(fixture.receipts.single.activeSeconds, greaterThanOrEqualTo(2.1));
  });

  testWidgets('default video stays paused after ready until gate releases', (
    tester,
  ) async {
    final gate = Completer<void>();
    final fixture = await _mountPractice(
      tester,
      action: action,
      gate: gate.future,
      defaultMedia: true,
    );
    await tester.pump();
    expect(video.sources, [
      action.video.resolve(Uri.parse('file:///verified-practice/')),
    ]);
    video.ready();
    await tester.pump();
    await _advance(tester, 2000);
    expect(video.commands.where((command) => command.$2 == 'play'), isEmpty);
    expect(
      tester.widget<PoseHubPackMedia>(find.byType(PoseHubPackMedia)).paused,
      isTrue,
    );
    expect(fixture.output.begins, 0);
    expect(platformCalls.where((call) => call.method == 'start'), isEmpty);
    gate.complete();
    await tester.pump();
    expect(
      video.commands.where((command) => command.$2 == 'play'),
      hasLength(1),
    );
    expect(video.sources, hasLength(1));
    expect(fixture.output.begins, 1);
  });

  testWidgets('null gate and media retain immediate built-in playback', (
    tester,
  ) async {
    final fixture = await _mountPractice(
      tester,
      action: action,
      defaultMedia: true,
      exitHooks: false,
    );
    await tester.pump();
    expect(find.byType(PoseHubPackMedia), findsOneWidget);
    expect(fixture.output.begins, 1);
    expect(platformCalls.where((call) => call.method == 'start'), hasLength(1));
    video.ready();
    await tester.pump();
    expect(
      video.commands.where((command) => command.$2 == 'play'),
      hasLength(1),
    );
    await _advance(tester, 1000);
    await _confirmExit(tester);
    await tester.pumpAndSettle();
    expect(fixture.saved, hasLength(1));
    expect(fixture.popped, hasLength(1));
    expect(fixture.events, isNot(contains('exit-start')));
    expect(fixture.events, isNot(contains('before')));
  });

  testWidgets(
    'dispose before gate neither saves nor starts on late completion',
    (tester) async {
      final gate = Completer<void>();
      final fixture = await _mountPractice(
        tester,
        action: action,
        gate: gate.future,
      );
      await _advance(tester, 1500);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      gate.complete();
      await _advance(tester, 6000);
      expect(fixture.saved, isEmpty);
      expect(fixture.receipts, isEmpty);
      expect(fixture.output.begins, 0);
      expect(fixture.output.spoken, isEmpty);
      expect(fixture.output.chimes, isEmpty);
      expect(platformCalls.where((call) => call.method == 'start'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a failed gate releases the single-practice session once', (
    tester,
  ) async {
    final gate = Completer<void>();
    final fixture = await _mountPractice(
      tester,
      action: action,
      gate: gate.future,
    );
    gate.completeError(StateError('host entrance failed'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(fixture.output.begins, 1);
    expect(fixture.requests.last.paused, isFalse);
    expect(platformCalls.where((call) => call.method == 'start'), hasLength(1));
  });

  for (final back in [false, true]) {
    testWidgets(
      '${back ? 'back' : 'close'} before gate awaits exit without saving',
      (tester) async {
        final gate = Completer<void>();
        final exit = Completer<void>();
        final fixture = await _mountPractice(
          tester,
          action: action,
          gate: gate.future,
          beforeExit: () => exit.future,
        );
        await _advance(tester, 400);
        if (back) {
          await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
        } else {
          await tester.tap(find.byKey(const ValueKey('close')));
        }
        await tester.pump();
        expect(fixture.events, ['exit-start', 'before']);
        expect(fixture.saved, isEmpty);
        expect(fixture.returns, 0);
        gate.complete();
        await tester.pump();
        expect(fixture.output.begins, 0);
        exit.complete();
        await tester.pumpAndSettle();
        expect(fixture.returns, 1);
        expect(fixture.popped, isEmpty);
        expect(fixture.receipts, isEmpty);
        expect(platformCalls.where((call) => call.method == 'start'), isEmpty);
      },
    );

    testWidgets(
      '${back ? 'system back' : 'confirmed early exit'} has no completion frame and ordered hooks',
      (tester) async {
        final receipt = Completer<void>();
        final exit = Completer<void>();
        final fixture = await _mountPractice(
          tester,
          action: action,
          complete: (_) => receipt.future,
          beforeExit: () => exit.future,
        );
        await _advance(tester, 2100);
        await _confirmExit(tester, back: back);
        // Saving may finish in the microtasks flushed by tap, but the notification
        // must be first and does not wait for a new rendered frame.
        expect(fixture.events.first, 'exit-start');
        await tester.pump();
        expect(fixture.events, ['exit-start', 'save', 'receipt']);
        expect(find.byType(TrainerCompletion), findsNothing);
        for (var frame = 0; frame < 30; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(find.byType(TrainerCompletion), findsNothing);
        }
        expect(fixture.requests.last.paused, isTrue);
        expect(fixture.saved, hasLength(1));
        expect(fixture.returns, 0);
        receipt.complete();
        await tester.pump();
        expect(fixture.events, [
          'exit-start',
          'save',
          'receipt',
          'received',
          'before',
        ]);
        await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
        await tester.tap(
          find.byKey(const ValueKey('close')),
          warnIfMissed: false,
        );
        for (var frame = 0; frame < 15; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(find.byType(TrainerCompletion), findsNothing);
        }
        expect(fixture.saved, hasLength(1));
        expect(fixture.receipts, hasLength(1));
        expect(
          fixture.events.where((event) => event == 'exit-start'),
          hasLength(1),
        );
        expect(
          fixture.events.where((event) => event == 'before'),
          hasLength(1),
        );
        expect(fixture.returns, 0);
        exit.complete();
        await tester.pumpAndSettle();
        expect(fixture.popped.single, same(fixture.receipts.single));
        expect(fixture.popped.single.endedEarly, isTrue);
        expect(fixture.events.last, 'pop');
      },
    );
  }

  testWidgets('natural completion waits for Finish before exit hooks and pop', (
    tester,
  ) async {
    final exit = Completer<void>();
    final fixture = await _mountPractice(
      tester,
      action: shortAction,
      beforeExit: () => exit.future,
    );
    await _advance(tester, 3000);
    expect(find.byType(TrainerCompletion), findsOneWidget);
    expect(fixture.saved, hasLength(1));
    expect(fixture.events, ['save']);
    await tester.tap(find.byKey(const ValueKey('finish')));
    expect(fixture.events.take(2), ['save', 'exit-start']);
    await tester.pump();
    expect(fixture.events, [
      'save',
      'exit-start',
      'receipt',
      'received',
      'before',
    ]);
    expect(fixture.returns, 0);
    exit.complete();
    await tester.pumpAndSettle();
    expect(fixture.saved, hasLength(1));
    expect(fixture.popped.single.endedEarly, isFalse);
  });

  testWidgets('failed completion receipt exposes retry without exit pop hook', (
    tester,
  ) async {
    final fixture = await _mountPractice(
      tester,
      action: action,
      complete: (_) async => throw StateError('host save failed'),
    );
    await _advance(tester, 600);
    await _confirmExit(tester);
    await tester.pumpAndSettle();
    expect(find.byType(TrainerCompletion), findsOneWidget);
    expect(find.byKey(const ValueKey('save-retry')), findsOneWidget);
    expect(fixture.events, ['exit-start', 'save', 'receipt']);
    expect(fixture.returns, 0);
  });

  testWidgets(
    'preview keeps existing playback and ignores gate and exit hooks',
    (tester) async {
      final gate = Completer<void>();
      final fixture = await _mountPractice(
        tester,
        action: action,
        gate: gate.future,
        mode: TrainerStartMode.preview,
      );
      await _advance(tester, 400);
      expect(fixture.requests.last.paused, isFalse);
      expect(fixture.output.begins, 0);
      expect(find.byKey(const ValueKey('start-training')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('close')));
      await tester.pumpAndSettle();
      expect(fixture.events, ['pop']);
      expect(fixture.saved, isEmpty);
      gate.complete();
      await tester.pump();
      expect(fixture.output.begins, 0);
    },
  );
}
