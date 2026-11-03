import 'dart:convert';

import 'package:ugk_coach/ugk_coach.dart' as coach;

import 'chat_bindings.dart';

enum ChatRole { user, assistant }

class ChatOption {
  const ChatOption(this.label, [String? value]) : value = value ?? label;
  final String label, value;
  bool get isCommand => value.startsWith('@');
  Map<String, Object?> toJson() => {'label': label, 'value': value};
  factory ChatOption.fromJson(Map<String, Object?> json) =>
      ChatOption(json['label'] as String? ?? '', json['value'] as String?);
}

/// A display row. Actual plans are the canonical ugk_coach TrainingPlan type.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.at,
    this.text = '',
    this.options = const [],
    this.chosen,
    this.question,
    this.conversationMessageId,
    this.questionAnswered = false,
    this.answeredChoices = const [],
    this.answeredForm = const {},
    this.isPlanningFailure = false,
    this.plan,
    this.validatedPlan,
    this.sdkVersion,
    this.savedRef,
    this.savedExternalId,
    this.storageRevision,
    this.isSavedPlanDisplay = false,
    this.coachTask,
    this.actions,
    this.request,
    this.greeting = false,
    this.aiVisible = false,
    this.receiptSessionId,
    this.qaV2 = false,
    this.assumption,
    this.quickActions = const [],
    this.actionReasons = const {},
  });
  final String id;
  final ChatRole role;
  final DateTime at;
  final String text;
  final List<ChatOption> options;
  final int? chosen;
  final coach.AskUserQuestion? question;
  final String? conversationMessageId;
  final bool questionAnswered;
  final List<String> answeredChoices;
  final Map<String, List<String>> answeredForm;
  final bool isPlanningFailure;
  final coach.TrainingPlan? plan;
  final coach.ValidatedPlan? validatedPlan;
  final int? sdkVersion;
  final coach.CoachSavedPlanRef? savedRef;
  final String? savedExternalId;

  /// This card's host CAS revision; never inferred from savedRef.baseVersion.
  final Object? storageRevision;
  final bool isSavedPlanDisplay;
  final coach.CoachTaskState? coachTask;
  final coach.ValidatedActions? actions;
  final coach.CoachContext? request;
  final bool greeting, aiVisible;
  final String? receiptSessionId;
  final bool qaV2;
  final String? assumption;
  final List<String> quickActions;
  final Map<String, String> actionReasons;
  bool get isUser => role == ChatRole.user;
  bool get isPlan => plan != null;
  int? get planVersion => sdkVersion ?? validatedPlan?.version;
  coach.CoachSavedPlanRef? get planSavedRef =>
      savedRef ?? validatedPlan?.savedRef;

  ChatMessage copyWith({
    int? chosen,
    String? text,
    coach.AskUserQuestion? question,
    String? conversationMessageId,
    bool? questionAnswered,
    List<String>? answeredChoices,
    Map<String, List<String>>? answeredForm,
    coach.TrainingPlan? plan,
    coach.ValidatedPlan? validatedPlan,
    int? sdkVersion,
    coach.CoachSavedPlanRef? savedRef,
    String? savedExternalId,
    Object? storageRevision,
    bool? isSavedPlanDisplay,
    coach.ValidatedActions? actions,
    bool clearActions = false,
    bool? aiVisible,
  }) => ChatMessage(
    id: id,
    role: role,
    at: at,
    text: text ?? this.text,
    options: options,
    chosen: chosen ?? this.chosen,
    question: question ?? this.question,
    conversationMessageId: conversationMessageId ?? this.conversationMessageId,
    questionAnswered: questionAnswered ?? this.questionAnswered,
    answeredChoices: answeredChoices ?? this.answeredChoices,
    answeredForm: answeredForm ?? this.answeredForm,
    isPlanningFailure: isPlanningFailure,
    plan: plan ?? this.plan,
    validatedPlan: validatedPlan ?? this.validatedPlan,
    sdkVersion: sdkVersion ?? this.sdkVersion,
    savedRef: savedRef ?? this.savedRef,
    savedExternalId: savedExternalId ?? this.savedExternalId,
    storageRevision: storageRevision ?? this.storageRevision,
    isSavedPlanDisplay: isSavedPlanDisplay ?? this.isSavedPlanDisplay,
    coachTask: coachTask,
    actions: clearActions ? null : actions ?? this.actions,
    request: request,
    greeting: greeting,
    aiVisible: aiVisible ?? this.aiVisible,
    receiptSessionId: receiptSessionId,
    qaV2: qaV2,
    assumption: assumption,
    quickActions: quickActions,
    actionReasons: actionReasons,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'role': role.name,
    'at': at.toIso8601String(),
    if (text.isNotEmpty) 'text': text,
    if (options.isNotEmpty)
      'options': [for (final option in options) option.toJson()],
    'chosen': ?chosen,
    'question': ?question?.toJson(),
    'conversationMessageId': ?conversationMessageId,
    if (questionAnswered) 'questionAnswered': true,
    if (answeredChoices.isNotEmpty) 'answeredChoices': answeredChoices,
    if (answeredForm.isNotEmpty) 'answeredForm': answeredForm,
    if (isPlanningFailure) 'isPlanningFailure': true,
    'plan': ?plan?.toJson(),
    'sdkVersion': ?planVersion,
    'savedRef': ?planSavedRef?.toJson(),
    'savedExternalId': ?savedExternalId,
    'storageRevision': ?storageRevision,
    if (isSavedPlanDisplay) 'savedPlanDisplay': true,
    'coachTask': ?coachTask?.toJson(),
    if (actions != null)
      'actionIds': [for (final item in actions!.items) item.id],
    'request': ?request?.toJson(),
    if (greeting) 'greeting': true,
    if (aiVisible) 'aiVisible': true,
    'receiptSessionId': ?receiptSessionId,
    if (qaV2) 'qaV2': true,
    'assumption': ?assumption,
    if (quickActions.isNotEmpty) 'quickActions': quickActions,
    if (actionReasons.isNotEmpty) 'actionReasons': actionReasons,
  };

  factory ChatMessage.fromJson(
    Map<String, Object?> json, {
    coach.ValidatedPlan? Function(coach.TrainingPlan, coach.CoachContext?)?
    admitPlan,
    coach.ValidatedActions? Function(List<String>)? restoreActions,
  }) {
    final request = json['request'] is Map
        ? contextFromJson(Map<String, Object?>.from(json['request']! as Map))
        : null;
    coach.TrainingPlan? plan;
    coach.ValidatedPlan? admitted;
    if (json['plan'] != null) {
      final decoded = const coach.PlanCodec().decodeStrict(json['plan']);
      if (!decoded.ok) {
        throw FormatException('Invalid stored plan: ${decoded.issues}');
      }
      plan = decoded.plan!;
      if (json['isAiPlan'] == true || plan.source == 'ai') {
        admitted = admitPlan?.call(plan, request);
        if (admitPlan != null && admitted == null) {
          throw const FormatException('Stored plan is not admitted');
        }
      }
    }
    final ids = (json['actionIds'] as List? ?? const []).cast<String>();
    return ChatMessage(
      id: json['id'] as String,
      role: json['role'] == 'user' ? ChatRole.user : ChatRole.assistant,
      at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime(2026),
      text: json['text'] as String? ?? '',
      options: [
        for (final item in json['options'] as List? ?? const [])
          ChatOption.fromJson(Map<String, Object?>.from(item as Map)),
      ],
      chosen: (json['chosen'] as num?)?.toInt(),
      question: restoreQuestion(json['question'], direct: json['qaV2'] == true),
      conversationMessageId: json['conversationMessageId'] as String?,
      questionAnswered: json['questionAnswered'] == true,
      answeredChoices: (json['answeredChoices'] as List? ?? const [])
          .cast<String>(),
      answeredForm: stringLists(json['answeredForm']),
      isPlanningFailure: json['isPlanningFailure'] == true,
      plan: plan,
      validatedPlan: admitted,
      sdkVersion: (json['sdkVersion'] as num?)?.toInt(),
      savedRef: json['savedRef'] is Map
          ? coach.CoachSavedPlanRef.fromJson(
              Map<String, Object?>.from(json['savedRef']! as Map),
            )
          : null,
      savedExternalId: json['savedExternalId'] as String?,
      storageRevision: json['storageRevision'],
      isSavedPlanDisplay: json['savedPlanDisplay'] == true,
      coachTask: json['coachTask'] is Map
          ? coach.CoachTaskState.fromJson(
              Map<String, Object?>.from(json['coachTask']! as Map),
            )
          : null,
      actions: ids.isEmpty ? null : restoreActions?.call(ids),
      request: request,
      greeting: json['greeting'] == true,
      aiVisible: json['aiVisible'] == true,
      receiptSessionId: json['receiptSessionId'] as String?,
      qaV2: json['qaV2'] == true,
      assumption: json['assumption'] as String?,
      quickActions: (json['quickActions'] as List? ?? const []).cast<String>(),
      actionReasons: {
        for (final entry in (json['actionReasons'] as Map? ?? const {}).entries)
          entry.key as String: entry.value as String,
      },
    );
  }
}

