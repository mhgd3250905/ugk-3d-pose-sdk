// ugk_trainer regressions for the player page (SmartFit@e8981ee
// lib/ui/player_page.dart as base): it runs a plan to the end and hands the
// app one result whose id was fixed at start; a failed save is retried with
// the same id; self-paced sets wait for 完成本组; 不舒服 → end is recorded.
import 'dart:async';

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
    Map<String, Rhythm> rhythms = const {},
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
                      rhythms: rhythms,
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

  testWidgets('finish and system back wait for the pending save', (
    tester,
  ) async {
    final gate = Completer<void>();
    final popped = <SessionResult>[];
    final saved = await pump(
      tester,
      planOf([timed('a', 3)]),
      save: (_) => gate.future,
      popped: popped,
    );
    await advance(tester, 6);
    final finish = find.byKey(const ValueKey('finish'));
    expect(tester.widget<FilledButton>(finish).onPressed, isNull);
    await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
    await tester.pump();
    await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
    await tester.pump();
    expect(popped, isEmpty);
    expect(saved, hasLength(1));
    gate.complete();
    await tester.pumpAndSettle();
    expect(popped.single.sessionId, saved.single.sessionId);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('failed save blocks finish and back until retry succeeds', (
    tester,
  ) async {
    var fail = true;
    final popped = <SessionResult>[];
    final saved = await pump(
      tester,
      planOf([timed('a', 3)]),
      save: (_) async {
        if (fail) throw StateError('disk full');
      },
      popped: popped,
    );
    await advance(tester, 6);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('finish')))
          .onPressed,
      isNull,
    );
    await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
    await tester.pumpAndSettle();
    expect(popped, isEmpty);
    expect(find.byKey(const ValueKey('save-retry')), findsOneWidget);
    fail = false;
    await tester.tap(find.byKey(const ValueKey('save-retry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('finish')));
    await tester.pumpAndSettle();
    expect(popped.single.sessionId, saved.first.sessionId);
    expect(saved.every((r) => identical(r, saved.first)), isTrue);
  });

  testWidgets('confirmed early close keeps a failed save available to retry', (
    tester,
  ) async {
    final gate = Completer<void>();
    final popped = <SessionResult>[];
    final saved = await pump(
      tester,
      planOf([timed('a', 30)]),
      save: (_) => gate.future,
      popped: popped,
    );
    await advance(tester, 3);
    await tester.tap(find.byKey(const ValueKey('close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('close-confirm')));
    await tester.pumpAndSettle();
    expect(popped, isEmpty);
    expect(saved.single.endedEarly, isTrue);
    gate.completeError(StateError('disk full'));
    await tester.pumpAndSettle();
    expect(popped, isEmpty);
    expect(find.byKey(const ValueKey('save-retry')), findsOneWidget);
  });

  testWidgets('a self-paced set waits for 完成本组', (tester) async {
    final saved = await pump(
      tester,
      planOf([reps('a', 12)]),
      rhythms: {'a': Rhythm.selfPacedReps},
    );
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

  testWidgets('glass controls keep button semantics; theme hook keeps glass', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final custom = TrainerTheme.light.copyWith(
      glassStyle: TrainerGlassStyle.dark,
    );
    expect(custom.glass, TrainerGlassStyle.dark);
    expect(TrainerTheme.dark.glass, TrainerGlassStyle.dark);
    expect(TrainerTheme.light.glass, TrainerGlassStyle.light);
    await tester.pumpWidget(
      MaterialApp(
        home: TrainerPlayer(
          plan: planOf([timed('a', 30)]),
          drillOf: drillOf,
          strings: TrainerStrings.zh(),
          theme: TrainerTheme.light,
          prepSeconds: 0,
          keepAlive: false,
          mediaBuilder: (_, _) => const SizedBox(height: 100),
          onFinished: (_) async {},
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TrainerGlassButton), findsNWidgets(4));
    final pause = find.semantics.byLabel('暂停训练');
    expect(pause, findsOneWidget);
    expect(
      pause.evaluate().single,
      matchesSemantics(
        label: '暂停训练',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        // Keyboard-focusable like the InkWell it replaced (sdk-stage-r9).
        isFocusable: true,
        hasFocusAction: true,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('pause')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.semantics.byLabel('继续训练'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  for (final (w, h, dark) in [(360.0, 780.0, false), (390.0, 844.0, true)]) {
    testWidgets(
      'stage layout fits ${w.toInt()}x${h.toInt()} without overflow',
      (tester) async {
        tester.view.physicalSize = Size(w, h);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            home: TrainerPlayer(
              plan: planOf([reps('a', 8), timed('b', 30)]),
              rhythms: {'a': Rhythm.selfPacedReps},
              drillOf: drillOf,
              strings: TrainerStrings.zh(),
              theme: dark ? TrainerTheme.dark : TrainerTheme.light,
              prepSeconds: 0,
              keepAlive: false,
              mediaBuilder: (_, _) => const SizedBox.expand(),
              onFinished: (_) async {},
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
        // A slim card on top; the clip takes the whole stage between it and
        // the fixed transport (it may run a little past the sides); the
        // pendants hang below the figure, above the transport.
        final card = tester.getRect(find.byKey(const ValueKey('info-card')));
        final clip = tester.getRect(find.byKey(const ValueKey('media-a')));
        final pause = tester.getRect(find.byKey(const ValueKey('pause')));
        expect(card.top, lessThan(16));
        expect(card.height, lessThanOrEqualTo(76));
        expect(clip.top, greaterThan(card.bottom));
        expect(clip.bottom, lessThan(pause.top));
        expect(clip.width, closeTo(clip.height, .01));
        expect(clip.width, greaterThanOrEqualTo(w));
        expect(clip.height, greaterThan((pause.top - card.bottom) * .65));
        expect(clip.center.dx, closeTo(w / 2, .5));
        expect(h - pause.bottom, lessThan(40));
        final track = tester.getRect(find.byKey(const ValueKey('progress')));
        expect(
          track.bottom <= card.bottom && track.top > card.center.dy,
          isTrue,
        );
        // 完成本组 (r8): a compact pill in the transport, below the clip,
        // right above the pause button, at least 44 px tall.
        final done = tester.getRect(
          find.byKey(const ValueKey('complete-set-button')),
        );
        expect(done.height, greaterThanOrEqualTo(44));
        expect(done.height, lessThan(56));
        expect(done.width, lessThan(w * .7));
        expect(done.top, greaterThanOrEqualTo(clip.bottom));
        expect(done.bottom, lessThan(pause.top));
        // The countdown ring is the pause button's border; its number slot
        // sits just above it — on a self-paced set 完成本组 takes it (the
        // dose is on the card); the exercise index sits inside the card.
        final ring = tester.getRect(find.byKey(const ValueKey('ring')));
        expect(ring.center.dx, closeTo(pause.center.dx, .5));
        expect(ring.center.dy, closeTo(pause.center.dy, .5));
        expect(ring.width, greaterThan(pause.width));
        expect(done.bottom, lessThanOrEqualTo(ring.top));
        expect(done.center.dx, closeTo(pause.center.dx, 1));
        final index = tester.getRect(find.byKey(const ValueKey('index')));
        expect(card.contains(index.center), isTrue);
        expect(index.left, greaterThan(card.center.dx));
        final discomfort = tester.getRect(
          find.byKey(const ValueKey('discomfort')),
        );
        expect(discomfort.bottom, lessThan(clip.top + clip.height * .25));
        for (final k in ['close', 'pause', 'skip', 'prev', 'discomfort']) {
          final r = tester.getRect(find.byKey(ValueKey(k)));
          expect(r.bottom <= h && r.top >= 0, isTrue, reason: k);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
