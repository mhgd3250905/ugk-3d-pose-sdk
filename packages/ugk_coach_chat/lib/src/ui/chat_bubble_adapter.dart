import 'package:flutter/material.dart';
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

import '../core/chat_models.dart';
import 'coach_ui_adapter.dart';

typedef Appear = CoachAppear;

/// Adapt App history to SDK presentation without sharing local safety/history
/// data with a network client. All copy and theme roles are App supplied.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.optionsActive,
    required this.onOption,
  });
  final ChatMessage message;
  final bool optionsActive;
  final void Function(int) onOption;
  @override
  Widget build(BuildContext context) {
    final step = RegExp(
      r'^(\d+/\d+)\u3000(.+)$',
      dotAll: true,
    ).firstMatch(message.text);
    return withCoachChatUi(
      context,
      CoachMessageBubble(
        message: CoachBubbleData(
          id: message.id,
          isUser: message.isUser,
          text: step?.group(2) ?? message.text,
          caption: step == null ? null : '安全确认 ${step.group(1)}',
          options: message.options.map((o) => o.label).toList(),
          chosen: message.chosen,
        ),
        optionsActive: optionsActive,
        onOption: onOption,
        optionBuilder: (id, i, label, chosen, dimmed, enabled, tap) =>
            OptionPill(
              key: ValueKey('option-$id-$i'),
              label: label,
              chosen: chosen,
              dimmed: dimmed,
              enabled: enabled,
              onTap: tap,
            ),
      ),
    );
  }
}

class OptionPill extends StatelessWidget {
  const OptionPill({
    super.key,
    required this.label,
    required this.onTap,
    this.chosen = false,
    this.dimmed = false,
    this.enabled = true,
  });
  final String label;
  final VoidCallback onTap;
  final bool chosen, dimmed, enabled;
  @override
  Widget build(BuildContext context) => withCoachChatUi(
    context,
    CoachOptionPill(
      label: label,
      onTap: onTap,
      chosen: chosen,
      dimmed: dimmed,
      enabled: enabled,
    ),
  );
}

class GreetingBlock extends StatelessWidget {
  const GreetingBlock({super.key, required this.text});
  final String text;
  @override
  Widget build(BuildContext context) =>
      withCoachChatUi(context, CoachGreetingBlock(text: text));
}

class TimeMark extends StatelessWidget {
  const TimeMark(this.at, {super.key, required this.now});
  final DateTime at, now;
  @override
  Widget build(BuildContext context) =>
      withCoachChatUi(context, CoachTimeMark(at, now: now));
}
