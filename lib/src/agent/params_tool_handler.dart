part of 'structured_tool_handler.dart';

extension ParamsToolHandler on StructuredToolHandler {
  StructuredToolResult setParams(
    CoachSessionState state,
    Object? args,
    String language,
    List<MemoryEntry> memory,
  ) {
    final result = SessionParams(
      ActionTags(profile, catalog),
    ).set(state, args, memory: memory);
    if (!result.ok) {
      return StructuredToolResult(state, jsonEncode(result.toJson()));
    }
    final nodes = result.changedFields.isEmpty
        ? NodeResult(result.state)
        : NodeGates(
            profile,
            catalog,
            minPicks: profile.minActions,
          ).parametersChanged(
            result.state,
            language: language,
            changedFields: result.changedFields,
            valueChangedFields: result.valueChangedFields,
          );
    return StructuredToolResult(
      nodes.state,
      jsonEncode(result.toJson()),
      changes: nodes.changes,
      fresh: result.changedFields.isNotEmpty,
    );
  }
}
