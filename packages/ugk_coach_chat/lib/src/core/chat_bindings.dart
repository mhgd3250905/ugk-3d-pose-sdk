import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_trainer_runtime/engine.dart' show SessionResult;

import 'chat_snapshot.dart';

typedef CoachChatObserver = void Function(String event, Object? detail);

/// A client and its concrete release operation. Generic LlmClient has no close.
class CoachClientLease {
  const CoachClientLease.shared(this.client) : release = null;
  const CoachClientLease.owned(this.client, {required this.release});
  final coach.LlmClient client;
  final FutureOr<void> Function()? release;
}

class CoachGatewayBinding {
  const CoachGatewayBinding({required this.create});
  factory CoachGatewayBinding.shared(coach.LlmClient client) =>
      CoachGatewayBinding(create: () => CoachClientLease.shared(client));
  factory CoachGatewayBinding.configured({
    required coach.LlmConfig config,
    required coach.AuthProvider auth,
  }) => CoachGatewayBinding(
    create: () {
      final client = coach.OpenAiCompatibleClient(config: config, auth: auth);
      return CoachClientLease.owned(client, release: client.close);
    },
  );
  final FutureOr<CoachClientLease> Function() create;
}

class CoachChatBindings {
  const CoachChatBindings({
    required this.storageNamespace,
    required this.gateway,
    required this.plans,
    required this.history,
    required this.preferences,
    required this.actions,
    this.memory,
    this.observer,
  });
  final String storageNamespace;
  final CoachGatewayBinding gateway;
  final CoachPlanStorageAdapter plans;
  final CoachChatHistoryStore history;
  final CoachChatPreferenceStore preferences;
  final coach.UserMemoryStore? memory;
  final CoachChatHostActions actions;
  final CoachChatObserver? observer;
}

class CoachSavedPlanSnapshot {
  const CoachSavedPlanSnapshot({
    required this.externalId,
    required this.title,
    required this.plan,
    required this.storageRevision,
    this.sdkVersion,
    this.updatedAt,
  });
  final String externalId, title;
  final coach.TrainingPlan plan;

  /// Host-owned opaque compare-and-swap value, independent of SDK baseVersion.
  final Object storageRevision;
  final int? sdkVersion;
  final DateTime? updatedAt;
  String get id => externalId;
  String get name => title;
}

typedef CoachSavedPlanSelection = CoachSavedPlanSnapshot;

enum CoachPlanWriteMode { create, copy, update }

enum CoachPlanWriteStatus { saved, conflict, deleted, readOnly, failed }

class CoachPlanWriteRequest {
  const CoachPlanWriteRequest({
    required this.admittedPlan,
    required this.mode,
    required this.name,
    this.sdkVersion,
    this.savedRef,
    this.externalId,
    this.expectedStorageRevision,
  });
  final coach.ValidatedPlan admittedPlan;
  coach.TrainingPlan get plan => admittedPlan.plan;
  final CoachPlanWriteMode mode;
  final String name;
  final int? sdkVersion;
  final coach.CoachSavedPlanRef? savedRef;
  final String? externalId;
  final Object? expectedStorageRevision;
}

class CoachPlanWriteResult {
  const CoachPlanWriteResult.saved(CoachSavedPlanSnapshot this.saved)
    : status = CoachPlanWriteStatus.saved,
      error = null;
  const CoachPlanWriteResult.failure(this.status, {this.error}) : saved = null;
  final CoachPlanWriteStatus status;
  final CoachSavedPlanSnapshot? saved;
  final Object? error;
  bool get ok => status == CoachPlanWriteStatus.saved && saved != null;
}

class CoachPlanStorageException implements Exception {
  const CoachPlanStorageException(this.result);
  final CoachPlanWriteResult result;
  @override
  String toString() => 'CoachPlanStorageException(${result.status.name})';
}

/// The same store used by the host's "My plans" page. Update must compare
/// expectedStorageRevision atomically and return conflict/deleted explicitly.
abstract class CoachPlanStorageAdapter {
  Future<List<CoachSavedPlanSnapshot>> load();
  Stream<void> get changes => const Stream.empty();
  Future<CoachSavedPlanSnapshot?> read(String externalId) async =>
      (await load()).where((plan) => plan.externalId == externalId).firstOrNull;
  Future<CoachPlanWriteResult> save(CoachPlanWriteRequest request);
}

class WorkoutLog {
  const WorkoutLog({
    required this.title,
    required this.at,
    required this.minutes,
    required this.completed,
    required this.total,
  });
  final String title;
  final DateTime at;
  final int minutes, completed, total;
  bool get finished => total > 0 && completed >= total;
}

class CoachChatHistoryContext {
  const CoachChatHistoryContext({this.lastPlan, this.history = const []});
  final coach.TrainingPlan? lastPlan;
  final List<WorkoutLog> history;
}

abstract class CoachChatHistoryStore {
  Future<CoachChatSnapshot?> load(String namespace);
  Future<void> write(String namespace, CoachChatSnapshot snapshot);
  Future<CoachChatLegacyData?> loadLegacy(String namespace) async => null;
  Future<CoachChatHistoryContext> readTrainingContext() async =>
      const CoachChatHistoryContext();
  Future<void> rememberStartedPlan(
    coach.TrainingPlan plan, {
    String? savedExternalId,
  }) async {}
}

