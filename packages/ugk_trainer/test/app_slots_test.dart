import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

class _AppBuilder extends SessionBuilder {
  _AppBuilder() : super(prepSeconds: 0, transitionSeconds: 5);
  double workSecondsOverride = 2;

  @override
  List<SessionPhase> phases(TrainingPlan plan) => [
    SessionPhase(
      kind: PhaseKind.work,
      seconds: workSecondsOverride,
      exerciseId: 'a',
      item: plan.blocks.single.items.first,
      itemIndex: 0,
      blockIndex: 0,
      itemInBlock: 0,
      set: 1,
      sets: 1,
    ),
    ...super.phases(plan).where((p) => p.itemIndex > 0),
  ];
}

class _ReplayOutput extends RecordingOutput {
  int begins = 0;
  int ends = 0;
  @override
  Future<void> begin() async => begins++;
  @override
  Future<void> end() async => ends++;
}

class _PendingEndOutput extends _ReplayOutput {
  final ending = Completer<void>();
  bool active = false;
  @override
  Future<void> begin() async {
    begins++;
    active = true;
  }

  @override
  Future<void> end() async {
    ends++;
    await ending.future;
    active = false;
  }
}

class _LongCloseScript extends _AppScript {
  _LongCloseScript(super.source, super.language);
  @override
  List<VoiceCue> cues(
    SessionPhase p, {
    required double planSeconds,
    bool bySkip = false,
  }) => p.kind == PhaseKind.done
      ? [VoiceCue(0, List.filled(6, 'p.finish'), CuePriority.call)]
      : super.cues(p, planSeconds: planSeconds, bySkip: bySkip);
}

class _SilentPauseOutput extends _ReplayOutput
    implements InterruptibleVoiceOutput {
  int reactivations = 0;
  @override
  Stream<AudioInterruption> get interruptions => const Stream.empty();
  @override
  Future<void> reactivate() async => reactivations++;
}

class _AppScript extends SessionScript {
  _AppScript(VoiceSource source, String language)
    : super(source: source, lang: language);
  @override
  List<VoiceCue> cues(
    SessionPhase p, {
    required double planSeconds,
    bool bySkip = false,
  }) => p.isWork
      ? const [
          VoiceCue(0, ['p.skip'], CuePriority.call),
        ]
      : const [];
}

