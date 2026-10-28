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
    this.changes = const [],
    this.rejected = false,
  });
  final String response;
  final AskUserQuestion? question;
  final AgentOutputResult? output;

  /// Receipt-only metadata after a rejected show; nodes and picks are intact.
  final CoachSessionState? state;
  final List<CoachNodeState> changes;
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
      jsonEncode({
        'ok': true,
        'asked': true,
        'awaitingUser': true,
        if (checked.notes.isNotEmpty || position != count)
          'notes': [...checked.notes, if (position != count) '已在本批其他操作之后暂停询问。'],
      }),
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
    if (output.needsUserChoice) {
      return TerminalToolResult(
        jsonEncode({
          'ok': true,
          'status': 'infeasible',
          'needsUserChoice': true,
          'feasibility': output.feasibility,
          if (output.unavailableMessage != null)
            'message': output.unavailableMessage,
          if (output.notices.isNotEmpty) 'notices': output.notices,
        }),
        state: output.state,
        changes: output.changes,
      );
    }
    if (!output.ok) {
      return TerminalToolResult(
        jsonEncode(output.error),
        rejected: true,
        state: output.state,
      );
    }
    if (output.unavailable) {
      return TerminalToolResult(
        jsonEncode({
          'ok': true,
          'unavailable': true,
          'message': output.unavailableMessage,
        }),
        state: output.state,
        output: output,
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
