import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_trainer_runtime/engine.dart' show SessionResult;

import 'app_profile.dart';
import 'chat_bindings.dart';
import 'chat_models.dart';
import 'chat_snapshot.dart';
import 'transition_activity.dart';

/// The SF conversation lifecycle and display controller, with host services
/// injected. One instance owns exactly one core conversation and Agent.
class CoachChatController extends ChangeNotifier {
  CoachChatController({
    required this.profile,
    required coach.Catalog catalog,
    required this.bindings,
    this.context = const coach.CoachContext(),
    this.replyDelay = const Duration(milliseconds: 450),
    this.prepareReply,
    this.turnTimeout = const Duration(seconds: 390),
    DateTime Function()? clock,
  }) : _sourceCatalog = catalog,
       _clock = clock ?? DateTime.now;

  final CoachAppProfile profile;
  final CoachChatBindings bindings;
  final coach.CoachContext context;
  final coach.Catalog _sourceCatalog;
  final DateTime Function() _clock;
  final Duration replyDelay, turnTimeout;
  final Future<void> Function()? prepareReply;
  final transitionActivity = CoachChatTransitionActivity();
  final _messages = <ChatMessage>[];
  List<String> _suggestions = const [];
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  List<String> get suggestions => List.unmodifiable(_suggestions);
  bool get typing => _typing;
  bool _typing = false, _started = false, _restoring = false;
  bool _closed = false, _notifierDisposed = false, _openingTraining = false;
  int _seq = 0, _generation = 0;
  int? _safetyStep;
  String? _safetyMessageId;
  bool get inSafetyCheck => _safetyStep != null;
  Object? _lastError;
  Object? get error => _lastError;
  CoachChatPreferences _preferences = const CoachChatPreferences();
  CoachChatPreferences get preferences => _preferences;
  List<CoachSavedPlanSnapshot> _saved = const [];
  List<CoachSavedPlanSnapshot> get savedPlans => List.unmodifiable(_saved);
  CoachChatHistoryContext _trainingContext = const CoachChatHistoryContext();
  final _savedOrigins = <String, CoachSavedPlanSnapshot>{};
  final _saving = <String, Future<CoachSavedPlanSnapshot>>{};
  final _previews = <String, CoachChatScopePreview>{};
  final _receipts = <String>{};
  coach.TrainingPlan? _currentPlan;
  coach.TrainingPlan? get currentPlan => _currentPlan;

  coach.CoachAgent? _agent;
  coach.CoachConversationController? _conversation;
  coach.CoachAgent get agent =>
      _agent ?? (throw StateError('Call start first'));
  coach.CoachConversationController get conversation =>
      _conversation ?? (throw StateError('Call start first'));
  coach.Catalog get catalog => _agent?.actionScope?.catalog ?? _sourceCatalog;
  coach.CoachPlanFocus? get focus => _conversation?.focus;
  coach.CoachPlanFocus? get planFocus => focus;
  coach.CoachTurnResult? get lastResult => _conversation?.state.lastResult;
  coach.CoachTaskState? _latestTask;
  coach.CoachTaskState? get activeTask => _latestTask;
  coach.CoachSessionState? get activeSessionState =>
      _latestTask == null ? null : _agent?.sessionState;

  CoachChatState get state => CoachChatState(
    messages: _messages,
    suggestions: _suggestions,
    waiting: _typing,
    inSafetyCheck: inSafetyCheck,
    focus: focus,
    error: _lastError,
    activeTask: _latestTask,
    savingMessageIds: _saving.keys.toSet(),
  );

  final _actions = StreamController<CoachChatCommand>.broadcast();
  Stream<CoachChatCommand> get actions => _actions.stream;
  final _progress = StreamController<coach.AgentEvent>.broadcast();
  final _progressHistory = <coach.AgentEvent>[];
  final _finishedProgressTurns = <String>{};
  String? _progressTurnId;
  bool _progressEnded = true;
  late final Stream<coach.AgentEvent> progressEvents = Stream.multi((listener) {
    final subscription = _progress.stream.listen(
      listener.add,
      onError: listener.addError,
      onDone: listener.close,
    );
    for (final event in _progressHistory) {
      listener.add(event);
    }
    listener.onCancel = subscription.cancel;
  }, isBroadcast: true);
  Stream<coach.AgentEvent> get events => progressEvents;
  StreamSubscription<coach.AgentEvent>? _progressSubscription;
  StreamSubscription<void>? _plansSubscription;
  StreamSubscription<CoachChatPreferences>? _preferencesSubscription;
  CoachClientLease? _lease;
  bool _leaseReleased = false;
  Future<CoachChatOperationResult>? _starting;
  Future<void>? _closing;
  Future<CoachChatOperationResult>? _resetting;
  coach.CancelToken? _cancel;
  Timer? _persistenceTimer;
  Future<void> _persistenceTail = Future.value();

  /// Reads host adapters once, creates the sole core session, then restores.
  /// Repeated calls share the same startup operation and never call the model.
  Future<CoachChatOperationResult> start() => _starting ??= _start();

  Future<CoachChatOperationResult> _start() async {
    if (_closed) return const CoachChatOperationResult(ok: false);
    try {
      if (bindings.storageNamespace.trim().isEmpty) {
        throw ArgumentError('storageNamespace must not be empty');
      }
      final planning = profile.planningCatalog(_sourceCatalog);
      _preferences = await bindings.preferences.load();
      _saved = await bindings.plans.load();
      _trainingContext = await bindings.history.readTrainingContext();
      if (_closed) return const CoachChatOperationResult(ok: false);
      _lease = await bindings.gateway.create();
      if (_closed) {
        await _releaseClient();
        return const CoachChatOperationResult(ok: false);
      }
      _agent = coach.CoachAgent(
        client: _CancellableClient(_lease!.client),
        catalog: () => planning,
        profile: profile.coachProfile,
        scopeManifest: profile.scopeManifest,
        scopePolicy: profile.conversationPolicy,
        executionTiming: profile.executionTiming,
        memoryStore: bindings.memory,
        enableUserMemory: _preferences.enableUserMemory,
      );
      _conversation = coach.CoachConversationController(
        agent: agent,
        clock: _clock,
      );
      conversation.addListener(_onConversationChanged);
      _progressSubscription = agent.events.listen(_onProgress);
      _plansSubscription = bindings.plans.changes.listen((_) {
        unawaited(_reloadPlans());
      });
      _preferencesSubscription = bindings.preferences.changes.listen((value) {
        if (_closed) return;
        _preferences = value;
        agent.enableUserMemory = value.enableUserMemory;
        _notify();
      });
      _started = true;
      if (!_preferences.safetyAccepted) {
        _beginSafety(firstRun: true);
      } else {
        final saved = await bindings.history.load(bindings.storageNamespace);
        if (_closed) return const CoachChatOperationResult(ok: false);
        if (saved != null) {
          final restored = _restoreSnapshot(saved);
          if (!restored.ok) {
            _notify();
            return restored;
          }
        } else {
          final legacy = await bindings.history.loadLegacy(
            bindings.storageNamespace,
          );
          if (_closed) return const CoachChatOperationResult(ok: false);
          if (legacy != null) {
            final restored = await importLegacy(legacy);
            if (!restored.ok) {
              _notify();
              return restored;
            }
          }
        }
        final last = _messages.lastOrNull?.at;
        if (last == null ||
            _clock().difference(last) > const Duration(hours: 6)) {
          _addBot(
            '${profile.strings.greetingFor(_clock())}\n'
            '${_messages.isEmpty ? profile.strings.invitation : profile.strings.returningInvitation}',
            greeting: true,
          );
        }
        _suggestions = _defaults();
      }
      _notify();
      return const CoachChatOperationResult(ok: true);
    } on Object catch (error) {
      _recordError('chat.start.error', error);
      if (_conversation == null) await _releaseClient();
      _notify();
      return CoachChatOperationResult(ok: false, error: error);
    }
  }

