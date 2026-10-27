import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

void main() {
  Widget host(Widget child, {Brightness brightness = Brightness.light}) =>
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: Scaffold(body: Center(child: child)),
      );

  testWidgets('agent events select observed phases and host copy rotates', (
    tester,
  ) async {
    final events = StreamController<CoachTypingEvent>.broadcast(sync: true);
    addTearDown(events.close);
    var cancels = 0;
    await tester.pumpWidget(
      host(
        CoachTypingBubble(
          events: events.stream,
          onCancel: () => cancels++,
          rotationInterval: const Duration(seconds: 2),
          messages: const {
            CoachTypingPhase.understanding: ['Understand', 'Understand again'],
            CoachTypingPhase.searching: ['Search', 'Search again'],
            CoachTypingPhase.planning: ['Arrange'],
            CoachTypingPhase.checking: ['Check'],
          },
        ),
      ),
    );
    expect(find.text('Understand'), findsOneWidget);
    expect(find.byTooltip('Cancel'), findsOneWidget);
    events.add(
      const CoachTypingEvent(
        'reading',
        path: 'action-library/index/scene/home.md',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Search'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Search again'), findsOneWidget);
    events.add(const CoachTypingEvent('thinking'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Arrange'), findsOneWidget);
    events.add(const CoachTypingEvent('checking'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Check'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('chat-cancel')));
    expect(cancels, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('irrelevant reads do not pretend to be catalog activity', (
    tester,
  ) async {
    final events = StreamController<CoachTypingEvent>.broadcast(sync: true);
    addTearDown(events.close);
    await tester.pumpWidget(
      host(
        CoachTypingBubble(
          events: events.stream,
          messages: const {
            CoachTypingPhase.understanding: ['Understanding'],
            CoachTypingPhase.searching: ['Searching'],
          },
        ),
      ),
    );
    events.add(
      const CoachTypingEvent('reading', path: 'user-memory/profile.md'),
    );
    events.add(const CoachTypingEvent('slow'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Understanding'), findsOneWidget);
    expect(find.text('Searching'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('compact bubble respects supplied label and dark theme', (
    tester,
  ) async {
    final theme = ThemeData(brightness: Brightness.dark);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const Scaffold(
          body: CoachTypingBubble(progressLabel: 'Custom progress'),
        ),
      ),
    );
    expect(find.text('Custom progress'), findsOneWidget);
    expect(find.byType(CoachTypingBubble), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-cancel')), findsNothing);
    final size = tester.getSize(
      find.byKey(const ValueKey('typing-bubble-surface')),
    );
    expect(size.height, lessThanOrEqualTo(50));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
