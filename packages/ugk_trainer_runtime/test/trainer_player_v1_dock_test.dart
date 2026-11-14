import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer_runtime/src/ui/trainer_player_v1_dock.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

void main() {
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
