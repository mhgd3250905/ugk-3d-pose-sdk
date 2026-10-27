part of 'structured_tool_handler.dart';

extension DraftToolHandler on StructuredToolHandler {
  StructuredToolResult draft(
    CoachSessionState state,
    String raw,
    String language,
  ) {
    final args = _decode(raw);
    if (args is! Map || args.keys.any((key) => key is! String)) {
      return StructuredToolResult(
        state,
        jsonEncode(
          nodeError(
            'invalid_arguments',
            'arguments',
            '包含 title、blocks 和可选 plan_id 的 JSON 对象',
            args,
            '按 draft_plan schema 提供结构化计划。',
          ),
        ),
      );
    }
    final result = PlanBuilder(profile, catalog, minPicks: profile.minActions)
        .draft(
          state,
          args.cast<String, Object?>(),
          newPlanId: newPlanId(),
          language: language,
        );
    return StructuredToolResult(
      result.planId == null ? state : result.state,
      jsonEncode(result.toJson()),
      changes: result.planId == null ? const [] : result.changes,
      fresh: result.planId != null,
    );
  }
}
