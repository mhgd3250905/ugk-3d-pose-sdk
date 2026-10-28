/// Pure validation of final cards, before the caller commits output state.
library;

import '../catalog/catalog.dart';
import '../plan/plan_codec.dart';
import '../plan/plan_validator.dart';
import '../plan/training_plan.dart';
import '../profile/coach_profile.dart';
import '../tools/coach_tools.dart';
import 'agent_task.dart';
import 'catalog_data_gaps.dart';
import 'node_gates.dart';
import 'plan_builder.dart';
import 'plan_checker.dart';
import 'session_state.dart';

class OutputPreparation {
  const OutputPreparation({
    this.nodeResult,
    this.note = '',
    this.noteTruncated = false,
    this.notices = const [],
    this.unavailable = false,
    this.unavailableMessage,
    this.needsUserChoice = false,
    this.feasibility,
    this.plan,
    this.actions,
    this.warnings = const [],
    this.warningDetails = const [],
    this.error,
  });
  final NodeResult? nodeResult;
  final String note;
  final bool noteTruncated;
  final List<String> notices;
  final bool unavailable;
  final String? unavailableMessage;
  final bool needsUserChoice;
  final Map<String, Object?>? feasibility;
  final TrainingPlan? plan;
  final List<Drill>? actions;
  final List<String> warnings;
  final List<Map<String, Object?>> warningDetails;
  final Map<String, Object?>? error;
  bool get ok => error == null;
}

class OutputGate {
  OutputGate(
    this.profile,
    this.catalog, {
    this.extraRules = const [],
    this.enforceDrillDoseRange = false,
  }) : gate = NodeGates(profile, catalog, minPicks: profile.minActions);
  final CoachProfile profile;
  final Catalog catalog;
  final List<PlanRule> extraRules;
  final bool enforceDrillDoseRange;
  final NodeGates gate;

