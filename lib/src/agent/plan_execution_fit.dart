part of 'plan_builder.dart';

Map<String, Object?> _executionTimingJson(PlanExecutionTiming timing) => {
  'totalSeconds': timing.totalSeconds,
  'blocks': [
    for (final block in timing.blocks)
      {'blockId': block.blockId, 'seconds': block.seconds},
  ],
  'containsManualCounting': timing.containsManualCounting,
  'isEstimate': timing.containsManualCounting,
  if (timing.containsManualCounting) 'label': '估算',
};

double _durationErrorPercent(
  double card,
  PlanExecutionTiming? execution,
  double target,
) =>
    math.max(
      (card - target).abs(),
      execution == null ? 0 : (execution.totalSeconds - target).abs(),
    ) /
    target *
    100;

/// Keeps the two clocks separate. The SDK measures only its existing card;
/// all execution measurements come from the host's actual timeline callback.
extension _ExecutionFit on PlanBuilder {
  PlanExecutionTiming? _executionOf(TrainingPlan plan) =>
      executionTiming == null
      ? null
      : evaluatePlanExecutionTiming(plan, executionTiming!);

  double _executionSeconds(TrainingPlan plan) =>
      _executionOf(plan)?.totalSeconds ??
      PlanBuilder._duration.estimateSeconds(plan, catalog);

  // The unchanged dose search minimizes the worse of the two clock errors.
  // Returning that clock's actual seconds also supplies its search direction.
  // No preparation/lead/switch duration is derived here.
  double _fitSeconds(TrainingPlan plan, double target) {
    final card = PlanBuilder._duration.estimateSeconds(plan, catalog);
    final execution = _executionOf(plan)?.totalSeconds;
    if (execution == null) return card;
    return (card - target).abs() > (execution - target).abs()
        ? card
        : execution;
  }

  Map<String, Object?> _executionBounds(
    TrainingPlan minimum,
    TrainingPlan maximum,
    double target,
    Map<String, Object?> legacy,
  ) {
    if (executionTiming == null) return legacy;
    // A circuit changes semantics at round 1: subsequent rounds execute one
    // set per occurrence. Test each legal branch's endpoint with the callback,
    // including combinations across blocks, instead of assuming all-max doses
    // necessarily produce the longest player timeline.
    PlanExecutionTiming extreme(bool maximumDuration) {
      final base = maximumDuration ? maximum : minimum;
      PlanExecutionTiming? chosen;
      final selected = <PlanBlock>[];
      void visit(int index) {
        if (index == base.blocks.length) {
          final measured = _executionOf(
            base.copyWith(blocks: List.of(selected)),
          )!;
          if (chosen == null ||
              (maximumDuration
                  ? measured.totalSeconds > chosen!.totalSeconds
                  : measured.totalSeconds < chosen!.totalSeconds)) {
            chosen = measured;
          }
          return;
        }
        final block = base.blocks[index];
        final low = minimum.blocks[index].rounds;
        final high = maximum.blocks[index].rounds;
        final rounds = <int>{block.rounds};
        if (block.type == BlockType.circuit && low == 1 && high > 1) {
          rounds
            ..clear()
            ..add(1)
            ..add(maximumDuration ? high : 2);
        }
        for (final count in rounds) {
          selected.add(
            PlanBlock(
              id: block.id,
              name: block.name,
              type: block.type,
              rounds: count,
              restBetweenRoundsSeconds: block.restBetweenRoundsSeconds,
              items: block.items,
            ),
          );
          visit(index + 1);
          selected.removeLast();
        }
      }

      visit(0);
      return chosen!;
    }

    final minTiming = extreme(false);
    final maxTiming = extreme(true);
    final minCard = PlanBuilder._duration.estimateSeconds(minimum, catalog);
    final maxCard = PlanBuilder._duration.estimateSeconds(maximum, catalog);
    final tolerance = math.min(.1, profile.limits.durationTolerance);
    final lower = target * (1 - tolerance);
    final upper = target * (1 + tolerance);
    final reason = minTiming.totalSeconds > upper + 1e-9
        ? 'minimum_exceeds_target'
        : maxTiming.totalSeconds < lower - 1e-9
        ? 'maximum_below_target'
        : minCard > upper + 1e-9
        ? 'card_minimum_exceeds_target'
        : maxCard < lower - 1e-9
        ? 'card_maximum_below_target'
        : null;
    return {
      for (final entry in legacy.entries)
        if (entry.key != 'reason') entry.key: entry.value,
      'status': reason == null ? 'not_proven_infeasible' : 'infeasible',
      'reason': ?reason,
      'targetSec': target,
      'toleranceRatio': tolerance,
      'boundBasis':
          'host_player_timeline_and_card; catalogue/profile legal ranges; confirmed dose locked',
      'minEstimatedSec': minTiming.totalSeconds,
      'maxEstimatedSec': maxTiming.totalSeconds,
      'minExecutedSec': minTiming.totalSeconds,
      'maxExecutedSec': maxTiming.totalSeconds,
      'minCardSec': minCard,
      'maxCardSec': maxCard,
      'minimumExecutionTiming': _executionTimingJson(minTiming),
      'maximumExecutionTiming': _executionTimingJson(maxTiming),
    };
  }

  DraftResult _executionTimingRejected(
    CoachSessionState state,
    PlanExecutionTimingException error, {
    required String language,
  }) => DraftResult(
    state,
    error: nodeError(
      error.code,
      'plan.executionTiming',
      'valid synchronous player timeline with ordered block durations',
      {'reason': error.reason},
      language.toLowerCase().startsWith('en')
          ? 'The host execution-timing callback failed. Repair it before delivering a plan; do not fall back to card duration.'
          : '宿主执行时长回调失败；修复回调后再交付计划，禁止回退到卡片时长。',
    ),
  );
}
