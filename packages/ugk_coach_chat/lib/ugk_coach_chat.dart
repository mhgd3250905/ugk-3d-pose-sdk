/// Shared coach conversation module. Apps supply a profile and host adapters.
library;

export 'src/core/app_profile.dart';
export 'src/core/chat_bindings.dart';
export 'src/core/chat_controller.dart';
export 'src/core/chat_models.dart';
export 'src/core/chat_snapshot.dart';
export 'src/core/chat_strings.dart';
export 'src/core/transition_activity.dart';
export 'src/core/training_adapter.dart';

export 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart'
    show
        TrainerExperienceConfig,
        TrainingMediaPolicy,
        TrainingLibraryConfig,
        TrainingLibraryStrings,
        TrainingLibraryBrowser,
        TrainingLibraryPage,
        TrainingLibraryDetails,
        TrainingLibraryActionArt;

export 'src/theme/chat_theme.dart';
export 'src/ui/chat_home_page.dart' show CoachChatPage;
export 'src/ui/coach_chat_plan_details_page.dart';
