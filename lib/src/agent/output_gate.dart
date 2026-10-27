/// Pure validation of final cards, before the caller commits output state.
library;

import '../catalog/catalog.dart';
import '../plan/plan_codec.dart';
import '../plan/training_plan.dart';
import '../profile/coach_profile.dart';
import '../tools/coach_tools.dart';
import 'agent_task.dart';
import 'node_gates.dart';
import 'session_state.dart';

class OutputPreparation {
  const OutputPreparation({
    this.nodeResult,
    this.note = '',
    this.plan,
    this.actions,
    this.warnings = const [],
    this.error,
  });
  final NodeResult? nodeResult;
  final String note;
  final TrainingPlan? plan;
  final List<Drill>? actions;
  final List<String> warnings;
  final Map<String, Object?>? error;
  bool get ok => error == null;
}

class OutputGate {
  OutputGate(this.profile, this.catalog)
    : gate = NodeGates(profile, catalog, minPicks: profile.minActions);
  final CoachProfile profile;
  final Catalog catalog;
  final NodeGates gate;

  OutputPreparation prepare(
    CoachSessionState state,
    String tool,
    Object? arguments, {
    String language = 'zh',
  }) {
    OutputPreparation fail(
      String code,
      String field,
      Object? expected,
      Object? actual,
      String fix,
    ) =>
        OutputPreparation(error: nodeError(code, field, expected, actual, fix));
    if (tool != CoachTools.showActions && tool != CoachTools.showPlan) {
      return fail(
        'invalid_output_tool',
        'tool',
        [CoachTools.showActions, CoachTools.showPlan],
        tool,
        '调用对应任务的输出工具。',
      );
    }
    final task = state.task;
    final requiredType = tool == CoachTools.showPlan ? 'plan' : 'recommend';
    if (task?.type != requiredType) {
      return fail(
        'wrong_task_type',
        'task.type',
        requiredType,
        task?.type,
        '完成对应类型的任务后再交付。',
      );
    }
    final expectedNodes = requiredType == 'plan'
        ? AgentTask.planNodes
        : AgentTask.recommendNodes;
    if (task!.nodes.length != expectedNodes.length ||
        List.generate(
              expectedNodes.length,
              (i) => task.nodes[i].id,
            ).join(',') !=
            expectedNodes.join(',')) {
      return fail(
        'invalid_task_nodes',
        'task.nodes',
        expectedNodes,
        task.nodes.map((n) => n.id).toList(),
        '重新开始并完成固定节点。',
      );
    }
    final completed = gate.completeOutput(state, language: language);
    if (!completed.ok) return OutputPreparation(error: completed.error);
    if (arguments is! Map ||
        arguments.keys.any(
          (k) => !{
            'note',
            tool == CoachTools.showPlan ? 'plan_id' : 'ids',
          }.contains(k),
        )) {
      return fail(
        'invalid_arguments',
        'arguments',
        tool == CoachTools.showPlan ? '{plan_id,note}' : '{ids,note}',
        arguments,
        '只提供输出工具要求的字段。',
      );
    }
    final note = arguments['note'];
    if (note is! String ||
        note.trim().isEmpty ||
        note.runes.length > 120 ||
        _sentenceMarks(note) > 2) {
      return fail(
        'invalid_note',
        'note',
        '非空、最多 120 字、句末标点最多 2 个',
        note,
        '写一到两句不超过 120 字的说明。',
      );
    }
    final warnings = <String>[
      for (final code
          in (state.hostValues['limitsOpaque'] as List<Object?>? ?? const [])
              .cast<String>())
        '目录缺少限制 ${gate.tags.limitValue(code) ?? code} 的可核对禁忌，不能确认其安全性。',
    ];
    if (tool == CoachTools.showActions) {
      final value = arguments['ids'];
      if (value is! List || value.any((id) => id is! String)) {
        return fail(
          'invalid_ids',
          'ids',
          'picks 中的动作 ID 数组',
          value,
          '提供已选动作的 ID 数组。',
        );
      }
      final ids = value.cast<String>();
      final notPicked = ids.where((id) => !state.picks.contains(id)).toList();
      if (notPicked.isNotEmpty) {
        return fail(
          'unpicked_actions',
          'ids',
          state.picks,
          notPicked,
          '只交付动作节点选中的 ID。',
        );
      }
      final incompatible = {
        for (final id in ids)
          id: ?gate.actionProblem(state, id),
      };
      if (incompatible.isNotEmpty) {
        return fail(
          'incompatible_actions',
          'ids',
          '符合当前条件的已选动作',
          incompatible,
          '重新选择符合当前条件的动作。',
        );
      }
      return OutputPreparation(
        nodeResult: completed,
        note: note.trim(),
        actions: [for (final id in ids) catalog[id]!],
        warnings: warnings,
      );
    }
    final id = arguments['plan_id'];
    final active =
        state.activePlanId ??
        (state.legacyPlanFallback && state.plans.length == 1
            ? state.plans.keys.single
            : null);
    if (id is! String || id != active || state.plans[id]?.isNotEmpty != true) {
      return fail(
        'invalid_plan_id',
        'plan_id',
        active ?? '当前计划 ID',
        id,
        '交付当前计划的最新版本。',
      );
    }
    final version = state.plans[id]!.last;
    if (version.check?['ok'] != true) {
      return fail(
        'plan_not_checked',
        'plan_id',
        '最新版本 check_plan 已通过',
        id,
        '先核对当前计划版本。',
      );
    }
    final parsed = const PlanCodec().decodeStrict(version.plan);
    if (!parsed.ok) {
      return fail(
        'invalid_plan',
        'plan_id',
        '有效的计划卡',
        parsed.issues.map((issue) => issue.message).toList(),
        '重新生成并核对计划。',
      );
    }
    final plan = parsed.plan!;
    final ids = <String>{
      for (final block in plan.blocks)
        for (final item in block.items)
          if (item.segments.isEmpty)
            item.exerciseId
          else
            ...item.segments.map((segment) => segment.exerciseId),
    };
    final incompatible = {
      for (final action in ids)
        action: ?gate.actionProblem(state, action),
    };
    if (incompatible.isNotEmpty) {
      return fail(
        'incompatible_actions',
        'plan_id',
        '符合当前条件的计划动作',
        incompatible,
        '重新生成并核对符合当前条件的计划。',
      );
    }
    final actualEquipment = <String>{
      for (final action in ids) ...?catalog[action]?.equipment,
    }..remove('none');
    final declaredEquipment = plan.equipment.toSet();
    final minutes = state.params['minutes']?.value;
    if (plan.targetMinutes != minutes ||
        declaredEquipment.length != actualEquipment.length ||
        !declaredEquipment.containsAll(actualEquipment)) {
      return fail(
        'card_conditions_changed',
        'plan_id',
        {'minutes': minutes, 'equipment': actualEquipment.toList()},
        {'minutes': plan.targetMinutes, 'equipment': plan.equipment},
        '重新生成并核对与当前条件一致的计划。',
      );
    }
    final savedWarnings = version.check?['warnings'];
    if (savedWarnings is List) {
      warnings.addAll(
        savedWarnings.whereType<String>().where((w) => !warnings.contains(w)),
      );
    }
    return OutputPreparation(
      nodeResult: completed,
      note: note.trim(),
      plan: plan,
      warnings: warnings,
    );
  }
}

int _sentenceMarks(String text) {
  final runes = text.runes.toList();
  var count = 0;
  bool digit(int r) => r >= 0x30 && r <= 0x39;
  for (var i = 0; i < runes.length; i++) {
    final r = runes[i];
    if (!'。！？.!?'.runes.contains(r)) continue;
    if (r == 0x2e &&
        i > 0 &&
        i + 1 < runes.length &&
        digit(runes[i - 1]) &&
        digit(runes[i + 1])) {
      continue;
    }
    count++;
  }
  return count;
}