  Future<void> _reloadPlans() async {
    try {
      final values = await bindings.plans.load();
      if (_closed) return;
      _saved = values;
      _notify();
    } on Object catch (error) {
      _recordError('chat.plans.error', error);
    }
  }

  void _onConversationChanged() {
    if (_closed) return;
    _syncQuestions();
    _schedulePersistence();
    _notify();
  }

  void _onProgress(coach.AgentEvent event) {
    bindings.observer?.call('chat.agent.event', event);
    if (!_typing ||
        _progressEnded ||
        _finishedProgressTurns.contains(event.turnId)) {
      return;
    }
    if (_progressTurnId != null && _progressTurnId != event.turnId) return;
    _progressTurnId ??= event.turnId;
    if (event.kind == coach.AgentEventKind.node && event.task != null) {
      _latestTask = event.task;
      _schedulePersistence();
      _notify();
    }
    _progressHistory.add(event);
    if (_progressHistory.length > 64) _progressHistory.removeAt(0);
    if (!_progress.isClosed) _progress.add(event);
    if (event.kind == coach.AgentEventKind.done) _endProgress();
  }

  void _endProgress() {
    if (_progressTurnId case final id?) {
      _finishedProgressTurns.add(id);
      if (_finishedProgressTurns.length > 64) {
        _finishedProgressTurns.remove(_finishedProgressTurns.first);
      }
    }
    _progressTurnId = null;
    _progressEnded = true;
    _progressHistory.clear();
  }

  /// Ordinary text stays ordinary text, including strings beginning with '@'.
  Future<coach.CoachTurnResult?> send(String text, {String? label}) =>
      _send(text, label: label);

  Future<coach.CoachTurnResult?> _send(
    String text, {
    String? label,
    String? questionId,
    List<String>? choices,
    Map<String, List<String>>? formAnswers,
    bool skipQuestion = false,
  }) async {
    await start();
    if (_resetting case final resetting?) await resetting;
    final input = text.trim();
    if (_closed ||
        !_started ||
        _conversation == null ||
        _typing ||
        input.isEmpty) {
      return null;
    }
    final user = _addUser(label ?? input);
    if (inSafetyCheck) {
      _addBot(profile.strings.finishSafetyFirst);
      _notify();
      _schedulePersistence();
      return null;
    }
    if (!_preferences.trainingAllowed) {
      _blocked();
      _notify();
      _schedulePersistence();
      return null;
    }
    final generation = ++_generation;
    final cancel = coach.CancelToken();
    _cancel = cancel;
    _typing = true;
    _latestTask = null;
    _lastError = null;
    _endProgress();
    _progressEnded = false;
    _notify();
    var timedOut = false;
    final timer = Timer(turnTimeout, () {
      timedOut = true;
      cancel.cancel('turn timeout');
    });
    try {
      try {
        await prepareReply?.call();
      } on Object catch (error) {
        bindings.observer?.call('chat.prepare.error', error);
      }
      if (_closed || generation != _generation) return null;
      final result = questionId == null
          ? await conversation.send(input, context: context, cancel: cancel)
          : skipQuestion
          ? await conversation.skipQuestion(
              questionId,
              context: context,
              cancel: cancel,
            )
          : formAnswers != null
          ? await conversation.answerForm(
              questionId,
              formAnswers,
              context: context,
              cancel: cancel,
            )
          : choices != null
          ? await conversation.answerChoices(
              questionId,
              choices,
              context: context,
              cancel: cancel,
            )
          : await conversation.answerText(
              questionId,
              input,
              context: context,
              cancel: cancel,
            );
      if (replyDelay > Duration.zero) await Future<void>.delayed(replyDelay);
      if (_closed || generation != _generation) return result;
      _typing = false;
      _endProgress();
      if (timedOut) {
        _addBot('', isPlanningFailure: true, aiVisible: true);
      } else if (result != null && result.status == coach.TurnStatus.ok) {
        _replace(user.copyWith(aiVisible: true));
        final output = conversation.state.messages
            .where(
              (message) => !message.isUser && message.turnId == result.turnId,
            )
            .lastOrNull;
        if (output != null) {
          _messages.add(_displayMessage(output));
        } else if (result.text.isNotEmpty) {
          _addBot(result.text, aiVisible: true);
        }
        if (result.plan != null) _currentPlan = result.plan!.plan;
      } else if (result?.status == coach.TurnStatus.inputTooLong) {
        _addBot('请把这一条缩短到 ${agent.maxInputChars} 字以内再发送。');
      } else if (result != null &&
          result.status != coach.TurnStatus.cancelled &&
          result.status != coach.TurnStatus.busy) {
        _addBot('', isPlanningFailure: true, aiVisible: true);
      }
      _syncQuestions();
      final asks =
          conversation.state.pendingQuestion != null ||
          (_messages.lastOrNull?.options.isNotEmpty ?? false);
      _suggestions = asks
          ? const []
          : result?.plan != null
          ? profile.strings.planSuggestions
          : _defaults();
      _notify();
      _persistInBackground();
      return result;
    } on Object catch (error) {
      if (!_closed && generation == _generation) {
        _typing = false;
        _endProgress();
        _recordError('chat.turn.error', error);
        _addBot('', isPlanningFailure: true, aiVisible: true);
        _suggestions = _defaults();
        _notify();
        _persistInBackground();
      }
      return null;
    } finally {
      timer.cancel();
      if (identical(_cancel, cancel)) _cancel = null;
    }
  }

