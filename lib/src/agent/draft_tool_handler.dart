part of 'structured_tool_handler.dart';

extension DraftToolHandler on StructuredToolHandler {
  StructuredToolResult draft(
    CoachSessionState state,
    String raw,
    String language, {
    SkillDisclosures? disclosures,
  }) {
    beginTool(AgentTools.draftPlan);
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
    var prepared = state;
    StructuredToolResult? switched;
    if (state.task?.type != 'plan') {
      if (args['blocks'] is! List || (args['blocks'] as List).isEmpty) {
        return StructuredToolResult(
          state,
          jsonEncode(
            nodeError(
              'invalid_draft',
              'blocks',
              '非空计划块数组',
              args['blocks'],
              '提供包含动作选择的计划块。',
            ),
          ),
        );
      }
      final started = task(
        state,
        AgentTools.startTask,
        jsonEncode({'type': 'plan'}),
        language,
        disclosures: disclosures,
        allocatePlanReference: false,
      );
      if ((jsonDecode(started.response) as Map)['ok'] != true) return started;
      switched = started;
      prepared = started.state;
    }
    final taskCheckpoint = prepared;
    StructuredToolResult finish(StructuredToolResult result) {
      if (switched == null) return result;
      final taskReceipt = jsonDecode(switched.response) as Map;
      final response = jsonDecode(result.response) as Map;
      final next = identical(result.state, state)
          ? taskCheckpoint
          : result.state;
      return StructuredToolResult(
        next,
        jsonEncode({
          ...response,
          'task': next.task?.toJson(),
          'skills': taskReceipt['skills'],
          'profile': taskReceipt['profile'],
          'notices': [
            if (response['notices'] is List) ...response['notices'] as List,
            '已按 draft_plan 的类型准备同一计划任务，未创建未验证的计划版本。',
          ],
        }),
        changes: [...switched.changes, ...result.changes],
        fresh: switched.fresh || result.fresh,
        accessed: result.accessed,
        fullSkills: {...switched.fullSkills, ...result.fullSkills},
        requiredSkills: {...switched.requiredSkills, ...result.requiredSkills},
      );
    }

    final gates = NodeGates(profile, catalog, minPicks: profile.minActions);
    final changes = <CoachNodeState>[];
    if (prepared.task?.type == 'plan') {
      final defaults = <String, Object?>{
        if (prepared.params['scene']?.value == null)
          'scene': {'value': profile.defaultScene, 'source': 'default'},
        if (prepared.params['minutes']?.value == null &&
            int.tryParse(profile.vars['defaultMinutes'] ?? '') != null)
          'minutes': {
            'value': int.parse(profile.vars['defaultMinutes']!),
            'source': 'default',
          },
      };
      if (defaults.isNotEmpty) {
        final filled = setParams(
          prepared,
          {'fields': defaults},
          language,
          const [],
        );
        final receipt = jsonDecode(filled.response) as Map;
        if (receipt['ok'] != true) {
          return finish(StructuredToolResult(state, filled.response));
        }
        prepared = filled.state;
        changes.addAll(filled.changes);
      }
    }
    final missing = [
      for (final key in ['scene', 'goal', 'minutes'])
        if (prepared.params[key]?.value == null ||
            (prepared.params[key]?.value is List &&
                (prepared.params[key]!.value as List).isEmpty))
          key,
    ];
    if (missing.isNotEmpty) {
      return finish(
        StructuredToolResult(
          state,
          jsonEncode(
            nodeError(
              'missing_parameters',
              'params',
              ['scene', 'goal', 'minutes'],
              missing,
              '通过 set_params 补齐缺少的参数。',
            ),
          ),
        ),
      );
    }
    if (prepared.task?.type == 'plan' &&
        prepared.task?.nodes
                .where((n) => n.status == 'current')
                .firstOrNull
                ?.id ==
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
        prepared,
        'actions',
        picks: ids.toList(),
        language: language,
      );
      if (!selected.ok) {
        return finish(StructuredToolResult(state, jsonEncode(selected.error)));
      }
      prepared = selected.state;
      changes.addAll(selected.changes);
    }
    final result =
        PlanBuilder(
          profile,
          catalog,
          minPicks: profile.minActions,
          executionTiming: executionTiming,
        ).draft(
          prepared,
          args.cast<String, Object?>(),
          newPlanId: newPlanId(),
          language: language,
        );
    if (result.planId == null) {
      if (result.feasibility != null) {
        return finish(
          StructuredToolResult(
            prepared,
            jsonEncode(result.toJson()),
            changes: changes,
            fresh: true,
          ),
        );
      }
      return finish(StructuredToolResult(state, jsonEncode(result.toJson())));
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
    return finish(
      StructuredToolResult(
        next,
        jsonEncode(receipt),
        changes: changes,
        fresh: true,
      ),
    );
  }
}
