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
export 'src/plan_card.dart';
