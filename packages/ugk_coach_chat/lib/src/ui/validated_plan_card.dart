import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;

import 'plan_card.dart';

/// The AI boundary accepts a gate result, then adapts it for the App's trainer.
class ValidatedPlanCard extends StatelessWidget {
  const ValidatedPlanCard({
    super.key,
    required this.validatedPlan,
    required this.library,
    required this.isSaved,
    required this.onStart,
    required this.onSave,
    required this.onOpen,
    this.landing = false,
    this.executionTiming,
    this.updatingSavedPlan = false,
    this.savedOverride,
    this.onSaveCopy,
  });

  final coach.ValidatedPlan validatedPlan;
  final coach.Catalog library;
  final bool Function(coach.TrainingPlan) isSaved;
  final ValueChanged<coach.TrainingPlan> onStart;
  final ValueChanged<coach.TrainingPlan> onSave;
  final ValueChanged<coach.TrainingPlan> onOpen;
  final bool landing;
  final coach.PlanExecutionTimingCallback? executionTiming;
  final bool updatingSavedPlan;
  final bool? savedOverride;
  final ValueChanged<coach.TrainingPlan>? onSaveCopy;

  @override
  Widget build(BuildContext context) {
    final plan = validatedPlan.plan;
    return PlanCard(
      plan: plan,
      library: library,
      executionTiming: executionTiming,
      saved: savedOverride ?? isSaved(plan),
      landing: landing,
      saveLabel: updatingSavedPlan ? '更新到我的计划' : null,
      savedLabel: updatingSavedPlan ? '已更新' : null,
      onStart: () => onStart(plan),
      onSave: () => onSave(plan),
      onSaveCopy: onSaveCopy == null ? null : () => onSaveCopy!(plan),
      onOpen: () => onOpen(plan),
    );
  }
}