  OutputPreparation prepare(
    CoachSessionState state,
    String tool,
    Object? arguments, {
    String language = 'zh',
  }) {
    var next = state;
    final changes = <CoachNodeState>[];
    final notices = <String>[];
    final warnings = <String>[];
    OutputPreparation fail(Map<String, Object?> error) => OutputPreparation(
      nodeResult: NodeResult(
        state.copyWith(
          recommendationHintShown: next.recommendationHintShown,
          emittedWarningCodes: next.emittedWarningCodes,
        ),
      ),
      notices: notices,
      error: error,
    );
    if (tool != CoachTools.showActions && tool != CoachTools.showPlan) {
      return fail(
        nodeError(
          'invalid_output_tool',
          'tool',
          [CoachTools.showActions, CoachTools.showPlan],
          tool,
          '调用对应输出工具。',
        ),
      );
    }
    if (arguments is! Map) {
      return fail(
        nodeError(
          'invalid_arguments',
          'arguments',
          '输出参数对象',
          arguments,
          '提供所选动作或当前计划。',
        ),
      );
    }
    final requiredType = tool == CoachTools.showPlan ? 'plan' : 'recommend';
    final expected = requiredType == 'plan'
        ? AgentTask.planNodes
        : AgentTask.recommendNodes;
    final currentIndex =
        next.task?.nodes.indexWhere((node) => node.status == 'current') ?? -1;
    final incompletePast =
        currentIndex >= 0 &&
        next.task!.nodes
            .take(currentIndex)
            .any((node) => node.status != 'done' && node.status != 'updated');
    if (next.task?.type != requiredType ||
        incompletePast ||
        next.task!.nodes.map((n) => n.id).join(',') != expected.join(',')) {
      final repairingSameTask = next.task?.type == requiredType;
      // A malformed graph can be rebuilt without changing the task's source
      // boundary. A different task must use AgentTask's real reuse rules;
      // copying the previous pool here would bypass seen-action provenance.
      final started = AgentTask.start(next, requiredType);
      next = repairingSameTask
          ? started.state.copyWith(
              seenActionIds: state.seenActionIds,
              picks: state.picks,
              activePlanId: state.activePlanId,
              emittedWarningCodes: state.emittedWarningCodes,
            )
          : started.state;
      changes.addAll(started.changes);
      notices.add('已按模型选择的交付工具准备对应任务节点。');
    }
    final parameter = gate.check(next, 'parameters', language: language);
    if (!parameter.ok) return fail(parameter.error!);
    next = parameter.state;
    changes.addAll(parameter.changes);
    final note = arguments['note'];
    final normalized = normalizeOutputNote(
      note is String ? note : '',
      language: language,
    );
    if (note is! String || note.trim().isEmpty) notices.add('说明为空，已按卡片交付。');
    final extra = arguments.keys.where(
      (key) => !{
        'note',
        tool == CoachTools.showPlan ? 'plan_id' : 'ids',
      }.contains(key),
    );
    if (extra.isNotEmpty) notices.add('已忽略输出中的额外字段：${extra.join('、')}。');
    if (tool == CoachTools.showActions) {
      final value = arguments['ids'] ?? const [];
      if (value is! List || value.any((id) => id is! String)) {
        return fail(
          nodeError('invalid_ids', 'ids', '动作ID数组', value, '提供已选动作的ID。'),
        );
      }
      final ids = value.cast<String>().toSet().toList();
      if (ids.length != value.length) notices.add('已合并重复的推荐动作ID。');
      if (ids.isEmpty && gate.recommendationCandidates(next).isEmpty) {
        return OutputPreparation(
          nodeResult: NodeResult(next.copyWith(clearTask: true)),
          unavailable: true,
          unavailableMessage: language.toLowerCase().startsWith('en')
              ? 'No actions match the current conditions. Would you like to adjust them?'
              : '当前条件没有合规动作，是否愿意调整条件？',
          notices: notices,
        );
      }
      final focused = gate.validateRecommendationPicks(
        next,
        ids,
        language: language,
      );
      if (!focused.ok) return fail(focused.error!);
      next = focused.state;
      notices.addAll(focused.notices);
      final bad = {for (final id in ids) id: ?gate.actionProblem(next, id)};
      final unseen = ids
          .where((id) => !next.seenActionIds.contains(id))
          .toList();
      if (unseen.isNotEmpty) {
        return fail(
          nodeError('unseen_actions', 'ids', '已搜索动作', unseen, '先搜索这些动作。'),
        );
      }
      if (bad.isNotEmpty) {
        return fail(
          nodeError(
            'incompatible_actions',
            'ids',
            '当前合规动作',
            bad,
            '重新选择符合条件的动作。',
          ),
        );
      }
      if (ids.isEmpty) {
        return fail(
          nodeError(
            'no_actions_selected',
            'ids',
            '已选择的合规动作',
            ids,
            '请选择一个或多个动作。',
          ),
        );
      }
      final selected = gate.check(
        next.copyWith(picks: ids),
        'actions',
        picks: ids,
        language: language,
      );
      if (!selected.ok) return fail(selected.error!);
      next = selected.state.copyWith(picks: ids);
      changes.addAll(selected.changes);
      warnings.addAll(selected.warnings);
      final ready = gate.completeOutput(next, language: language);
      if (!ready.ok) return fail(ready.error!);
      changes.addAll(ready.changes);
      return OutputPreparation(
        nodeResult: NodeResult(ready.state, changes: changes),
        note: normalized.text,
        noteTruncated: normalized.truncated,
        notices: notices,
        actions: [for (final id in ids) catalog[id]!],
        warnings: warnings,
      );
    }
    final active =
        next.activePlanId ??
        (next.legacyPlanFallback && next.plans.length == 1
            ? next.plans.keys.single
            : null);
    if (active == null || next.plans[active]?.isNotEmpty != true) {
      return fail(
        nodeError(
          'missing_plan',
          'plan_id',
          '已选择动作的当前草稿',
          null,
          '先通过 draft_plan 提供所选动作。',
        ),
      );
    }
    if (arguments['plan_id'] != active) notices.add('已使用当前计划的最新版本。');
    var version = next.plans[active]!.last;
    final decoded = const PlanCodec().decodeStrict(version.plan);
    if (!decoded.ok) {
      return fail(
        nodeError(
          'invalid_plan',
          'plan',
          '有效的已存计划',
          decoded.issues.map((e) => e.message).toList(),
          '当前计划数据无法恢复。',
        ),
      );
    }
    var plan = decoded.plan!;
    final ids = <String>{
      for (final item in plan.items)
        if (item.segments.isEmpty)
          item.exerciseId
        else
          for (final segment in item.segments) segment.exerciseId,
    };
    final unseen = ids.where((id) => !next.seenActionIds.contains(id)).toList();
    final bad = {for (final id in ids) id: ?gate.actionProblem(next, id)};
    if (unseen.isNotEmpty) {
      return fail(
        nodeError('unseen_actions', 'plan', '已搜索动作', unseen, '先搜索所选动作。'),
      );
    }
    if (bad.isNotEmpty) {
      return fail(
        nodeError(
          'incompatible_actions',
          'plan',
          '符合当前条件的动作',
          bad,
          '重新选择符合条件的动作。',
        ),
      );
    }
    final actualEquipment = <String>{
      for (final id in ids) ...?catalog[id]?.equipment,
    }..remove('none');
    final minutes = next.params['minutes']?.value as int;
    final needsRefit =
        plan.targetMinutes != minutes || !_matchesConfirmedDose(next, plan);
    if (needsRefit) {
      final reopened = gate.parametersChanged(
        next,
        language: language,
        changedFields: const {'minutes', 'dose'},
      );
      next = reopened.state;
      changes.addAll(reopened.changes);
      final selected = gate.check(
        next,
        'actions',
        picks: ids.toList(),
        planId: active,
        language: language,
      );
      if (!selected.ok) return fail(selected.error!);
      next = selected.state;
      changes.addAll(selected.changes);
      final builder = PlanBuilder(
        profile,
        catalog,
        minPicks: profile.minActions,
      );
      final refitted = plan.items.any((item) => item.segments.isNotEmpty)
          ? builder.refit(next, plan, language: language)
          : builder.draft(
              next,
              {
                'plan_id': active,
                'title': plan.title,
                'blocks': [
                  for (final block in plan.blocks)
                    {
                      'kind': block.type == BlockType.circuit
                          ? 'main'
                          : block.type.name,
                      'items': [
                        for (final item in block.items) {'id': item.exerciseId},
                      ],
                    },
                ],
              },
              newPlanId: active,
              language: language,
            );
      if (!refitted.ok) return fail(refitted.error!);
      notices.addAll(refitted.notes);
      if (refitted.feasibility != null) {
        return OutputPreparation(
          nodeResult: NodeResult(next, changes: changes),
          needsUserChoice: true,
          unavailableMessage: language.toLowerCase().startsWith('en')
              ? 'The confirmed duration and doses cannot be satisfied together. Which condition would you like to adjust?'
              : '已确认的时长和剂量不能同时满足。你愿意调整哪项条件？',
          feasibility: refitted.feasibility,
          notices: notices,
        );
      }
      next = refitted.state;
      changes.addAll(refitted.changes);
      version = next.plans[active]!.last;
      plan = const PlanCodec().decode(version.plan);
      notices.add('已保留所选动作并按当前时长及已确认剂量重新配时。');
      if (refitted.durationErrorPercent != null) {
        notices.add(
          '配时误差 ${refitted.durationErrorPercent!.toStringAsFixed(1)}%。',
        );
      }
    }
    if (plan.equipment.toSet().difference(actualEquipment).isNotEmpty ||
        actualEquipment.difference(plan.equipment.toSet()).isNotEmpty) {
      plan = const PlanCodec().decode({
        ...plan.toJson(),
        'equipment': actualEquipment.toList(),
      });
      version = CoachPlanVersion(
        version: version.version,
        plan: plan.toJson(),
        estimateSec: const PlanDuration().estimateSeconds(plan, catalog),
        fitLog: version.fitLog,
        createdAtTurn: version.createdAtTurn,
        operation: version.operation,
      );
      next = next.copyWith(
        plans: {
          ...next.plans,
          active: [
            ...next.plans[active]!.take(next.plans[active]!.length - 1),
            version,
          ],
        },
      );
      notices.add('已从实际动作同步卡片器械字段。');
    }
    final selected = gate.check(
      next,
      'actions',
      picks: ids.toList(),
      planId: active,
      language: language,
    );
    if (!selected.ok) return fail(selected.error!);
    next = selected.state;
    changes.addAll(selected.changes);
    final planned = gate.check(
      next,
      'planning',
      planId: active,
      language: language,
    );
    if (!planned.ok) return fail(planned.error!);
    next = planned.state;
    changes.addAll(planned.changes);
    if (version.check?['ok'] != true ||
        next.task!.nodes.any(
          (node) => node.id == 'review' && node.status == 'current',
        )) {
      final checked = PlanChecker(
        profile,
        catalog,
        minPicks: profile.minActions,
        extraRules: extraRules,
        enforceDrillDoseRange: enforceDrillDoseRange,
      ).check(next, active);
      next = checked.state;
      if (!checked.ok) return fail(checked.toJson());
      changes.addAll(checked.changes);
    }
    final reviewed = gate.check(
      next,
      'review',
      planId: active,
      language: language,
    );
    if (!reviewed.ok) return fail(reviewed.error!);
    next = reviewed.state;
    changes.addAll(reviewed.changes);
    final ready = gate.completeOutput(next, language: language);
    if (!ready.ok) return fail(ready.error!);
    changes.addAll(ready.changes);
    final savedWarnings = next.plans[active]!.last.check?['warnings'];
    final gaps = CatalogDataGaps(gate.tags);
    if (savedWarnings is List) {
      warnings.addAll(
        gaps.filterWarnings(next, savedWarnings.whereType<String>()),
      );
    }
    return OutputPreparation(
      nodeResult: NodeResult(ready.state, changes: changes),
      note: normalized.text,
      noteTruncated: normalized.truncated,
      notices: notices,
      plan: plan,
      warnings: warnings,
      warningDetails: [
        for (final detail
            in next.plans[active]!.last.check?['warningDetails'] as List? ??
                const [])
          if (detail is Map &&
              (detail['message'] is! String ||
                  gaps.filterWarnings(next, [
                    detail['message'] as String,
                  ]).isNotEmpty))
            detail.cast<String, Object?>(),
      ],
    );
  }
}

