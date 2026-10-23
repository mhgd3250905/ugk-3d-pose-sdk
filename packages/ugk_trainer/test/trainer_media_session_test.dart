import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

class _InterruptibleOutput extends RecordingOutput
    implements InterruptibleVoiceOutput {
  final events = StreamController<AudioInterruption>.broadcast(sync: true);
  int begins = 0;

  @override
  Future<void> begin() async => begins++;

  @override
  Stream<AudioInterruption> get interruptions => events.stream;

  @override
  Future<void> reactivate() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<bool> Function(MethodCall)? reply;

  setUp(() {
    calls.clear();
    reply = null;
    TrainingKeepAlive.isAndroid = () => true;
    messenger.setMockMethodCallHandler(TrainingKeepAlive.channel, (call) async {
      calls.add(call);
      return await reply?.call(call) ?? true;
    });
  });

  tearDown(() {
    TrainingKeepAlive.isAndroid = () => false;
    messenger.setMockMethodCallHandler(TrainingKeepAlive.channel, null);
  });

  Map<Object?, Object?> args(MethodCall call) => call.arguments as Map;
  List<MethodCall> states() => [
    for (final call in calls)
      if (call.method == 'setPlaybackState') call,
  ];

  Future<void> open(
    WidgetTester tester,
    _InterruptibleOutput output, {
    Future<DiscomfortDecision?> Function()? discomfort,
    VoiceSettings settings = const VoiceSettings(),
  }) => tester.pumpWidget(
    MaterialApp(
      home: TrainerPlayer(
        plan: planOf([timed('a', 30)]),
        prepSeconds: 0,
        drillOf: (id) => TrainerDrill(id: id, name: id),
        strings: TrainerStrings.en(),
        voice: TrainerVoice(
          source: hipSource(),
          output: output,
          settings: settings,
        ),
        mediaBuilder: (_, _) => const SizedBox(height: 50),
        onFinished: (_) async {},
        onDiscomfort: discomfort == null ? null : (_, _) => discomfort(),
        replayBuilder: (_, _, replay) => TextButton(
          key: const ValueKey('replay'),
          onPressed: replay,
          child: const Text('again'),
        ),
      ),
    ),
  );

  testWidgets('silent visual training and replay use only a generic hold', (
    tester,
  ) async {
    final output = _InterruptibleOutput();
    await open(
      tester,
      output,
      settings: const VoiceSettings(voice: false, chimes: false),
    );
    await tester.pump();
    final first = TrainingKeepAlive.currentSession;
    expect(args(calls.single)['mediaPlayback'], isFalse);
    expect(output.begins, 0);
    await tester.tap(find.byKey(const ValueKey('pause')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('pause')));
    await tester.pump();
    expect(states(), isEmpty);
    await tester.tap(find.byKey(const ValueKey('skip')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('replay')));
    await tester.pump();
    final second = TrainingKeepAlive.currentSession;
    expect(second, isNot(first));
    final starts = calls.where((call) => call.method == 'start');
    expect(starts, hasLength(3), reason: 'initial, renew and fresh replay');
    expect(
      starts.every((call) => args(call)['mediaPlayback'] == false),
      isTrue,
    );
    expect(output.begins, 0);
    expect(states(), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(calls.last.method, 'stop');
    expect(args(calls.last)['session'], second);
    await output.events.close();
  });

  testWidgets(
    'player media state follows pause, interruption and manual resume',
    (tester) async {
      final output = _InterruptibleOutput();
      await open(tester, output);
      await tester.pump();
      final owner = args(calls.single)['session'];
      expect(args(calls.single)['mediaPlayback'], isTrue);
      await tester.tap(find.byKey(const ValueKey('pause')));
      await tester.pump();
      expect(args(states().last), {'session': owner, 'paused': true});
      await tester.tap(find.byKey(const ValueKey('pause')));
      await tester.pump();
      expect(args(states().last), {'session': owner, 'paused': false});
      for (final interruption in [
        AudioInterruption.began,
        AudioInterruption.unplugged,
      ]) {
        output.events.add(interruption);
        await tester.pump();
        expect(args(states().last), {'session': owner, 'paused': true});
        final count = states().length;
        output.events.add(AudioInterruption.ended);
        await tester.pump();
        expect(states(), hasLength(count), reason: 'ending never auto-resumes');
        await tester.tap(find.byKey(const ValueKey('pause')));
        await tester.pump();
        expect(args(states().last), {'session': owner, 'paused': false});
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(calls.last.method, 'stop');
      expect(args(calls.last)['session'], owner);
      await output.events.close();
    },
  );

  testWidgets('app discomfort pauses media until its answer then resumes', (
    tester,
  ) async {
    final output = _InterruptibleOutput();
    final answer = Completer<DiscomfortDecision?>();
    await open(tester, output, discomfort: () => answer.future);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('discomfort')));
    await tester.pump();
    expect(args(states().last)['paused'], isTrue);
    final count = states().length;
    await tester.pump(const Duration(seconds: 1));
    expect(states(), hasLength(count));
    answer.complete(null);
    await tester.pump();
    expect(args(states().last)['paused'], isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await output.events.close();
  });

  testWidgets(
    'ending a call during a discomfort dialog still needs manual resume',
    (tester) async {
      final output = _InterruptibleOutput();
      final answer = Completer<DiscomfortDecision?>();
      await open(tester, output, discomfort: () => answer.future);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('discomfort')));
      await tester.pump();
      output.events.add(AudioInterruption.began);
      output.events.add(AudioInterruption.ended);
      answer.complete(null);
      await tester.pump();
      expect(args(states().last)['paused'], isTrue);
      await tester.tap(find.byKey(const ValueKey('pause')));
      await tester.pump();
      expect(args(states().last)['paused'], isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await output.events.close();
    },
  );

  testWidgets('pending old pause reply cannot alter a quick replay owner', (
    tester,
  ) async {
    final oldReply = Completer<bool>();
    final output = _InterruptibleOutput();
    await open(tester, output);
    await tester.pump();
    final first = TrainingKeepAlive.currentSession;
    reply = (call) => call.method == 'setPlaybackState'
        ? oldReply.future
        : Future.value(true);
    await tester.tap(find.byKey(const ValueKey('pause')));
    await tester.pump();
    expect(args(states().single), {'session': first, 'paused': true});
    await tester.tap(find.byKey(const ValueKey('skip')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('replay')));
    await tester.pump();
    final second = TrainingKeepAlive.currentSession;
    expect(second, isNot(first));
    final starts = calls.where((c) => c.method == 'start').toList();
    expect(args(starts.last)['mediaPlayback'], isTrue);
    final count = calls.length;
    reply = null;
    oldReply.complete(true);
    await tester.pump();
    expect(calls, hasLength(count), reason: 'old reply has no state callback');
    await tester.pump(const Duration(seconds: 5));
    expect(TrainingKeepAlive.currentSession, second);
    expect(calls.where((c) => c.method == 'stop'), hasLength(1));
    await tester.tap(find.byKey(const ValueKey('pause')));
    await tester.pump();
    expect(args(states().last), {'session': second, 'paused': true});
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(args(calls.last)['session'], second);
    await output.events.close();
  });
}
