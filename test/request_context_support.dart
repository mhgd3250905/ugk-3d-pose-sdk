import 'dart:convert';

import 'package:ugk_coach/src/agent/append_only_context.dart';
import 'package:ugk_coach/ugk_coach.dart';

/// Uses real wire configuration/measurement while every completion stays local.
class OfflineConfiguredClient extends OpenAiCompatibleClient {
  OfflineConfiguredClient({required this.replay, required super.config});
  final LlmClient replay;

  @override
  Future<LlmResponse> complete(LlmRequest request, {CancelToken? cancel}) =>
      replay.complete(request, cancel: cancel);
}

/// Protocol/history assertions exclude only the explicitly generated tail.
/// No real user, assistant or tool message is filtered by its prose.
List<LlmMessage> modelRequestHistory(LlmRequest request) {
  final messages = request.messages;
  if (messages.isNotEmpty &&
      messages.last.role == LlmRole.user &&
      messages.last.content.startsWith(AppendOnlyContext.statePrefix)) {
    return messages.sublist(0, messages.length - 1);
  }
  return messages;
}

Map<String, Object?> requestCurrentState(LlmRequest request) {
  final message = request.messages.last;
  if (message.role != LlmRole.user ||
      !message.content.startsWith(AppendOnlyContext.statePrefix)) {
    throw StateError('Expected a generated trailing state message');
  }
  return (jsonDecode(
            message.content.substring(AppendOnlyContext.statePrefix.length),
          )
          as Map)
      .cast<String, Object?>();
}
