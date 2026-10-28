/// ugk_coach：FlareLab / HipLab / SmartFit 共用的 AI 训练助理 SDK（纯 Dart，不依赖 Flutter）。
///
/// 入口是 [CoachAgent]（0.3 Agent 版：skill 渐进式披露 + 工具循环）；[CoachSession]（0.2 工具版）保留作降级；
/// 0.1 的 [CoachAssistant] 保留一版（deprecated）。
///其余是它的零件，App 也可单独使用（如只用 [PlanValidator] 校验模板计划）。
library;

export 'src/agent/agent_prompt.dart';
export 'src/agent/coach_agent.dart';
export 'src/agent/coach_conversation_controller.dart';
export 'src/agent/context_turn_ledger.dart';
export 'src/agent/session_snapshot.dart';
export 'src/agent/session_state.dart';
export 'src/agent/skill_files.dart';
export 'src/agent/user_memory.dart';
export 'src/assistant/coach_assistant.dart';
export 'src/assistant/conversation.dart';
export 'src/assistant/fallback.dart';
export 'src/catalog/asset_resolver.dart';
export 'src/catalog/catalog.dart';
export 'src/catalog/catalog_repository.dart';
export 'src/catalog/catalog_source.dart';
export 'src/catalog/drill_pack_adapter.dart';
export 'src/catalog/pose_hub_app_test_pack.dart';
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
export 'src/prompt/tool_prompt.dart';
export 'src/tools/ask_user.dart';
export 'src/tools/coach_session.dart';
export 'src/tools/coach_tools.dart';
export 'src/tools/tool_gate.dart';
export 'src/usage/usage.dart';
export 'src/util/json.dart' show LocalizedText;
export 'src/util/version.dart';
