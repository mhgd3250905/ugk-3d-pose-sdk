import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_chat/src/ui/cosmos.dart';
import 'package:ugk_coach_chat/src/theme/chat_theme.dart';

void main() {
  testWidgets(
    'explicit off removes stars and ticker while default off stays static',
    (tester) async {
      Widget sky({required bool animate, bool showStars = true}) => MediaQuery(
        data: const MediaQueryData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: CoachChatTheme(
            visual: const CoachChatVisuals(),
            child: CosmosBackground(animate: animate, showStars: showStars),
          ),
        ),
      );
      final painters = find.descendant(
        of: find.byType(CosmosBackground),
        matching: find.byType(CustomPaint),
      );

      // Existing animate=false callers retain the static decorative layer.
      await tester.pumpWidget(sky(animate: false));
      expect(painters, findsOneWidget);
      expect(SchedulerBinding.instance.transientCallbackCount, 0);

      // A control cell removes the layer even when animation was requested.
      await tester.pumpWidget(sky(animate: true, showStars: false));
      expect(painters, findsNothing);
      expect(SchedulerBinding.instance.transientCallbackCount, 0);

      await tester.pumpWidget(sky(animate: true));
      expect(painters, findsOneWidget);
      expect(SchedulerBinding.instance.transientCallbackCount, greaterThan(0));

      // Turning off an already active sky also cancels its scheduled ticker.
      await tester.pumpWidget(sky(animate: true, showStars: false));
      expect(painters, findsNothing);
      expect(SchedulerBinding.instance.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
