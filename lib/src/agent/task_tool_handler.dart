part of 'structured_tool_handler.dart';

extension TaskToolHandler on StructuredToolHandler {
  StructuredToolResult task(
    CoachSessionState state,
    String tool,
    String raw,
    String language, {
    SkillDisclosures? disclosures,
  }) {
    var decoded = _decode(raw);
    final normalization = <String>[];
    if (decoded is String) {
      decoded = _decode(decoded);
      normalization.add('已解包字符串化参数。');
    }
    if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
      return StructuredToolResult(
        state,
        jsonEncode(
          nodeError(
            'invalid_arguments',
            'arguments',
            '参数对象',
            decoded,
            '提供结构化参数。',
          ),
        ),
      );
    }
    final args = decoded.cast<String, Object?>();
    if (tool == AgentTools.startTask && args['type'] is! String) {
      return StructuredToolResult(
        state,
        jsonEncode(
          nodeError(
            'invalid_arguments',
            'type',
            'recommend 或 plan',
            args['type'],
            '明确任务类型。',
          ),
        ),
      );
    }
    if (tool == AgentTools.startTask &&
        args['reuse'] != null &&
        args['reuse'] is! bool) {
      args.remove('reuse');
      normalization.add('已按真实状态决定复用。');
    }
    final allowed = tool == AgentTools.startTask
        ? const {'type', 'reuse'}
        : const {'node', 'picks'};
    final extra = args.keys.where((key) => !allowed.contains(key)).toList();
    for (final key in extra) {
      args.remove(key);
    }
    if (extra.isNotEmpty) normalization.add('已忽略额外字段：${extra.join('、')}。');
    if (tool == AgentTools.check && args['node'] is! String) {
      return StructuredToolResult(
        state,
        jsonEncode({
          'ok': true,
          'task': state.task?.toJson(),
          'note': '节点由代码推进，已返回当前状态。',
        }),
      );
    }
    if (tool == AgentTools.check && args['picks'] is String) {
      args['picks'] = _decode(args['picks'] as String);
      normalization.add('已解包动作ID数组。');
    }
    if (tool == AgentTools.check &&
        args['picks'] != null &&
        (args['picks'] is! List ||
            (args['picks'] as List).any((v) => v is! String))) {
      return StructuredToolResult(
        state,
        jsonEncode(
          nodeError(
            'invalid_arguments',
            'picks',
            '动作ID数组',
            args['picks'],
            '提供已选ID。',
          ),
        ),
      );
    }
    if (tool == AgentTools.check &&
        {'planning', 'review'}.contains(args['node']) &&
        state.activePlanId != null &&
        state.plans[state.activePlanId]?.isNotEmpty == true) {
      return checkPlan(
        state,
        jsonEncode({'plan_id': state.activePlanId}),
        language: language,
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
        if (args['type'] == 'recommend') SkillFiles.actionCoaching,
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
              if (result.notices.isNotEmpty || normalization.isNotEmpty)
                'notices': [...normalization, ...result.notices],
            },
      ),
      changes: result.ok ? changes : const [],
      fresh: result.ok && (changes.isNotEmpty || fullSkills.isNotEmpty),
      fullSkills: result.ok ? fullSkills : const {},
      requiredSkills: result.ok ? requiredSkills : const {},
    );
  }
}
