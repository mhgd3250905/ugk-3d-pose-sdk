import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_coach_ui/ugk_coach_ui.dart';

import '../core/chat_bindings.dart';
import '../core/chat_controller.dart';
import '../core/chat_models.dart';
import '../theme/chat_surface.dart';
import '../theme/chat_theme.dart';
import '../theme/chat_tokens.dart';
import 'chat_widgets.dart';
import 'chat_composer_dock.dart';
import 'coach_ui_adapter.dart';
import 'coach_chat_plan_details_page.dart';
import 'cosmos.dart';
import 'plan_card.dart';
import 'plan_details_controls.dart';
import 'validated_plan_card.dart';
import 'chat_timeline.dart';
import 'training_card_media.dart';
import 'training_transition_freeze.dart';
import 'training_transition_activity.dart';

/// The home screen: one conversation floating in an endless sky. No app
/// bar, no borders; the input's left icon opens the feature panel.
class CoachChatPage extends StatelessWidget {
  const CoachChatPage({
    super.key,
    required this.controller,
    this.scrollController,
    this.clock,
    this.showBackButton,
    this.onBack,
    this.backLabel,
  });

  /// A long-lived controller owned by the host, shared by this page and My plans.
  final CoachChatController controller;

  /// Internal scripted comparisons share the production conversation viewport.
  /// A supplied controller remains owned by its caller.
  final ScrollController? scrollController;
  final DateTime Function()? clock;

  /// Top-left back button. Null (default) shows it when the page's route can
  /// be dismissed, as an [AppBar] would imply; false never; true always.
  final bool? showBackButton;

  /// Back action; default [Navigator.maybePop], which still closes the
  /// feature panel first.
  final VoidCallback? onBack;

  /// Back button tooltip and semantics; default the Material back tooltip.
  final String? backLabel;

  @override
  Widget build(BuildContext context) => CoachChatTheme(
    visual: controller.profile.visual,
    executionTiming: controller.profile.executionTiming,
    doseUnitLabels: {
      for (final entry in controller.profile.doseOverrides.entries)
        if (entry.value.unitLabel != null) entry.key: entry.value.unitLabel!,
    },
    child: TrainingTransitionScope(
      activity: controller.transitionActivity,
      child: _CoachChatBody(
        key: ObjectKey(controller),
        controller: controller,
        scrollController: scrollController,
        clock: clock,
        showBackButton: showBackButton,
        onBack: onBack,
        backLabel: backLabel,
      ),
    ),
  );
}

class _CoachChatBody extends StatefulWidget {
  const _CoachChatBody({
    super.key,
    required this.controller,
    this.scrollController,
    this.clock,
    this.showBackButton,
    this.onBack,
    this.backLabel,
  });
  final CoachChatController controller;
  final ScrollController? scrollController;
  final DateTime Function()? clock;
  final bool? showBackButton;
  final VoidCallback? onBack;
  final String? backLabel;

  @override
  State<_CoachChatBody> createState() => _CoachChatPageState();
}

