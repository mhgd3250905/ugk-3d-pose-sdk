/// AI 问答推荐 Agent v2（原型，可选启用）。与 `package:ugk_coach/ugk_coach.dart` 的 CoachAgent 并存。
///
/// 用户的话全部由模型照 SOP（`coachQaSop`，来源 `lib/src/qa_v2/coach_qa_sop.md`）理解；
/// 代码只按结构化标签圈范围、排时长、做一致性检查。
///
/// ```dart
/// final agent = CoachQaAgent(client: client, catalog: catalog, profile: profile, aiTags: tags);
/// final reply = await agent.send('推荐几个练腹肌的动作');
/// ```
library;

export 'src/qa_v2/coach_qa_agent.dart';
export 'src/qa_v2/qa_action.dart';
export 'src/qa_v2/qa_finder.dart';
export 'src/qa_v2/qa_plan_builder.dart';
