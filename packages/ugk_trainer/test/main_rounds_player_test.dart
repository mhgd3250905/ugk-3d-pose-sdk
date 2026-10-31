import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

Future<void> _advance(WidgetTester tester, double seconds) async {
  var remaining = (seconds * 1000000).round();
  while (remaining > 0) {
    final step = remaining < 50000 ? remaining : 50000;
    await tester.pump(Duration(microseconds: step));
    remaining -= step;
  }
}

List<Color?> _progressColors(WidgetTester tester) => tester
    .widgetList<Container>(
      find.descendant(
        of: find.byKey(const ValueKey('progress')),
        matching: find.byType(Container),
      ),
    )
    .map((container) => (container.decoration! as BoxDecoration).color)
    .toList();

String? _index(WidgetTester tester) => tester
    .widget<Semantics>(find.byKey(const ValueKey('index')))
    .properties
    .label;

void main() {
  for (final type in [BlockType.main, BlockType.circuit]) {
    testWidgets(
      '${type.name} multi-round progress and prompts reach the later round',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        });
        final plan = planOf(
          [timed('a', 10), timed('b', 10)],
          type: type,
          rounds: 2,
          restBetweenRounds: 3,
        );
        final builder = SessionBuilder(prepSeconds: 0, transitionSeconds: 0);
        final phases = builder.phases(plan);
        final theme = TrainerTheme.light;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: TrainerPlayer(
              plan: plan,
              drillOf: (id) => TrainerDrill(id: id, name: 'Move $id'),
              strings: TrainerStrings.zh(),
              theme: theme,
              keepAlive: false,
              sessionBuilder: builder,
              mediaBuilder: (_, _) => const SizedBox.expand(),
              onFinished: (_) async {},
            ),
          ),
        );
        await tester.pump();
        // Retire the outgoing zero-length prep label without crossing work.
        await _advance(tester, .65);
        expect(_index(tester), '1 / 4');
        expect(find.textContaining('第 1/2 轮'), findsOneWidget);
        expect(_progressColors(tester), [
          theme.accentSubtle,
          theme.track,
          theme.track,
          theme.track,
        ]);

        final restStart = phases
            .takeWhile((phase) => phase.kind != PhaseKind.roundRest)
            .fold<double>(0, (sum, phase) => sum + phase.seconds);
        await _advance(tester, restStart);
        expect(_index(tester), '3 / 4');
        expect(find.textContaining('第 2/2 轮'), findsOneWidget);
        expect(find.textContaining('这一轮完成'), findsOneWidget);
        expect(_progressColors(tester), [
          theme.accent,
          theme.accent,
          theme.accentSubtle,
          theme.track,
        ]);

        final secondRoundStart = phases
            .takeWhile((phase) => !(phase.isWork && phase.round == 2))
            .fold<double>(0, (sum, phase) => sum + phase.seconds);
        await _advance(tester, secondRoundStart - restStart);
        expect(find.text('Move a'), findsOneWidget);
        expect(find.textContaining('第 2/2 轮'), findsOneWidget);
        expect(_index(tester), '3 / 4');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
