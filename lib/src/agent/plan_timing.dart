part of 'plan_builder.dart';

/// Re-times a previously admitted card without flattening its performed parts.
/// The existing heuristic changes only its usual rounds/sets stages here;
/// segment work remains unchanged except for source-validated dose parameters.
extension TrustedCardTiming on PlanBuilder {
  DraftResult refit(
    CoachSessionState state,
    TrainingPlan saved, {
    String language = 'zh',
  }) {
    DraftResult fail(String code, Object? actual) => DraftResult(
      state,
      error: nodeError(code, 'plan', '已收录且符合当前条件的原计划', actual, '重新选择合法动作。'),
    );
    final minutes = state.params['minutes']?.value;
    final previous = state.plans[saved.id];
    if (minutes is! int ||
        minutes <= 0 ||
        previous?.isNotEmpty != true ||
        state.activePlanId != saved.id) {
      return fail('invalid_refit', saved.id);
    }
    final turn = state.userTurns.lastOrNull?.turn ?? 0;
    final focused = state.focusPlanId == saved.id;
    if ((state.lastOperationRequestTurn ?? state.params['operation']?.turn) ==
            turn &&
        state.params['operation']?.value == 'replace_all') {
      return fail('replace_too_similar', '原动作不能代表整体换一套');
    }
    final actualIds = <String>{
      for (final item in saved.items)
        if (item.segments.isEmpty)
          item.exerciseId
        else
          for (final segment in item.segments) segment.exerciseId,
    };
    for (final id in actualIds) {
      if (!state.seenActionIds.contains(id) ||
          gate.actionProblem(state, id) != null) {
        return fail('incompatible_action', id);
      }
    }
    final blocks = <_DraftBlock>[];
    final doseBlocks = <_DraftBlock>[];
    final groups = <String, List<(PlanItem, List<_DraftItem>)>>{};
    for (final block in saved.blocks) {
      final kind = block.type == BlockType.circuit ? 'main' : block.type.name;
      final shadows = <_DraftItem>[];
      final works = <_DraftItem>[];
      final blockGroups = <(PlanItem, List<_DraftItem>)>[];
      for (final item in block.items) {
        final parent = catalog[item.exerciseId];
        if (parent == null) return fail('incompatible_action', item.exerciseId);
        final sets = _range(
          block.type == BlockType.circuit ? null : parent.doseRange.sets,
          profile.limits.sets,
        );
        final rest = _range(
          parent.doseRange.restSeconds,
          profile.limits.restSeconds,
        );
        if (sets == null || rest == null) {
          return fail('invalid_dose_range', item.exerciseId);
        }
        shadows.add(
          _DraftItem(
            parent,
            item.sets,
            0,
            item.restSeconds,
            sets,
            const IntRange(0, 0),
            rest,
          ),
        );
        final parts = item.segments.isEmpty
            ? [item]
            : [for (final s in item.segments) s.toPlanItem(item)];
        final proxies = <_DraftItem>[];
        for (final part in parts) {
          final drill = catalog[part.exerciseId]!;
          if (part.mode != drill.defaultDose.mode ||
              part.perSide != drill.unilateral) {
            return fail('incompatible_action', part.exerciseId);
          }
          final work = _range(
            part.mode == DoseMode.reps
                ? drill.doseRange.reps
                : drill.doseRange.seconds,
            part.mode == DoseMode.reps
                ? profile.limits.reps
                : profile.limits.workSeconds,
          );
          if (work == null) return fail('invalid_dose_range', part.exerciseId);
          final amount = part.mode == DoseMode.reps
              ? part.reps
              : part.workSeconds;
          if (amount == null) {
            return fail('invalid_saved_dose', part.exerciseId);
          }
          proxies.add(
            _DraftItem(
              drill,
              item.sets,
              amount,
              item.restSeconds,
              sets,
              work,
              rest,
            ),
          );
        }
        works.addAll(proxies);
        blockGroups.add((item, proxies));
      }
      _DraftBlock wrap(List<_DraftItem> items) => _DraftBlock(
        block.id,
        kind,
        block.rounds,
        items,
        roundsRange: profile.limits.rounds,
        roundRestRange: profile.limits.restBetweenRoundsSeconds,
        roundRest: block.restBetweenRoundsSeconds,
      );
      blocks.add(wrap(shadows));
      doseBlocks.add(wrap(works));
      groups[block.id] = blockGroups;
    }
    final conflicts = _applyDoseConstraints(
      doseBlocks,
      state.params['dose']?.value,
      profile.limits.rounds,
    );
    for (var bi = 0; bi < blocks.length; bi++) {
      blocks[bi].rounds = doseBlocks[bi].rounds;
      blocks[bi].roundsRange = doseBlocks[bi].roundsRange;
      for (var ii = 0; ii < blocks[bi].items.length; ii++) {
        final shadow = blocks[bi].items[ii];
        final proxies = groups[blocks[bi].id]![ii].$2;
        final low = proxies
            .map((p) => p.setRange.min)
            .fold(shadow.setRange.min, math.max);
        final high = proxies
            .map((p) => p.setRange.max)
            .fold(shadow.setRange.max, math.min);
        if (low > high) {
          conflicts.add({
            'blockId': blocks[bi].id,
            'actionId': shadow.drill.id,
            'field': 'sets',
            'reason': 'segmented_group_sets_conflict',
          });
        } else {
          shadow.setRange = IntRange(low, high);
          shadow.sets = shadow.sets.clamp(low, high);
        }
        if (focused && groups[blocks[bi].id]![ii].$1.segments.isEmpty) {
          // A focused ordinary item can be re-timed from its saved work dose;
          // segmented groups keep their independent proxy work unchanged.
          shadow.work = proxies.single.work;
          shadow.workRange = proxies.single.workRange;
        }
      }
    }
    TrainingPlan render(List<_DraftBlock> source, [bool? extreme]) {
      int amount(_DraftItem p) => extreme == null
          ? p.work
          : extreme
          ? p.workRange.max
          : p.workRange.min;
      return const PlanCodec().decode({
        ...saved.toJson(),
        'targetMinutes': minutes,
        'scene': state.params['scene']?.value ?? saved.scene,
        'level': state.params['level']?.value ?? saved.level,
        'avoid': state.params['limits'] == null
            ? saved.avoid.toList()
            : [
                for (final code
                    in state.params['limits']!.value! as List<Object?>)
                  gate.tags.limitValue(code as String) ?? code,
              ],
        'equipment': {
          for (final id in actualIds) ...catalog[id]!.equipment,
        }.where((e) => e != 'none').toList(),
        'blocks': [
          for (var bi = 0; bi < source.length; bi++)
            {
              ...saved.blocks[bi].toJson(),
              'rounds': source[bi].rounds,
              'restBetweenRoundsSeconds': source[bi].roundRest,
              'items': [
                for (var ii = 0; ii < source[bi].items.length; ii++)
                  (() {
                    final (original, proxies) = groups[source[bi].id]![ii];
                    final shadow = source[bi].items[ii];
                    return original
                        .copyWith(
                          sets: shadow.sets,
                          restSeconds: shadow.rest,
                          reps:
                              original.segments.isEmpty &&
                                  original.mode == DoseMode.reps
                              ? amount(focused ? shadow : proxies.single)
                              : null,
                          workSeconds:
                              original.segments.isEmpty &&
                                  original.mode == DoseMode.time
                              ? amount(focused ? shadow : proxies.single)
                              : null,
                          segments: [
                            for (
                              var si = 0;
                              si < original.segments.length;
                              si++
                            )
                              PlanSegment(
                                id: original.segments[si].id,
                                exerciseId: original.segments[si].exerciseId,
                                mode: original.segments[si].mode,
                                reps:
                                    original.segments[si].mode == DoseMode.reps
                                    ? amount(proxies[si])
                                    : original.segments[si].reps,
                                workSeconds:
                                    original.segments[si].mode == DoseMode.time
                                    ? amount(proxies[si])
                                    : original.segments[si].workSeconds,
                                holdSeconds: original.segments[si].holdSeconds,
                                label: original.segments[si].label,
                                rhythm: original.segments[si].rhythm,
                              ),
                          ],
                        )
                        .toJson();
                  })(),
              ],
            },
        ],
      });
    }

    double estimate(List<_DraftBlock> source) =>
        PlanBuilder._duration.estimateSeconds(render(source), catalog);
    final target = minutes * 60.0;
    final bounds = _timingBounds(
      blocks,
      target,
      estimate,
      estimateExtreme: (source, maximum) => PlanBuilder._duration
          .estimateSeconds(render(source, maximum), catalog),
    );
    if (conflicts.isNotEmpty || bounds['status'] == 'infeasible') {
      return DraftResult(
        state,
        feasibility: {
          ...bounds,
          if (conflicts.isNotEmpty) ...{
            'status': 'infeasible',
            'reason': 'explicit_dose_conflict',
            'conflicts': conflicts,
          },
          'fix': '请说明已确认条件的冲突，询问用户愿意调整时长还是剂量。',
        },
      );
    }
    final log = <Map<String, Object?>>[];
    _fit(blocks, target, estimate, log);
    final plan = render(blocks);
    final seconds = PlanBuilder._duration.estimateSeconds(plan, catalog);
    final version = previous!.map((v) => v.version).reduce(math.max) + 1;
    return DraftResult(
      state.copyWith(
        plans: {
          ...state.plans,
          saved.id: [
            ...previous,
            CoachPlanVersion(
              version: version,
              plan: plan.toJson(),
              estimateSec: seconds,
              fitLog: log,
              createdAtTurn: turn,
              operation: 'edit',
            ),
          ],
        },
      ),
      planId: saved.id,
      version: version,
      estimateMinutes: (seconds / 6).round() / 10,
      fitLog: log,
      durationErrorPercent: (seconds - target).abs() / target * 100,
      notes: [
        language.toLowerCase().startsWith('en')
            ? 'Preserved the saved segments and re-timed their groups with confirmed doses.'
            : '已保留原分段结构，并按已确认剂量重新配组数与轮数。',
      ],
    );
  }
}

