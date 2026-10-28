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
    final gates = NodeGates(profile, catalog, minPicks: profile.minActions);
    var nodes = result.changedFields.isEmpty
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
    // A partial update succeeds without claiming that missing conditions are
    // known. Once complete, use the same gate and defaults as explicit check.
    if (nodes.state.task?.nodes
            .where((n) => n.status == 'current')
            .firstOrNull
            ?.id ==
        'parameters') {
      final completed = gates.check(
        nodes.state,
        'parameters',
        language: language,
      );
      if (completed.ok) {
        nodes = NodeResult(
          completed.state,
          changes: [...nodes.changes, ...completed.changes],
        );
      }
    }
    final parameterNode = nodes.state.task?.nodes
        .where((n) => n.id == 'parameters')
        .firstOrNull;
    return StructuredToolResult(
      nodes.state,
      jsonEncode({
        ...result.toJson(),
        'params': {
          for (final e in nodes.state.params.entries) e.key: e.value.toJson(),
        },
        'stamp': ?parameterNode?.stamp,
      }),
      changes: nodes.changes,
      fresh: result.changedFields.isNotEmpty,
    );
  }
}