  void cancelRequest() {
    if (!_typing || _closed) return;
    _generation++;
    _cancel?.cancel();
    _conversation?.cancel();
    _conversation?.invalidateQuestion();
    _typing = false;
    _endProgress();
    _suggestions = _defaults();
    _notify();
    _persistInBackground();
  }

  Future<CoachChatOperationResult> newConversation() {
    final pending = _resetting;
    if (pending != null) return pending;
    final operation = _newConversation();
    _resetting = operation;
    return operation.whenComplete(() {
      if (identical(_resetting, operation)) _resetting = null;
    });
  }

  Future<CoachChatOperationResult> _newConversation() async {
    await start();
    if (_closed || _conversation == null) {
      return const CoachChatOperationResult(ok: false);
    }
    _generation++;
    _cancel?.cancel();
    conversation.newConversation();
    _typing = false;
    _endProgress();
    _latestTask = null;
    _currentPlan = null;
    _safetyStep = null;
    _safetyMessageId = null;
    _messages.clear();
    _savedOrigins.clear();
    _previews.clear();
    if (!_preferences.safetyAccepted) {
      _beginSafety(firstRun: true);
    } else {
      _addBot(
        '${profile.strings.greetingFor(_clock())}\n${profile.strings.invitation}',
        greeting: true,
      );
      _suggestions = _defaults();
    }
    _notify();
    try {
      await _persist();
      return const CoachChatOperationResult(ok: true);
    } on Object catch (error) {
      return CoachChatOperationResult(ok: true, persisted: false, error: error);
    }
  }

  bool canAnswerQuestion(ChatMessage message) =>
      !_typing &&
      !inSafetyCheck &&
      message.conversationMessageId != null &&
      (_conversation?.canAnswer(message.conversationMessageId!) ?? false);

  Future<coach.CoachTurnResult?> answerQuestion(
    ChatMessage message,
    String text,
  ) => canAnswerQuestion(message) && text.trim().isNotEmpty
      ? _send(text, questionId: message.conversationMessageId)
      : Future.value();

  Future<coach.CoachTurnResult?> answerText(String questionId, String text) =>
      _conversation?.canAnswer(questionId) == true
      ? _send(text, questionId: questionId)
      : Future.value();

  Future<coach.CoachTurnResult?> answerChoices(
    ChatMessage message,
    List<String> selected,
  ) {
    if (!canAnswerQuestion(message)) return Future.value();
    final id = message.conversationMessageId!;
    final text = conversation.choiceText(id, selected);
    return text == null
        ? Future.value()
        : _send(text, questionId: id, choices: selected);
  }

  Future<coach.CoachTurnResult?> answerForm(
    ChatMessage message,
    Map<String, List<String>> answers,
  ) {
    if (!canAnswerQuestion(message)) return Future.value();
    final snapshot = {
      for (final entry in answers.entries)
        entry.key: List<String>.unmodifiable(entry.value),
    };
    final label = [
      for (final field in message.question!.fields)
        if (snapshot[field.key]?.isNotEmpty ?? false)
          '${field.label}：${snapshot[field.key]!.join('、')}',
    ].join('；');
    return _send(
      label,
      questionId: message.conversationMessageId,
      formAnswers: snapshot,
    );
  }

  Future<coach.CoachTurnResult?> skipQuestion(ChatMessage message) =>
      canAnswerQuestion(message)
      ? _send(
          message.question!.skipLabel,
          questionId: message.conversationMessageId,
          skipQuestion: true,
        )
      : Future.value();

  bool isActive(ChatMessage message) =>
      message.options.isNotEmpty &&
      message.chosen == null &&
      (!message.options.any((option) => option.value.startsWith('@safety:')) ||
          message.id == _safetyMessageId);

  Future<void> choose(ChatMessage message, int index) async {
    if (!isActive(message) ||
        index < 0 ||
        index >= message.options.length ||
        _typing ||
        _closed) {
      return;
    }
    final option = message.options[index];
    final link =
        option.isCommand &&
        !option.value.startsWith('@save:') &&
        !option.value.startsWith('@saved:') &&
        !option.value.startsWith('@safety');
    if (!link) _replace(message.copyWith(chosen: index));
    if (option.value.startsWith('@safety:')) {
      await _safetyAnswer(option);
      return;
    }
    if (option.value.startsWith('@save:')) {
      final plan = _messages.reversed
          .where((row) => row.plan?.id == option.value.substring(6))
          .firstOrNull
          ?.plan;
      _addUser(option.label);
      if (plan != null) {
        final saved = await save(plan);
        _addBot('存好了，叫「${saved.name}」。下次说「上次那个」或者从左下角的计划里一键开始。');
      }
      _notify();
      _persistInBackground();
      return;
    }
    if (option.value.startsWith('@saved:')) {
      final saved = await bindings.plans.read(option.value.substring(7));
      if (saved != null) {
        await sendPlanToConversation(saved);
      } else {
        _addBot(profile.strings.noSavedPlan);
        _notify();
      }
      return;
    }
    final command = option.isCommand
        ? CoachChatCommand.fromLegacy(option.value)
        : null;
    if (command != null) {
      await dispatch(command);
    } else {
      await send(option.value, label: option.label);
    }
  }

  void command(String value) {
    final command = CoachChatCommand.fromLegacy(value);
    if (command != null) unawaited(dispatch(command));
  }

