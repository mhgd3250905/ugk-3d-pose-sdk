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
    this.noteTruncated = false,
    this.plan,
    this.actions,
    this.warnings = const [],
    this.error,
  });
  final NodeResult? nodeResult;
  final String note;
  final bool noteTruncated;
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
    if (note is! String || note.trim().isEmpty) {
      return fail('invalid_note', 'note', '非空的说明字符串', note, '提供一到两句说明。');
    }
    final normalized = normalizeOutputNote(note, language: language);
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
      var next = state;
      final changes = <CoachNodeState>[];
      final current = task.nodes
          .where((node) => node.status == 'current')
          .firstOrNull;
      if (current?.id == 'actions') {
        final selected = gate.check(
          next,
          'actions',
          picks: ids,
          language: language,
        );
        if (!selected.ok) return OutputPreparation(error: selected.error);
        next = selected.state;
        changes.addAll(selected.changes);
        warnings.addAll(
          selected.warnings.where((warning) => !warnings.contains(warning)),
        );
      }
      final ready = gate.completeOutput(next, language: language);
      if (!ready.ok) return OutputPreparation(error: ready.error);
      final notPicked = ids.where((id) => !next.picks.contains(id)).toList();
      if (notPicked.isNotEmpty) {
        return fail(
          'unpicked_actions',
          'ids',
          next.picks,
          notPicked,
          '只交付动作节点选中的 ID。',
        );
      }
      final incompatible = {
        for (final id in ids) id: ?gate.actionProblem(next, id),
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
        nodeResult: NodeResult(
          ready.state,
          changes: List.unmodifiable([...changes, ...ready.changes]),
          warnings: ready.warnings,
        ),
        note: normalized.text,
        noteTruncated: normalized.truncated,
        actions: [for (final id in ids) catalog[id]!],
        warnings: warnings,
      );
    }
    final completed = gate.completeOutput(state, language: language);
    if (!completed.ok) return OutputPreparation(error: completed.error);
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
      for (final action in ids) action: ?gate.actionProblem(state, action),
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
      note: normalized.text,
      noteTruncated: normalized.truncated,
      plan: plan,
      warnings: warnings,
    );
  }
}

/// Deterministic presentation shortening only; never interprets user intent or
/// changes the card data. Callers still reject missing/non-string/empty notes.
({String text, bool truncated}) normalizeOutputNote(
  String input, {
  String language = 'zh',
}) {
  final original = input.trim();
  final runes = original.runes.toList();
  var sentences = 0;
  var end = runes.length;
  bool digit(int r) => r >= 0x30 && r <= 0x39;
  bool punctuation(int r) => '。！？.!?'.runes.contains(r);
  for (var i = 0; i < runes.length; i++) {
    final r = runes[i];
    if (!punctuation(r)) continue;
    if (r == 0x2e &&
        i > 0 &&
        i + 1 < runes.length &&
        digit(runes[i - 1]) &&
        digit(runes[i + 1])) {
      continue;
    }
    sentences++;
    while (i + 1 < runes.length && punctuation(runes[i + 1])) {
      i++;
    }
    if (sentences == 2) {
      end = i + 1;
      // Closing quotes belong to the sentence whose punctuation precedes them.
      while (end < runes.length && '"\'’”」』）)'.runes.contains(runes[end])) {
        end++;
      }
      break;
    }
  }
  var text = String.fromCharCodes(runes.take(end)).trimRight();
  if (language.toLowerCase().startsWith('en')) {
    final words = RegExp(r'\S+').allMatches(text).toList();
    if (words.length > 45) text = text.substring(0, words[44].end);
  } else if (text.runes.length > 120) {
    text = String.fromCharCodes(text.runes.take(120));
  }
  return (text: text, truncated: text != original);
}
