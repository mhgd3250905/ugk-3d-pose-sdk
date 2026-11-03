/// AI 问答推荐 Agent v2（原型，可选启用）。与 `package:ugk_coach/ugk_coach.dart` 的 CoachAgent 并存。
///
/// ```dart
/// final agent = CoachQaAgent(client: client, catalog: catalog, profile: profile, aiTags: tags);
/// final reply = await agent.send('推荐几个练腹肌的动作');
/// ```
library;

export 'src/qa_v2/coach_qa_agent.dart';
export 'src/qa_v2/qa_action.dart';
export 'src/qa_v2/qa_finder.dart';
export 'src/qa_v2/qa_lexicon.dart';
export 'src/qa_v2/qa_plan_builder.dart';
