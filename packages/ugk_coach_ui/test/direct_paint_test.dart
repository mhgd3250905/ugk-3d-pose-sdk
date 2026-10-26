import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/src/paint_reveal.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

void _expectDirectPaint(Finder root) {
  expect(
    find.descendant(
      of: root,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Opacity ||
            widget is AnimatedOpacity ||
            widget is FadeTransition ||
            widget is ShaderMask ||
            widget is ColorFiltered ||
            widget is BackdropGroup,
      ),
    ),
    findsNothing,
  );
}

void main() {
  testWidgets('settled reveal keeps protruding cutout pixels visible', (
    tester,
  ) async {
    const capture = ValueKey('cutout-capture');
    const green = Color(0xFF00CC44);
    await tester.pumpWidget(
      const MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: capture,
            child: ColoredBox(
              color: Colors.white,
              child: Padding(
                padding: EdgeInsets.all(20),
                child: PaintReveal(
                  progress: AlwaysStoppedAnimation(1),
                  child: SizedBox(
                    width: 100,
                    height: 100,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          top: -14,
                          left: 0,
                          width: 100,
                          height: 114,
                          child: ColoredBox(color: green),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(capture),
    );
    final image = (await tester.runAsync(
      () => boundary.toImage(pixelRatio: 1),
    ))!;
    try {
      final bytes = (await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      final offset = (10 * image.width + 30) * 4;
      expect(bytes.getUint8(offset), 0);
      expect(bytes.getUint8(offset + 1), 204);
      expect(bytes.getUint8(offset + 2), 68);
      expect(bytes.getUint8(offset + 3), 255);
    } finally {
      image.dispose();
    }
  });

  testWidgets('arrival retains its layout without group alpha at any phase', (
    tester,
  ) async {
    const marker = ValueKey('arrival-marker');
    await tester.pumpWidget(
      const MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: CoachAppear(
            animate: true,
            delay: Duration(milliseconds: 60),
            duration: Duration(milliseconds: 300),
            child: SizedBox(key: marker, width: 160, height: 60),
          ),
        ),
      ),
    );
    for (final milliseconds in [0, 40, 80, 180, 300]) {
      await tester.pump(Duration(milliseconds: milliseconds));
      _expectDirectPaint(find.byType(CoachAppear));
      expect(tester.getSize(find.byKey(marker)), const Size(160, 60));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'reduced arrival is immediate; typing paints dot alpha directly',
    (tester) async {
      const marker = ValueKey('reduced-marker');
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Column(
              children: [
                const CoachAppear(
                  animate: true,
                  child: SizedBox(key: marker, width: 100, height: 40),
                ),
                CoachTypingBubble(onCancel: () {}),
              ],
            ),
          ),
        ),
      );
      _expectDirectPaint(find.byType(CoachAppear));
      _expectDirectPaint(find.byType(CoachTypingBubble));
      expect(tester.getTopLeft(find.byKey(marker)).dy, 0);
      await tester.pump(const Duration(milliseconds: 600));
      _expectDirectPaint(find.byType(CoachTypingBubble));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('appending a reply preserves expanded card state and callbacks', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    const plan = CoachRoutine(
      id: 'state',
      title: 'Routine',
      items: [
        CoachRoutineItem(exerciseId: 'a', dose: '10 reps'),
        CoachRoutineItem(exerciseId: 'b', dose: '20 seconds'),
      ],
      durationLabel: '1 minute',
      gearLabel: 'None',
      levelLabel: 'Easy',
      metaLabel: '2 moves',
    );
    final library = CoachExerciseLibrary(const []);
    var replies = 0, saved = 0, started = 0, opened = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return CoachChatList(
                controller: scroll,
                topColor: Colors.white,
                initiallySeen: const {'plan'},
                timeMarkBuilder: (_, _) => const SizedBox.shrink(),
                entries: [
                  CoachChatEntry(
                    id: 'plan',
                    at: DateTime(2026),
                    isUser: false,
                    isCard: true,
                    child: CoachPlanCard(
                      plan: plan,
                      library: library,
                      saved: false,
                      onSave: () => saved++,
                      onStart: (origin) {
                        expect(origin(), isNotNull);
                        started++;
                      },
                      onOpen: () => opened++,
                    ),
                  ),
                  for (var i = 0; i < replies; i++)
                    CoachChatEntry(
                      id: 'reply-$i',
                      at: DateTime(2026),
                      isUser: false,
                      child: const SizedBox(height: 20, child: Text('Reply')),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final cardState = tester.state(find.byType(CoachPlanCard));
    await tester.tap(find.byKey(const ValueKey('plan-expand-state')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    update(() => replies++);
    await tester.pump();
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      _expectDirectPaint(find.byType(CoachChatList));
      expect(tester.state(find.byType(CoachPlanCard)), same(cardState));
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.byKey(const ValueKey('plan-save-state')));
    await tester.tap(find.byKey(const ValueKey('plan-start-state')));
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('plan-header')),
        matching: find.byKey(const ValueKey('plan-open-state')),
      ),
    );
    expect(saved, 1);
    expect(started, 1);
    expect(opened, 1);
  });
}
