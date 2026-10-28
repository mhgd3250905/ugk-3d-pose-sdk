import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/context_compactor.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  const compactor = ContextCompactor();
  final catalog = loadCatalog();
  final finished = CoachSessionState(
    task: CoachTaskState(
      type: 'recommend',
      reused: false,
      nodes: const [CoachNodeState(id: 'output', status: 'done')],
    ),
  );

  test('new user input preserves reasoning on retained visible assistants', () {
    const history = [
      LlmMessage.user('推荐动作'),
      LlmMessage.assistant('可以先温和活动。', reasoning: 'delivered-reasoning'),
      LlmMessage.user('动作有什么用？'),
      LlmMessage.assistant('帮助舒展。', reasoning: 'plain-qa-reasoning'),
    ];
    final messages = compactor.compose(
      system: const LlmMessage.system('system'),
      state: finished,
      catalog: catalog,
      history: history,
      turnMessages: const [LlmMessage.user('还有什么建议？')],
      previousTaskFinished: true,
    );
    final assistants = messages.where((m) => m.role == LlmRole.assistant);
    expect(assistants.map((m) => m.reasoning), [
      'delivered-reasoning',
      'plain-qa-reasoning',
    ]);
    expect(assistants.map((m) => m.toJson()['reasoning_content']), [
      'delivered-reasoning',
      'plain-qa-reasoning',
    ]);
    expect(messages.last.content, '还有什么建议？');
    expect(assistants.every((m) => m.toolCalls.isEmpty), isTrue);
    expect(history.last.reasoning, 'plain-qa-reasoning');
  });

  test(
    'dropping completed internal tool history does not drop visible reasoning',
    () {
      const call = LlmToolCall(id: 'internal', name: 'read', arguments: '{}');
      final messages = compactor.compose(
        system: const LlmMessage.system('system'),
        state: finished,
        catalog: catalog,
        history: const [
          LlmMessage.user('推荐动作'),
          LlmMessage.assistant(
            '',
            reasoning: 'discarded-internal-reasoning',
            toolCalls: [call],
          ),
          LlmMessage.tool('internal', 'old internal tool result'),
          LlmMessage.assistant('可以舒展一下。', reasoning: 'kept-reasoning'),
        ],
        turnMessages: const [LlmMessage.user('谢谢')],
        previousTaskFinished: true,
      );
      final assistants = messages.where((m) => m.role == LlmRole.assistant);
      expect(assistants, hasLength(1));
      expect(assistants.single.reasoning, 'kept-reasoning');
      expect(messages.where((m) => m.role == LlmRole.tool), isEmpty);
    },
  );

  test(
    'compaction preserves explicit empty reasoning after privacy sanitation',
    () {
      final messages = compactor.compose(
        system: const LlmMessage.system('system'),
        state: finished,
        catalog: catalog,
        history: const [
          LlmMessage.user('之前的问题'),
          LlmMessage.assistant('保留可见回答。', reasoning: ''),
        ],
        turnMessages: const [LlmMessage.user('记忆已关闭')],
        previousTaskFinished: true,
      );
      expect(
        messages.singleWhere((m) => m.role == LlmRole.assistant).toJson(),
        {'role': 'assistant', 'content': '保留可见回答。', 'reasoning_content': ''},
      );
    },
  );
}
