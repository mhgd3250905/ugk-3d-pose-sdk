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
    Widget? feedback,
    int? streakDays,
    List<String> trainedAreas = const [],
    String? thumbnailAsset,
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
            drillOf: (id) => TrainerDrill(
              id: id,
              name: 'Move $id',
              thumbnailAsset: thumbnailAsset,
            ),
            feeling: feeling,
            onFeelingChanged: onFeeling ?? (_) {},
            onFinish: onFinish,
            onReplay: onReplay,
            error: error,
            feedback: feedback,
            streakDays: streakDays,
            trainedAreas: trainedAreas,
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

  testWidgets('player V1 shows supplied streak and areas with host actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final events = <Object>[];
    await mount(
      tester,
      theme: TrainerTheme.playerV1Dark,
      reduced: true,
      session: result(single: true),
      streakDays: 4,
      trainedAreas: const ['Hips', 'Glutes'],
      feedback: const Text('Host feedback'),
      onFeeling: (feeling) => events.add(feeling!),
      onFinish: () => events.add('finish'),
      onReplay: () => events.add('replay'),
    );
    final hero = find.byKey(const ValueKey('completion-hero'));
    final stats = find.byKey(const ValueKey('completion-stats'));
    expect(tester.getSize(hero).height, 300);
    expect(tester.getTopLeft(stats).dy - tester.getTopLeft(hero).dy, 244);
    expect(
      tester.getSize(find.byKey(const ValueKey('completion-badge'))),
      const Size(72, 72),
    );
    final badge = find.byKey(const ValueKey('completion-badge'));
    expect(
      tester
          .widget<Icon>(
            find.descendant(
              of: badge,
              matching: find.byIcon(Icons.check_rounded),
            ),
          )
          .color,
      TrainerTheme.playerV1Dark.accent,
    );
    expect(value(tester, 'duration'), '2:05');
    expect(value(tester, 'exercises'), '1/1');
    expect(value(tester, 'streak'), '4');
    final feedback = find.byKey(const ValueKey('completion-feedback'));
    final areas = find.byKey(const ValueKey('completion-trained-areas'));
    final prompt = find.text('How did that feel?');
    final firstChoice = find.byKey(const ValueKey('completion-feeling-easy'));
    final hostExplanation = find.text('Host feedback');
    expect(tester.widget<Text>(prompt).style?.fontSize, 16);
    expect(tester.widget<Text>(prompt).style?.fontWeight, FontWeight.w700);
    expect(
      tester.getTopLeft(firstChoice).dy - tester.getBottomLeft(prompt).dy,
      14,
    );
    expect(
      tester.getTopLeft(hostExplanation).dy -
          tester.getBottomLeft(firstChoice).dy,
      12,
    );
    expect(tester.getTopLeft(areas).dy - tester.getBottomLeft(feedback).dy, 16);
    expect(
      find.descendant(of: feedback, matching: find.text('Host feedback')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: areas, matching: find.text('Hips')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: areas, matching: find.text('Glutes')),
      findsOneWidget,
    );
    final finish = find.byKey(const ValueKey('finish'));
    expect(tester.getSize(finish).height, 52);
    final style = tester.widget<FilledButton>(finish).style!;
    expect(style.foregroundColor!.resolve({}), Colors.white);
    await tester.tap(find.byKey(const ValueKey('completion-feeling-easy')));
    await tester.tap(finish);
    await tester.tap(find.byKey(const ValueKey('completion-replay')));
    expect(events, [TrainingFeeling.easy, 'finish', 'replay']);
  });

  testWidgets('player V1 lists recorded exercise time in compact rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const theme = TrainerTheme.playerV1Dark;
    await mount(
      tester,
      reduced: true,
      theme: theme,
      thumbnailAsset:
          '${PoseHubActionLibrary.standingAssetRoot}glute-max-A.webp',
    );
    final item = find.byKey(const ValueKey('completion-item-0'));
    final thumbnail = find.descendant(
      of: item,
      matching: find.byType(ClipOval),
    );
    final name = find.descendant(of: item, matching: find.text('Move squat'));
    final time = find.descendant(of: item, matching: find.text('1:23'));
    final check = find.byKey(const ValueKey('completion-item-check-0'));
    expect(tester.getSize(item).height, 56);
    expect(tester.getSize(thumbnail), const Size(40, 40));
    expect(
      tester
          .widget<ColoredBox>(
            find.descendant(of: thumbnail, matching: find.byType(ColoredBox)),
          )
          .color,
      const Color(0xFF3A3D46),
    );
    final image = find.descendant(of: thumbnail, matching: find.byType(Image));
    final filter = find.descendant(
      of: image,
      matching: find.byType(ColorFiltered),
    );
    expect(
      tester.widget<ColorFiltered>(filter).colorFilter,
      const ColorFilter.matrix([
        1.15,
        0,
        0,
        0,
        0,
        0,
        1.15,
        0,
        0,
        0,
        0,
        0,
        1.15,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
      ]),
    );
    expect(tester.getTopLeft(name).dx - tester.getTopRight(thumbnail).dx, 12);
    expect(tester.widget<Text>(name).maxLines, 1);
    expect(tester.widget<Text>(name).overflow, TextOverflow.ellipsis);
    expect(tester.widget<Text>(name).style?.fontSize, 15);
    expect(tester.widget<Text>(name).style?.fontWeight, FontWeight.w600);
    expect(tester.widget<Text>(time).style?.fontSize, 13);
    expect(tester.widget<Text>(time).style?.color, theme.sub);
    expect(tester.getTopLeft(check).dx - tester.getTopRight(time).dx, 8);
    expect(tester.widget<Icon>(check).color, theme.good);
    expect(find.text('Skipped'), findsOneWidget);
    expect(find.byKey(const ValueKey('completion-item-check-1')), findsNothing);
  });

  testWidgets('player V1 scrolls the whole action card above the footer fade', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const theme = TrainerTheme.playerV1;
    await mount(tester, reduced: true, theme: theme, onFinish: () {});
    final scroll = find.byKey(const ValueKey('completion-scroll'));
    final viewport = find.descendant(
      of: scroll,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(viewport).position;
    expect(position.maxScrollExtent, greaterThan(0));
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();

    final card = find.byKey(const ValueKey('completion-items'));
    final lastRow = find.byKey(const ValueKey('completion-item-1'));
    final fade = find.byKey(const ValueKey('completion-footer-fade'));
    final footer = find.byKey(const ValueKey('completion-footer'));
    final cardDecoration =
        tester.widget<DecoratedBox>(card).decoration as BoxDecoration;
    expect(cardDecoration.borderRadius, BorderRadius.circular(20));
    expect(
      tester.getBottomLeft(card).dy - tester.getBottomLeft(lastRow).dy,
      16,
    );
    final fadeDecoration =
        tester.widget<DecoratedBox>(fade).decoration as BoxDecoration;
    expect((fadeDecoration.gradient! as LinearGradient).colors, [
      theme.background.withValues(alpha: 0),
      theme.background,
    ]);
    expect(tester.getSize(fade).height, 24);
    expect(
      tester.getBottomLeft(card).dy,
      closeTo(tester.getTopLeft(fade).dy, .01),
    );
    expect(tester.getBottomLeft(fade).dy, tester.getTopLeft(footer).dy);
    expect(lastRow.hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('finish')).hitTestable(), findsOneWidget);
  });

  testWidgets('player V1 keeps absent host data empty on a compact display', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await mount(
      tester,
      theme: TrainerTheme.playerV1,
      reduced: true,
      textScale: 1.5,
      session: result(single: true),
      onFinish: () {},
    );
    expect(value(tester, 'streak'), '—');
    expect(
      find.byKey(const ValueKey('completion-trained-areas')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('finish')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final theme in [TrainerTheme.playerV1, TrainerTheme.playerV1Dark]) {
    testWidgets('V1 completion feedback colors in ${theme.brightness.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      TrainingFeeling? selection;
      Future<void> show() => mount(
        tester,
        theme: theme,
        reduced: true,
        session: result(single: true),
        feeling: selection,
        onFeeling: (value) => selection = value,
      );
      Finder option(TrainingFeeling feeling) =>
          find.byKey(ValueKey('completion-feeling-${feeling.name}'));
      ButtonStyle style(TrainingFeeling feeling) => tester
          .widget<TextButton>(
            find.descendant(
              of: option(feeling),
              matching: find.byType(TextButton),
            ),
          )
          .style!;

      await show();
      final roles = [
        (theme.good, theme.goodBg),
        (theme.good, theme.goodBg),
        (theme.caution, theme.cautionBg),
        (theme.danger, theme.dangerBg),
      ];
      Rect? previous;
      for (final (index, feeling) in TrainingFeeling.values.indexed) {
        final (color, fill) = roles[index];
        final rect = tester.getRect(option(feeling));
        expect(rect.height, 44);
        if (previous case final last?) {
          expect(rect.top, last.top);
          expect(rect.width, closeTo(last.width, .01));
          expect(rect.left - last.right, 8);
        }
        previous = rect;
        final inactive = style(feeling);
        expect(inactive.foregroundColor!.resolve({}), color);
        expect(inactive.backgroundColor!.resolve({}), fill);
        expect(
          inactive.side!.resolve({}),
          BorderSide(color: color.withValues(alpha: theme.isDark ? .3 : .2)),
        );
        expect(
          inactive.shape!.resolve({}),
          const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(22)),
          ),
        );
        final label = inactive.textStyle!.resolve({})!;
        expect(label.fontSize, 15);
        expect(label.fontWeight, FontWeight.w600);
      }
      final tired = option(TrainingFeeling.tired);
      await tester.ensureVisible(tired);
      await tester.tap(tired);
      expect(selection, TrainingFeeling.tired);
      await show();
      final active = style(TrainingFeeling.tired);
      expect(active.backgroundColor!.resolve({}), theme.caution);
      expect(
        active.foregroundColor!.resolve({}),
        theme.isDark ? const Color(0xFF111214) : Colors.white,
      );
      final check = find.descendant(
        of: tired,
        matching: find.byIcon(Icons.check_rounded),
      );
      expect(tester.widget<Icon>(check).size, 14);
      await tester.ensureVisible(tired);
      await tester.tap(tired);
      expect(selection, isNull);
    });
  }
}
