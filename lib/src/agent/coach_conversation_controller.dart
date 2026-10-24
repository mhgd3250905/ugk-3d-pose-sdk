/// App-neutral conversation state around one long-lived [CoachAgent].
library;

import 'dart:async';

import '../llm/cancel_token.dart';
import '../plan/coach_context.dart';
import '../tools/ask_user.dart';
import '../tools/coach_session.dart';
import '../tools/tool_gate.dart';
import 'coach_agent.dart';

/// A presentation/history snapshot. Only live controller results are answerable.
///
/// Apps own persistence and must re-admit stored plans/actions before supplying
/// them to [CoachConversationController.restoreHistory]. This class never
/// serializes credentials, transport settings or the agent's tool history.
class CoachConversationMessage {
  CoachConversationMessage({
    required this.id,
    required this.at,
    this.isUser = false,
    this.text = '',
    this.question,
    this.questionAnswered = false,
    List<String> answeredChoices = const [],
    this.plan,
    this.actions,
    this.turnId,
  }) : answeredChoices = List.unmodifiable(answeredChoices);

  final String id;
  final DateTime at;
  final bool isUser;
  final String text;
  final AskUserQuestion? question;
  final bool questionAnswered;
  final List<String> answeredChoices;
  final ValidatedPlan? plan;
  final ValidatedActions? actions;
  final String? turnId;

  CoachConversationMessage copyWith({
    String? text,
    bool? questionAnswered,
    List<String>? answeredChoices,
  }) => CoachConversationMessage(
    id: id,
    at: at,
    isUser: isUser,
    text: text ?? this.text,
    question: question,
    questionAnswered: questionAnswered ?? this.questionAnswered,
    answeredChoices: answeredChoices ?? this.answeredChoices,
    plan: plan,
    actions: actions,
    turnId: turnId,
  );
}

/// Immutable observable state. [pendingQuestion] is disabled while [isWaiting].
class CoachConversationState {
  CoachConversationState._({
    List<CoachConversationMessage> messages = const [],
    this.pendingQuestion,
    this.isWaiting = false,
    this.error,
    this.lastResult,
  }) : messages = List.unmodifiable(messages),
       admittedPlans = List.unmodifiable([
         for (final message in messages) ?message.plan,
       ]);

  final List<CoachConversationMessage> messages;
  final CoachConversationMessage? pendingQuestion;
  final bool isWaiting;
  final List<ValidatedPlan> admittedPlans;
  final Object? error;
  final CoachTurnResult? lastResult;
}

/// Owns sends and the lifecycle of the supplied [agent], without Flutter.
///
/// The App constructs the agent with its client, profile, catalog and fallback.
/// It retains ownership of HTTP-client disposal, persistence, navigation,
/// training and presentation mappings. Do not call agent.send/reset/dispose
/// directly while this controller owns it. A new conversation resets the same
/// agent; it never constructs another one.
class CoachConversationController {
  CoachConversationController({
    required this.agent,
    DateTime Function()? clock,
    this.choiceSeparator = '、',
  }) : _clock = clock ?? DateTime.now;

  final CoachAgent agent;
  final String choiceSeparator;
  final DateTime Function() _clock;
  final _states = StreamController<CoachConversationState>.broadcast();
  final _listeners = <void Function()>{};
  CoachConversationState _state = CoachConversationState._();
  int _generation = 0;
  int _sequence = 0;
  CancelToken? _active;
  Future<CoachTurnResult>? _agentPending;
  Future<void>? _disposal;
  bool _disposed = false;

  CoachConversationState get state => _state;

  /// Broadcast state changes; read [state] immediately for the initial value.
  Stream<CoachConversationState> get states => _states.stream;

  /// Progress is informational: askUser events never enable an answer.
  Stream<AgentEvent> get events => agent.events;

  void addListener(void Function() listener) {
    if (!_disposed) _listeners.add(listener);
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);

  bool canAnswer(String questionId) =>
      !_disposed &&
      !_state.isWaiting &&
      _state.pendingQuestion?.id == questionId &&
      !_state.pendingQuestion!.questionAnswered;

  /// Validates selection and returns labels in their original option order.
  /// Invalid, stale or currently submitting answers return null.
  String? choiceText(String questionId, List<String> selected) {
    final ordered = _orderedChoices(questionId, selected);
    return ordered?.join(choiceSeparator);
  }

  List<String>? _orderedChoices(String questionId, List<String> selected) {
    if (!canAnswer(questionId)) return null;
    final question = _state.pendingQuestion!.question!;
    if (question.mode != AskUserMode.choice ||
        selected.isEmpty ||
        selected.toSet().length != selected.length ||
        (!question.multiple && selected.length != 1) ||
        selected.any((value) => !question.options.contains(value))) {
      return null;
    }
    return [
      for (final option in question.options)
        if (selected.contains(option)) option,
    ];
  }

  /// Free text also permits an alternative answer to a choice question.
  Future<CoachTurnResult?> answerText(
    String questionId,
    String text, {
    CoachContext context = const CoachContext(),
    CancelToken? cancel,
  }) {
    if (!canAnswer(questionId)) return Future.value();
    return _send(text, context: context, cancel: cancel);
  }

  Future<CoachTurnResult?> answerChoices(
    String questionId,
    List<String> selected, {
    CoachContext context = const CoachContext(),
    CancelToken? cancel,
  }) {
    final ordered = _orderedChoices(questionId, selected);
    if (ordered == null) return Future.value();
    return _send(
      ordered.join(choiceSeparator),
      context: context,
      cancel: cancel,
      choices: ordered,
    );
  }