  Future<CoachChatOperationResult> dispatch(CoachChatCommand command) async {
    await start();
    if (_closed) return const CoachChatOperationResult(ok: false);
    switch (command.kind) {
      case CoachChatCommandKind.newConversation:
        return newConversation();
      case CoachChatCommandKind.recheckSafety:
        await startSafetyCheck();
      case CoachChatCommandKind.showHistory:
        _trainingContext = await bindings.history.readTrainingContext();
        final last = _trainingContext.history.firstOrNull;
        _addBot(
          last == null
              ? profile.strings.noHistory
              : '上次训练「${last.title}」，完成 ${last.completed}/${last.total} 个动作。',
          options:
              last != null &&
                  _trainingContext.lastPlan != null &&
                  _preferences.trainingAllowed
              ? const [ChatOption('再来一次', '@last')]
              : const [],
        );
      case CoachChatCommandKind.showLastPlan:
        final plan = _trainingContext.lastPlan;
        if (!_preferences.trainingAllowed) {
          _blocked();
        } else if (plan == null) {
          _addBot(profile.strings.noLastPlan);
        } else {
          final admitted = _admitDisplay(plan, requestForPlan(plan));
          if (admitted == null) {
            return _problem(
              'plan_unavailable',
              profile.strings.focusUnavailable,
            );
          }
          _addUser('上次那个');
          _addBot('这是你上次的「${plan.title}」。', plan: plan, admitted: admitted);
          _currentPlan = plan;
        }
      case CoachChatCommandKind.appearance:
        if (!{'light', 'dark', 'system'}.contains(command.value)) {
          return _problem('invalid_setting', '无效外观');
        }
        await _updatePreferences(
          _preferences.copyWith(appearance: command.value),
        );
      case CoachChatCommandKind.voice:
        final value = command.value;
        if (value == 'mute') {
          await _updatePreferences(
            _preferences.copyWith(voice: false, chimes: false),
          );
        } else if (value == 'on' || value == 'off') {
          await _updatePreferences(_preferences.copyWith(voice: value == 'on'));
        }
      case CoachChatCommandKind.chimes:
        if (command.value == 'on' || command.value == 'off') {
          await _updatePreferences(
            _preferences.copyWith(chimes: command.value == 'on'),
          );
        }
      case CoachChatCommandKind.openLibrary ||
          CoachChatCommandKind.openSavedPlans ||
          CoachChatCommandKind.openCustomPlan ||
          CoachChatCommandKind.openSettings:
        _actions.add(command);
    }
    _notify();
    _persistInBackground();
    return const CoachChatOperationResult(ok: true);
  }

  Future<void> openHostPage(
    BuildContext context,
    CoachChatCommand command,
  ) async {
    final actions = bindings.actions;
    switch (command.kind) {
      case CoachChatCommandKind.openLibrary:
        await actions.onOpenLibrary(
          context,
          CoachChatLibraryOpenRequest(initialCategoryId: command.value),
        );
      case CoachChatCommandKind.openSavedPlans:
        await actions.onOpenSavedPlans(context);
      case CoachChatCommandKind.openCustomPlan:
        await actions.onOpenCustomPlan(context);
      case CoachChatCommandKind.openSettings:
        await actions.onOpenSettings(context);
      default:
        await dispatch(command);
    }
  }

  Future<void> openAction(
    BuildContext context,
    String actionId, {
    String? messageId,
  }) async {
    await start();
    if (!context.mounted ||
        _closed ||
        agent.actionScope?.contains(actionId) != true) {
      return;
    }
    await bindings.actions.onOpenAction(
      context,
      CoachChatActionOpenRequest(actionId: actionId, messageId: messageId),
    );
  }

  Future<void> clearPlanFocus() async {
    if (_closed || _conversation == null) return;
    if (_typing) cancelRequest();
    conversation.clearPlanFocus();
    _notify();
    await _persist();
  }

  bool isSaved(coach.TrainingPlan plan) =>
      _saved.any((saved) => _samePlan(saved.plan, plan));

  CoachSavedPlanSnapshot? savedTargetFor(ChatMessage message) {
    final id = message.planSavedRef?.externalId;
    return id == null
        ? null
        : _saved.where((saved) => saved.externalId == id).firstOrNull ??
              _savedOrigins[id];
  }

  bool isPlanCardSaved(ChatMessage message) {
    final plan = message.plan;
    if (plan == null) return false;
    if (message.isSavedPlanDisplay) return isSaved(plan);
    final id = message.savedExternalId ?? message.planSavedRef?.externalId;
    return _saved.any(
      (saved) =>
          (id == null || saved.externalId == id) &&
          saved.sdkVersion == message.planVersion &&
          _samePlan(saved.plan, plan),
    );
  }

  Future<CoachSavedPlanSnapshot> savePlanCard(
    ChatMessage message, {
    bool saveAsCopy = false,
  }) {
    final id = message.id;
    if (_saving[id] case final pending?) return pending;
    final operation = _savePlanCard(message, saveAsCopy: saveAsCopy);
    _saving[id] = operation;
    _notify();
    return operation.whenComplete(() {
      _saving.remove(id);
      _notify();
    });
  }

  Future<CoachSavedPlanSnapshot> _savePlanCard(
    ChatMessage message, {
    required bool saveAsCopy,
  }) async {
    await start();
    if (_closed || message.plan == null) throw StateError('No plan to save');
    final plan = message.plan!;
    final admitted = agent.prepareTraining(
      plan,
      context: message.request ?? requestForPlan(plan),
    );
    if (admitted == null) {
      throw const CoachPlanStorageException(
        CoachPlanWriteResult.failure(
          CoachPlanWriteStatus.failed,
          error: 'plan_not_admitted',
        ),
      );
    }
    final externalId =
        message.savedExternalId ?? message.planSavedRef?.externalId;
    final target = externalId == null
        ? null
        : _saved.where((saved) => saved.externalId == externalId).firstOrNull ??
              _savedOrigins[externalId];
    if (!saveAsCopy && isPlanCardSaved(message) && target != null) {
      return target;
    }
    final mode = saveAsCopy
        ? CoachPlanWriteMode.copy
        : externalId == null
        ? CoachPlanWriteMode.create
        : CoachPlanWriteMode.update;
    Object? expected = message.storageRevision;
    if (mode == CoachPlanWriteMode.update && expected == null) {
      // A pre-revision legacy card is readable, but cannot silently update.
      throw const CoachPlanStorageException(
        CoachPlanWriteResult.failure(
          CoachPlanWriteStatus.conflict,
          error: 'refresh_storage_revision',
        ),
      );
    }
    final savingGeneration = _generation;
    final result = await bindings.plans.save(
      CoachPlanWriteRequest(
        admittedPlan: admitted,
        mode: mode,
        name: target?.title ?? plan.title,
        sdkVersion: message.planVersion,
        savedRef: message.planSavedRef,
        externalId: mode == CoachPlanWriteMode.update ? externalId : null,
        expectedStorageRevision: mode == CoachPlanWriteMode.update
            ? expected
            : null,
      ),
    );
    if (!result.ok) {
      if (!_closed && savingGeneration == _generation) {
        _lastError = result;
        _notify();
      }
      throw CoachPlanStorageException(result);
    }
    final saved = result.saved!;
    // The host write has succeeded. A departed conversation must not publish
    // its old card or queue a new snapshot into the replacement conversation.
    bindings.actions.onSaved?.call(saved);
    if (_closed || savingGeneration != _generation) return saved;
    _saved = [
      saved,
      ..._saved.where((value) => value.externalId != saved.externalId),
    ];
    _replace(
      message.copyWith(
        savedExternalId: saved.externalId,
        storageRevision: saved.storageRevision,
      ),
    );
    if (message.planSavedRef != null) _savedOrigins[saved.externalId] = saved;
    _notify();
    await _persist();
    return saved;
  }

