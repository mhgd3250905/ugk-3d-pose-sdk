import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer_runtime/src/ui/trainer_player_v1_dock.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

void main() {
  testWidgets('V1 rest feedback collapses and reopens above fixed controls', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await withClock(Clock(tester.binding.clock.now), () async {
      const item = PlanItem(
        exerciseId: 'squat',
        mode: DoseMode.time,
        sets: 3,
        workSeconds: 2,
        perSide: false,
        restSeconds: 15,
      );
      const theme = TrainerTheme.playerV1;
      TrainerRestFeedback? rest;
      SessionPhase? recordedPhase;
      final selections = <TrainerRestFeedbackChoice>[];
      await tester.pumpWidget(
        MaterialApp(
          home: TrainerPlayer(
            plan: const TrainingPlan(
              id: 'between-set-feedback',
              source: 'template',
              title: 'Plan',
              goal: 'core',
              scene: 'home',
              level: 1,
              targetMinutes: 1,
              blocks: [
                PlanBlock(
                  id: 'main',
                  name: 'Main',
                  type: BlockType.main,
                  items: [item],
                ),
              ],
            ),
            drillOf: (id) => TrainerDrill(id: id, name: id),
            theme: theme,
            strings: TrainerStrings.zh(),
            prepSeconds: 0,
            keepAlive: false,
            onFinished: (_) async {},
            restFeedbackBuilder: (_, feedback) {
              rest = feedback;
              return StatefulBuilder(
                builder: (_, update) => TrainerRestFeedbackPanel(
                  theme: theme,
                  title: '刚才感觉怎么样？',
                  selected: recordedPhase == feedback.phase
                      ? selections.last
                      : null,
                  comfortableLabel: '舒服',
                  tightLabel: '有点紧',
                  painLabel: '疼',
                  onComfortable: () => update(() {
                    recordedPhase = feedback.phase;
                    selections.add(TrainerRestFeedbackChoice.comfortable);
                  }),
                  onTight: () => update(() {
                    recordedPhase = feedback.phase;
                    selections.add(TrainerRestFeedbackChoice.tight);
                  }),
                ),
              );
            },
          ),
        ),
      );
      final dock = find.byType(TrainerPlayerV1Dock);
      final panel = find.descendant(
        of: dock,
        matching: find.byType(TrainerRestFeedbackPanel),
      );
      expect(panel, findsNothing);
      await tester.pump(const Duration(milliseconds: 2100));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(rest!.phase.kind, PhaseKind.rest);
      expect(rest!.phase.itemIndex, rest!.completedPhase.itemIndex);
      expect(rest!.phase.set, 2);
      expect(rest!.completedPhase.set, 1);
      expect(panel.hitTestable(), findsOneWidget);
      expect(find.text('选一个，下一组帮你调整'), findsOneWidget);
      final cards = <Finder>[];
      for (final (choice, icon, color) in [
        (
          TrainerRestFeedbackChoice.comfortable,
          Icons.sentiment_satisfied_alt_rounded,
          theme.feedbackPositive,
        ),
        (
          TrainerRestFeedbackChoice.tight,
          Icons.sentiment_neutral_rounded,
          theme.feedbackNeutral,
        ),
        (
          TrainerRestFeedbackChoice.pain,
          Icons.sentiment_dissatisfied_rounded,
          theme.feedbackNegative,
        ),
      ]) {
        final card = find.descendant(
          of: panel,
          matching: find.byKey(ValueKey('player-v1-rest-${choice.name}')),
        );
        cards.add(card);
        expect(tester.getSize(card).height, 84);
        expect(
          tester
              .widget<Icon>(
                find.descendant(of: card, matching: find.byIcon(icon)),
              )
              .color,
          color,
        );
      }
      expect(
        find.descendant(of: panel, matching: find.byType(OutlinedButton)),
        findsNothing,
      );
      final pause = find.byKey(const ValueKey('pause'));
      final countdown = find.byKey(
        const ValueKey('player-v1-countdown-number'),
      );
      final viewport = find.byKey(const ValueKey('player-v1-media-viewport'));
      final capsule = find.byKey(
        const ValueKey('player-v1-rest-feedback-edit'),
      );
      final dockTop = tester.getTopLeft(dock).dy;
      final pausePosition = tester.getCenter(pause);
      final pauseElement = tester.element(pause);
      final countdownPosition = tester.getCenter(countdown);
      final mediaRect = tester.getRect(viewport);
      expect(tester.getRect(cards.first).bottom, lessThan(pausePosition.dy));
      expect(dockTop, lessThan(mediaRect.bottom));
      await tester.tap(cards.first);
      expect(selections, [TrainerRestFeedbackChoice.comfortable]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 299));
      expect(tester.getTopLeft(dock).dy, dockTop);
      expect(capsule, findsNothing);
      expect(
        find.descendant(
          of: cards.first,
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      for (final card in cards.skip(1)) {
        expect(
          tester
              .widget<AnimatedOpacity>(
                find.descendant(
                  of: card,
                  matching: find.byType(AnimatedOpacity),
                ),
              )
              .opacity,
          .45,
        );
      }

      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 120));
      final midpoint = tester.getTopLeft(dock).dy;
      expect(midpoint, greaterThan(dockTop));
      await tester.pump(const Duration(milliseconds: 120));
      expect(tester.getTopLeft(dock).dy, greaterThan(midpoint));
      expect(
        tester.getTopLeft(dock).dy,
        greaterThanOrEqualTo(mediaRect.bottom),
      );
      expect(tester.getRect(viewport), mediaRect);
      expect(tester.getCenter(pause), pausePosition);
      expect(tester.element(pause), same(pauseElement));
      expect(tester.getCenter(countdown), countdownPosition);
      expect(panel, findsNothing);
      expect(tester.getSize(capsule).height, 32);
      expect(find.text('已记录：舒服'), findsOneWidget);
      expect(find.text('修改'), findsOneWidget);

      await tester.tap(capsule);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      expect(tester.getTopLeft(dock).dy, dockTop);
      expect(cards[1].hitTestable(), findsOneWidget);
      await tester.tap(cards[1]);
      expect(selections, [
        TrainerRestFeedbackChoice.comfortable,
        TrainerRestFeedbackChoice.tight,
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 240));
      expect(find.text('已记录：有点紧'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('skip')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 2100));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(rest!.phase.set, 3);
      expect(panel.hitTestable(), findsOneWidget);
      expect(capsule, findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('V1 rest after a user skip keeps the ordinary dock height', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await withClock(Clock(tester.binding.clock.now), () async {
      await tester.pumpWidget(
        MaterialApp(
          home: TrainerPlayer(
            plan: TrainingPlan(
              id: 'skipped-rest',
              source: 'template',
              title: 'Plan',
              goal: 'core',
              scene: 'home',
              level: 1,
              targetMinutes: 2,
              blocks: [
                PlanBlock(
                  id: 'main',
                  name: 'Main',
                  type: BlockType.main,
                  items: [
                    for (final id in ['squat', 'lunge'])
                      PlanItem(
                        exerciseId: id,
                        mode: DoseMode.time,
                        sets: 1,
                        workSeconds: 30,
                        perSide: false,
                        restSeconds: 0,
                      ),
                  ],
                ),
              ],
            ),
            drillOf: (id) => TrainerDrill(id: id, name: id),
            theme: TrainerTheme.playerV1,
            strings: TrainerStrings.zh(),
            prepSeconds: 0,
            keepAlive: false,
            onFinished: (_) async {},
            restFeedbackBuilder: (_, _) => const Text('休息反馈'),
          ),
        ),
      );
      final dock = find.byType(TrainerPlayerV1Dock);
      final pause = find.byKey(const ValueKey('pause'));
      await tester.pump(const Duration(seconds: 1));
      final workHeight = tester.getSize(dock).height;
      final pauseCenter = tester.getCenter(pause);

      await tester.tap(find.byKey(const ValueKey('skip')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      final restDock = tester.widget<TrainerPlayerV1Dock>(dock);
      expect(restDock.restIdentity, isA<SessionPhase>());
      expect((restDock.restIdentity! as SessionPhase).kind, PhaseKind.rest);
      expect(find.text('休息反馈'), findsNothing);
      expect(tester.getSize(dock).height, workHeight);
      expect(tester.getCenter(pause), pauseCenter);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('wrapped rest feedback appears when dock layout retargets', (
    tester,
  ) async {
    final extraHeight = ValueNotifier<double?>(null);
    addTearDown(extraHeight.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ValueListenableBuilder(
              valueListenable: extraHeight,
              builder: (context, height, _) => TrainerPlayerV1Dock(
                theme: TrainerTheme.playerV1,
                strings: TrainerStrings.zh(),
                minHeight: height == null ? 172 : 300,
                compactMinHeight: 172,
                bottomInset: 0,
                countdown: const Text('10'),
                previous: const SizedBox.shrink(),
                primary: const SizedBox(height: 80),
                next: const SizedBox.shrink(),
                restFeedback: height == null
                    ? null
                    : StatefulBuilder(
                        builder: (_, _) => Padding(
                          padding: EdgeInsets.only(top: height),
                          child: TrainerRestFeedbackPanel(
                            theme: TrainerTheme.playerV1,
                            title: '刚才感觉怎么样？',
                            comfortableLabel: '舒服',
                            onComfortable: () {},
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
    final feedbackOpacity = find.byKey(
      const ValueKey('player-v1-rest-feedback-opacity'),
    );
    extraHeight.value = 0;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 340));
    expect(tester.widget<Opacity>(feedbackOpacity).opacity, 0);

    extraHeight.value = 32;
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
    extraHeight.value = 64;
    await tester.pump(const Duration(milliseconds: 20));
    extraHeight.value = 96;
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 500));

    expect(tester.widget<Opacity>(feedbackOpacity).opacity, 1);
    expect(find.text('舒服').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reduced motion toggles the rest feedback immediately', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: TrainerPlayerV1Dock(
              theme: TrainerTheme.playerV1,
              strings: TrainerStrings.zh(),
              minHeight: 300,
              compactMinHeight: 172,
              bottomInset: 0,
              countdown: const SizedBox.shrink(),
              previous: const SizedBox.shrink(),
              primary: const SizedBox.shrink(),
              next: const SizedBox.shrink(),
              restFeedback: TrainerRestFeedbackPanel(
                theme: TrainerTheme.playerV1,
                title: '刚才感觉怎么样？',
                comfortableLabel: '舒服',
                onComfortable: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('舒服'));
    await tester.pump();
    expect(find.text('已记录：舒服'), findsOneWidget);
    expect(find.text('刚才感觉怎么样？'), findsNothing);

    await tester.tap(find.text('修改'));
    await tester.pump();
    expect(find.text('已记录：舒服'), findsNothing);
    expect(find.text('刚才感觉怎么样？'), findsOneWidget);
  });

  testWidgets('a newly opened player can exit before dock feedback animates', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
    );

    final navigator = navigatorKey.currentState!;
    final closed = navigator.push<void>(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => TrainerPlayer(
          plan: const TrainingPlan(
            id: 'dock-exit-test',
            source: 'template',
            title: 'Plan',
            goal: 'core',
            scene: 'home',
            level: 1,
            targetMinutes: 1,
            blocks: [
              PlanBlock(
                id: 'main',
                name: 'Main',
                type: BlockType.main,
                items: [
                  PlanItem(
                    exerciseId: 'squat',
                    mode: DoseMode.time,
                    sets: 1,
                    workSeconds: 30,
                    perSide: false,
                    restSeconds: 0,
                  ),
                ],
              ),
            ],
          ),
          drillOf: (id) => TrainerDrill(id: id, name: id),
          strings: TrainerStrings.en(),
          keepAlive: false,
          onFinished: (_) async {},
          theme: TrainerTheme.playerV1,
        ),
      ),
    );
    await tester.pump();
    final dock = find.byType(TrainerPlayerV1Dock);
    expect(dock, findsOneWidget);

    navigator.pop();
    await tester.pumpAndSettle();
    await closed;
    expect(dock, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
