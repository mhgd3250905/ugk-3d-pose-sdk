/// Bridge between Coach fitting and the player's existing phase builder.
library;

import 'package:ugk_coach/ugk_coach.dart';

import 'session.dart';

/// Uses the very same [SessionBuilder] for playback and Coach duration checks.
extension SessionBuilderPlanExecutionTiming on SessionBuilder {
  /// Sums the actual phases produced by [phases], without estimating overhead.
  ///
  /// Pass this method as Coach's synchronous execution-timing callback. Use the
  /// player's actual builder and its already-loaded rhythm and voice settings;
  /// this method performs no I/O. Self-paced work remains an estimate (估算).
  /// Hosts should assert that [PlanExecutionTiming.totalSeconds] equals their
  /// player's phase sum for an identical candidate and configuration.
  PlanExecutionTiming executionTiming(TrainingPlan plan) {
    final timeline = phases(plan);
    final blockSeconds = List<double>.filled(plan.blocks.length, 0);
    var total = 0.0;
    var containsManualCounting = false;
    for (final phase in timeline) {
      if (!phase.seconds.isFinite || phase.seconds < 0) {
        throw const PlanExecutionTimingException(
          code: 'invalid_execution_timing',
          reason: 'invalid_phase_seconds',
        );
      }
      if (phase.blockIndex < -1 || phase.blockIndex >= plan.blocks.length) {
        throw const PlanExecutionTimingException(
          code: 'invalid_execution_timing',
          reason: 'invalid_phase_block_index',
        );
      }
      total += phase.seconds;
      if (phase.blockIndex >= 0) {
        blockSeconds[phase.blockIndex] += phase.seconds;
      }
      containsManualCounting |= phase.isWork && phase.selfPaced;
    }
    return PlanExecutionTiming(
      totalSeconds: total,
      blocks: [
        for (final (index, block) in plan.blocks.indexed)
          PlanBlockExecutionTiming(
            blockId: block.id,
            seconds: blockSeconds[index],
          ),
      ],
      containsManualCounting: containsManualCounting,
    );
  }
}
