import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_chat/src/ui/training_transition_activity.dart';
import 'package:ugk_coach_chat/src/ui/training_transition_freeze.dart';

void main() {
  testWidgets(
    'a slide retains the last painted data until its hold is released',
    (tester) async {
      final activity = TrainingTransitionActivity();
      final value = ValueNotifier<int>(0);
      addTearDown(activity.dispose);
      addTearDown(value.dispose);
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: TrainingTransitionFreeze(
            activity: activity,
            listenable: value,
            builder: (_) {
              builds++;
              return Text('value ${value.value}');
            },
          ),
        ),
      );
      expect(find.text('value 0'), findsOneWidget);
      final initialBuilds = builds;
      final release = activity.hold();
      await tester.pump();
      value.value = 1;
      value.value = 2;
      await tester.pump();
      expect(find.text('value 0'), findsOneWidget);
      expect(builds, initialBuilds);
      release();
      await tester.pump();
      expect(find.text('value 2'), findsOneWidget);
      expect(builds, initialBuilds + 1);
      release();
      expect(activity.active, isFalse);
    },
  );
}