  Future<CoachSavedPlanSnapshot> save(coach.TrainingPlan plan) {
    final card = _messages.reversed
        .where(
          (message) => message.plan != null && _samePlan(message.plan!, plan),
        )
        .firstOrNull;
    return savePlanCard(
      card ??
          ChatMessage(
            id: _id(),
            role: ChatRole.assistant,
            at: _clock(),
            plan: plan,
            request: requestForPlan(plan),
          ),
    );
  }

  CoachChatPlanDetailsPreparation prepareSavedPlanDetails(
    CoachSavedPlanSelection selection,
  ) {
    final admitted = _admitDisplay(
      selection.plan,
      requestForPlan(selection.plan),
    );
    if (admitted != null) {
      return CoachChatPlanDetailsPreparation(
        reference: CoachChatPlanReference(
          admittedPlan: admitted,
          savedSelection: selection,
        ),
      );
    }
    final preview = _scopePreview(selection);
    return CoachChatPlanDetailsPreparation(
      scopePreview: preview,
      issues: [const coach.PlanIssue('plan_not_admitted', '计划不符合当前动作范围或训练条件。')],
    );
  }

  Future<CoachChatFocusResult> sendPlanToConversation(
    CoachSavedPlanSelection selection,
  ) async {
    await start();
    if (_closed || _typing) {
      return _focusFailure(_closed ? 'disposed' : 'busy', '请在当前请求结束后选择计划。');
    }
    final prepared = prepareSavedPlanDetails(selection);
    if (!prepared.ok) {
      return CoachChatFocusResult(
        core: coach.CoachPlanFocusResult.failure(prepared.issues),
        persisted: false,
        scopePreview: prepared.scopePreview,
      );
    }
    final result = conversation.focusExternalPlan(
      externalId: selection.externalId,
      plan: selection.plan,
      title: selection.title,
    );
    if (!result.ok) return CoachChatFocusResult(core: result, persisted: false);
    _savedOrigins[selection.externalId] = selection;
    _addUser(selection.title);
    _messages.add(
      ChatMessage(
        id: _id(),
        role: ChatRole.assistant,
        at: _clock(),
        text: '「${selection.title}」来了。',
        plan: selection.plan,
        validatedPlan: prepared.reference!.admittedPlan,
        sdkVersion: selection.sdkVersion,
        savedExternalId: selection.externalId,
        storageRevision: selection.storageRevision,
        isSavedPlanDisplay: true,
        request: requestForPlan(selection.plan),
      ),
    );
    _currentPlan = selection.plan;
    _suggestions = _defaults();
    _notify();
    try {
      await _persist();
      return CoachChatFocusResult(core: result, persisted: true);
    } on Object catch (error) {
      return CoachChatFocusResult(
        core: result,
        persisted: false,
        persistenceError: error,
      );
    }
  }

  Future<CoachChatFocusResult> showSaved(CoachSavedPlanSelection selection) =>
      sendPlanToConversation(selection);

  Future<bool> started(coach.TrainingPlan plan) async {
    if (_closed || !_preferences.trainingAllowed || _conversation == null) {
      return false;
    }
    final admitted = agent.prepareTraining(plan, context: requestForPlan(plan));
    if (admitted == null) return false;
    final card = _messages.reversed
        .where(
          (message) => message.plan != null && _samePlan(message.plan!, plan),
        )
        .firstOrNull;
    await bindings.history.rememberStartedPlan(
      plan,
      savedExternalId: card?.savedExternalId ?? card?.planSavedRef?.externalId,
    );
    if (_closed || !_preferences.trainingAllowed) return false;
    _trainingContext = CoachChatHistoryContext(
      lastPlan: plan,
      history: _trainingContext.history,
    );
    _currentPlan = plan;
    if (card == null) _addBot('', plan: plan, admitted: admitted);
    _notify();
    await _persist();
    return !_closed && _preferences.trainingAllowed;
  }

  Future<SessionResult?> startTraining(
    BuildContext context,
    ChatMessage message, {
    String sourceEntry = 'chat',
    VoidCallback? beforeStarting,
    Future<bool> Function()? afterStarting,
  }) async {
    await start();
    if (!context.mounted ||
        _closed ||
        _openingTraining ||
        !_preferences.trainingAllowed ||
        message.plan == null) {
      return null;
    }
    final admitted = agent.prepareTraining(
      message.plan!,
      context: message.request ?? requestForPlan(message.plan!),
    );
    if (admitted == null) return null;
    _openingTraining = true;
    Future<bool>? starting;
    Future<bool> startOnce() async {
      beforeStarting?.call();
      if (!await started(admitted.plan)) return false;
      return afterStarting == null || await afterStarting();
    }

    final request = CoachChatTrainingRequest(
      plan: admitted,
      sourceEntry: sourceEntry,
      messageId: message.id,
      onStarting: () => starting ??= startOnce(),
      holdTransition: transitionActivity.hold,
    );
    try {
      final result = await bindings.actions.onStartTraining(context, request);
      if (!_closed && result != null) completeTraining(admitted.plan, result);
      return result;
    } finally {
      _openingTraining = false;
    }
  }

  /// Adds the host's already-saved receipt once. It never saves a result again.
  void completeTraining(coach.TrainingPlan plan, SessionResult receipt) {
    if (_closed || !_receipts.add(receipt.sessionId)) return;
    finished(
      plan,
      completed: receipt.completedExercises,
      total: receipt.totalExercises,
      receiptSessionId: receipt.sessionId,
    );
  }

  void finished(
    coach.TrainingPlan plan, {
    required int completed,
    required int total,
    String? receiptSessionId,
  }) {
    if (_closed || total <= 0) return;
    final text = completed >= total
        ? '练完「${plan.title}」了，辛苦！记得喝点水。'
        : completed == 0
        ? '这次先到这儿。想换个更轻松的，跟我说「简单点」。'
        : '完成了 $completed/$total 个动作，已经不错了。';
    final offer = completed > 0 && !isSaved(plan);
    _addBot(
      offer ? '$text\n要把这套存下来，下次直接用吗？' : text,
      options: offer ? [ChatOption('保存这套', '@save:${plan.id}')] : const [],
      receiptSessionId: receiptSessionId,
    );
    _suggestions = _defaults();
    _notify();
    _persistInBackground();
  }

  Future<void> startSafetyCheck() async {
    await start();
    if (_closed) return;
    _beginSafety(firstRun: false);
    _notify();
    await _updatePreferences(_preferences.copyWith(safetyChecking: true));
    await _persist();
  }

