import 'package:flutter/widgets.dart';

import '../core/transition_activity.dart';

/// The page and its host route share one short transition activity.
typedef TrainingTransitionActivity = CoachChatTransitionActivity;

class TrainingTransitionScope
    extends InheritedNotifier<CoachChatTransitionActivity> {
  const TrainingTransitionScope({
    super.key,
    required CoachChatTransitionActivity activity,
    required super.child,
  }) : super(notifier: activity);

  static CoachChatTransitionActivity of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<TrainingTransitionScope>()!
      .notifier!;
}
