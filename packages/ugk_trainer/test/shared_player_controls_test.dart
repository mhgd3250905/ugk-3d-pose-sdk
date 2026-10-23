import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

class _Output extends RecordingOutput implements InterruptibleVoiceOutput {
  final events = StreamController<AudioInterruption>.broadcast(sync: true);
  double lastVolume = 1;
  @override
  set volume(double value) => lastVolume = value;
  @override
  Stream<AudioInterruption> get interruptions => events.stream;
  @override
  Future<void> reactivate() async {}
}

void main() {
  Future<void> advance(WidgetTester tester, double seconds) async {
    for (var i = 0; i < seconds * 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> open(
    WidgetTester tester,
    TrainingPlan plan, {
    bool controls = true,
    _Output? output,
    void Function(SessionResult)? save,
    List<String>? media,
    DiscomfortHandler? onDiscomfort,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TrainerPlayer(
          plan: plan,
          prepSeconds: 0,
          transitionSeconds: 5,
          keepAlive: false,
          drillOf: (id) => TrainerDrill(id: id, name: 'name-$id'),
          strings: TrainerStrings.en(),
          showExtendRest: controls,
          showCompleteTimedPhase: controls,
          showSoundToggle: controls,
          showSkipSegment: controls,
          onDiscomfort: onDiscomfort,
          voice: output == null
              ? null
              : TrainerVoice(source: hipSource(), output: output),
          mediaBuilder: (_, request) {
            media?.add(request.drill.id);
            return const SizedBox();
          },
          onFinished: (result) async => save?.call(result),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets('controls remain hidden for an unchanged App constructor', (
    tester,
  ) async {
    await open(tester, planOf([timed('a', 30)]), controls: false);
    for (final key in [
      'extend-rest',
      'complete-timed-phase',
      'sound-toggle',
      'skip-segment',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing);
    }
    await close(tester);
  });

  testWidgets(
    'finish timer records completion; extending rest adds 15 seconds',
    (tester) async {
      SessionResult? result;
      await open(
        tester,
        planOf([timed('a', 30), timed('b', 30)]),
        save: (value) => result = value,
      );
      await advance(tester, 1);
      await tester.tap(find.byKey(const ValueKey('complete-timed-phase')));
      await tester.pump();
      expect(find.byKey(const ValueKey('extend-rest')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('extend-rest')));
      await advance(tester, 6);
      expect(find.byKey(const ValueKey('extend-rest')), findsOneWidget);
      await advance(tester, 15);
      expect(find.byKey(const ValueKey('extend-rest')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('complete-timed-phase')));
      await tester.pump();
      expect(result?.completedExercises, 2);
      expect(result?.items.first.completedSets, 1);
      await close(tester);
    },
  );

  testWidgets(
    'mute silences future cues and unmute preserves the same training clock',
    (tester) async {
      final output = _Output();
      await open(tester, planOf([reps('h-squat', 4)]), output: output);
      await tester.tap(find.byKey(const ValueKey('sound-toggle')));
      await tester.pump();
      expect(output.lastVolume, 0);
      final spoken = output.spoken.length;
      final chimes = output.chimes.length;
      await advance(tester, 4);
      expect(output.spoken, hasLength(spoken));
      expect(output.chimes, hasLength(chimes));
      await tester.tap(find.byKey(const ValueKey('sound-toggle')));
      await tester.pump();
      expect(
        output.spoken,
        hasLength(spoken),
        reason: 'unmute never replays the missed first count',
      );
      await advance(tester, 3);
      expect(output.lastVolume, 1);
      expect(output.spoken.length, greaterThan(spoken));
      expect(find.byKey(const ValueKey('complete-timed-phase')), findsNothing);
      await close(tester);
      await output.events.close();
    },
  );

  testWidgets(
    'interruption pauses the clock until explicit resume after ending',
    (tester) async {
      final output = _Output();
      SessionResult? result;
      await open(
        tester,
        planOf([timed('a', 3)]),
        output: output,
        save: (value) => result = value,
      );
      output.events.add(AudioInterruption.began);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pause')));
      await advance(tester, 4);
      output.events.add(AudioInterruption.ended);
      await advance(tester, 4);
      expect(result, isNull);
      await tester.tap(find.byKey(const ValueKey('pause')));
      await advance(tester, 4);
      expect(result?.full, isTrue);
      await close(tester);
      await output.events.close();
    },
  );

  testWidgets(
    'substitution keeps segment identities and the parent completion contract',
    (tester) async {
      SessionResult? result;
      final media = <String>[];
      final item = PlanItem(
        exerciseId: 'ytw',
        mode: DoseMode.time,
        sets: 1,
        perSide: false,
        restSeconds: 0,
        segments: const [
          PlanSegment(
            id: 'y',
            exerciseId: 'pose-y',
            mode: DoseMode.time,
            workSeconds: 2,
          ),
          PlanSegment(
            id: 't',
            exerciseId: 'pose-t',
            mode: DoseMode.time,
            workSeconds: 2,
          ),
        ],
      );
      await open(
        tester,
        planOf([item]),
        media: media,
        save: (value) => result = value,
        onDiscomfort: (_, _) async => const DiscomfortDecision(
          DiscomfortAction.substitute,
          substituteId: 'easier-y',
        ),
      );
      await tester.tap(find.byKey(const ValueKey('discomfort')));
      await tester.pump();
      expect(media, contains('easier-y'));
      expect(find.text('name-ytw'), findsOneWidget);
      await advance(tester, 5);
      expect(media, contains('pose-t'));
      expect(result?.full, isTrue);
      expect(result?.items.single.completedSets, 1);
      await close(tester);
    },
  );

  testWidgets(
    'segments switch media under one parent title and skipped segment is partial',
    (tester) async {
      final media = <String>[];
      SessionResult? result;
      final parent = PlanItem(
        exerciseId: 'ytw',
        mode: DoseMode.time,
        sets: 1,
        perSide: false,
        restSeconds: 0,
        segments: const [
          PlanSegment(
            id: 'y',
            exerciseId: 'pose-y',
            mode: DoseMode.time,
            workSeconds: 2,
            label: 'Y',
          ),
          PlanSegment(
            id: 't',
            exerciseId: 'pose-t',
            mode: DoseMode.time,
            workSeconds: 2,
            label: 'T',
          ),
          PlanSegment(
            id: 'w',
            exerciseId: 'pose-w',
            mode: DoseMode.time,
            workSeconds: 2,
            label: 'W',
          ),
        ],
      );
      await open(
        tester,
        planOf([parent]),
        media: media,
        save: (value) => result = value,
      );
      expect(find.text('name-ytw'), findsOneWidget);
      expect(media, contains('pose-y'));
      await advance(tester, 2.1);
      expect(media, contains('pose-t'));
      expect(find.text('name-ytw'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('skip-segment')));
      await tester.pump();
      expect(media, contains('pose-w'));
      await advance(tester, 3);
      expect(result?.items, hasLength(1));
      expect(result?.full, isFalse);
      expect(result?.items.single.completedSets, 0);
      await close(tester);
    },
  );
}