/// Tests explicit dose values without interpreting user text. Unscoped rounds
/// apply to main blocks, just as they do in the shared timer.
bool _matchesConfirmedDose(CoachSessionState state, TrainingPlan plan) {
  final raw = state.params['dose']?.value;
  if (raw == null) return true;
  if (raw is! List) return false;
  if (raw.any((value) => value is! Map)) return false;
  final constraints = raw.cast<Map<Object?, Object?>>();
  final matched = <Map<Object?, Object?>>{};
  bool matches(String field, PlanBlock block, int? actual, [String? id]) {
    final applicable = constraints
        .where(
          (entry) =>
              entry['field'] == field &&
              (entry['blockId'] == null || entry['blockId'] == block.id) &&
              (entry['actionId'] == null || entry['actionId'] == id),
        )
        .toList();
    if (applicable.isEmpty) return true;
    matched.addAll(applicable);
    int priority(Map<Object?, Object?> entry) =>
        (entry['actionId'] == null ? 0 : 2) +
        (entry['blockId'] == null ? 0 : 1);
    final ordered = List<Map<Object?, Object?>>.of(applicable)
      ..sort((a, b) => priority(b).compareTo(priority(a)));
    final values = ordered
        .where((entry) => priority(entry) == priority(ordered.first))
        .map((entry) => entry['value'])
        .toSet();
    return values.length == 1 && values.single == actual;
  }

  for (final block in plan.blocks) {
    if ((block.type == BlockType.main ||
            block.type == BlockType.circuit ||
            constraints.any(
              (entry) =>
                  entry['field'] == 'rounds' && entry['blockId'] == block.id,
            )) &&
        !matches('rounds', block, block.rounds)) {
      return false;
    }
    for (final item in block.items) {
      final parts = item.segments.isEmpty
          ? [item]
          : [for (final segment in item.segments) segment.toPlanItem(item)];
      for (final part in parts) {
        if (!matches('sets', block, item.sets, part.exerciseId) ||
            !(part.mode == DoseMode.reps
                ? matches('reps', block, part.reps, part.exerciseId)
                : matches(
                    'seconds',
                    block,
                    part.workSeconds,
                    part.exerciseId,
                  ))) {
          return false;
        }
      }
    }
  }
  return matched.length == constraints.length;
}

/// Deterministic presentation shortening only; never interprets user intent or
/// changes the card data. An empty presentation note does not block a card.
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
