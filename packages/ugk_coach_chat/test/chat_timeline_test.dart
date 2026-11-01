import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_chat/src/ui/chat_timeline.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

void main() {
  for (final scrolled in [false, true]) {
    testWidgets(
      'finished row preserves the first layout anchor, scrolled=$scrolled',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        final at = DateTime(2026, 10, 30, 12);
        final old = [
          for (var index = 0; index < 14; index++)
            CoachChatEntry(
              id: 'old-$index',
              at: at,
              isUser: false,
              child: SizedBox(
                key: ValueKey('content-$index'),
                height: 64,
                child: Text('row $index'),
              ),
            ),
        ];
        Widget build(List<CoachChatEntry> rows) => MaterialApp(
          home: Scaffold(
            body: ChatTimeline(
              entries: rows,
              controller: scroll,
              initiallySeen: old.map((row) => row.id).toSet(),
              finishedEntries: const {'finished'},
              timeMarkBuilder: (_, _) => const SizedBox(height: 24),
            ),
          ),
        );
        await tester.pumpWidget(build(old));
        await tester.pumpAndSettle();
        if (scrolled) {
          scroll.jumpTo(100);
          await tester.pump();
        }
        final originalOffset = scroll.offset;
        final anchor = tester.getRect(find.byKey(const ValueKey('content-11')));
        await tester.pumpWidget(
          build([
            ...old,
            CoachChatEntry(
              id: 'finished',
              at: at,
              isUser: false,
              child: const SizedBox(
                key: ValueKey('finished-content'),
                height: 80,
                child: Text('finished'),
              ),
            ),
          ]),
        );
        expect(scroll.offset, originalOffset);
        expect(
          tester.getRect(find.byKey(const ValueKey('content-11'))).top,
          closeTo(anchor.top, .001),
        );
        expect(
          tester
              .getSize(
                find.byKey(
                  const ValueKey('training-finished-size'),
                  skipOffstage: false,
                ),
              )
              .height,
          0,
        );
        final fade = find.byKey(
          const ValueKey('training-finished-opacity'),
          skipOffstage: false,
        );
        final position = find.byKey(
          const ValueKey('training-finished-position'),
          skipOffstage: false,
        );
        expect(tester.widget<Opacity>(fade).opacity, 0);
        expect(tester.widget<Transform>(position).transform.storage[13], 12);
        expect(
          find.ancestor(
            of: find.byKey(
              const ValueKey('finished-content'),
              skipOffstage: false,
            ),
            matching: find.byType(CoachAppear, skipOffstage: false),
          ),
          findsNothing,
        );
        await tester.pump(const Duration(milliseconds: 120));
        expect(
          tester.widget<Opacity>(fade).opacity,
          closeTo(Curves.easeOutCubic.transform(.5), .0001),
        );
        expect(
          tester.widget<Transform>(position).transform.storage[13],
          closeTo(12 * (1 - Curves.easeOutCubic.transform(.5)), .0001),
        );
        expect(
          tester.getRect(find.byKey(const ValueKey('content-11'))).top,
          lessThan(anchor.top),
        );
        await tester.pump(const Duration(milliseconds: 120));
        expect(tester.widget<Opacity>(fade).opacity, 1);
        expect(tester.widget<Transform>(position).transform.storage[13], 0);
        final settled = tester.getRect(
          find.byKey(const ValueKey('content-11')),
        );
        await tester.pump(const Duration(milliseconds: 130));
        expect(
          tester.getRect(find.byKey(const ValueKey('content-11'))),
          settled,
        );
        await tester.pumpWidget(const SizedBox());
        expect(tester.binding.transientCallbackCount, 0);
      },
    );
  }
}
