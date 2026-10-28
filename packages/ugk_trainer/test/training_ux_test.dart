import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

class _MediaProbe extends StatefulWidget {
  const _MediaProbe({required this.paused});
  final bool paused;
  @override
  State<_MediaProbe> createState() => _MediaProbeState();
}

class _MediaProbeState extends State<_MediaProbe> {
  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  Future<void> mount(
    WidgetTester tester, {
    TrainerStartMode mode = TrainerStartMode.training,
    VoidCallback? started,
    Future<void> Function(SessionResult)? finished,
    Future<void> Function(SessionResult)? completed,
    List<SessionResult?>? popped,
    DiscomfortHandler? discomfort,
    bool known = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await withClock(Clock(tester.binding.clock.now), () async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              child: const Text('open'),
              onPressed: () async {
                final result = await Navigator.of(context).push<SessionResult>(
                  MaterialPageRoute(
                    builder: (_) => TrainerPlayer(
                      plan: planOf([timed('a', 3)]),
                      drillOf: (id) => !known
                          ? null
                          : TrainerDrill(
                              id: id,
                              name: 'Demo',
                              targetMuscles: 'Core',
                              equipment: 'None',
                              cues: const [
                                'Stand tall',
                                'Keep breathing',
                                'Move gently',
                              ],
                              precautions: const ['Do not force the range'],
                            ),
                      strings: TrainerStrings.en(),
                      startMode: mode,
                      onStartTraining: started,
                      onFinished: finished ?? (_) async {},
                      onCompleted: completed,
                      onDiscomfort: discomfort,
                      keepAlive: false,
                      prepSeconds: 2,
                      theme: TrainerTheme.light,
                      mediaBuilder: (_, request) =>
                          _MediaProbe(paused: request.paused),
                    ),
                  ),
                );
                popped?.add(result);
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    });
  }

  Future<void> advance(WidgetTester tester, double seconds) async {
    for (var i = 0; i < seconds * 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('an empty playable session still saves once and enables Finish', (
    tester,
  ) async {
    final saved = <SessionResult>[];
    await mount(
      tester,
      known: false,
      finished: (result) async => saved.add(result),
    );
    await tester.pump();
    expect(saved, hasLength(1));
    expect(saved.single.totalExercises, 0);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('finish')))
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(saved, hasLength(1));
  });

  testWidgets(
    'preview loops without running or saving; start keeps media state',
    (tester) async {
      var starts = 0;
      final saved = <SessionResult>[];
      await mount(
        tester,
        mode: TrainerStartMode.preview,
        started: () => starts++,
        finished: (value) async => saved.add(value),
      );
      expect(find.text('Exercise demonstration'), findsOneWidget);
      expect(find.byKey(const ValueKey('progress')), findsNothing);
      expect(find.byKey(const ValueKey('index')), findsNothing);
      expect(find.byKey(const ValueKey('prev')).hitTestable(), findsNothing);
      expect(
        find.byKey(const ValueKey('discomfort')).hitTestable(),
        findsNothing,
      );
      expect(
        tester.widget<_MediaProbe>(find.byType(_MediaProbe)).paused,
        isFalse,
      );
      final mediaState = tester.state(find.byType(_MediaProbe));
      final previewCenter = tester.getCenter(
        find.byKey(const ValueKey('start-training')),
      );
      await advance(tester, 12);
      expect(saved, isEmpty);
      await tester.tap(find.byKey(const ValueKey('start-training')));
      await tester.pump();
      expect(starts, 1);
      await tester.pump(const Duration(milliseconds: 150));
      final morph = tester.getSize(
        find.byKey(const ValueKey('start-training-morph')),
      );
      expect(morph.width, greaterThan(76));
      expect(morph.width, lessThan(350));
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('Exercise demonstration'), findsNothing);
      expect(
        identical(mediaState, tester.state(find.byType(_MediaProbe))),
        isTrue,
      );
      expect(
        tester.getCenter(find.byKey(const ValueKey('pause'))).dy,
        closeTo(previewCenter.dy, .1),
      );
      expect(find.byKey(const ValueKey('counter')), findsOneWidget);
      await advance(tester, 6);
      expect(saved, hasLength(1));
      expect(
        saved.single.activeSeconds,
        lessThan(7),
        reason: 'preview time is excluded',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('leaving preview does not save an unstarted workout', (
    tester,
  ) async {
    final saved = <SessionResult>[];
    final popped = <SessionResult?>[];
    await mount(
      tester,
      mode: TrainerStartMode.preview,
      popped: popped,
      finished: (result) async => saved.add(result),
    );
    await tester.tap(find.byKey(const ValueKey('close')));
    await tester.pumpAndSettle();
    expect(popped, [null]);
    expect(saved, isEmpty);
  });

  testWidgets('closing during the start morph cancels preparation and saving', (
    tester,
  ) async {
    final saved = <SessionResult>[];
    final popped = <SessionResult?>[];
    await mount(
      tester,
      mode: TrainerStartMode.preview,
      popped: popped,
      finished: (result) async => saved.add(result),
    );
    await tester.tap(find.byKey(const ValueKey('start-training')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('close')));
    await tester.pumpAndSettle();
    expect(popped, [null]);
    expect(saved, isEmpty);
  });

  testWidgets('the instructions sheet cannot interrupt the start morph', (
    tester,
  ) async {
    await mount(tester, mode: TrainerStartMode.preview);
    expect(find.byType(TrainerCueCarousel).hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('start-training')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(TrainerCueCarousel).hitTestable(), findsNothing);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('start-training')), findsNothing);
    expect(find.byType(TrainerCueCarousel).hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'host feedback stays visible while the sheet keeps the full steps',
    (tester) async {
      await mount(
        tester,
        discomfort: (_, _) async => const DiscomfortDecision(
          DiscomfortAction.continueEasier,
          subtitle: 'Reduce the range',
        ),
      );
      await advance(tester, 2);
      await tester.tap(find.byKey(const ValueKey('discomfort')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Reduce the range'), findsOneWidget);
      await tester.tap(find.byType(TrainerCueCarousel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Stand tall'), findsOneWidget);
      expect(find.text('Move gently'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'instructions pause and restore training, preserving manual pause',
    (tester) async {
      await mount(tester);
      await advance(tester, .6);
      expect(
        tester.widget<_MediaProbe>(find.byType(_MediaProbe)).paused,
        isFalse,
      );
      await tester.tap(find.byType(TrainerCueCarousel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('How to do it'), findsOneWidget);
      expect(
        tester.widget<_MediaProbe>(find.byType(_MediaProbe)).paused,
        isTrue,
      );
      Navigator.of(tester.element(find.text('How to do it'))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        tester.widget<_MediaProbe>(find.byType(_MediaProbe)).paused,
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('pause')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byType(TrainerCueCarousel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      Navigator.of(tester.element(find.text('How to do it'))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        tester.widget<_MediaProbe>(find.byType(_MediaProbe)).paused,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'feeling receipt retries with the same result and preserves old save',
    (tester) async {
      final saved = <SessionResult>[];
      final receipts = <SessionResult>[];
      final popped = <SessionResult?>[];
      var fail = true;
      await mount(
        tester,
        popped: popped,
        finished: (value) async => saved.add(value),
        completed: (value) async {
          receipts.add(value);
          if (fail) throw StateError('offline');
        },
      );
      await advance(tester, 6);
      expect(saved, hasLength(1));
      expect(saved.single.feeling, isNull);
      await tester.tap(find.text('Just right'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('finish')));
      await tester.pump();
      expect(receipts.single.feeling, TrainingFeeling.justRight);
      expect(popped, isEmpty);
      expect(find.byKey(const ValueKey('save-retry')), findsOneWidget);
      fail = false;
      await tester.tap(find.byKey(const ValueKey('finish')));
      await tester.pumpAndSettle();
      expect(receipts, hasLength(2));
      expect(identical(receipts[0], receipts[1]), isTrue);
      expect(popped.single!.sessionId, saved.single.sessionId);
      expect(popped.single!.feeling, TrainingFeeling.justRight);
      expect(saved, hasLength(1));
    },
  );
}