  void _beginSafety({required bool firstRun}) {
    _conversation?.invalidateQuestion();
    _generation++;
    _cancel?.cancel();
    _conversation?.cancel();
    _typing = false;
    _endProgress();
    _preferences = _preferences.copyWith(safetyChecking: true);
    if (firstRun) {
      _messages.clear();
      _addBot(profile.strings.safetyIntro);
    } else {
      _addBot(profile.strings.recheckSafety);
    }
    _safetyMessageId = _addBot(
      profile.strings.safetyDisclaimer,
      options: const [ChatOption('我已了解', '@safety:ack')],
    ).id;
    _safetyStep = -1;
    _suggestions = const [];
  }

  Future<void> _safetyAnswer(ChatOption option) async {
    final step = _safetyStep;
    if (step == null) return;
    _addUser(option.label);
    if (option.value == '@safety:ack') {
      _addBot(profile.strings.safetyLead);
      _askSafety(0);
    } else if (option.value == '@safety:no' &&
        step + 1 < profile.strings.safetyQuestions.length) {
      _askSafety(step + 1);
    } else {
      final blocked = option.value != '@safety:no';
      _safetyStep = null;
      _safetyMessageId = null;
      await _updatePreferences(
        _preferences.copyWith(
          safetyAccepted: true,
          safetyBlocked: blocked,
          safetyChecking: false,
        ),
      );
      _addBot(
        blocked
            ? profile.strings.safetyBlockedText(step)
            : profile.strings.safetyAllClear,
        options: blocked ? const [ChatOption('浏览动作库', '@library')] : const [],
      );
      _suggestions = blocked ? const ['浏览动作库'] : _defaults();
    }
    _notify();
    await _persist();
  }

  void _askSafety(int index) {
    _safetyStep = index;
    _safetyMessageId = _addBot(
      profile.strings.safetyQuestionText(index),
      options: const [
        ChatOption('否', '@safety:no'),
        ChatOption('是', '@safety:yes'),
      ],
    ).id;
  }

  Future<void> _updatePreferences(CoachChatPreferences value) async {
    await bindings.preferences.update(value);
    if (_closed) return;
    _preferences = value;
    _agent?.enableUserMemory = value.enableUserMemory;
    _notify();
  }

  void _blocked() => _addBot(
    profile.strings.safetyBlocked,
    options: const [
      ChatOption('动作库', '@library'),
      ChatOption('重新确认', '@safety'),
    ],
  );

  List<String> _defaults() =>
      profile.strings.suggestions(blocked: _preferences.safetyBlocked);

  coach.ValidatedPlan? _admitDisplay(
    coach.TrainingPlan plan,
    coach.CoachContext? request,
  ) => _agent
      ?.gateFor(catalog)
      .admitTemplate(plan, request ?? requestForPlan(plan));

  coach.ValidatedActions? _restoreActions(List<String> ids) =>
      _agent?.restoreRecommendation(
        coach.CoachRecommendationSnapshot(
          messageId: 'history',
          actionIds: ids,
          note: '',
        ),
      );

  ChatMessage _displayMessage(coach.CoachConversationMessage sdk) {
    final ref = sdk.plan?.savedRef;
    final origin = ref == null ? null : _savedOrigins[ref.externalId];
    return ChatMessage(
      id: sdk.id,
      conversationMessageId: sdk.id,
      at: sdk.at,
      role: sdk.isUser ? ChatRole.user : ChatRole.assistant,
      text: sdk.text,
      question: sdk.question,
      questionAnswered: sdk.questionAnswered,
      answeredChoices: sdk.answeredChoices,
      answeredForm: sdk.answeredForm,
      isPlanningFailure: sdk.isFailure || sdk.isPlanningFailure,
      plan: sdk.plan?.plan,
      validatedPlan: sdk.plan,
      sdkVersion: sdk.plan?.version,
      savedRef: ref,
      savedExternalId: ref?.externalId,
      storageRevision: origin?.storageRevision,
      coachTask: _latestTask,
      actions: sdk.actions,
      request: sdk.plan == null ? null : requestForPlan(sdk.plan!.plan),
      aiVisible: true,
    );
  }

  coach.CoachConversationMessage _sdkDisplay(ChatMessage message) =>
      coach.CoachConversationMessage(
        id: message.conversationMessageId ?? message.id,
        at: message.at,
        isUser: message.isUser,
        text: message.text,
        question: message.question,
        questionAnswered: message.questionAnswered,
        answeredChoices: message.answeredChoices,
        answeredForm: message.answeredForm,
        isFailure: message.isPlanningFailure,
        isPlanningFailure: message.isPlanningFailure,
        plan: message.validatedPlan,
        planState: message.plan == null
            ? null
            : coach.CoachPlanState(
                planId: message.plan!.id,
                context: message.request ?? requestForPlan(message.plan!),
              ),
        actions: message.actions,
      );

  void _syncQuestions({bool appendMissing = false}) {
    final conversation = _conversation;
    if (conversation == null) return;
    final snapshots = {
      for (final sdk in conversation.state.messages) sdk.id: sdk,
    };
    final existing = <String>{};
    for (var index = 0; index < _messages.length; index++) {
      final message = _messages[index];
      final sdk =
          snapshots[message.conversationMessageId ??
              (message.aiVisible ? message.id : null)];
      if (sdk == null) continue;
      existing.add(sdk.id);
      _messages[index] = message.copyWith(
        text: sdk.isUser ? null : sdk.text,
        question: sdk.question,
        conversationMessageId: sdk.id,
        questionAnswered: sdk.questionAnswered,
        answeredChoices: sdk.answeredChoices,
        answeredForm: sdk.answeredForm,
        actions: sdk.actions,
        clearActions: sdk.actions == null,
      );
    }
    if (appendMissing) {
      for (final sdk in conversation.state.messages) {
        if (!sdk.isUser && !existing.contains(sdk.id)) {
          _messages.add(_displayMessage(sdk));
        }
      }
    }
  }

  ChatMessage _addUser(String text) => _add(
    ChatMessage(id: _id(), role: ChatRole.user, at: _clock(), text: text),
  );

  ChatMessage _addBot(
    String text, {
    List<ChatOption> options = const [],
    coach.TrainingPlan? plan,
    coach.ValidatedPlan? admitted,
    bool greeting = false,
    bool aiVisible = false,
    bool isPlanningFailure = false,
    String? receiptSessionId,
  }) => _add(
    ChatMessage(
      id: _id(),
      role: ChatRole.assistant,
      at: _clock(),
      text: text,
      options: options,
      plan: plan,
      validatedPlan: admitted,
      request: plan == null ? null : requestForPlan(plan),
      greeting: greeting,
      aiVisible: aiVisible,
      isPlanningFailure: isPlanningFailure,
      receiptSessionId: receiptSessionId,
    ),
  );

