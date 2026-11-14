import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer_runtime/src/ui/trainer_player_v1_dock.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

void main() {
  testWidgets('V1 between-set rest renders the SDK semantic feedback cards', (
    tester,
  ) async {
    await withClock(Clock(tester.binding.clock.now), () async {
      const item = PlanItem(
        exerciseId: 'squat',
        mode: DoseMode.time,
        sets: 2,
        workSeconds: 2,
        perSide: false,
        restSeconds: 15,
      );
      const theme = TrainerTheme.playerV1;
      TrainerRestFeedback? rest;
      var selections = 0;
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
                  selected: selections == 0
                      ? null
                      : TrainerRestFeedbackChoice.comfortable,
                  comfortableLabel: '舒服',
                  tightLabel: '有点紧',
                  painLabel: '疼',
                  onComfortable: () => update(() => selections++),
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
      expect(
        tester.getRect(cards.first).bottom,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('pause'))).dy),
      );
      await tester.tap(cards.first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(selections, 1);
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
      await tester.pumpWidget(const SizedBox.shrink());
    });
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
