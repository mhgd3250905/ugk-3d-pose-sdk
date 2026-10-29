part of 'plan_builder.dart';

extension FocusedPlanDraft on PlanBuilder {
  DraftResult _draftFocused(
    CoachSessionState original,
    CoachSessionState working,
    TrainingPlan current,
    List<_DraftBlock> selected, {
    required String title,
    required int minutes,
    required String legacyGoal,
    required List<CoachNodeState> changes,
    required Set<String> extras,
    required List<String> notes,
    required String language,
  }) {
    // draft_plan expresses an ordered selection, not the full stored dose.
    // Match repeated occurrences independently so an unchanged item carries
    // its complete saved segments, notes and dose into the next version.
    final usedBlocks = <int>{};
    final usedItems = <(int, int)>{};
    final blocks = <PlanBlock>[];
    final originals = current.items.toList();
    final indexed = selected.any(
      (block) => block.items.any((item) => item.sourceIndex != null),
    );
    for (final block in selected) {
      final oldIndex = current.blocks.indexed
          .where(
            (entry) =>
                !usedBlocks.contains(entry.$1) &&
                (entry.$2.type == BlockType.circuit
                        ? 'main'
                        : entry.$2.type.name) ==
                    block.kind,
          )
          .map((entry) => entry.$1)
          .firstOrNull;
      if (oldIndex != null) usedBlocks.add(oldIndex);
      final previous = oldIndex == null ? null : current.blocks[oldIndex];
      PlanItem restore(_DraftItem item) {
        if (item.sourceIndex case final int index) return originals[index - 1];
        if (indexed) return item.toPlanItem();
        final order = [
          ?oldIndex,
          for (var bi = 0; bi < current.blocks.length; bi++)
            if (bi != oldIndex) bi,
        ];
        for (final bi in order) {
          final candidates = current.blocks[bi].items;
          for (var ii = 0; ii < candidates.length; ii++) {
            if (!usedItems.contains((bi, ii)) &&
                candidates[ii].exerciseId == item.drill.id) {
              usedItems.add((bi, ii));
              return candidates[ii];
            }
          }
        }
        return item.toPlanItem();
      }

      blocks.add(
        PlanBlock(
          id: previous?.id ?? block.id,
          name: previous?.name ?? block.kind,
          type: previous?.type ?? BlockType.values.byName(block.kind),
          rounds: previous?.rounds ?? block.rounds,
          restBetweenRoundsSeconds:
              previous?.restBetweenRoundsSeconds ?? block.roundRest,
          items: [for (final item in block.items) restore(item)],
        ),
      );
    }
    final candidate = const PlanCodec().decode({
      ...current.toJson(),
      'source': 'ai',
      'title': title,
      'goal': legacyGoal,
      'blocks': [for (final block in blocks) block.toJson()],
    });
    if (extras.isNotEmpty) {
      final added = gate.addDraftPicks(working, extras, language: language);
      if (!added.ok) return DraftResult(original, error: added.error);
      working = added.state;
      changes.addAll(added.changes);
    }
    // Only an actual duration/dose request invokes the fitter. Merely changing
    // a selected action must not reset all other saved items to catalogue doses.
    if (minutes != current.targetMinutes || working.params['dose'] != null) {
      final fitted = refit(working, candidate, language: language);
      return DraftResult(
        fitted.planId == null ? original : fitted.state,
        planId: fitted.planId,
        version: fitted.version,
        estimateMinutes: fitted.estimateMinutes,
        fitLog: fitted.fitLog,
        legacyGoal: legacyGoal,
        changes: [...changes, ...fitted.changes],
        notes: [...notes, ...fitted.notes],
        feasibility: fitted.feasibility,
        durationErrorPercent: fitted.durationErrorPercent,
        error: fitted.error,
      );
    }
    final plan = const PlanCodec().decode({
      ...candidate.toJson(),
      'scene': working.params['scene']?.value ?? candidate.scene,
      'level': working.params['level']?.value ?? candidate.level,
      'equipment': {
        for (final item in candidate.items)
          for (final id
              in item.segments.isEmpty
                  ? [item.exerciseId]
                  : [for (final segment in item.segments) segment.exerciseId])
            ...catalog[id]!.equipment,
      }.where((id) => id != 'none').toList(),
      if (working.params['limits']?.value case final List<Object?> limits)
        'avoid': [
          for (final code in limits)
            gate.tags.limitValue(code as String) ?? code,
        ],
    });
    final versions = original.plans[current.id]!;
    final version = versions.map((v) => v.version).reduce(math.max) + 1;
    final seconds = PlanBuilder._duration.estimateSeconds(plan, catalog);
    final next = working.copyWith(
      activePlanId: current.id,
      plans: {
        ...working.plans,
        current.id: [
          ...versions,
          CoachPlanVersion(
            version: version,
            plan: plan.toJson(),
            estimateSec: seconds,
            fitLog: const [],
            operation: 'edit',
            createdAtTurn: original.userTurns.lastOrNull?.turn ?? 0,
          ),
        ],
      },
    );
    return DraftResult(
      next,
      planId: current.id,
      version: version,
      estimateMinutes: (seconds / 6).round() / 10,
      legacyGoal: legacyGoal,
      changes: changes,
      notes: [...notes, '已保留未改动作的原剂量和分段结构。'],
      durationErrorPercent:
          (seconds - minutes * 60).abs() / (minutes * 60) * 100,
      structure: [
        for (final block in plan.blocks)
          {
            'blockId': block.id,
            'kind': block.type.name,
            'rounds': block.rounds,
            'items': block.items.length,
          },
      ],
    );
  }
}
