/// AI 问答推荐 Agent v2（原型，可选启用）。与 `package:ugk_coach/ugk_coach.dart` 的 CoachAgent 并存。
///
/// 常规 agent 循环（v3，规格 docs/coach-qa-agent-v3.md）：模型照 SOP（`coachQaSop`，来源
/// `lib/src/qa_v2/coach_qa_sop.md`）自己调用工具；代码只做交付验收、安全与场景准入、配时和条件记录。
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
