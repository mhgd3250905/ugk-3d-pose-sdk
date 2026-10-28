part of 'structured_tool_handler.dart';

extension PlanCheckToolHandler on StructuredToolHandler {
  StructuredToolResult checkPlan(
    CoachSessionState state,
    String raw, {
    String language = 'zh',
  }) {
    var args = _decode(raw);
    if (args is String) args = _decode(args);
    if (args is! Map) {
      return StructuredToolResult(
        state,
        jsonEncode(
          nodeError(
            'invalid_arguments',
            'arguments',
            '参数对象',
            args,
            '提供当前计划引用。',
          ),
        ),
      );
    }
    final id =
        state.activePlanId ??
        (state.plans.length == 1 ? state.plans.keys.single : null);
    final notes = <String>[
      if (args['plan_id'] != null && args['plan_id'] != id)
        '已使用当前计划引用，忽略过期 plan_id。',
      if (args.keys.any((key) => key != 'plan_id')) '已忽略核对参数中的额外字段。',
    ];
    if (id == null || state.plans[id]?.isNotEmpty != true) {
      return StructuredToolResult(
        state,
        jsonEncode({
          'ok': true,
          'notReady': true,
          'note': '尚未生成草稿，可先选择动作并调用 draft_plan。',
          if (notes.isNotEmpty) 'notes': notes,
        }),
      );
    }
    final gates = NodeGates(profile, catalog, minPicks: profile.minActions);
    final version = state.plans[id]!.last;
    final ids = {
      for (final block in version.plan['blocks'] as List? ?? const [])
        if (block is Map)
          for (final item in block['items'] as List? ?? const [])
            if (item is Map && item['exerciseId'] is String)
              item['exerciseId'] as String,
    };
    var prepared = state;
    final changes = <CoachNodeState>[];
    if (state.task?.type == 'plan') {
      final advanced = gates.check(
        prepared,
        'planning',
        picks: ids.toList(),
        planId: id,
        language: language,
      );
      if (!advanced.ok) {
        return StructuredToolResult(state, jsonEncode(advanced.error));
      }
      prepared = advanced.state;
      changes.addAll(advanced.changes);
    }
    final result = PlanChecker(
      profile,
      catalog,
      minPicks: profile.minActions,
      extraRules: extraRules,
      enforceDrillDoseRange: enforceDrillDoseRange,
    ).check(prepared, id);
    final completed = result.ok
        ? NodeGates(
            profile,
            catalog,
            minPicks: profile.minActions,
          ).check(result.state, 'review', planId: id, language: language)
        : NodeResult(result.state);
    return StructuredToolResult(
      completed.state,
      jsonEncode({
        ...result.toJson(),
        if (notes.isNotEmpty) 'notes': [...result.notes, ...notes],
        'task': completed.state.task?.toJson(),
      }),
      changes: [...changes, ...result.changes, ...completed.changes],
      fresh: result.error == null,
    );
  }
}
