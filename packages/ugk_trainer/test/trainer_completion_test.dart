import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/src/ui/trainer_completion.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

SessionResult result({bool timed = false, bool single = false}) =>
    SessionResult(
      sessionId: 'completion-test',
      planId: 'plan-test',
      planTitle: 'Daily mobility',
      startedAt: DateTime.utc(2026, 10, 28, 10),
      endedAt: DateTime.utc(2026, 10, 28, 10, 2, 5),
      activeSeconds: 125,
      endedEarly: false,
      completedExercises: 1,
      totalExercises: single ? 1 : 2,
      items: [
        ItemResult(
          exerciseId: 'squat',
          blockIndex: 0,
          itemInBlock: 0,
          plannedSets: 3,
          completedSets: 2,
          activeSeconds: 83,
          status: ItemStatus.completed,
          completedReps: timed ? null : 17,
        ),
        if (!single)
          const ItemResult(
            exerciseId: 'fold',
            blockIndex: 0,
            itemInBlock: 1,
            plannedSets: 1,
            completedSets: 0,
            activeSeconds: 6,
            status: ItemStatus.skipped,
          ),
      ],
    );

void main() {
  Future<void> mount(
    WidgetTester tester, {
    SessionResult? session,
    TrainerTheme theme = TrainerTheme.light,
    bool reduced = false,
    double textScale = 1,
    TrainingFeeling? feeling,
    ValueChanged<TrainingFeeling?>? onFeeling,
    VoidCallback? onFinish,
    VoidCallback? onReplay,
    Widget? error,
  }) => tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          disableAnimations: reduced,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: TrainerCompletion(
            theme: theme,
            strings: TrainerStrings.en(),
            result: session ?? result(),
            drillOf: (id) => TrainerDrill(id: id, name: 'Move $id'),
            feeling: feeling,
            onFeelingChanged: onFeeling ?? (_) {},
            onFinish: onFinish,
            onReplay: onReplay,
            error: error,
          ),
        ),
      ),
    ),
  );

  String value(WidgetTester tester, String metric) => tester
      .widget<Text>(find.byKey(ValueKey('completion-$metric-value')))
      .data!;

  testWidgets('rolls recorded values and finishes after 600 ms', (
    tester,
  ) async {
    await mount(tester);
    expect(value(tester, 'duration'), '0m0s');
    expect(value(tester, 'exercises'), '0/2');
    expect(value(tester, 'dose'), '0');
    await tester.pump(const Duration(milliseconds: 300));
    expect(value(tester, 'duration'), '1m3s');
    expect(value(tester, 'dose'), '9');
    await tester.pump(const Duration(milliseconds: 300));
    expect(value(tester, 'duration'), '2m5s');
    expect(value(tester, 'exercises'), '1/2');
    expect(value(tester, 'dose'), '17');
    expect(find.text('Total reps'), findsOneWidget);
    expect(find.textContaining('calor'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'time-only results use recorded work time and one move has no list',
    (tester) async {
      await mount(
        tester,
        session: result(timed: true, single: true),
        reduced: true,
      );
      expect(value(tester, 'duration'), '2m5s');
      expect(value(tester, 'dose'), '1m23s');
      expect(find.text('Total work time'), findsOneWidget);
      expect(find.byKey(const ValueKey('completion-items')), findsNothing);
      expect(find.text('Session complete!'), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
    },
  );

  testWidgets(
    'skipped rows have no completion check or invented planned dose',
    (tester) async {
      await mount(tester, reduced: true);
      expect(find.text('17 reps'), findsOneWidget);
      expect(find.text('Skipped'), findsOneWidget);
      expect(
        tester
            .widget<Opacity>(find.byKey(const ValueKey('completion-item-1')))
            .opacity,
        .5,
      );
      expect(
        find.byKey(const ValueKey('completion-item-check-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('completion-item-check-1')),
        findsNothing,
      );
    },
  );

  testWidgets('feeling is optional and choosing it does not repeat the burst', (
    tester,
  ) async {
    TrainingFeeling? selection;
    Future<void> show() => mount(
      tester,
      feeling: selection,
      onFeeling: (value) => selection = value,
    );
    await show();
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pump(const Duration(milliseconds: 1701));
    expect(tester.hasRunningAnimations, isFalse);
    final justRight = find.byKey(
      const ValueKey('completion-feeling-justRight'),
    );
    await tester.ensureVisible(justRight);
    await tester.tap(justRight);
    expect(selection, TrainingFeeling.justRight);
    await show();
    await tester.pumpAndSettle();
    expect(value(tester, 'dose'), '17');
    expect(tester.hasRunningAnimations, isFalse);
    await tester.tap(justRight);
    expect(selection, isNull);
  });

  testWidgets('finish and replay are independent host actions', (tester) async {
    var finished = 0;
    var replayed = 0;
    await mount(
      tester,
      reduced: true,
      onFinish: () => finished++,
      onReplay: () => replayed++,
    );
    await tester.tap(find.byKey(const ValueKey('finish')));
    expect(finished, 1);
    expect(replayed, 0);
    await tester.tap(find.byKey(const ValueKey('completion-replay')));
    expect(replayed, 1);
    await mount(tester, reduced: true);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('finish')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const ValueKey('completion-replay')))
          .onPressed,
      isNull,
    );
  });

  for (final theme in [TrainerTheme.light, TrainerTheme.dark]) {
    testWidgets(
      'uses the supplied card and primary tokens in ${theme.brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final custom = theme.copyWith(
          cardSurface: const Color(0xFF123456),
          cardBorder: const Color(0xFF654321),
          accent: const Color(0xFF765432),
          primaryForeground: const Color(0xFFABCDEF),
        );
        await mount(tester, reduced: true, theme: custom, onFinish: () {});
        final box = tester.widget<DecoratedBox>(
          find.byKey(const ValueKey('completion-stats')),
        );
        final decoration = box.decoration as BoxDecoration;
        expect(decoration.color, custom.cardSurface);
        expect((decoration.border! as Border).top.color, custom.cardBorder);
        final finish = find.byKey(const ValueKey('finish'));
        expect(tester.getSize(finish).height, 56);
        expect(tester.getRect(finish).left, 20);
        expect(tester.getRect(finish).right, 370);
        final style = tester.widget<FilledButton>(finish).style!;
        expect(style.backgroundColor!.resolve({}), custom.accent);
        expect(style.foregroundColor!.resolve({}), custom.primaryForeground);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'small and large-text layouts scroll while keeping finish reachable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await mount(
        tester,
        reduced: true,
        textScale: 1.5,
        onFinish: () {},
        error: const Text('Save failed'),
      );
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('finish')).hitTestable(),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Save failed'));
      await tester.pumpAndSettle();
      expect(find.text('Save failed').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
