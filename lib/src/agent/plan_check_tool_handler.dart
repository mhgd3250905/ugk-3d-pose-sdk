part of 'structured_tool_handler.dart';

extension PlanCheckToolHandler on StructuredToolHandler {
  StructuredToolResult checkPlan(
    CoachSessionState state,
    String raw, {
    String language = 'zh',
  }) {
    final args = _decode(raw);
    if (args is! Map ||
        args.keys.any((key) => key != 'plan_id') ||
        args['plan_id'] is! String ||
        (args['plan_id'] as String).isEmpty) {
      return StructuredToolResult(
        state,
        jsonEncode(
          nodeError(
            'invalid_arguments',
            'arguments',
            '{plan_id: nonempty string}',
            args,
            '提供当前计划的 plan_id。',
          ),
        ),
      );
    }
    final result = PlanChecker(
      profile,
      catalog,
      minPicks: profile.minActions,
      extraRules: extraRules,
      enforceDrillDoseRange: enforceDrillDoseRange,
    ).check(state, args['plan_id'] as String);
    final completed = result.ok
        ? NodeGates(profile, catalog, minPicks: profile.minActions).check(
            result.state,
            'review',
            planId: args['plan_id'] as String,
            language: language,
          )
        : NodeResult(result.state);
    return StructuredToolResult(
      completed.state,
      jsonEncode({...result.toJson(), 'task': completed.state.task?.toJson()}),
      changes: [...result.changes, ...completed.changes],
      fresh: result.error == null,
    );
  }
}
