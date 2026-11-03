import 'dart:convert';

import 'package:ugk_coach/ugk_coach.dart' as coach;

import 'chat_models.dart';

/// Chat display storage is versioned separately from the existing core snapshot.
class CoachChatSnapshot {
  CoachChatSnapshot({
    required this.appId,
    required this.storageNamespace,
    required this.session,
    required List<Map<String, Object?>> messages,
    this.envelopeSchemaVersion = 1,
    this.qaState,
  }) : messages = List.unmodifiable(
         messages.map((message) => Map<String, Object?>.unmodifiable(message)),
       );
  final int envelopeSchemaVersion;
  final String appId, storageNamespace;
  final coach.CoachSessionSnapshot session;
  final List<Map<String, Object?>> messages;

  /// Optional opt-in agent state; legacy envelopes and sessions remain valid.
  final Map<String, Object?>? qaState;
  Map<String, Object?> toJson() => {
    'envelopeSchemaVersion': envelopeSchemaVersion,
    'appId': appId,
    'storageNamespace': storageNamespace,
    'session': session.toJson(),
    'messages': messages,
    'qaState': ?qaState,
  };
  factory CoachChatSnapshot.fromJson(Map<String, Object?> value) =>
      CoachChatSnapshot(
        envelopeSchemaVersion: value['envelopeSchemaVersion'] as int? ?? 1,
        appId: value['appId']! as String,
        storageNamespace: value['storageNamespace']! as String,
        qaState: value['qaState'] is Map
            ? Map<String, Object?>.from(value['qaState']! as Map)
            : null,
        session: coach.CoachSessionSnapshot.fromJson(value['session']),
        messages: [
          for (final item in value['messages'] as List? ?? const [])
            Map<String, Object?>.from(item as Map),
        ],
      );
}

/// Read-only legacy SF fields. Hosts read their old keys; the module decodes
/// them and writes a new envelope without deleting or changing the old data.
class CoachChatLegacyData {
  const CoachChatLegacyData({
    this.chat = const [],
    this.coachDisplay = const [],
    this.coachSessionJson,
  });
  final List<Map<String, Object?>> chat, coachDisplay;
  final String? coachSessionJson;
  coach.CoachSessionSnapshot? get session => coachSessionJson == null
      ? null
      : coach.CoachSessionSnapshot.fromJson(jsonDecode(coachSessionJson!));
}

class CoachChatOperationResult {
  const CoachChatOperationResult({
    required this.ok,
    this.persisted = true,
    this.error,
    this.issues = const [],
  });
  final bool ok, persisted;
  final Object? error;
  final List<coach.PlanIssue> issues;
}

class CoachChatRestoreResult extends CoachChatOperationResult {
  const CoachChatRestoreResult({
    required super.ok,
    super.persisted,
    super.error,
    super.issues,
  });
}

class CoachChatFocusResult {
  const CoachChatFocusResult({
    required this.core,
    required this.persisted,
    this.persistenceError,
    this.scopePreview,
  });
  final coach.CoachPlanFocusResult core;
  final bool persisted;
  final Object? persistenceError;
  final CoachChatScopePreview? scopePreview;
  bool get ok => core.ok;
  List<coach.PlanIssue> get errors => core.errors;
  String? get planId => core.planId;
  int? get version => core.version;
}
