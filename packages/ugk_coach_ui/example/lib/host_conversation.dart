import 'package:flutter/material.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

/// Example App view model: all fields are trusted/localized by its caller.
class HostMessage {
  const HostMessage({
    required this.id,
    required this.at,
    this.isUser = false,
    this.text = '',
    this.question,
    this.routine,
  });
  final String id, text;
  final DateTime at;
  final bool isUser;
  final CoachQuestionData? question;
  final CoachRoutine? routine;
}

/// HipLab / Flare can adapt their own view model just like this example.
/// Set awaitingQuestionId only AFTER awaiting CoachAgent.send(). No client,
/// endpoint, credential or persistence implementation enters the UI package.
class HostConversation extends StatelessWidget {
  const HostConversation({
    super.key,
    required this.messages,
    required this.controller,
    required this.catalog,
    required this.onAnswer,
    required this.onStart,
    required this.onSave,
    required this.onOpen,
    required this.isSaved,
    this.awaitingQuestionId,
    this.busy = false,
    this.style,
  });
  final List<HostMessage> messages;
  final ScrollController controller;
  final CoachExerciseLibrary catalog;
  final String? awaitingQuestionId;
  final bool busy;
  final CoachUiStyle? style;
  final Future<void> Function(String messageId, String answer) onAnswer;
  final void Function(CoachRoutine, CoachOriginRect) onStart;
  final ValueChanged<CoachRoutine> onSave, onOpen;
  final bool Function(CoachRoutine) isSaved;

  @override
  Widget build(BuildContext context) {
    final view = CoachChatList(
      controller: controller,
      timeMarkBuilder: (at, now) => CoachTimeMark(at, now: now),
      typing: busy ? const CoachTypingBubble() : null,
      entries: [
        for (final m in messages)
          CoachChatEntry(
            id: m.id,
            at: m.at,
            isUser: m.isUser,
            isCard: m.routine != null,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (m.question case final question?)
                  CoachQuestionBubble(
                    key: ValueKey('question-${m.id}'),
                    question: question,
                    enabled: !busy && awaitingQuestionId == m.id,
                    onTextAnswer: (answer) => onAnswer(m.id, answer),
                    onChoiceAnswer: (answers) =>
                        onAnswer(m.id, answers.join(', ')),
                  )
                else if (m.text.isNotEmpty)
                  CoachMessageBubble(
                    message: CoachBubbleData(
                      id: m.id,
                      text: m.text,
                      isUser: m.isUser,
                    ),
                    optionsActive: false,
                    onOption: (_) {},
                  ),
                if (m.routine case final routine?)
                  CoachPlanCard(
                    plan: routine,
                    library: catalog,
                    saved: isSaved(routine),
                    onStart: (origin) => onStart(routine, origin),
                    onSave: () => onSave(routine),
                    onOpen: () => onOpen(routine),
                  ),
              ],
            ),
          ),
      ],
    );
    return style == null ? view : CoachUiTheme(style: style!, child: view);
  }
}