/// Alternates available primary groups without changing the selected set or
/// the relative order of exercises from the same group. Single-part targets
/// naturally retain their original sequence.
void _stableMainOrder(_DraftBlock block) {
  if (block.kind != 'main' || block.items.length < 2) return;
  final pending = List<_DraftItem>.of(block.items);
  final ordered = <_DraftItem>[];
  String? previous;
  while (pending.isNotEmpty) {
    var chosen = pending.indexWhere(
      (item) => item.drill.muscleGroups.firstOrNull != previous,
    );
    if (chosen < 0) chosen = 0;
    final item = pending.removeAt(chosen);
    ordered.add(item);
    previous = item.drill.muscleGroups.firstOrNull;
  }
  block.items
    ..clear()
    ..addAll(ordered);
}

/// Locks only source-validated user dose parameters. The parameter layer owns
/// quote/source validation; restoring an invalid value never relaxes a range.
List<Map<String, Object?>> _applyDoseConstraints(
  List<_DraftBlock> blocks,
  Object? raw,
  IntRange supportedRounds,
) {
  if (raw == null) return const [];
  if (raw is! List) {
    return [
      {'field': 'dose', 'reason': 'invalid_saved_constraints'},
    ];
  }
  final conflicts = <Map<String, Object?>>[];
  final constraints = <Map<Object?, Object?>>[];
  for (final value in raw) {
    if (value is! Map || value['value'] is! int || value['field'] is! String) {
      conflicts.add({'field': 'dose', 'reason': 'invalid_saved_constraint'});
    } else {
      constraints.add(value.cast<Object?, Object?>());
    }
  }
  final matched = <Map<Object?, Object?>>{};
  int? resolve(String field, _DraftBlock block, [_DraftItem? item]) {
    final applicable = constraints
        .where(
          (entry) =>
              entry['field'] == field &&
              (entry['blockId'] == null || entry['blockId'] == block.id) &&
              (entry['actionId'] == null ||
                  entry['actionId'] == item?.drill.id),
        )
        .toList();
    if (applicable.isEmpty) return null;
    matched.addAll(applicable);
    int specificity(Map<Object?, Object?> entry) =>
        (entry['actionId'] == null ? 0 : 2) +
        (entry['blockId'] == null ? 0 : 1);
    final mostSpecific = applicable.map(specificity).reduce(math.max);
    final values = applicable
        .where((entry) => specificity(entry) == mostSpecific)
        .map((entry) => entry['value'] as int)
        .toSet();
    if (values.length != 1) {
      conflicts.add({
        'blockId': block.id,
        'actionId': item?.drill.id,
        'field': field,
        'reason': 'conflicting_explicit_values',
        'values': values.toList(),
      });
      return null;
    }
    return values.single;
  }

  for (final block in blocks) {
    final rounds =
        block.kind == 'main' ||
            constraints.any(
              (entry) =>
                  entry['field'] == 'rounds' && entry['blockId'] == block.id,
            )
        ? resolve('rounds', block)
        : null;
    if (rounds != null) {
      if (supportedRounds.contains(rounds)) {
        block.rounds = rounds;
        block.roundsRange = IntRange(rounds, rounds);
      } else {
        conflicts.add({
          'blockId': block.id,
          'field': 'rounds',
          'actual': rounds,
          'allowed': [supportedRounds.min, supportedRounds.max],
        });
      }
    }
    for (final item in block.items) {
      for (final field in ['sets', 'reps', 'seconds']) {
        final timed = item.drill.defaultDose.mode == DoseMode.time;
        if ((field == 'reps' && timed) || (field == 'seconds' && !timed)) {
          for (final entry in constraints.where(
            (entry) =>
                entry['field'] == field &&
                entry['actionId'] == item.drill.id &&
                (entry['blockId'] == null || entry['blockId'] == block.id),
          )) {
            matched.add(entry);
            conflicts.add({
              'blockId': block.id,
              'actionId': item.drill.id,
              'field': field,
              'actual': entry['value'],
              'reason': 'catalogue_dose_mode',
            });
          }
          continue;
        }
        final value = resolve(field, block, item);
        if (value == null) continue;
        final range = field == 'sets' ? item.setRange : item.workRange;
        if (!range.contains(value)) {
          conflicts.add({
            'blockId': block.id,
            'actionId': item.drill.id,
            'field': field,
            'actual': value,
            'allowed': [range.min, range.max],
          });
        } else if (field == 'sets') {
          item.sets = value;
          item.setRange = IntRange(value, value);
        } else {
          item.work = value;
          item.workRange = IntRange(value, value);
        }
      }
    }
  }
  for (final entry in constraints.where((entry) => !matched.contains(entry))) {
    conflicts.add({
      'field': entry['field'],
      'actionId': entry['actionId'],
      'blockId': entry['blockId'],
      'reason': 'no_selected_action_matches_constraint',
    });
  }
  return conflicts;
}