class _CoachChatPageState extends State<_CoachChatBody>
    with WidgetsBindingObserver {
  late CoachChatController _chat;
  StreamSubscription<CoachChatCommand>? _actions;
  late final _scroll = widget.scrollController ?? ScrollController();

  /// Only the reverse list's viewport follows the dock. Its cached subtree
  /// keeps message state while the menu animates; the page is not rebuilt.
  final _dockExtent = ValueNotifier<double>(112);
  String? _pendingDeliveryId;
  String? _pendingUserId;
  DateTime? _pendingDeliveryAt;
  Set<String> _replyStartIds = {};
  final Map<String, String> _deliveryEntryIds = {};
  final Map<String, GlobalKey> _deliveryKeys = {};
  final _finishedEntries = <String>{};
  final _finishedSessions = <String>{};
  final _input = FocusNode();
  bool _panelOpen = false;
  bool _trainingInFlight = false;
  bool _hostPageOpen = false;
  bool _composeAfterHostReturn = false;

  /// Messages already on screen when the page opened don't animate in.
  final _seen = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _dismissInput() {
    _input.unfocus(disposition: UnfocusDisposition.scope);
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
  }

  void _togglePanel() {
    if (_panelOpen) {
      _closePanel();
      return;
    }
    setState(() => _panelOpen = true);
  }

  void _closePanel() {
    if (!_panelOpen) return;
    setState(() => _panelOpen = false);
  }

  void _inputTapped() {
    _closePanel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_chat.flushPersistence());
    }
    if ((state == AppLifecycleState.inactive ||
            state == AppLifecycleState.resumed) &&
        (ModalRoute.of(context)?.isCurrent ?? false)) {
      _dismissInput();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_actions != null) return;
    _chat = widget.controller;
    unawaited(_chat.start());
    _seen.addAll(_chat.messages.map((m) => m.id));
    _actions = _chat.actions.listen(_onAction);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _actions?.cancel();
    if (widget.scrollController == null) _scroll.dispose();
    _input.dispose();
    _dockExtent.dispose();
    super.dispose();
  }

  void _onAction(CoachChatCommand command) {
    if (!mounted) return;
    if (command.kind == CoachChatCommandKind.compose) {
      _closePanel();
      if (_hostPageOpen) {
        _composeAfterHostReturn = true;
      } else {
        _focusComposer();
      }
      return;
    }
    unawaited(_openHost(command));
  }

  void _focusComposer() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _input.requestFocus();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _openHost(CoachChatCommand command) async {
    _closePanel();
    _dismissInput();
    _hostPageOpen = true;
    try {
      await _chat.openHostPage(context, command);
    } finally {
      _hostPageOpen = false;
      if (mounted) {
        if (_composeAfterHostReturn) {
          _composeAfterHostReturn = false;
          _focusComposer();
        } else {
          _dismissInput();
        }
      }
    }
  }

  void _openPlans() => _chat.command('@drawer');

  /// The host uses the shared route and holds the source only during slides.
  Future<void> _start(
    ChatMessage message, {
    String sourceEntry = 'chat',
  }) async {
    if (_trainingInFlight) return;
    _trainingInFlight = true;
    try {
      final previous = _chat.messages.map((entry) => entry.id).toSet();
      final result = await _chat.startTraining(
        context,
        message,
        sourceEntry: sourceEntry,
        beforeStarting: _dismissInput,
      );
      if (!mounted) return;
      _dismissInput();
      if (result == null || !_finishedSessions.add(result.sessionId)) return;
      final added = _chat.messages.where(
        (entry) => !previous.contains(entry.id),
      );
      if (added.isEmpty) return;
      setState(() => _finishedEntries.addAll(added.map((entry) => entry.id)));
      // The receipt row starts at zero height, so existing rows stay put.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_scroll.hasClients) return;
      unawaited(
        _scroll.animateTo(
          _scroll.position.minScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        ),
      );
    } finally {
      _trainingInFlight = false;
    }
  }

  Future<void> _save(coach.TrainingPlan p) async {
    ChatHaptic.selection.play();
    try {
      final saved = await _chat.save(p);
      _toast(_chat.profile.strings.saveSuccess(saved.name));
    } on CoachPlanStorageException catch (failure) {
      _saveFailure(failure);
    }
  }

  Future<void> _savePlanCard(
    ChatMessage message, {
    bool saveAsCopy = false,
  }) async {
    ChatHaptic.selection.play();
    final updating = _chat.savedTargetFor(message) != null && !saveAsCopy;
    try {
      final saved = await _chat.savePlanCard(message, saveAsCopy: saveAsCopy);
      _toast(_chat.profile.strings.saveSuccess(saved.name, updating: updating));
    } on CoachPlanStorageException catch (failure) {
      _saveFailure(failure);
    }
  }

  void _saveFailure(CoachPlanStorageException failure) =>
      _toast(switch (failure.result.status) {
        CoachPlanWriteStatus.conflict => _chat.profile.strings.saveConflict,
        CoachPlanWriteStatus.deleted => _chat.profile.strings.noSavedPlan,
        _ => _chat.profile.strings.saveFailed,
      }, icon: ChatGlyph.info);

  Future<void> _details(
    ChatMessage message, {
    coach.TrainingPlan? validatedPlan,
  }) async {
    _dismissInput();
    await openCoachChatPlanDetails(
      context,
      _chat,
      message,
      planOverride: validatedPlan,
    );
    if (mounted) _dismissInput();
  }

  void _toast(String text, {ChatGlyph icon = ChatGlyph.checkCircle}) {
    if (!mounted) return;
    showChatSolidToast(
      context,
      text,
      icon: ChatIcon(
        icon,
        size: 18,
        color: ChatTheme.of(context).colors.accentText,
        filled: true,
      ),
    );
  }

  Future<void> _send(String text, {String? label}) async {
    if (_scroll.hasClients && _scroll.offset > 0) {
      unawaited(
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        ),
      );
    }
    await _chat.send(text, label: label);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ChatTheme.of(context).colors;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value:
          (colors.isDark
                  ? SystemUiOverlayStyle.light
                  : SystemUiOverlayStyle.dark)
              .copyWith(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: colors.isDark
                    ? Brightness.light
                    : Brightness.dark,
                statusBarBrightness: colors.isDark
                    ? Brightness.dark
                    : Brightness.light,
                systemStatusBarContrastEnforced: false,
                systemNavigationBarColor: colors.skyBottom,
                systemNavigationBarIconBrightness: colors.isDark
                    ? Brightness.light
                    : Brightness.dark,
              ),
      child: PopScope(
        canPop: !_panelOpen,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _panelOpen) _closePanel();
        },
        child: Scaffold(
          backgroundColor: ChatTheme.of(context).colors.skyBottom,
          resizeToAvoidBottomInset: false,
          body: TrainingTransitionFreeze(
            listenable: _chat,
            activity: _chat.transitionActivity,
            builder: (context) => CosmosBackground(
              showStars: _chat.profile.visual.showStars,
              animate:
                  _chat.profile.visual.animateBackground &&
                  _chat.preferences.starfield,
              child: TrainingTransitionFreeze(
                listenable: _chat,
                activity: _chat.transitionActivity,
                builder: (context) => Stack(
                  fit: StackFit.expand,
                  children: [
                    ValueListenableBuilder<double>(
                      valueListenable: _dockExtent,
                      child: RepaintBoundary(
                        key: const ValueKey('chat-messages-boundary'),
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: _closePanel,
                          child: _messages(),
                        ),
                      ),
                      builder: (context, extent, child) =>
                          Positioned.fill(bottom: extent, child: child!),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: RepaintBoundary(
                        key: const ValueKey('chat-composer-dock-boundary'),
                        child: ChatComposerDock(
                          panelOpen: _panelOpen,
                          activity: _chat.transitionActivity,
                          focusNode: _input,
                          extent: _dockExtent,
                          planFocusTitle: _chat.planFocus?.title,
                          onClearPlanFocus: () =>
                              unawaited(_chat.clearPlanFocus()),
                          suggestions: SuggestionStrip(
                            items: _chat.typing ? const [] : _chat.suggestions,
                            onTap: _send,
                            glyphFor: (text) =>
                                text ==
                                    _chat.profile.strings.discoverySuggestion
                                ? ChatGlyph.sparkle
                                : null,
                          ),
                          input: ChatInputBar(
                            focusNode: _input,
                            onSend: _send,
                            enabled: !_chat.typing,
                            onPlans: _togglePanel,
                            panelOpen: _panelOpen,
                            onTextTap: _inputTapped,
                            hint: _chat.profile.strings.inputHint,
                            sendLabel: _chat.profile.strings.sendLabel,
                            openPanelLabel:
                                _chat.profile.strings.openPanelLabel,
                            closePanelLabel:
                                _chat.profile.strings.closePanelLabel,
                          ),
                          panel: _featurePanel(),
                        ),
                      ),
                    ),
                    if (_showBack(context))
                      PositionedDirectional(
                        top: MediaQuery.paddingOf(context).top + 8,
                        start: 12,
                        child: ChatDetailsCircleButton(
                          key: const ValueKey('chat-back-button'),
                          icon: ChatGlyph.back,
                          tooltip:
                              widget.backLabel ??
                              Localizations.of<MaterialLocalizations>(
                                context,
                                MaterialLocalizations,
                              )?.backButtonTooltip ??
                              'Back',
                          onPressed:
                              widget.onBack ??
                              () => unawaited(Navigator.maybePop(context)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Room kept above the first row so it never starts under the back button.
  static const _backClearance = 52.0;

  bool _showBack(BuildContext context) =>
      widget.showBackButton ??
      (ModalRoute.of(context)?.impliesAppBarDismissal ?? false);

  ChatFeaturePanel _featurePanel() {
    final entries =
        <({String key, String label, ChatGlyph icon, VoidCallback tap})>[
          (
            key: 'panel-plans',
            label: _chat.profile.strings.myPlansLabel,
            icon: ChatGlyph.bookmark,
            tap: _openPlans,
          ),
          (
            key: 'chat-new-conversation',
            label: _chat.profile.strings.newConversationLabel,
            icon: ChatGlyph.sparkle,
            tap: () {
              _closePanel();
              unawaited(_chat.newConversation());
            },
          ),
          (
            key: 'panel-library',
            label: _chat.profile.strings.libraryLabel,
            icon: ChatGlyph.grid,
            tap: () => _chat.command('@library'),
          ),
          (
            key: 'panel-settings',
            label: _chat.profile.strings.settingsLabel,
            icon: ChatGlyph.sliders,
            tap: () => _chat.command('@settings'),
          ),
        ];
    return ChatFeaturePanel(
      key: const ValueKey('chat-feature-panel'),
      actions: [
        for (final entry in entries)
          ChatPanelAction(
            key: ValueKey(entry.key),
            label: entry.label,
            icon: entry.icon,
            onTap: entry.tap,
          ),
      ],
    );
  }

  Widget _messages() {
    final msgs = _chat.messages;
    final messageIds = msgs.map((m) => m.id).toSet();
    _deliveryEntryIds.removeWhere((id, _) => !messageIds.contains(id));
    if (_pendingDeliveryId != null && !messageIds.contains(_pendingUserId)) {
      _pendingDeliveryId = null;
      _pendingUserId = null;
      _replyStartIds = {};
    }
    if (_chat.typing && _pendingDeliveryId == null) {
      final user = msgs.where((m) => m.isUser).lastOrNull;
      _pendingUserId = user?.id;
      _pendingDeliveryId = 'coach-delivery-${user?.id ?? msgs.length}';
      _pendingDeliveryAt = user?.at ?? msgs.lastOrNull?.at ?? DateTime.now();
      _replyStartIds = msgs.map((m) => m.id).toSet();
    } else if (!_chat.typing && _pendingDeliveryId != null) {
      final replies = msgs.where(
        (m) => !m.isUser && !m.greeting && !_replyStartIds.contains(m.id),
      );
      final delivered =
          replies.where((m) => m.isPlan || m.actions != null).firstOrNull ??
          replies.firstOrNull;
      if (delivered != null) {
        _deliveryEntryIds[delivered.id] = _pendingDeliveryId!;
      }
      _pendingDeliveryId = null;
      _pendingUserId = null;
    }
    final liveDeliveries = {..._deliveryEntryIds.values, ?_pendingDeliveryId};
    _deliveryKeys.removeWhere((id, _) => !liveDeliveries.contains(id));
    GlobalKey deliveryKey(String id) =>
        _deliveryKeys.putIfAbsent(id, GlobalKey.new);
    final summary = coach.CoachTaskSummary.fromState(
      _chat.activeSessionState,
      task: _chat.activeTask,
    );
    final library = _chat.catalog;
    final picks = summary.picks.where(library.contains).toList(growable: false);
    final rows = [
      for (final m in msgs)
        CoachChatEntry(
          id: _deliveryEntryIds[m.id] ?? m.id,
          at: m.at,
          isUser: m.isUser,
          isCard: m.isPlan || m.actions != null,
          greeting: m.greeting,
          child: _deliveryEntryIds.containsKey(m.id)
              ? CoachDeliveryTransition(
                  key: deliveryKey(_deliveryEntryIds[m.id]!),
                  preparing: false,
                  successful:
                      !m.isPlanningFailure && (m.isPlan || m.actions != null),
                  interrupted: _chat.typing,
                  child: _message(m),
                )
              : m.greeting
              ? GreetingBlock(text: m.text)
              : _message(m, fresh: !_seen.contains(m.id)),
        ),
      if (_chat.typing)
        CoachChatEntry(
          id: _pendingDeliveryId!,
          at: _pendingDeliveryAt!,
          isUser: false,
          isCard: true,
          child: CoachDeliveryTransition(
            key: deliveryKey(_pendingDeliveryId!),
            preparing: true,
            child: CoachTaskBubble(
              title: summary.title,
              status: summary.status,
              phase: summary.phase,
              parameters: summary.parameters,
              picks: picks,
              complete: summary.complete,
              waiting: true,
              onCancel: _chat.cancelRequest,
              cutoutBuilder: chatTaskCutouts(context, library),
            ),
          ),
        ),
    ];
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _seen.addAll(msgs.map((m) => m.id)),
    );
    return withCoachChatUi(
      context,
      ChatTimeline(
        entries: rows,
        controller: _scroll,
        initiallySeen: _seen,
        finishedEntries: _finishedEntries,
        clock: widget.clock,
        // Keep the viewport behind Android's transparent status bar. The
        // initial safe clearance belongs to the scrollable content instead.
        topInset:
            MediaQuery.paddingOf(context).top +
            (_showBack(context) ? _backClearance : 0),
        timeMarkBuilder: (at, now) => TimeMark(at, now: now),
      ),
    );
  }

  Widget _message(ChatMessage m, {bool fresh = false}) {
    final library = _chat.catalog;
    final hasText =
        m.question != null || m.text.isNotEmpty || m.options.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (m.isPlanningFailure)
          CoachFailureBubble(
            key: ValueKey('coach-planning-failure-${m.id}'),
            message: m.text.isEmpty
                ? _chat.profile.strings.generationFailure
                : m.text,
            enabled: !_chat.typing,
            onRetry: () => _chat.send(_chat.profile.strings.retryRequest),
          ),
        if (m.question case final question?)
          CoachQuestionBubble(
            key: ValueKey('coach-question-${m.id}'),
            question: toCoachQuestionData(m),
            enabled: _chat.canAnswerQuestion(m),
            onTextAnswer: (answer) =>
                question.mode == coach.AskUserMode.form &&
                    answer == question.skipLabel
                ? _chat.skipQuestion(m)
                : _chat.answerQuestion(m, answer),
            onChoiceAnswer: (choices) => _chat.answerChoices(m, choices),
            onFormAnswer: (answers) => _chat.answerForm(m, answers),
            onSkip: () => _chat.skipQuestion(m),
          ),
        if (!m.isPlanningFailure &&
            m.actions == null &&
            hasText &&
            (m.question == null ||
                (m.text.isNotEmpty && m.text != m.question!.question)))
          MessageBubble(
            message: m,
            optionsActive: !_chat.typing && _chat.isActive(m),
            onOption: (i) => _chat.choose(m, i),
          ),
        if (m.actions case final actions?) ...[
          withCoachChatRecommendUi(
            context,
            CoachRecommendCard(
              key: ValueKey('coach-recommendation-${m.id}'),
              actionIds: actions.items.map((action) => action.id).toList(),
              note: m.text,
              library: CoachExerciseLibrary([
                for (final action in actions.items)
                  if (library[action.id] case final exercise?)
                    toCoachRecommendationExercise(context, exercise),
              ]),
              onOpenAction: (id) {
                unawaited(_chat.openAction(context, id, messageId: m.id));
              },
              onPlanFromActions: _chat.typing
                  ? null
                  : (_) => unawaited(
                      _chat.send(_chat.profile.strings.planFromActionsRequest),
                    ),
            ),
          ),
        ],
        if (m.validatedPlan case final validated?) ...[
          if (hasText) const SizedBox(height: ChatSpace.x3),
          _trainingCard(
            m,
            ValidatedPlanCard(
              validatedPlan: validated,
              library: library,
              executionTiming: _chat.profile.executionTiming,
              landing: fresh,
              isSaved: _chat.isSaved,
              updatingSavedPlan: _chat.savedTargetFor(m) != null,
              savedOverride: _chat.isPlanCardSaved(m),
              onSaveCopy: _chat.savedTargetFor(m) == null
                  ? null
                  : (_) => unawaited(_savePlanCard(m, saveAsCopy: true)),
              onStart: (_) => _start(m),
              onSave: (_) => unawaited(_savePlanCard(m)),
              onOpen: (plan) => _details(m, validatedPlan: plan),
            ),
          ),
        ] else if (m.isPlan &&
            (m.plan!.source != 'ai' || m.isSavedPlanDisplay)) ...[
          if (hasText) const SizedBox(height: ChatSpace.x3),
          _trainingCard(
            m,
            PlanCard(
              plan: m.plan!,
              landing: fresh,
              library: library,
              executionTiming: _chat.profile.executionTiming,
              saved: _chat.isSaved(m.plan!),
              onStart: () => _start(m),
              onSave: () => _save(m.plan!),
              onOpen: () => _details(m),
            ),
          ),
        ],
      ],
    );
  }

  Widget _trainingCard(ChatMessage message, Widget child) {
    final plan = message.plan ?? message.validatedPlan?.plan;
    final exerciseId = plan?.items.firstOrNull?.exerciseId;
    if (exerciseId == null) return child;
    final exercise = _chat.catalog[exerciseId];
    if (exercise == null) return child;
    return TrainingCardMedia(
      key: ValueKey('training-card-poster-${message.id}'),
      actionId: exercise.id,
      child: child,
    );
  }
}
