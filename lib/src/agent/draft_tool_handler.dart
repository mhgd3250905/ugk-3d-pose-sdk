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
    final gates = NodeGates(profile, catalog, minPicks: profile.minActions);
    var prepared = state;
    final changes = <CoachNodeState>[];
    if (state.task?.type == 'plan' &&
        state.task?.nodes.where((n) => n.status == 'current').firstOrNull?.id ==
            'actions') {
      final blocks = args['blocks'];
      final ids = <String>{
        if (blocks is List)
          for (final block in blocks)
            if (block is Map && block['items'] is List)
              for (final item in block['items'] as List)
                if (item is Map && item['id'] is String) item['id'] as String,
      };
      final selected = gates.check(
        state,
        'actions',
        picks: ids.toList(),
        language: language,
      );
      if (!selected.ok) {
        return StructuredToolResult(state, jsonEncode(selected.error));
      }
      prepared = selected.state;
      changes.addAll(selected.changes);
    }
    final result = PlanBuilder(profile, catalog, minPicks: profile.minActions)
        .draft(
          prepared,
          args.cast<String, Object?>(),
          newPlanId: newPlanId(),
          language: language,
        );
    if (result.planId == null) {
      return StructuredToolResult(state, jsonEncode(result.toJson()));
    }
    changes.addAll(result.changes);
    var next = result.state;
    final receipt = result.toJson();
    if (result.ok) {
      final planned = gates.check(
        next,
        'planning',
        planId: result.planId,
        language: language,
      );
      next = planned.state;
      changes.addAll(planned.changes);
      final checked = checkPlan(
        next,
        jsonEncode({'plan_id': result.planId}),
        language: language,
      );
      next = checked.state;
      changes.addAll(checked.changes);
      final review = jsonDecode(checked.response) as Map<String, dynamic>;
      // The request's current-state message already contains the full nodes.
      // Keep this receipt focused on the review and actionable failures.
      review.remove('task');
      receipt['check'] = review;
      if (review['ok'] != true) {
        receipt.addAll(review);
      }
    }
    return StructuredToolResult(
      next,
      jsonEncode(receipt),
      changes: changes,
      fresh: true,
    );
  }
}