void main() {
  final plan = planOf([timed('a', 30), timed('b', 3), timed('c', 3)]);

  testWidgets(
    'silent app discomfort cancel, replacement and rest feedback preserve work voice',
    (tester) async {
      for (final scenario in ['cancel', 'replacement', 'afterExercise']) {
        final source = hipSource();
        final output = _SilentPauseOutput();
        final builder = _AppBuilder();
        final short = planOf([timed('a', 30), timed('b', 3)]);
        final answer = Completer<DiscomfortDecision?>();
        DiscomfortContext? reported;
        await tester.pumpWidget(
          MaterialApp(
            home: TrainerPlayer(
              plan: short,
              drillOf: (id) => TrainerDrill(id: id, name: id),
              strings: TrainerStrings.zh(),
              keepAlive: false,
              sessionBuilder: builder,
              announceDiscomfortPause: false,
              voice: TrainerVoice(
                source: source,
                output: output,
                scriptBuilder: _AppScript.new,
              ),
              mediaBuilder: (_, _) => const SizedBox(height: 100),
              onFinished: (_) async {},
              onDiscomfort: (_, at) {
                reported = at;
                return answer.future;
              },
              restFeedbackBuilder: (_, feedback) => TextButton(
                key: const ValueKey('rest-discomfort'),
                onPressed: feedback.reportDiscomfort,
                child: const Text('report finished exercise'),
              ),
            ),
          ),
        );
        await tester.pump(
          Duration(seconds: scenario == 'afterExercise' ? 3 : 1),
        );
        output.spoken.clear();
        await tester.tap(
          find.byKey(
            ValueKey(
              scenario == 'afterExercise' ? 'rest-discomfort' : 'discomfort',
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        expect(output.spoken, isEmpty, reason: '$scenario must enter silently');
        expect(reported!.afterExercise, scenario == 'afterExercise');
        answer.complete(
          scenario == 'replacement'
              ? DiscomfortDecision(
                  DiscomfortAction.continueEasier,
                  subtitle: '幅度小一点，别勉强',
                  replacementPhases: builder.phases(short),
                )
              : scenario == 'afterExercise'
              ? const DiscomfortDecision(DiscomfortAction.continueEasier)
              : null,
        );
        await tester.pump();
        if (scenario == 'replacement') {
          expect(
            find.text('幅度小一点，别勉强'),
            findsOneWidget,
            reason: 'a response remains visible without a voice clip',
          );
        }
        for (var i = 0; i < 24; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        final spoken = output.spoken.expand((clips) => clips).toList();
        expect(spoken, isNot(contains(source.asset('p.paused', lang: 'zh'))));
        expect(spoken, isNot(contains(source.asset('p.resume', lang: 'zh'))));
        expect(
          spoken,
          contains(source.asset('p.skip', lang: 'zh')),
          reason: '$scenario resumes the later work script',
        );
        expect(output.reactivations, 1);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'fixed countdown dial fits number and caption at 1.5 text scale',
    (tester) async {
      final progress = ValueNotifier<double>(0);
      addTearDown(progress.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: Scaffold(
              body: Center(
                child: TrainerCountdownRing(
                  theme: TrainerTheme.dark,
                  progress: progress,
                  value: '25',
                  caption: '准备开始',
                  size: 112,
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('25'), findsOneWidget);
      expect(find.text('准备开始'), findsOneWidget);
      expect(
        tester.getSize(find.byType(TrainerCountdownRing)),
        const Size(112, 112),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'discomfort has one exact accessible button label and tap action',
    (tester) async {
      final semantics = tester.ensureSemantics();
      var reports = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: TrainerPlayer(
            plan: plan,
            drillOf: (id) => TrainerDrill(id: id, name: id),
            strings: TrainerStrings.zh(),
            prepSeconds: 0,
            keepAlive: false,
            mediaBuilder: (_, _) => const SizedBox(height: 100),
            onFinished: (_) async {},
            onDiscomfort: (_, _) async {
              reports++;
              return null;
            },
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      final button = find.semantics.byLabel('不舒服');
      expect(button, findsOneWidget);
      expect(
        button.evaluate().single,
        matchesSemantics(label: '不舒服', isButton: true, hasTapAction: true),
      );
      tester.semantics.tap(button);
      await tester.pump();
      expect(reports, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    },
  );

  test(
    'app filters can restart with a rest and retain original coordinates',
    () {
      final builder = SessionBuilder(prepSeconds: 0);
      final engine = SessionEngine(builder.phases(plan));
      engine.update(1);
      final filtered = builder
          .phases(plan)
          .where((p) => p.itemIndex != 1)
          .toList();
      engine.restartWith(filtered, 1, fromItemIndex: 1, withRest: true);
      expect(engine.phase.kind, PhaseKind.rest);
      expect(engine.phase.exerciseId, 'c');
      expect(engine.phase.itemIndex, 2);
      expect(engine.visits.last.exit, PhaseExit.replaced);
      engine.update(100);
      final result = SessionRecorder(
        plan: plan,
        totalExercises: 3,
      ).finish(engine, activeSeconds: 100);
      expect(result.items[0].status, ItemStatus.partial);
      expect(result.items[1].status, ItemStatus.notReached);
      expect(result.items[2].status, ItemStatus.completed);
    },
  );

  test('filtering every remaining item reaches done', () {
    final engine = SessionEngine(SessionBuilder(prepSeconds: 0).phases(plan));
    engine.update(1);
    engine.restartWith(const [
      SessionPhase(kind: PhaseKind.done, seconds: 0, itemIndex: 3),
    ], 1);
    expect(engine.done, isTrue);
    expect(engine.visits.last.exit, PhaseExit.replaced);
    expect(engine.visits.last.phase.exerciseId, 'a');
    expect(engine.fullyCompletedExercises, 0);
  });

  test('skipping every exercise never produces a full completion', () {
    final engine = SessionEngine(SessionBuilder(prepSeconds: 0).phases(plan));
    engine.update(1);
    engine.skip(1);
    engine.skip(1);
    engine.skip(1);
    engine.skip(1);
    engine.skip(1);
    expect(engine.done, isTrue);
    final result = SessionRecorder(
      plan: plan,
      totalExercises: 3,
    ).finish(engine, activeSeconds: 1);
    expect(result.completedExercises, 0);
    expect(result.full, isFalse);
  });

  test('one finished side with the other removed remains partial', () {
    final sided = planOf([timed('a', 3, perSide: true)]);
    final builder = SessionBuilder(prepSeconds: 0);
    final engine = SessionEngine(builder.phases(sided));
    engine.update(4);
    expect(engine.phase.kind, PhaseKind.switchSide);
    engine.restartWith(const [
      SessionPhase(kind: PhaseKind.done, seconds: 0, itemIndex: 1),
    ], 4);
    expect(engine.fullyCompletedExercises, 0);
    expect(
      SessionRecorder(
        plan: sided,
        totalExercises: 1,
      ).finish(engine, activeSeconds: 4).full,
      isFalse,
    );
  });

  test(
    'result preserves unequal per-side sets without counting replays twice',
    () {
      final sided = planOf([timed('a', 3, sets: 2, perSide: true)]);
      final phases = [
        for (final (side, count) in [(Side.right, 3), (Side.left, 2)])
          for (var set = 1; set <= count; set++)
            SessionPhase(
              kind: PhaseKind.work,
              seconds: 3,
              exerciseId: 'a',
              item: sided.blocks.single.items.single,
              itemIndex: 0,
              blockIndex: 0,
              itemInBlock: 0,
              side: side,
              set: set,
              sets: count,
            ),
        const SessionPhase(kind: PhaseKind.done, seconds: 0, itemIndex: 1),
      ];
      final engine = SessionEngine(phases)..update(100);
      engine.previous(100);
      engine.update(200);
      final result = SessionRecorder(
        plan: sided,
        totalExercises: 1,
      ).finish(engine, activeSeconds: 15);
      expect(result.items.single.plannedSideSets, {'right': 3, 'left': 2});
      expect(result.items.single.completedSideSets, {'right': 3, 'left': 2});
      // Two bilateral sets plus one required right-only set in the actual
      // initial arrangement. Replaying them does not create more sets.
      expect(result.items.single.plannedSets, 3);
      expect(result.items.single.completedSets, 3);
      expect(result.completedExercises, 1);
      final decoded = SessionResult.fromJson(result.toJson());
      expect(decoded.items.single.completedSideSets, {'right': 3, 'left': 2});
    },
  );

  testWidgets('app builder and rest feedback target the completed exercise', (
    tester,
  ) async {
    final saved = <SessionResult>[];
    DiscomfortContext? reported;
    final appBuilder = _AppBuilder();
    final short = planOf([timed('a', 30), timed('b', 3)]);
    await tester.pumpWidget(
      MaterialApp(
        home: TrainerPlayer(
          plan: short,
          drillOf: (id) => TrainerDrill(id: id, name: id),
          strings: TrainerStrings.en(),
          keepAlive: false,
          sessionBuilder: appBuilder,
          mediaBuilder: (_, _) => const SizedBox(height: 100),
          onFinished: (result) async => saved.add(result),
          onDiscomfort: (_, at) async {
            reported = at;
            return DiscomfortDecision(
              DiscomfortAction.continueEasier,
              replacementPhases: appBuilder.phases(short),
              restartItemIndex: at.resumePhase.itemIndex,
              withRest: true,
              note: 'finished-exercise pain',
            );
          },
          restFeedbackBuilder: (_, feedback) => TextButton(
            key: const ValueKey('app-rest-pain'),
            onPressed: feedback.reportDiscomfort,
            child: Text('feedback-${feedback.completedPhase.exerciseId}'),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(
      find.text('feedback-a'),
      findsOneWidget,
      reason: 'the injected builder uses 2 seconds instead of the plan 30',
    );
    expect(
      find.byKey(const ValueKey('discomfort')),
      findsNothing,
      reason: 'rest feedback must not report pain on the upcoming exercise',
    );
    await tester.tap(find.byKey(const ValueKey('app-rest-pain')));
    await tester.pump();
    expect(reported!.phase.exerciseId, 'a');
    expect(reported!.resumePhase.exerciseId, 'b');
    expect(reported!.afterExercise, isTrue);
    expect(saved, isEmpty);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(saved, hasLength(1));
    expect(saved.single.discomfort.single.exerciseId, 'a');
    expect(saved.single.discomfort.single.note, 'finished-exercise pain');
    expect(saved.single.items.last.status, ItemStatus.completed);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('replacement with no remaining work completes and saves once', (
    tester,
  ) async {
    final saved = <SessionResult>[];
    await tester.pumpWidget(
      MaterialApp(
        home: TrainerPlayer(
          plan: plan,
          drillOf: (id) => TrainerDrill(id: id, name: id),
          strings: TrainerStrings.en(),
          keepAlive: false,
          prepSeconds: 0,
          mediaBuilder: (_, _) => const SizedBox(height: 100),
          onFinished: (result) async => saved.add(result),
          onDiscomfort: (_, _) async => const DiscomfortDecision(
            DiscomfortAction.skip,
            replacementPhases: [
              SessionPhase(kind: PhaseKind.done, seconds: 0, itemIndex: 3),
            ],
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const ValueKey('discomfort')));
    await tester.pump();
    await tester.pump();
    expect(saved, hasLength(1));
    expect(saved.single.discomfort.single.action, DiscomfortAction.skip);
    expect(saved.single.items.last.status, ItemStatus.notReached);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(saved, hasLength(1));
  });

  testWidgets(
    'replay owns a fresh result and hold without ending shared audio',
    (tester) async {
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      TrainingKeepAlive.isAndroid = () => true;
      messenger.setMockMethodCallHandler(TrainingKeepAlive.channel, (
        call,
      ) async {
        calls.add(call);
        return true;
      });
      addTearDown(() {
        TrainingKeepAlive.isAndroid = () => false;
        messenger.setMockMethodCallHandler(TrainingKeepAlive.channel, null);
      });
      final saved = <SessionResult>[];
      final output = _ReplayOutput();
      final builder = _AppBuilder();
      var scriptBuilds = 0;
      final source = hipSource();
      await tester.pumpWidget(
        MaterialApp(
          home: TrainerPlayer(
            plan: planOf([timed('a', 30)]),
            drillOf: (id) => TrainerDrill(id: id, name: id),
            strings: TrainerStrings.en(),
            sessionBuilder: builder,
            voice: TrainerVoice(
              source: source,
              output: output,
              scriptBuilder: (source, language) {
                scriptBuilds++;
                return _AppScript(source, language);
              },
            ),
            doseLabel: (_) => 'authored dose',
            mediaBuilder: (_, _) => const SizedBox(height: 100),
            onFinished: (result) async => saved.add(result),
            replayBuilder: (_, _, replay) => TextButton(
              key: const ValueKey('replay'),
              onPressed: () {
                builder.workSecondsOverride = 20;
                replay();
              },
              child: const Text('again'),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('authored dose'), findsOneWidget);
      expect(
        output.spoken.expand((clips) => clips),
        contains(source.asset('p.skip', lang: 'zh')),
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(saved, hasLength(1));
      final firstOwner = TrainingKeepAlive.currentSession;
      await tester.tap(find.byKey(const ValueKey('replay')));
      await tester.pump();
      final secondOwner = TrainingKeepAlive.currentSession;
      expect(secondOwner, isNot(firstOwner));
      expect(output.ends, 0);
      await tester.pump(const Duration(seconds: 6));
      expect(
        TrainingKeepAlive.currentSession,
        secondOwner,
        reason: 'the first round delayed release must not stop this round',
      );
      expect(output.ends, 0);
      expect(saved, hasLength(1));
      await tester.pump(const Duration(seconds: 15));
      await tester.pump();
      expect(saved, hasLength(2));
      expect(saved.last.sessionId, isNot(saved.first.sessionId));
      expect(output.begins, 2);
      expect(scriptBuilds, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(output.ends, 1);
      expect(calls.where((call) => call.method == 'start'), hasLength(2));
    },
  );
  for (final scenario in ['normal', 'long closing line', 'pending end']) {
    testWidgets(
      'terminal audio releases while staying on done, then replays safely ($scenario)',
      (tester) async {
        final calls = <MethodCall>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        TrainingKeepAlive.isAndroid = () => true;
        messenger.setMockMethodCallHandler(TrainingKeepAlive.channel, (
          call,
        ) async {
          calls.add(call);
          return true;
        });
        addTearDown(() {
          TrainingKeepAlive.isAndroid = () => false;
          messenger.setMockMethodCallHandler(TrainingKeepAlive.channel, null);
        });
        final output = scenario == 'pending end'
            ? _PendingEndOutput()
            : _ReplayOutput();
        final source = hipSource();
        final builder = _AppBuilder();
        final saved = <SessionResult>[];
        await tester.pumpWidget(
          MaterialApp(
            home: TrainerPlayer(
              plan: planOf([timed('a', 30)]),
              drillOf: (id) => TrainerDrill(id: id, name: id),
              strings: TrainerStrings.en(),
              sessionBuilder: builder,
              voice: TrainerVoice(
                source: source,
                output: output,
                scriptBuilder: scenario == 'long closing line'
                    ? _LongCloseScript.new
                    : _AppScript.new,
              ),
              mediaBuilder: (_, _) => const SizedBox(height: 100),
              onFinished: (result) async => saved.add(result),
              replayBuilder: (_, _, replay) => TextButton(
                key: const ValueKey('replay'),
                onPressed: () {
                  builder.workSecondsOverride = 20;
                  replay();
                },
                child: const Text('again'),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        expect(saved, hasLength(1));
        final firstOwner = TrainingKeepAlive.currentSession;
        expect(firstOwner, isNotNull);
        expect(output.ends, 0);
        await tester.pump(const Duration(milliseconds: 3900));
        expect(
          output.ends,
          0,
          reason: 'closing audio keeps at least the original four seconds',
        );
        if (scenario == 'long closing line') {
          expect(
            output.spoken.last,
            List.filled(6, source.asset('p.finish', lang: 'zh')),
          );
          await tester.pump(const Duration(milliseconds: 200));
          expect(
            output.ends,
            0,
            reason: 'a long queued closing line is not cut at four seconds',
          );
          final seconds =
              source.total(List.filled(6, 'p.finish'), lang: 'zh') +
              VoiceQueue.tailGrace;
          await tester.pump(
            Duration(milliseconds: ((seconds - 4.1) * 1000).ceil() + 100),
          );
        } else {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(
          output.ends,
          1,
          reason: 'remaining on done releases the audio owner',
        );
        expect(TrainingKeepAlive.currentSession, isNull);
        expect(calls.where((c) => c.method == 'stop'), hasLength(1));
        await tester.tap(find.byKey(const ValueKey('replay')));
        await tester.pump();
        if (output is _PendingEndOutput) {
          expect(
            output.begins,
            1,
            reason: 'new begin waits until native end has finished',
          );
          await tester.pump(const Duration(seconds: 1));
          expect(output.begins, 1);
          output.ending.complete();
          await tester.pump();
          expect(
            output.active,
            isTrue,
            reason: 'old end cannot close new playback',
          );
        }
        expect(output.begins, 2);
        final secondOwner = TrainingKeepAlive.currentSession;
        expect(secondOwner, isNot(firstOwner));
        await tester.pump(const Duration(seconds: 6));
        expect(
          output.ends,
          1,
          reason: 'the first terminal timer cannot end the replay',
        );
        expect(TrainingKeepAlive.currentSession, secondOwner);
        expect(saved, hasLength(1));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(
          output.ends,
          2,
          reason: 'dispose releases the new owner exactly once',
        );
        await tester.pump(const Duration(seconds: 10));
        expect(output.ends, 2, reason: 'dispose cancels terminal timers');
      },
    );
  }
}
