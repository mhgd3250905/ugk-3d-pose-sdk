/// Validate terminating tool calls; delivery/ask commits remain with the turn.
library;

import 'dart:convert';

import '../tools/ask_user.dart';
import '../tools/tool_gate.dart';
import 'agent_task.dart';
import 'session_state.dart';

class TerminalToolResult {
  const TerminalToolResult(
    this.response, {
    this.question,
    this.output,
    this.state,
    this.rejected = false,
  });
  final String response;
  final AskUserQuestion? question;
  final AgentOutputResult? output;

  /// Receipt-only metadata after a rejected show; nodes and picks are intact.
  final CoachSessionState? state;
  final bool rejected;
}

class TerminalToolHandler {
  const TerminalToolHandler(this.gate);
  final ToolGate gate;

  TerminalToolResult ask(
    String raw,
    int position,
    int count, {
    String language = 'zh',
  }) {
    if (position != count) {
      return TerminalToolResult(
        jsonEncode(
          nodeError(
            'ask_not_last',
            'tool_calls',
            'ask_user 位于批次最后',
            position,
            '将 ask_user 放在最后一次工具调用。',
          ),
        ),
        rejected: true,
      );
    }
    final checked = AskUserGate.check(raw, language: language);
    if (!checked.ok) {
      return TerminalToolResult(
        jsonEncode({
          ...nodeError(
            'invalid_ask',
            'arguments',
            '有效的 ask_user 参数',
            checked.errors.map((issue) => issue.message).toList(),
            '按 ask_user schema 修正问题参数。',
          ),
          'errors': [
            for (final issue in checked.errors) ToolGate.issueJson(issue),
          ],
        }),
        rejected: true,
      );
    }
    return TerminalToolResult(
      jsonEncode({'ok': true, 'asked': true, 'awaitingUser': true}),
      question: checked.question,
    );
  }

  TerminalToolResult show(
    CoachSessionState state,
    String tool,
    String raw, {
    required String language,
  }) {
    Object? args;
    try {
      args = jsonDecode(raw);
    } on FormatException {
      args = null;
    }
    final output = gate.checkAgentOutput(state, tool, args, language: language);
    if (!output.ok) {
      return TerminalToolResult(
        jsonEncode(output.error),
        rejected: true,
        state: output.state,
      );
    }
    return TerminalToolResult(
      jsonEncode({
        'ok': true,
        'shown': true,
        if (output.noteTruncated) ...{'noteTruncated': true, 'note': '已截断'},
        if (output.notices.isNotEmpty) 'notices': output.notices,
      }),
      output: output,
    );
  }
}