/// Duration is monotone in every legal positive dose component. These extrema
/// prove only interval impossibility; an interior gap or the bounded heuristic
/// failing to find a closer point is deliberately not called infeasible.
Map<String, Object?> _timingBounds(
  List<_DraftBlock> blocks,
  double target,
  double Function(List<_DraftBlock>) estimate, {
  double Function(List<_DraftBlock>, bool)? estimateExtreme,
}) {
  List<_DraftBlock> extreme(bool maximum) => [
    for (final block in blocks)
      block.cloneWithout(const {})
        ..rounds = maximum ? block.roundsRange.max : block.roundsRange.min
        ..roundRest = maximum
            ? block.roundRestRange.max
            : block.roundRestRange.min
        ..items.forEach((item) {
          item.sets = maximum ? item.setRange.max : item.setRange.min;
          item.work = maximum ? item.workRange.max : item.workRange.min;
          item.rest = maximum ? item.restRange.max : item.restRange.min;
        }),
  ];
  final minimum =
      estimateExtreme?.call(extreme(false), false) ?? estimate(extreme(false));
  final maximum =
      estimateExtreme?.call(extreme(true), true) ?? estimate(extreme(true));
  final reason = minimum > target * 1.1
      ? 'minimum_exceeds_target'
      : maximum < target * .9
      ? 'maximum_below_target'
      : null;
  return {
    'status': reason == null ? 'not_proven_infeasible' : 'infeasible',
    'reason': ?reason,
    'targetSec': target,
    'toleranceRatio': .1,
    'boundBasis':
        'catalogue/profile ranges including segment work, rest and rounds; confirmed dose locked',
    'minEstimatedSec': minimum,
    'maxEstimatedSec': maximum,
  };
}
