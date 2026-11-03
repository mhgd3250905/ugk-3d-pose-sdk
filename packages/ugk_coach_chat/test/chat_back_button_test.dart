import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_chat/ugk_coach_chat.dart';

import 'chat_controller_test.dart' show ChatHarness;

void main() {
  const back = ValueKey('chat-back-button');

  Future<ChatHarness> started(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final h = ChatHarness();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await h.close();
    });
    expect((await h.controller.start()).ok, isTrue);
    return h;
  }

  testWidgets('a root chat page has no back button by default', (tester) async {
    final h = await started(tester);
    await tester.pumpWidget(
      MaterialApp(home: CoachChatPage(controller: h.controller)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(back), findsNothing);
  });

  testWidgets('a pushed chat page shows back and pops its route', (
    tester,
  ) async {
    final h = await started(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => CoachChatPage(controller: h.controller),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(back), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(back));
    await tester.pumpAndSettle();
    expect(find.byType(CoachChatPage), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('showBackButton overrides the default and onBack is used', (
    tester,
  ) async {
    final h = await started(tester);
    var backs = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CoachChatPage(
          controller: h.controller,
          showBackButton: true,
          onBack: () => backs++,
          backLabel: '返回首页',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('返回首页'), findsOneWidget);
    await tester.tap(find.byKey(back));
    await tester.pump();
    expect(backs, 1);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => CoachChatPage(
                  controller: h.controller,
                  showBackButton: false,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(CoachChatPage), findsOneWidget);
    expect(find.byKey(back), findsNothing);
  });
}
