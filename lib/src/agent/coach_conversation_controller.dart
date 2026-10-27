/// App-neutral conversation state around one long-lived [CoachAgent].
library;

import 'dart:async';

import '../llm/cancel_token.dart';
import '../plan/coach_context.dart';
import '../plan/training_plan.dart';
import '../tools/ask_user.dart';
import '../tools/coach_session.dart';
import '../tools/tool_gate.dart';
import 'coach_agent.dart';
import 'training_confirmation.dart';

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
    Map<String, List<String>> answeredForm = const {},
    this.plan,
    this.planState,
    this.actions,
    this.turnId,
    this.isFailure = false,
    this.isPlanningFailure = false,
  }) : answeredChoices = List.unmodifiable(answeredChoices),
       answeredForm = Map.unmodifiable({
         for (final entry in answeredForm.entries)
           entry.key: List<String>.unmodifiable(entry.value),
       });

  final String id;
  final DateTime at;
  final bool isUser;
  final String text;
  final AskUserQuestion? question;
  final bool questionAnswered;
  final List<String> answeredChoices;

  /// Confirmed selections retained for the collapsed confirmation summary.
  final Map<String, List<String>> answeredForm;
  final ValidatedPlan? plan;

  /// Optional planning conditions to persist with [plan]. Older history may
  /// omit this; restoration then infers conditions from the admitted plan.
  final CoachPlanState? planState;
  final ValidatedActions? actions;
  final String? turnId;

  /// A failed turn for the host to render as a failure bubble. Exception
  /// details remain in state.error and are never copied into display text.
  final bool isFailure;

  /// Distinguishes a failed planning request from a failed explanation/chat.
  final bool isPlanningFailure;

  CoachConversationMessage copyWith({
    String? text,
    bool? questionAnswered,
    List<String>? answeredChoices,
    Map<String, List<String>>? answeredForm,
  }) => CoachConversationMessage(
    id: id,
    at: at,
    isUser: isUser,
    text: text ?? this.text,
    question: question,
    questionAnswered: questionAnswered ?? this.questionAnswered,
    answeredChoices: answeredChoices ?? this.answeredChoices,
    answeredForm: answeredForm ?? this.answeredForm,
    plan: plan,
    planState: planState,
    actions: actions,
    turnId: turnId,
    isFailure: isFailure,
    isPlanningFailure: isPlanningFailure,
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

  /// A preset can be offered only after a failed turn and only if the agent
  /// verifies both the requested focus and all confirmed plan constraints.
  bool canOfferPreset(TrainingPlan plan) =>
      !_disposed &&
      !_state.isWaiting &&
      _state.lastResult?.status == TurnStatus.error &&
      _state.lastResult!.isPlanningFailure &&
      agent.canOfferPreset(plan);

  /// Explicit user action; the plan is checked again before being displayed.
  CoachTurnResult? requestPreset(TrainingPlan plan) {
    if (!canOfferPreset(plan)) return null;
    final result = agent.requestPreset(plan);
    if (result?.plan == null) return null;
    final messages = List<CoachConversationMessage>.of(_state.messages)
      ..add(
        CoachConversationMessage(
          id: _nextId(),
          at: _clock(),
          isUser: true,
          text: '用预设方案',
          turnId: result!.turnId,
        ),
      )
      ..add(
        CoachConversationMessage(
          id: _nextId(),
          at: _clock(),
          text: result.text,
          plan: result.plan,
          planState: agent.planStateFor(result.plan!),
          turnId: result.turnId,
        ),
      );
    _publish(CoachConversationState._(messages: messages, lastResult: result));
    return result;
  }

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

  /// A grouped answer remains one ordinary user turn. No model/tool state is
  /// accepted from the UI; every label is checked against the pending form.
  Future<CoachTurnResult?> answerForm(
    String questionId,
    Map<String, List<String>> answers, {
    CoachContext context = const CoachContext(),
    CancelToken? cancel,
  }) {
    if (!canAnswer(questionId)) return Future.value();
    final question = _state.pendingQuestion!.question!;
    if (question.mode != AskUserMode.form ||
        answers.keys.any(
          (key) => !question.fields.any((field) => field.key == key),
        )) {
      return Future.value();
    }
    final lines = <String>[];
    final orderedAnswers = <String, List<String>>{};
    for (final field in question.fields) {
      final selected = answers[field.key] ?? const <String>[];
      final scene = answers['scene'];
      final sceneOptions = field.optionsByScene;
      if (selected.isEmpty ||
          selected.toSet().length != selected.length ||
          (!field.multiple && selected.length != 1) ||
          selected.any((value) => !field.options.contains(value)) ||
          (field.key == 'equipment' &&
              selected.contains('徒手') &&
              selected.length > 1) ||
          (question.isConfirmation &&
              field.key == 'equipment' &&
              sceneOptions.isNotEmpty &&
              (scene == null ||
                  scene.length != 1 ||
                  !sceneOptions.containsKey(scene.single) ||
                  selected.any(
                    (option) => !sceneOptions[scene.single]!.contains(option),
                  )))) {
        return Future.value();
      }
      final ordered = field.options.where(selected.contains).toList();
      orderedAnswers[field.key] = ordered;
      lines.add('${field.label}：${ordered.join(choiceSeparator)}');
    }
    return _send(
      question.isConfirmation
          ? _naturalFormText(orderedAnswers)
          : lines.join('；'),
      context: context,
      cancel: cancel,
      formAnswers: orderedAnswers,
      confirmedForm: question.isConfirmation ? orderedAnswers : null,
    );
  }

  String _naturalFormText(Map<String, List<String>> answers) {
    final scene = answers['scene']?.firstOrNull;
    final equipment = answers['equipment'] ?? const <String>[];
    final minutes = answers['minutes']?.firstOrNull;
    String naturalEquipment() {
      if (equipment.isEmpty) return '';
      if (equipment.length == 1 && equipment.first == '徒手') return '徒手';
      if (equipment.length == 1) return '有${equipment.single}';
      return '有${equipment.take(equipment.length - 1).join('、')}和${equipment.last}';
    }

    return [
      ?scene,
      if (equipment.isNotEmpty) naturalEquipment(),
      ?minutes,
    ].join('，');
  }

  Future<CoachTurnResult?> skipQuestion(
    String questionId, {
    CoachContext context = const CoachContext(),
    CancelToken? cancel,
  }) {
    if (!canAnswer(questionId)) return Future.value();
    final question = _state.pendingQuestion!.question!;
    return _send(
      question.skipLabel,
      context: context,
      cancel: cancel,
      formAnswers: question.isConfirmation
          ? question.defaultSelections
          : const {},
      confirmedForm: question.isConfirmation
          ? question.defaultSelections
          : null,
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
    Map<String, List<String>> formAnswers = const {},
    Map<String, List<String>>? confirmedForm,
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
    final originalMessages = _state.messages;
    final confirmationSubmitted =
        question?.question?.isConfirmation == true && confirmedForm != null;
    final submittedMessages = confirmationSubmitted
        ? (_closedMessages(question!.id, formAnswers: formAnswers)..add(
            CoachConversationMessage(
              id: _nextId(),
              at: _clock(),
              isUser: true,
              text: text,
            ),
          ))
        : originalMessages;
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
        messages: submittedMessages,
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
      final pending = agent.send(
        input,
        context: context,
        cancel: token,
        confirmedForm: confirmedForm,
      );
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
            messages: confirmationSubmitted
                ? originalMessages
                : _state.messages,
            pendingQuestion: question,
            lastResult: result,
            error: result.error,
          ),
        );
        return result;
      }
      final closedForm = question?.question?.isConfirmation == true
          ? agent.lastConfirmedForm ?? formAnswers
          : formAnswers;
      final keepsConfirmation =
          question?.question?.isConfirmation == true &&
          identical(agent.pendingConfirmation, question!.question);
      final messages = keepsConfirmation
          ? List<CoachConversationMessage>.of(originalMessages)
          : confirmationSubmitted
          ? List<CoachConversationMessage>.of(_state.messages)
          : _closedMessages(
              question?.id,
              choices: choices,
              formAnswers: closedForm,
            );
      final at = _clock();
      if (!confirmationSubmitted || keepsConfirmation) {
        messages.add(
          CoachConversationMessage(
            id: _nextId(),
            at: at,
            isUser: true,
            text: text,
            turnId: result.turnId,
          ),
        );
      }
      final admittedQuestion = result.status == TurnStatus.ok
          ? result.question
          : null;
      final assistant = CoachConversationMessage(
        id: _nextId(),
        at: _clock(),
        text: result.text == admittedQuestion?.question ? '' : result.text,
        question: admittedQuestion,
        plan: result.plan,
        planState: result.plan == null
            ? null
            : agent.planStateFor(result.plan!),
        actions: result.actions,
        turnId: result.turnId,
        isFailure:
            result.status == TurnStatus.error ||
            result.status == TurnStatus.limitReached,
        isPlanningFailure: result.isPlanningFailure,
      );
      if (assistant.text.isNotEmpty ||
          assistant.question != null ||
          assistant.plan != null ||
          assistant.actions != null ||
          assistant.isFailure) {
        messages.add(assistant);
      }
      _active = null;
      _publish(
        CoachConversationState._(
          messages: messages,
          pendingQuestion: admittedQuestion == null
              ? (keepsConfirmation ? question : null)
              : assistant,
          lastResult: result,
          error: result.error,
        ),
      );
      return result;
    } on Object catch (error) {
      if (current()) {
        _active = null;
        final keepsConfirmation =
            question?.question?.isConfirmation == true &&
            identical(agent.pendingConfirmation, question!.question);
        final messages = keepsConfirmation
            ? List<CoachConversationMessage>.of(originalMessages)
            : confirmationSubmitted
            ? List<CoachConversationMessage>.of(_state.messages)
            : _closedMessages(question?.id);
        if (!confirmationSubmitted || keepsConfirmation) {
          messages.add(
            CoachConversationMessage(
              id: _nextId(),
              at: _clock(),
              isUser: true,
              text: text,
            ),
          );
        }
        messages.add(
          CoachConversationMessage(
            id: _nextId(),
            at: _clock(),
            isFailure: true,
            isPlanningFailure: question?.question?.isConfirmation == true,
          ),
        );
        _publish(
          CoachConversationState._(
            messages: messages,
            pendingQuestion: keepsConfirmation ? question : null,
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
    if (_state.pendingQuestion!.question?.isConfirmation == true) {
      agent.dismissConfirmation();
    }
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
    agent.dismissConfirmation();
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

  /// Restores the last admitted plan as the active task. Questions remain
  /// read-only and old tool calls are not resumed. [planState], if supplied,
  /// takes precedence only when its planId matches the last plan card.
  void restoreHistory(
    List<CoachConversationMessage> messages, {
    CoachPlanState? planState,
  }) {
    if (_disposed) return;
    _cancel();
    agent.reset();
    final planIndex = messages.lastIndexWhere(
      (message) => message.plan != null,
    );
    if (planIndex >= 0) {
      final card = messages[planIndex];
      final plan = card.plan!;
      final explicit = planState?.planId == plan.plan.id ? planState : null;
      final stored = card.planState?.planId == plan.plan.id
          ? card.planState
          : null;
      String? focus;
      String? goal;
      // Only inspect the messages associated with this plan, never a previous
      // card's request. This avoids attaching stale focus to a new plan.
      for (var i = planIndex - 1; i >= 0; i--) {
        final message = messages[i];
        if (message.plan != null) break;
        if (message.isUser) {
          focus ??= trainingFocus(message.text);
          goal ??= trainingGoal(message.text);
        }
      }
      agent.restorePlan(
        plan,
        planState: explicit ?? stored,
        focusHint: focus,
        goalHint: goal,
      );
    }
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
    Map<String, List<String>> formAnswers = const {},
  }) => [
    for (final message in _state.messages)
      if (message.id == questionId && message.question != null)
        message.copyWith(
          questionAnswered: true,
          answeredChoices: choices,
          answeredForm: formAnswers,
        )
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
