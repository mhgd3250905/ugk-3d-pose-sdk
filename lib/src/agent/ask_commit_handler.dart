part of 'coach_agent.dart';

extension _AskCommitHandler on CoachAgent {
  void _commitAsk({
    required AskUserQuestion question,
    required int questionsAsked,
    required LlmMessage userMessage,
    required List<LlmMessage> turnMessages,
    required LlmMessage assistantMessage,
    required List<LlmToolCall> calls,
    required List<String> results,
    required List<LlmMessage> resultMessages,
    required Set<String> memoryResultIds,
    required Set<LlmMessage> privateReasoning,
  }) {
    _questionsAsked = questionsAsked + 1;
    _pendingConfirmation = question;
    _turns++;
    final pending = <LlmMessage>[
      ...turnMessages,
      assistantMessage,
      ...resultMessages,
    ];
    final resumable = <LlmMessage>[];
    for (var i = 0; i < pending.length;) {
      final message = pending[i++];
      final batch = <LlmMessage>[message];
      if (message.role == LlmRole.assistant) {
        while (i < pending.length && pending[i].role == LlmRole.tool) {
          batch.add(pending[i++]);
        }
      }
      final privateIds = <String>{
        for (final tool in message.toolCalls)
          if (memoryResultIds.contains(tool.id) &&
              (tool.name == AgentTools.remember ||
                  tool.name == AgentTools.forget ||
                  (tool.name == AgentTools.read &&
                      SkillFiles.normalize(
                        CoachAgent._arg(tool, 'path') ?? '',
                      ).startsWith('${SkillFiles.userMemory}/'))))
            tool.id,
      };
      resumable.addAll(
        CoachAgent._withoutMemory(
          batch,
          privateIds,
          privateReasoning: privateReasoning,
        ),
      );
    }
    _history
      ..add(userMessage)
      ..addAll(resumable);
  }
}
