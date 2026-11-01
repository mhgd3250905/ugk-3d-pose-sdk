import 'package:ugk_coach/ugk_coach.dart' as coach;

import 'chat_strings.dart';

/// Presentation categories derived from typed failures, never response text.
enum ChatFailureKind {
  network,
  authentication,
  context,
  conversationLimit,
  planGate,
  timeout,
  service,
  unknown;

  static ChatFailureKind of({
    coach.CoachTurnResult? result,
    Object? error,
    bool timedOut = false,
  }) {
    final failure = error ?? result?.error;
    if (result?.status == coach.TurnStatus.limitReached) {
      return conversationLimit;
    }
    if (failure is coach.AgentContextBudgetExceeded) {
      return context;
    }
    final requestClass = failure is coach.AgentRequestFailed
        ? failure.errorClass
        : failure is coach.LlmException
        ? coach.RequestErrorClass.of(failure)
        : null;
    switch (requestClass) {
      case coach.RequestErrorClass.contextTooLong:
        return context;
      case coach.RequestErrorClass.auth:
        return authentication;
      case coach.RequestErrorClass.network:
        return network;
      case coach.RequestErrorClass.timeout:
        return timeout;
      case coach.RequestErrorClass.rateLimited:
      case coach.RequestErrorClass.server:
      case coach.RequestErrorClass.badResponse:
      case coach.RequestErrorClass.truncated:
        return service;
      default:
        break;
    }
    if (timedOut ||
        failure is coach.AgentRequestFailed &&
            failure.kind == coach.AgentFailureKind.turnTimeout) {
      return timeout;
    }
    if (failure is coach.PlanExecutionTimingException ||
        (result?.issues.isNotEmpty ?? false) ||
        result?.fallbackReason == coach.FallbackReason.invalidOutput) {
      return planGate;
    }
    return unknown;
  }

  String message(CoachChatStrings strings) => switch (this) {
    network => strings.networkFailure,
    authentication => strings.authenticationFailure,
    context => strings.contextFailure,
    conversationLimit => strings.conversationLimitReached,
    planGate => strings.planGateFailure,
    timeout => strings.timeoutFailure,
    service => strings.serviceFailure,
    unknown => strings.generationFailure,
  };
}