coach.CoachContext requestForPlan(coach.TrainingPlan plan) =>
    coach.CoachContext(
      scene: plan.scene,
      equipment: plan.equipment.toSet(),
      minutes: plan.targetMinutes,
      level: plan.level,
      goal: plan.goal,
      avoid: plan.avoid,
    );

coach.CoachContext contextFromJson(Map<String, Object?> json) =>
    coach.CoachContext(
      scene: json['scene'] as String?,
      equipment: json['equipment'] == null
          ? null
          : (json['equipment']! as List).cast<String>().toSet(),
      avoid: json['avoid'] == null
          ? null
          : (json['avoid']! as List).cast<String>().toSet(),
      minutes: (json['minutes'] as num?)?.toInt(),
      level: (json['level'] as num?)?.toInt(),
      goal: json['goal'] as String?,
      language: json['language'] as String? ?? 'zh',
      notes: (json['notes'] as List? ?? const []).cast<String>(),
    );

Map<String, List<String>> stringLists(Object? value) => value is Map
    ? {
        for (final entry in value.entries)
          entry.key as String: (entry.value as List).cast<String>(),
      }
    : const {};

coach.AskUserQuestion? restoreQuestion(Object? value, {bool direct = false}) {
  if (value is! Map) return null;
  final raw = Map<String, Object?>.from(value);
  if (direct) {
    return coach.AskUserQuestion.direct(
      raw['question']! as String,
      options: (raw['options'] as List? ?? const []).cast<String>(),
      multiple: raw['multiple'] == true,
      language: raw['language'] as String? ?? 'zh',
    );
  }
  if (raw['isConfirmation'] == true) {
    return coach.AskUserQuestion.confirmation(
      question: raw['question']! as String,
      focus: raw['focus'] as String?,
      defaultSelections: stringLists(raw['defaultSelections']),
      fields: [
        for (final item in raw['fields']! as List)
          (() {
            final field = Map<String, Object?>.from(item as Map);
            return coach.AskUserField(
              key: field['key']! as String,
              label: field['label']! as String,
              options: (field['options']! as List).cast<String>(),
              multiple: field['multiple'] == true,
              preselected: (field['preselected'] as List? ?? const [])
                  .cast<String>(),
              previousSelections:
                  (field['previousSelections'] as List? ?? const [])
                      .cast<String>(),
              optionsByScene: stringLists(field['optionsByScene']),
            );
          })(),
      ],
    );
  }
  return coach.AskUserGate.check(jsonEncode(raw)).question;
}