  ChatMessage _add(ChatMessage value) {
    _messages.add(value);
    return value;
  }

  void _replace(ChatMessage message) {
    final index = _messages.indexWhere((value) => value.id == message.id);
    if (index >= 0) _messages[index] = message;
  }

  String _id() => 'm${_clock().microsecondsSinceEpoch}-${_seq++}';
  void _notify() {
    if (!_closed && !_notifierDisposed) notifyListeners();
  }

  void _recordError(String event, Object error) {
    _lastError = error;
    bindings.observer?.call(event, error);
  }

  CoachChatOperationResult _problem(String code, String message) =>
      CoachChatOperationResult(
        ok: false,
        issues: [coach.PlanIssue(code, message)],
      );
  CoachChatFocusResult _focusFailure(String code, String message) =>
      CoachChatFocusResult(
        core: coach.CoachPlanFocusResult.failure([
          coach.PlanIssue(code, message),
        ]),
        persisted: false,
      );

  bool _samePlan(coach.TrainingPlan a, coach.TrainingPlan b) =>
      jsonEncode(_comparison(a)) == jsonEncode(_comparison(b));
  Map<String, Object?> _comparison(coach.TrainingPlan plan) => {
    ...plan.toJson(),
    'equipment': plan.equipment.toSet().toList()..sort(),
    if (plan.avoid.isNotEmpty) 'avoid': plan.avoid.toList()..sort(),
  };

  CoachChatSnapshot exportSnapshot() => CoachChatSnapshot(
    appId: profile.appId,
    storageNamespace: bindings.storageNamespace,
    session: conversation.exportSession(),
    messages: [for (final message in _messages) message.toJson()],
  );

  Future<CoachChatRestoreResult> restoreSnapshot(
    CoachChatSnapshot snapshot,
  ) async {
    await start();
    if (_closed) return const CoachChatRestoreResult(ok: false);
    final restored = _restoreSnapshot(snapshot);
    if (restored.ok) {
      _notify();
      await _persist();
    }
    return restored;
  }

  CoachChatRestoreResult _restoreSnapshot(CoachChatSnapshot snapshot) {
    try {
      if (snapshot.envelopeSchemaVersion != 1 ||
          snapshot.appId != profile.appId ||
          snapshot.storageNamespace != bindings.storageNamespace ||
          !agent.canRestoreSessionSnapshot(snapshot.session)) {
        return const CoachChatRestoreResult(
          ok: false,
          issues: [
            coach.PlanIssue('snapshot_not_admitted', '会话快照与当前存储或动作范围不符。'),
          ],
        );
      }
      final display = [
        for (final row in snapshot.messages)
          ChatMessage.fromJson(
            row,
            admitPlan: _admitDisplay,
            restoreActions: _restoreActions,
          ),
      ];
      _restoreDisplay(snapshot.session, display);
      return const CoachChatRestoreResult(ok: true);
    } on Object catch (error) {
      _recordError('chat.restore.error', error);
      return CoachChatRestoreResult(ok: false, error: error);
    }
  }

  void _restoreDisplay(
    coach.CoachSessionSnapshot? snapshot,
    List<ChatMessage> display, {
    List<ChatMessage>? sdkDisplay,
  }) {
    _generation++;
    _cancel?.cancel();
    _typing = false;
    _endProgress();
    _restoring = true;
    try {
      final sdk =
          (sdkDisplay ?? display.where((message) => message.aiVisible).toList())
              .map(_sdkDisplay)
              .toList();
      if (snapshot == null) {
        conversation.restoreHistory(sdk);
      } else {
        conversation.restoreSession(snapshot, sdk);
      }
      _messages
        ..clear()
        ..addAll(display);
      _receipts
        ..clear()
        ..addAll(
          display
              .map((message) => message.receiptSessionId)
              .whereType<String>(),
        );
      _currentPlan = _messages
          .where((message) => message.plan != null)
          .lastOrNull
          ?.plan;
      _savedOrigins.clear();
      for (final message in _messages) {
        final id = message.savedExternalId ?? message.planSavedRef?.externalId;
        if (id != null &&
            message.storageRevision != null &&
            message.plan != null) {
          _savedOrigins[id] = CoachSavedPlanSnapshot(
            externalId: id,
            title: message.plan!.title,
            plan: message.plan!,
            storageRevision: message.storageRevision!,
            sdkVersion: message.planVersion,
          );
        }
      }
      _syncQuestions(appendMissing: true);
      _suggestions = conversation.state.pendingQuestion == null
          ? _defaults()
          : const [];
    } finally {
      _restoring = false;
    }
  }

  Future<CoachChatRestoreResult> importLegacy(
    CoachChatLegacyData legacy,
  ) async {
    try {
      final display = [
        for (final row in legacy.chat)
          ChatMessage.fromJson(
            row,
            admitPlan: _admitDisplay,
            restoreActions: _restoreActions,
          ),
      ];
      final sdk = [
        for (final row in legacy.coachDisplay)
          ChatMessage.fromJson(
            row,
            admitPlan: _admitDisplay,
            restoreActions: _restoreActions,
          ),
      ];
      final snapshot = legacy.session;
      if (snapshot != null && !agent.canRestoreSessionSnapshot(snapshot)) {
        return const CoachChatRestoreResult(
          ok: false,
          issues: [coach.PlanIssue('snapshot_not_admitted', '旧会话中的计划不符合当前范围。')],
        );
      }
      _restoreDisplay(snapshot, display, sdkDisplay: sdk.isEmpty ? null : sdk);
      await _persist();
      return const CoachChatRestoreResult(ok: true);
    } on Object catch (error) {
      _recordError('chat.legacy_restore.error', error);
      return CoachChatRestoreResult(ok: false, error: error);
    }
  }

  void _schedulePersistence() {
    if (!_started || _restoring || _closed) return;
    _persistenceTimer?.cancel();
    _persistenceTimer = Timer(
      const Duration(milliseconds: 80),
      _persistInBackground,
    );
  }

  void _persistInBackground() {
    if (_closed || !_started) return;
    unawaited(
      _persist().catchError((Object error) {
        _recordError('chat.persist.error', error);
        _notify();
      }),
    );
  }

  Future<void> flushPersistence() =>
      _started && !_closed ? _persist() : Future.value();
  Future<void> _persist() {
    _persistenceTimer?.cancel();
    return _writeSnapshot(exportSnapshot());
  }

  Future<void> _writeSnapshot(CoachChatSnapshot snapshot) {
    final write = _persistenceTail.then(
      (_) => bindings.history.write(bindings.storageNamespace, snapshot),
    );
    _persistenceTail = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return write;
  }

