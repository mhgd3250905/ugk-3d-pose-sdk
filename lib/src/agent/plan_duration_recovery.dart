part of 'plan_builder.dart';

/// Selection diagnostics only. This never changes the fitting order, mutates
/// session state, or treats a model-selected action as a user requirement.
extension _DurationRecovery on PlanBuilder {
  Map<String, Object?> _durationRecovery(
    CoachSessionState state,
    TrainingPlan minimumPlan,
    TrainingPlan maximumPlan,
    Map<String, Object?> bounds, {
    String language = 'zh',
    Set<String> confirmedActionIds = const {},
  }) {
    final target = (bounds['targetSec'] as num).toDouble();
    final tolerance = math.min(.1, profile.limits.durationTolerance);
    final lower = target * (1 - tolerance);
    final upper = target * (1 + tolerance);
    final minimum = (bounds['minEstimatedSec'] as num).toDouble();
    final maximum = (bounds['maxEstimatedSec'] as num).toDouble();
    final direction = minimum > upper
        ? 'remove_action'
        : maximum < lower
        ? 'add_action'
        : 'adjust_selection';
    final dose = _recoveryUserDose(state);
    final locked = <String>{
      ...confirmedActionIds.where((id) => catalog[id] != null),
      for (final entry in dose)
        if (entry['actionId'] case final String id) id,
    };
    final removals = <Map<String, Object?>>[];
    final additions = <Map<String, Object?>>[];

    Map<String, Object?> range(TrainingPlan min, TrainingPlan max) {
      final lo = PlanBuilder._duration.estimateSeconds(min, catalog);
      final hi = PlanBuilder._duration.estimateSeconds(max, catalog);
      return {
        'minEstimatedSec': lo,
        'maxEstimatedSec': hi,
        'rangeOverlapsTarget': lo <= upper + 1e-9 && hi >= lower - 1e-9,
      };
    }

    TrainingPlan without(TrainingPlan plan, int blockIndex, int itemIndex) =>
        plan.copyWith(
          blocks: [
            for (final (bi, block) in plan.blocks.indexed)
              if (bi != blockIndex)
                block
              else if (block.items.length > 1)
                PlanBlock(
                  id: block.id,
                  name: block.name,
                  type: block.type,
                  rounds: block.rounds,
                  restBetweenRoundsSeconds: block.restBetweenRoundsSeconds,
                  items: [
                    for (final (ii, item) in block.items.indexed)
                      if (ii != itemIndex) item,
                  ],
                ),
          ],
        );

    var index = 0;
    for (final (bi, block) in minimumPlan.blocks.indexed) {
      for (final (ii, item) in block.items.indexed) {
        index++;
        final min = without(minimumPlan, bi, ii);
        if (min.items.isEmpty ||
            !min.exerciseIds.containsAll(locked) ||
            !_recoveryConstraintsStillMatch(min, dose)) {
          continue;
        }
        final max = without(maximumPlan, bi, ii);
        removals.add({
          'actionId': item.exerciseId,
          'name':
              catalog[item.exerciseId]?.name.of(language) ?? item.exerciseId,
          'blockId': block.id,
          'index': index,
          ...range(min, max),
        });
      }
    }

    final existingIds = minimumPlan.exerciseIds;
    final canAdd = minimumPlan.items.length < profile.limits.maxItems;
    final mainIndex = minimumPlan.blocks.indexWhere(
      (block) =>
          block.type == BlockType.main || block.type == BlockType.circuit,
    );
    var newBlockId = 'duration-recovery-main';
    while (minimumPlan.blocks.any((block) => block.id == newBlockId)) {
      newBlockId = '$newBlockId-1';
    }
    final targetBlockId = mainIndex < 0
        ? newBlockId
        : minimumPlan.blocks[mainIndex].id;
    if (canAdd) {
      for (final drill in catalog.drills) {
        if (existingIds.contains(drill.id) ||
            gate.actionProblem(state, drill.id) != null) {
          continue;
        }
        final itemRange = _recoveryNewItem(drill, targetBlockId, dose);
        if (itemRange == null) continue;
        TrainingPlan withItem(TrainingPlan plan, bool maximum) {
          final added = maximum ? itemRange.$2 : itemRange.$1;
          final blocks = [
            for (final (bi, block) in plan.blocks.indexed)
              if (bi != mainIndex)
                block
              else
                PlanBlock(
                  id: block.id,
                  name: block.name,
                  type: block.type,
                  rounds: block.rounds,
                  restBetweenRoundsSeconds: block.restBetweenRoundsSeconds,
                  items: [...block.items, added],
                ),
          ];
          if (mainIndex < 0) {
            final roundRange = _recoveryNewRounds(targetBlockId, dose);
            if (roundRange == null) return plan;
            blocks.add(
              PlanBlock(
                id: targetBlockId,
                name: 'main',
                type: BlockType.main,
                rounds: maximum ? roundRange.max : roundRange.min,
                restBetweenRoundsSeconds: maximum
                    ? profile.limits.restBetweenRoundsSeconds.max
                    : profile.limits.restBetweenRoundsSeconds.min,
                items: [added],
              ),
            );
            blocks.sort((a, b) => a.type.order.compareTo(b.type.order));
          }
          return plan.copyWith(blocks: blocks);
        }

        if (mainIndex < 0 && _recoveryNewRounds(targetBlockId, dose) == null) {
          continue;
        }
        final min = withItem(minimumPlan, false);
        final max = withItem(maximumPlan, true);
        if (!_recoveryConstraintsStillMatch(min, dose)) continue;
        additions.add({
          'actionId': drill.id,
          'name': drill.name.of(language),
          'blockId': targetBlockId,
          'requiresSearch': !state.seenActionIds.contains(drill.id),
          ...range(min, max),
        });
      }
    }

    // This is deliberately a lower bound: omit transitions and other unlocked
    // work, and use each required action's cheapest legal placement. It may
    // decline to prove a conflict, but must never overstate a locked minimum.
    var lockedMinimum = PlanBuilder._duration.prepSeconds.toDouble();
    var lockedMinimumKnown = true;
    for (final id in locked) {
      final drill = catalog[id];
      if (drill == null) {
        lockedMinimumKnown = false;
        continue;
      }
      final requiredBlocks = {
        for (final entry in dose)
          if (entry['actionId'] == id && entry['blockId'] is String)
            entry['blockId'] as String,
      };
      final possibleBlocks = requiredBlocks.isEmpty
          ? <String>{
              'duration-recovery-required',
              ...minimumPlan.blocks.map((b) => b.id),
            }
          : requiredBlocks;
      double? cheapest;
      for (final blockId in possibleBlocks) {
        final item = _recoveryNewItem(drill, blockId, dose)?.$1;
        if (item == null) continue;
        final work = const PlanDuration(prepSeconds: 0, transitionSeconds: 0)
            .estimateSeconds(
              minimumPlan.copyWith(
                blocks: [
                  PlanBlock(
                    id: blockId,
                    name: 'required',
                    type: BlockType.warmup,
                    items: [item],
                  ),
                ],
              ),
              catalog,
            );
        cheapest = cheapest == null ? work : math.min(cheapest, work);
      }
      if (cheapest == null) {
        lockedMinimumKnown = false;
      } else {
        lockedMinimum += cheapest;
      }
    }
    final hasUserLocks = dose.isNotEmpty || confirmedActionIds.isNotEmpty;
    final lockedMinimumExceedsTarget =
        hasUserLocks && lockedMinimumKnown && lockedMinimum > upper + 1e-9;
    final repairPossible = [
      ...removals,
      ...additions,
    ].any((candidate) => candidate['rangeOverlapsTarget'] == true);

    void sort(List<Map<String, Object?>> candidates, bool removing) {
      candidates.sort((a, b) {
        final overlapA = a['rangeOverlapsTarget'] == true ? 0 : 1;
        final overlapB = b['rangeOverlapsTarget'] == true ? 0 : 1;
        if (overlapA != overlapB) return overlapA.compareTo(overlapB);
        final field = removing ? 'minEstimatedSec' : 'maxEstimatedSec';
        final byDuration = (a[field] as num).compareTo(b[field] as num);
        return byDuration == 0
            ? (a['actionId'] as String).compareTo(b['actionId'] as String)
            : removing
            ? byDuration
            : -byDuration;
      });
    }

    sort(removals, true);
    sort(additions, false);
    final english = language.toLowerCase().startsWith('en');
    return {
      ...bounds,
      'status': lockedMinimumExceedsTarget ? 'infeasible' : 'requires_rebuild',
      'targetSec': target,
      'toleranceRatio': tolerance,
      'minEstimatedSec': minimum,
      'maxEstimatedSec': maximum,
      'direction': direction,
      'removeCandidates': removals.take(8).toList(),
      'addCandidates': additions.take(8).toList(),
      'removeCandidateCount': removals.length,
      'addCandidateCount': additions.length,
      'structuralRepairPossible': repairPossible,
      'userConfirmedDose': dose.isNotEmpty,
      'confirmedActionIds': locked.toList()..sort(),
      if (lockedMinimumKnown) 'lockedMinimumSec': lockedMinimum,
      'clarificationAllowed': lockedMinimumExceedsTarget,
      'needsDraftRebuild': !lockedMinimumExceedsTarget,
      if (lockedMinimumExceedsTarget)
        'clarificationProof': 'confirmed_action_minimum_exceeds_target',
      'fix': lockedMinimumExceedsTarget
          ? english
                ? 'The user-confirmed actions alone exceed the time budget at their legal minimum. Ask which confirmed requirement to change.'
                : '仅用户明确锁定动作的合法最小剂量就超过时长上限，增删未确认动作不能消除冲突；询问用户愿意调整哪项已确认要求。'
          : english
          ? 'These bounds describe only this selected combination. Do not ask the user to change their duration. ${direction == 'remove_action'
                ? 'Remove an unconfirmed action'
                : direction == 'add_action'
                ? 'Add a compliant action'
                : 'Change the selected combination'} using the candidates, then submit draft_plan again. Candidates requiring search must first be returned by search_actions. If one change is insufficient, rebuild the unconfirmed selection.'
          : '上下界只描述当前所选组合，不代表用户时长不可行，不要反问改时长。${direction == 'remove_action'
                ? '先删一个未确认动作'
                : direction == 'add_action'
                ? '先加一个合规动作'
                : '调整未确认的动作组合'}，参考候选重新提交 draft_plan；requiresSearch 的候选先用 search_actions 搜索。一次增删仍不够时继续重编未确认组合。',
    };
  }

  List<Map<String, Object?>> _recoveryUserDose(CoachSessionState state) {
    final parameter = state.params['dose'];
    final quote = parameter?.quote?.trim();
    if (parameter == null ||
        parameter.source != 'user' ||
        quote == null ||
        quote.isEmpty ||
        parameter.value is! List ||
        !state.userTurns.any(
          (turn) => turn.turn == parameter.turn && turn.text.contains(quote),
        )) {
      return const [];
    }
    return [
      for (final entry in parameter.value! as List)
        if (entry is Map &&
            entry['field'] is String &&
            {'sets', 'rounds', 'reps', 'seconds'}.contains(entry['field']) &&
            entry['value'] is int &&
            (entry['value'] as int) > 0 &&
            (entry['actionId'] == null || entry['actionId'] is String) &&
            (entry['blockId'] == null || entry['blockId'] is String))
          Map<String, Object?>.from(entry),
    ];
  }

  bool _recoveryConstraintsStillMatch(
    TrainingPlan plan,
    List<Map<String, Object?>> dose,
  ) => dose.every(
    (entry) => plan.blocks.any((block) {
      if (entry['blockId'] != null && entry['blockId'] != block.id) {
        return false;
      }
      if (entry['field'] == 'rounds') {
        return entry['blockId'] != null ||
            block.type == BlockType.main ||
            block.type == BlockType.circuit;
      }
      return block.items.any((item) {
        final parts = item.segments.isEmpty
            ? [item]
            : [for (final part in item.segments) part.toPlanItem(item)];
        return parts.any(
          (part) =>
              (entry['actionId'] == null ||
                  entry['actionId'] == part.exerciseId) &&
              (entry['field'] == 'sets' ||
                  entry['field'] == 'reps' && part.mode == DoseMode.reps ||
                  entry['field'] == 'seconds' && part.mode == DoseMode.time),
        );
      });
    }),
  );

  (PlanItem, PlanItem)? _recoveryNewItem(
    Drill drill,
    String blockId,
    List<Map<String, Object?>> dose,
  ) {
    final sets = _range(drill.doseRange.sets, profile.limits.sets);
    final work = _range(
      drill.defaultDose.mode == DoseMode.reps
          ? drill.doseRange.reps
          : drill.doseRange.seconds,
      drill.defaultDose.mode == DoseMode.reps
          ? profile.limits.reps
          : profile.limits.workSeconds,
    );
    final rest = _range(
      drill.doseRange.restSeconds,
      profile.limits.restSeconds,
    );
    if (sets == null || work == null || rest == null) return null;
    final item = _DraftItem(
      drill,
      sets.min,
      work.min,
      rest.min,
      sets,
      work,
      rest,
    );
    final block = _DraftBlock(
      blockId,
      'main',
      profile.limits.rounds.min,
      [item],
      roundsRange: profile.limits.rounds,
      roundRestRange: profile.limits.restBetweenRoundsSeconds,
    );
    final applicable = [
      for (final entry in dose)
        if ((entry['actionId'] == null || entry['actionId'] == drill.id) &&
            (entry['blockId'] == null || entry['blockId'] == blockId))
          entry,
    ];
    if (_applyDoseConstraints(
      [block],
      applicable,
      profile.limits.rounds,
    ).isNotEmpty) {
      return null;
    }
    final min = item.toPlanItem();
    final max = item.copy()
      ..sets = item.setRange.max
      ..work = item.workRange.max
      ..rest = item.restRange.max;
    return (min, max.toPlanItem());
  }

  IntRange? _recoveryNewRounds(String id, List<Map<String, Object?>> dose) {
    final values = {
      for (final entry in dose)
        if (entry['field'] == 'rounds' &&
            (entry['blockId'] == null || entry['blockId'] == id))
          entry['value'] as int,
    };
    if (values.isEmpty) return profile.limits.rounds;
    if (values.length != 1 || !profile.limits.rounds.contains(values.single)) {
      return null;
    }
    return IntRange(values.single, values.single);
  }
}