  /// Sends ordinary input, or a free-text answer to the current question.
  ///
  /// Empty/disposed/concurrent sends return null and never queue. Input rejected
  /// by the agent (inputTooLong/busy) leaves the question available for retry.
  Future<CoachTurnResult?> send(
    String text, {
    CoachContext context = const CoachContext(),
    CancelToken? cancel,
  }) => _send(text, context: context, cancel: cancel);

  Future<CoachTurnResult?> _send(
    String input, {
    required CoachContext context,
    CancelToken? cancel,
    List<String> choices = const [],
  }) async {
    final text = input.trim();
    if (_disposed || _state.isWaiting || text.isEmpty) return null;
    if (cancel?.isCancelled ?? false) {
      this.cancel();
      return null;
    }
    final generation = _generation;
    final token = CancelToken();
    final question = _state.pendingQuestion;
    _active = token;
    bool current() =>
        !_disposed &&
        generation == _generation &&
        identical(_active, token) &&
        !token.isCancelled;
    if (cancel != null) {
      unawaited(
        cancel.whenCancelled.then((_) {
          if (current()) this.cancel();
        }),
      );
    }
    _publish(
      CoachConversationState._(
        messages: _state.messages,
        pendingQuestion: question,
        isWaiting: true,
      ),
    );
    try {
      // Only a cancelled send may still be settling. Ordinary concurrent sends
      // were already rejected synchronously by isWaiting above.
      final previous = _agentPending;
      if (previous != null && agent.isBusy) {
        try {
          await previous;
        } on Object {
          // Its caller receives the original error; it cannot poison a new turn.
        }
      }
      if (!current()) return null;
      final pending = agent.send(text, context: context, cancel: token);
      _agentPending = pending;
      final result = await pending;
      if (!current()) return null;
      if (result.status == TurnStatus.cancelled) {
        this.cancel();
        return result;
      }
      if (result.status == TurnStatus.inputTooLong ||
          result.status == TurnStatus.busy) {
        _active = null;
        _publish(
          CoachConversationState._(
            messages: _state.messages,
            pendingQuestion: _state.pendingQuestion,
            lastResult: result,
            error: result.error,
          ),
        );
        return result;
      }
      final messages = _closedMessages(question?.id, choices: choices);
      final at = _clock();
      messages.add(
        CoachConversationMessage(
          id: _nextId(),
          at: at,
          isUser: true,
          text: text,
          turnId: result.turnId,
        ),
      );
      final admittedQuestion = result.status == TurnStatus.ok
          ? result.question
          : null;
      final assistant = CoachConversationMessage(
        id: _nextId(),
        at: _clock(),
        text: result.text == admittedQuestion?.question ? '' : result.text,
        question: admittedQuestion,
        plan: result.plan,
        actions: result.actions,
        turnId: result.turnId,
      );
      if (assistant.text.isNotEmpty ||
          assistant.question != null ||
          assistant.plan != null ||
          assistant.actions != null) {
        messages.add(assistant);
      }
      _active = null;
      _publish(
        CoachConversationState._(
          messages: messages,
          pendingQuestion: admittedQuestion == null ? null : assistant,
          lastResult: result,
          error: result.error,
        ),
      );
      return result;
    } on Object catch (error) {
      if (current()) {
        _active = null;
        _publish(
          CoachConversationState._(
            messages: _closedMessages(question?.id),
            error: error,
          ),
        );
      }
      rethrow;
    } finally {
      if (identical(_active, token)) _active = null;
      if (!agent.isBusy) _agentPending = null;
    }
  }

  /// Closes a live question when an App-only route consumes the interaction.
  void invalidateQuestion() {
    if (_disposed || _state.pendingQuestion == null) return;
    _publish(
      CoachConversationState._(
        messages: _closedMessages(_state.pendingQuestion?.id),
        isWaiting: _state.isWaiting,
        lastResult: _state.lastResult,
        error: _state.error,
      ),
    );
  }

  /// Cancels immediately; late results cannot append messages or revive a question.
  void cancel() {
    if (_disposed) return;
    _cancel();
    _publish(
      CoachConversationState._(
        messages: _closedMessages(_state.pendingQuestion?.id),
      ),
    );
  }

  void _cancel() {
    _generation++;
    _active?.cancel();
    _active = null;
  }

  /// Clears display/tool history while retaining the exact same agent instance.
  void newConversation() {
    if (_disposed) return;
    _cancel();
    agent.reset();
    _publish(CoachConversationState._());
  }

  /// Restores display history only. Restored questions always remain read-only.
  void restoreHistory(List<CoachConversationMessage> messages) {
    if (_disposed) return;
    _cancel();
    agent.reset();
    _publish(
      CoachConversationState._(
        messages: [
          for (final message in messages)
            if (message.question != null)
              message.copyWith(questionAnswered: true)
            else
              message,
        ],
      ),
    );
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _cancel();
    _disposed = true;
    agent.reset();
    _state = CoachConversationState._(
      messages: _closedMessages(_state.pendingQuestion?.id),
    );
    _listeners.clear();
    await agent.dispose();
    await _states.close();
  }

  List<CoachConversationMessage> _closedMessages(
    String? questionId, {
    List<String> choices = const [],
  }) => [
    for (final message in _state.messages)
      if (message.id == questionId && message.question != null)
        message.copyWith(questionAnswered: true, answeredChoices: choices)
      else
        message,
  ];

  String _nextId() => 'coach-${_clock().microsecondsSinceEpoch}-${_sequence++}';

  void _publish(CoachConversationState state) {
    if (_disposed) return;
    _state = state;
    _states.add(state);
    for (final listener in List.of(_listeners)) {
      if (_listeners.contains(listener)) {
        try {
          listener();
        } on Object catch (error, stack) {
          Zone.current.handleUncaughtError(error, stack);
        }
      }
    }
  }
}