  /// Flushes the captured display/session before disposing core and releasing
  /// the concrete gateway lease, including when a persistence write fails.
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    final snapshot = _started && _conversation != null
        ? exportSnapshot()
        : null;
    _closed = true;
    _generation++;
    _cancel?.cancel();
    _persistenceTimer?.cancel();
    _typing = false;
    _endProgress();
    _conversation?.removeListener(_onConversationChanged);
    try {
      if (_starting case final starting?) await starting;
      if (snapshot != null) await _writeSnapshot(snapshot);
      await _persistenceTail;
    } finally {
      try {
        await _progressSubscription?.cancel();
        await _plansSubscription?.cancel();
        await _preferencesSubscription?.cancel();
        await _conversation?.dispose();
      } finally {
        await _releaseClient();
        await _progress.close();
        await _actions.close();
        transitionActivity.dispose();
      }
    }
  }

  Future<void> _releaseClient() async {
    if (_leaseReleased || _lease == null) return;
    _leaseReleased = true;
    await _lease!.release?.call();
  }

  @override
  void dispose() {
    if (_notifierDisposed) return;
    _notifierDisposed = true;
    unawaited(
      close().catchError((Object error) {
        bindings.observer?.call('chat.close.error', error);
      }),
    );
    super.dispose();
  }

  CoachChatScopePreview? _scopePreview(CoachSavedPlanSelection selection) {
    final scope = _agent?.actionScope;
    if (scope == null) return null;
    final outside = scope
        .validatePlan(selection.plan)
        .map((issue) => issue.exerciseId)
        .whereType<String>()
        .toSet();
    if (outside.isEmpty) return null;
    final decisions = [
      for (final id in outside)
        scope.evaluateRequest(
          coach.CoachScopeRequest(
            originalText: '已保存计划「${selection.title}」中的动作',
            sourceActionId: id,
            hasInScopeContent: selection.plan.exerciseIds.any(scope.contains),
            scene: selection.plan.scene,
            equipment: selection.plan.equipment.toSet(),
            avoid: selection.plan.avoid,
          ),
          profile.conversationPolicy,
        ),
    ];
    final preview = CoachChatScopePreview(
      id: 'preview-${_seq++}',
      selection: selection,
      decisions: decisions,
    );
    _previews[preview.id] = preview;
    return preview;
  }

  Future<CoachChatOperationResult> regenerateFromScopePreview(
    String previewId,
  ) async {
    final preview = _previews[previewId];
    if (preview == null) return _problem('preview_missing', '请重新选择计划。');
    final current = await bindings.plans.read(preview.selection.externalId);
    if (current == null) {
      return _problem('saved_plan_deleted', profile.strings.noSavedPlan);
    }
    if (jsonEncode(current.storageRevision) !=
        jsonEncode(preview.selection.storageRevision)) {
      _scopePreview(current);
      return _problem('storage_conflict', profile.strings.saveConflict);
    }
    await clearPlanFocus();
    final plan = preview.selection.plan;
    final result = await send(
      '请重新生成一套${plan.targetMinutes}分钟的${plan.goal}计划，'
      '场景${plan.scene}，器械${plan.equipment.join('、')}。'
      '只采用本App范围内动作：${preview.explanation}',
    );
    return CoachChatOperationResult(ok: result?.plan != null);
  }

  Future<CoachChatFocusResult> adoptAndSaveScopePreview(
    String previewId,
  ) async {
    final preview = _previews[previewId];
    if (preview == null) return _focusFailure('preview_missing', '请重新选择计划。');
    final current = await bindings.plans.read(preview.selection.externalId);
    if (current == null) {
      return _focusFailure('saved_plan_deleted', profile.strings.noSavedPlan);
    }
    if (jsonEncode(current.storageRevision) !=
        jsonEncode(preview.selection.storageRevision)) {
      return CoachChatFocusResult(
        core: coach.CoachPlanFocusResult.failure([
          coach.PlanIssue('storage_conflict', profile.strings.saveConflict),
        ]),
        persisted: false,
        scopePreview: _scopePreview(current),
      );
    }
    final replacements = {
      for (final record in preview.decisions) record.sourceId: record,
    };
    final raw = preview.selection.plan.toJson();
    final blocks = <Map<String, Object?>>[];
    for (final block in preview.selection.plan.blocks) {
      final items = <Map<String, Object?>>[];
      for (final item in block.items) {
        final decision = replacements[item.exerciseId];
        if (decision != null && decision.adoptedActionId == null) continue;
        // Composite replacements need a new draft; no segment is silently cut.
        if (item.segments.any(
          (segment) => replacements.containsKey(segment.exerciseId),
        )) {
          return _focusFailure('needs_generation', '这套计划需要按范围内方案重新生成。');
        }
        items.add({
          ...item.toJson(),
          if (decision?.adoptedActionId != null)
            'exerciseId': decision!.adoptedActionId,
        });
      }
      if (items.isNotEmpty) blocks.add({...block.toJson(), 'items': items});
    }
    final decoded = const coach.PlanCodec().decodeStrict({
      ...raw,
      'blocks': blocks,
    });
    final admitted = decoded.ok
        ? agent.prepareTraining(
            decoded.plan!,
            context: requestForPlan(decoded.plan!),
          )
        : null;
    if (admitted == null) {
      return _focusFailure('needs_generation', '候选还不能通过训练门禁，请按范围内方案重新生成。');
    }
    final result = await bindings.plans.save(
      CoachPlanWriteRequest(
        admittedPlan: admitted,
        mode: CoachPlanWriteMode.copy,
        name: '${preview.selection.title} 新版',
      ),
    );
    if (!result.ok) return _focusFailure('save_failed', '新计划保存失败，请重试。');
    _saved = [result.saved!, ..._saved];
    bindings.actions.onSaved?.call(result.saved!);
    return sendPlanToConversation(result.saved!);
  }
}

/// Cancellation wins even if a custom host transport ignores its token.
class _CancellableClient implements coach.LlmClient {
  const _CancellableClient(this.inner);
  final coach.LlmClient inner;
  @override
  String get model => inner.model;
  @override
  coach.Pricing? get pricing => inner.pricing;
  @override
  Future<coach.LlmResponse> complete(
    coach.LlmRequest request, {
    coach.CancelToken? cancel,
  }) => Future.any([
    inner.complete(request, cancel: cancel),
    if (cancel != null)
      cancel.whenCancelled.then<coach.LlmResponse>(
        (_) => throw const coach.LlmException(
          coach.LlmErrorKind.cancelled,
          'cancelled',
        ),
      ),
  ]);
}

typedef ChatController = CoachChatController;
