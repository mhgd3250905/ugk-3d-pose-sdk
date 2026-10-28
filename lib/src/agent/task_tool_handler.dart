part of 'structured_tool_handler.dart';

extension TaskToolHandler on StructuredToolHandler {
  StructuredToolResult task(
    CoachSessionState state,
    String tool,
    String raw,
    String language, {
    SkillDisclosures? disclosures,
  }) {
    final args = _decode(raw);
    if (args is! Map ||
        args.keys.any((key) => key is! String) ||
        (tool == AgentTools.startTask &&
            (args['type'] is! String ||
                (args['reuse'] != null && args['reuse'] is! bool) ||
                args.keys.any((key) => key != 'type' && key != 'reuse'))) ||
        (tool == AgentTools.check &&
            (args['node'] is! String ||
                (args['picks'] != null &&
                    (args['picks'] is! List ||
                        (args['picks'] as List).any((v) => v is! String))) ||
                args.keys.any((key) => key != 'node' && key != 'picks')))) {
      return StructuredToolResult(
        state,
        jsonEncode(
          nodeError(
            'invalid_arguments',
            'arguments',
            tool == AgentTools.startTask
                ? '{type: recommend|plan, reuse?: bool}'
                : '{node: fixed node, picks?: string[]}',
            args,
            '使用工具 schema 中的字段和值。',
          ),
        ),
      );
    }
    Map<String, String>? taskSkills;
    final fullSkills = <String>{};
    final requiredSkills = <String>{};
    if (tool == AgentTools.startTask &&
        {'recommend', 'plan'}.contains(args['type'])) {
      final names = <String>[
        SkillFiles.ask,
        SkillFiles.actionLibrary,
        if (args['type'] == 'plan') SkillFiles.planTraining,
      ];
      final missing = names
          .where((name) => files?.read('$name/SKILL.md') == null)
          .toList();
      if (missing.isNotEmpty) {
        return StructuredToolResult(
          state,
          jsonEncode(
            nodeError(
              'skills_unavailable',
              'skills',
              names,
              missing,
              '恢复当前任务所需的技能文件。',
            ),
          ),
        );
      }
      requiredSkills.addAll(
        SkillDisclosures.requiredFor(args['type'] as String),
      );
      taskSkills = {};
      for (final name in names) {
        final path = '$name/SKILL.md';
        final source = disclosures?.sources[path];
        taskSkills[name] = switch (source) {
          SkillSource.read => SkillDisclosures.readReference,
          SkillSource.startTask => SkillDisclosures.startReference,
          null => files!.read(path)!,
        };
        if (source == null) fullSkills.add(path);
      }
    }
    final result = tool == AgentTools.startTask
        ? AgentTask.start(
            state,
            args['type'] as String,
            reuse: args['reuse'] as bool?,
          )
        : NodeGates(profile, catalog, minPicks: profile.minActions).check(
            state,
            args['node'] as String,
            picks: (args['picks'] as List?)?.cast<String>(),
            language: language,
          );
    var next = result.state;
    final changes = [...result.changes];
    if (result.ok &&
        tool == AgentTools.startTask &&
        next.task?.nodes.first.status == 'current') {
      final understood = NodeGates(
        profile,
        catalog,
        minPicks: profile.minActions,
      ).check(next, 'understand', language: language);
      next = understood.state;
      changes.addAll(understood.changes);
    }
    if (result.ok &&
        tool == AgentTools.startTask &&
        args['type'] == 'plan' &&
        next.activePlanId == null) {
      var id = newPlanId();
      while (next.plans.containsKey(id)) {
        id = newPlanId();
      }
      next = next.copyWith(
        plans: {...next.plans, id: <CoachPlanVersion>[]},
        activePlanId: id,
      );
    }
    return StructuredToolResult(
      next,
      jsonEncode(
        result.error ??
            {
              'ok': true,
              'task': next.task?.toJson(),
              'skills': ?taskSkills,
              if (taskSkills != null)
                'profile': {'focus': profile.focus, 'rules': profile.rules},
              if (tool == AgentTools.startTask && next.task?.type == 'plan')
                'plan_id': next.activePlanId,
              if (result.warnings.isNotEmpty) 'warnings': result.warnings,
              if (result.notices.isNotEmpty) 'notices': result.notices,
            },
      ),
      changes: result.ok ? changes : const [],
      fresh: result.ok,
      fullSkills: result.ok ? fullSkills : const {},
      requiredSkills: result.ok ? requiredSkills : const {},
    );
  }
}
