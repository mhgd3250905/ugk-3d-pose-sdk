// ugk_trainer regressions for the player page (SmartFit@e8981ee
// lib/ui/player_page.dart as base): it runs a plan to the end and hands the
// app one result whose id was fixed at start; a failed save is retried with
// the same id; self-paced sets wait for 完成本组; 不舒服 → end is recorded.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

void main() {
  TrainerDrill? drillOf(String id) => TrainerDrill(id: id, name: 'name-$id');

  Future<List<SessionResult>> pump(
    WidgetTester tester,
    TrainingPlan plan, {
    Future<void> Function(SessionResult r)? save,
    List<SessionResult>? popped,
  }) async {
    final saved = <SessionResult>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                final r = await Navigator.of(context).push<SessionResult>(
                  MaterialPageRoute(
                    builder: (_) => TrainerPlayer(
                      plan: plan,
                      drillOf: drillOf,
                      strings: TrainerStrings.en(),
                      keepAlive: false,
                      prepSeconds: 2,
                      mediaBuilder: (_, _) => const SizedBox(height: 50),
                      onFinished: (r) async {
                        saved.add(r);
                        await save?.call(r);
                      },
                    ),
                  ),
                );
                if (r != null) popped?.add(r);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // route transition
    return saved;
  }

  Future<void> advance(WidgetTester tester, double seconds) async {
    for (var i = 0; i < seconds * 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('runs to the end, saves once, pops with the result', (
    tester,
  ) async {
    final popped = <SessionResult>[];
    final saved = await pump(tester, planOf([timed('a', 3)]), popped: popped);
    expect(find.text('name-a'), findsOneWidget);
    await advance(tester, 6);
    expect(find.text('Session complete!'), findsOneWidget);
    expect(saved, hasLength(1));
    expect(saved.single.full, isTrue);
    expect(saved.single.items.single.completedSets, 1);
    await tester.tap(find.byKey(const ValueKey('finish')));
    await tester.pumpAndSettle();
    expect(popped.single.sessionId, saved.single.sessionId);
    expect(saved, hasLength(1), reason: 'dispose does not save again');
  });

  testWidgets('a failed save shows retry; the retry sends the same id', (
    tester,
  ) async {
    var fail = true;
    final saved = await pump(
      tester,
      planOf([timed('a', 3)]),
      save: (_) async {
        if (fail) throw StateError('offline');
      },
    );
    await advance(tester, 6);
    expect(find.byKey(const ValueKey('save-retry')), findsOneWidget);
    fail = false;
    await tester.tap(find.byKey(const ValueKey('save-retry')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('save-retry')), findsNothing);
    expect(saved, hasLength(2));
    expect(saved[1].sessionId, saved[0].sessionId);
    expect(identical(saved[0], saved[1]), isTrue);
  });

  testWidgets('a self-paced set waits for 完成本组', (tester) async {
    final saved = await pump(tester, planOf([reps('a', 12)]));
    await advance(tester, 60);
    expect(find.byKey(const ValueKey('complete-set-button')), findsOneWidget);
    expect(saved, isEmpty);
    await tester.tap(find.byKey(const ValueKey('complete-set-button')));
    await advance(tester, 1);
    expect(find.text('Session complete!'), findsOneWidget);
    expect(saved.single.items.single.status, ItemStatus.completed);
  });

  testWidgets('不舒服 → end: recorded, ended early', (tester) async {
    final saved = await pump(tester, planOf([timed('a', 30), timed('b', 30)]));
    await advance(tester, 4);
    await tester.tap(find.byKey(const ValueKey('discomfort')));
    await advance(tester, 1);
    await tester.tap(find.byKey(const ValueKey('discomfort-end')));
    await advance(tester, 1);
    expect(find.text('That\'s it for today'), findsOneWidget);
    final r = saved.single;
    expect(r.endedEarly, isTrue);
    expect(r.discomfort.single.action, DiscomfortAction.end);
    expect(r.discomfort.single.exerciseId, 'a');
    expect(r.items.last.status, ItemStatus.notReached);
  });
}
