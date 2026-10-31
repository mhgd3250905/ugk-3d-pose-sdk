/// Host-supplied measurements of the player's actual execution timeline.
library;

import 'training_plan.dart';

/// Measures a candidate with the same timeline builder used by the player.
///
/// This callback is synchronous, pure and must perform no I/O. It must not
/// mutate [plan], and repeated calls with the same plan and player configuration
/// must produce the same result. Preparation, authored leads, side switches and
/// every other phase belong to the returned timeline, rather than SDK estimates.
/// Manual-counting phases still contribute their timeline estimates and must set
/// [PlanExecutionTiming.containsManualCounting] so the result is labelled 估算.
typedef PlanExecutionTimingCallback =
    PlanExecutionTiming Function(TrainingPlan plan);

/// The duration of one candidate in the host player's actual timeline.
class PlanExecutionTiming {
  const PlanExecutionTiming({
    required this.totalSeconds,
    required this.blocks,
    this.containsManualCounting = false,
  });

  /// Sum of all timeline phases, including phases without a block assignment.
  final double totalSeconds;

  /// One entry per input block, in the same order as [TrainingPlan.blocks].
  ///
  /// These entries account for phases assigned to each block. Unassigned phases
  /// such as preparation remain in [totalSeconds], so the sum may be smaller.
  final List<PlanBlockExecutionTiming> blocks;

  /// Whether any work phase is manually counted; the duration is then 估算.
  final bool containsManualCounting;
}

/// Duration attributed by the host timeline to a single plan block.
class PlanBlockExecutionTiming {
  const PlanBlockExecutionTiming({
    required this.blockId,
    required this.seconds,
  });

  final String blockId;
  final double seconds;
}

/// A safe diagnostic for a failed host callback or an invalid measurement.
///
/// Callback exceptions are never copied into this diagnostic: they may contain
/// host configuration or other private data. Callers must reject delivery rather
/// than fall back to card duration when this exception is raised.
class PlanExecutionTimingException implements Exception {
  const PlanExecutionTimingException({
    required this.code,
    required this.reason,
  });

  final String code;
  final String reason;

  @override
  String toString() => 'PlanExecutionTimingException($code, $reason)';
}

/// Invokes [callback] once and validates its complete result.
///
/// Invalid measurements and every thrown object are converted into a safe
/// [PlanExecutionTimingException]. No card-duration fallback is performed.
/// The returned block list is immutable and detached from the callback's list.
PlanExecutionTiming evaluatePlanExecutionTiming(
  TrainingPlan plan,
  PlanExecutionTimingCallback callback,
) {
  final PlanExecutionTiming result;
  try {
    result = callback(plan);
  } catch (_) {
    throw const PlanExecutionTimingException(
      code: 'execution_timing_callback_failed',
      reason: 'callback_threw',
    );
  }

  Never invalid(String reason) => throw PlanExecutionTimingException(
    code: 'invalid_execution_timing',
    reason: reason,
  );

  if (!result.totalSeconds.isFinite || result.totalSeconds < 0) {
    invalid('invalid_total_seconds');
  }
  if (result.blocks.length != plan.blocks.length) {
    invalid('block_count_mismatch');
  }
  final ids = <String>{};
  var assignedSeconds = 0.0;
  for (var index = 0; index < result.blocks.length; index++) {
    final block = result.blocks[index];
    if (block.blockId.trim().isEmpty) invalid('empty_block_id');
    if (!ids.add(block.blockId)) invalid('duplicate_block_id');
    if (block.blockId != plan.blocks[index].id) {
      invalid('block_order_mismatch');
    }
    if (!block.seconds.isFinite || block.seconds < 0) {
      invalid('invalid_block_seconds');
    }
    assignedSeconds += block.seconds;
  }
  if (assignedSeconds > result.totalSeconds + 1e-9) {
    invalid('block_seconds_exceed_total');
  }
  return PlanExecutionTiming(
    totalSeconds: result.totalSeconds,
    blocks: List.unmodifiable(result.blocks),
    containsManualCounting: result.containsManualCounting,
  );
}
