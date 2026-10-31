/// Pure presentation widgets. Applications own networking, credentials,
/// admission of AI results, persistence and navigation.
library;

export 'src/models.dart';
export 'src/theme.dart';
export 'src/primitives.dart'
    show
        CoachAppear,
        CoachGlyph,
        CoachHaptic,
        CoachPressable,
        CoachControlFace,
        CoachTextAction,
        CoachCardSurface,
        CoachIcon,
        CoachStartButton;
export 'src/message_widgets.dart';
export 'src/chat_list.dart';
export 'src/question_bubble.dart';
export 'src/failure_bubble.dart';
export 'src/plan_card.dart';
export 'src/recommend_card.dart';
export 'src/task_bubble.dart' show CoachTaskBubble, CoachTaskCutoutBuilder;
export 'src/coach_delivery_transition.dart' show CoachDeliveryTransition;
export 'src/plan_focus_label.dart'
    show PlanFocusLabel, CoachPlanFocusIconBuilder;