class CoachChatPreferences {
  const CoachChatPreferences({
    this.safetyAccepted = false,
    this.safetyBlocked = false,
    this.safetyChecking = false,
    this.appearance = 'system',
    this.voice = true,
    this.chimes = true,
    this.enableUserMemory = true,
    this.starfield = true,
  });
  final bool safetyAccepted, safetyBlocked, safetyChecking;
  final String appearance;
  final bool voice, chimes, enableUserMemory, starfield;
  bool get trainingAllowed =>
      safetyAccepted && !safetyBlocked && !safetyChecking;
  CoachChatPreferences copyWith({
    bool? safetyAccepted,
    bool? safetyBlocked,
    bool? safetyChecking,
    String? appearance,
    bool? voice,
    bool? chimes,
    bool? enableUserMemory,
    bool? starfield,
  }) => CoachChatPreferences(
    safetyAccepted: safetyAccepted ?? this.safetyAccepted,
    safetyBlocked: safetyBlocked ?? this.safetyBlocked,
    safetyChecking: safetyChecking ?? this.safetyChecking,
    appearance: appearance ?? this.appearance,
    voice: voice ?? this.voice,
    chimes: chimes ?? this.chimes,
    enableUserMemory: enableUserMemory ?? this.enableUserMemory,
    starfield: starfield ?? this.starfield,
  );
}

abstract class CoachChatPreferenceStore {
  Future<CoachChatPreferences> load();
  Stream<CoachChatPreferences> get changes => const Stream.empty();
  Future<void> update(CoachChatPreferences preferences);
}

enum CoachChatCommandKind {
  newConversation,
  showHistory,
  showLastPlan,
  recheckSafety,
  openLibrary,
  openSavedPlans,
  openCustomPlan,
  openSettings,
  appearance,
  voice,
  chimes,
}

class CoachChatCommand {
  const CoachChatCommand(this.kind, {this.value});
  final CoachChatCommandKind kind;
  final String? value;
  static CoachChatCommand? fromLegacy(String action) {
    final parts = action.split(':');
    final kind = switch (parts.first) {
      '@new' => CoachChatCommandKind.newConversation,
      '@history' => CoachChatCommandKind.showHistory,
      '@last' => CoachChatCommandKind.showLastPlan,
      '@safety' => CoachChatCommandKind.recheckSafety,
      '@library' => CoachChatCommandKind.openLibrary,
      '@drawer' => CoachChatCommandKind.openSavedPlans,
      '@custom' => CoachChatCommandKind.openCustomPlan,
      '@settings' => CoachChatCommandKind.openSettings,
      '@appearance' => CoachChatCommandKind.appearance,
      '@voice' => CoachChatCommandKind.voice,
      '@chimes' => CoachChatCommandKind.chimes,
      _ => null,
    };
    return kind == null
        ? null
        : CoachChatCommand(
            kind,
            value: parts.length > 1 ? parts.skip(1).join(':') : null,
          );
  }
}

class CoachChatTrainingRequest {
  const CoachChatTrainingRequest({
    required this.plan,
    required this.sourceEntry,
    required this.messageId,
    required this.onStarting,
    required this.holdTransition,
  });
  final coach.ValidatedPlan plan;
  coach.ValidatedPlan get admittedPlan => plan;
  final String sourceEntry;
  final String? messageId;
  final Future<bool> Function() onStarting;
  final VoidCallback Function() holdTransition;
}

class CoachChatActionOpenRequest {
  const CoachChatActionOpenRequest({
    required this.actionId,
    this.messageId,
    this.sourceEntry = 'chat',
  });
  final String actionId, sourceEntry;
  final String? messageId;
}

class CoachChatLibraryOpenRequest {
  const CoachChatLibraryOpenRequest({
    this.initialCategoryId,
    this.sourceEntry = 'chat',
  });
  final String? initialCategoryId;
  final String sourceEntry;
}

class CoachChatHostActions {
  const CoachChatHostActions({
    required this.onStartTraining,
    required this.onOpenAction,
    required this.onOpenLibrary,
    required this.onOpenSavedPlans,
    required this.onOpenCustomPlan,
    required this.onOpenSettings,
    this.onSaved,
    this.onOpenOutOfScopeGuidance,
  });
  final Future<SessionResult?> Function(
    BuildContext context,
    CoachChatTrainingRequest request,
  )
  onStartTraining;
  final Future<void> Function(
    BuildContext context,
    CoachChatActionOpenRequest request,
  )
  onOpenAction;
  final Future<void> Function(
    BuildContext context,
    CoachChatLibraryOpenRequest request,
  )
  onOpenLibrary;
  final Future<void> Function(BuildContext context) onOpenSavedPlans;
  final Future<void> Function(BuildContext context) onOpenCustomPlan;
  final Future<void> Function(BuildContext context) onOpenSettings;
  final void Function(CoachSavedPlanSnapshot saved)? onSaved;
  final Future<void> Function(BuildContext context, String target)?
  onOpenOutOfScopeGuidance;
}
