/// ugk_coach：FlareLab / HipLab / SmartFit 共用的 AI 训练助理 SDK（纯 Dart，不依赖 Flutter）。
///
/// 入口是 [CoachAssistant]；其余是它的零件，App 也可单独使用（如只用 [PlanValidator] 校验模板计划）。
library;

export 'src/assistant/coach_assistant.dart';
export 'src/assistant/conversation.dart';
export 'src/assistant/fallback.dart';
export 'src/catalog/asset_resolver.dart';
export 'src/catalog/catalog.dart';
export 'src/catalog/catalog_repository.dart';
export 'src/catalog/catalog_source.dart';
export 'src/catalog/drill_pack_adapter.dart';
export 'src/config/auth.dart';
export 'src/config/llm_config.dart';
export 'src/config/pricing.dart';
export 'src/envelope/coach_reply.dart';
export 'src/envelope/json_extract.dart';
export 'src/llm/cancel_token.dart';
export 'src/llm/fake_llm_client.dart';
export 'src/llm/llm_client.dart';
export 'src/llm/llm_types.dart';
export 'src/llm/openai_compatible_client.dart';
export 'src/plan/coach_context.dart';
export 'src/plan/plan_codec.dart';
export 'src/plan/plan_issue.dart';
export 'src/plan/plan_validator.dart';
export 'src/plan/training_plan.dart';
export 'src/profile/coach_profile.dart';
export 'src/prompt/default_prompts.dart';
export 'src/prompt/prompt_builder.dart';
export 'src/prompt/prompt_template.dart';
export 'src/usage/usage.dart';
export 'src/util/json.dart' show LocalizedText;
export 'src/util/version.dart';