/// Immutable derived page state, independent of the core's model session facts.
class CoachChatState {
  CoachChatState({
    required List<ChatMessage> messages,
    required List<String> suggestions,
    required this.waiting,
    required this.inSafetyCheck,
    this.focus,
    this.error,
    this.activeTask,
    Set<String> savingMessageIds = const {},
  }) : messages = List.unmodifiable(messages),
       suggestions = List.unmodifiable(suggestions),
       savingMessageIds = Set.unmodifiable(savingMessageIds);
  final List<ChatMessage> messages;
  final List<String> suggestions;
  final bool waiting, inSafetyCheck;
  final coach.CoachPlanFocus? focus;
  final Object? error;
  final coach.CoachTaskState? activeTask;
  final Set<String> savingMessageIds;
}

class CoachChatPlanReference {
  const CoachChatPlanReference({
    required this.admittedPlan,
    this.messageId,
    this.savedSelection,
  });
  final coach.ValidatedPlan admittedPlan;
  coach.TrainingPlan get plan => admittedPlan.plan;
  String get title => plan.title;
  final String? messageId;
  final CoachSavedPlanSelection? savedSelection;
}

class CoachChatScopePreview {
  const CoachChatScopePreview({
    required this.id,
    required this.selection,
    required this.decisions,
  });
  final String id;
  final CoachSavedPlanSelection selection;
  final List<coach.CoachScopeDecisionRecord> decisions;
  String get explanation =>
      decisions.map((record) => record.message).join('\n');
}

class CoachChatPlanDetailsPreparation {
  const CoachChatPlanDetailsPreparation({
    this.reference,
    this.scopePreview,
    this.issues = const [],
  });
  final CoachChatPlanReference? reference;
  final CoachChatScopePreview? scopePreview;
  final List<coach.PlanIssue> issues;
  bool get ok => reference != null;
}

typedef CoachChatMessage = ChatMessage;
typedef CoachChatOption = ChatOption;
typedef CoachChatRole = ChatRole;
