/// Stateless handlers for structured Agent tools. State is returned to the
/// calling loop, which owns cancellation, memory epochs, and event delivery.
library;

import 'dart:convert';

import '../catalog/catalog.dart';
import '../plan/plan_validator.dart';
import '../profile/coach_profile.dart';
import 'action_search.dart';
import 'action_tags.dart';
import 'agent_prompt.dart';
import 'agent_task.dart';
import 'node_gates.dart';
import 'plan_builder.dart';
import 'plan_checker.dart';
import 'session_params.dart';
import 'session_state.dart';
import 'skill_disclosure.dart';
import 'skill_files.dart';
import 'user_memory.dart';

part 'draft_tool_handler.dart';
part 'action_tool_handler.dart';
part 'task_tool_handler.dart';
part 'params_tool_handler.dart';
part 'plan_check_tool_handler.dart';

class StructuredToolResult {
  const StructuredToolResult(
    this.state,
    this.response, {
    this.changes = const [],
    this.fresh = false,
    this.accessed = const [],
    this.fullSkills = const {},
    this.requiredSkills = const {},
  });
  final CoachSessionState state;
  final String response;
  final List<CoachNodeState> changes;
  final bool fresh;
  final List<String> accessed;
  final Set<String> fullSkills;
  final Set<String> requiredSkills;
}

class StructuredToolHandler {
  StructuredToolHandler(
    this.profile,
    this.catalog, {
    required this.newPlanId,
    this.extraRules = const [],
    this.enforceDrillDoseRange = false,
    this.files,
  });
  final CoachProfile profile;
  final Catalog catalog;
  final String Function() newPlanId;
  final List<PlanRule> extraRules;
  final bool enforceDrillDoseRange;
  final SkillFiles? files;

  Object? _decode(String raw) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }
}
