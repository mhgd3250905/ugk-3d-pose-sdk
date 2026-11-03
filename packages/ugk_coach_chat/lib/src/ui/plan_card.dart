import 'package:flutter/material.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_coach_ui/ugk_coach_ui.dart';
import '../theme/chat_polish_tokens.dart';
import '../theme/chat_theme.dart';
import 'coach_ui_adapter.dart';

/// App adapter: domain snapshots and navigation; card rendering lives in SDK.
class PlanCard extends StatelessWidget {
  const PlanCard({
    super.key,
    required this.plan,
    required this.library,
    required this.saved,
    required this.onStart,
    required this.onSave,
    required this.onOpen,
    this.landing = false,
    this.executionTiming,
    this.saveLabel,
    this.savedLabel,
    this.onSaveCopy,
    this.showNumbers = false,
  });
  final coach.TrainingPlan plan;
  final coach.Catalog library;
  final bool saved, landing;
  final bool showNumbers;
  final VoidCallback onStart;
  final VoidCallback onSave, onOpen;
  final String? saveLabel, savedLabel;
  final coach.PlanExecutionTimingCallback? executionTiming;
  final VoidCallback? onSaveCopy;
  static const exerciseHeight = CoachPlanCard.exerciseHeight;
  static const setHeight = CoachPlanCard.setHeight;
  @override
  Widget build(BuildContext context) {
    final heroId = plan.items.firstOrNull?.exerciseId;
    final hero = heroId == null ? null : library[heroId];
    final alphaHero =
        hero != null && toCoachExercise(context, hero).stage.mediaStage.a == 0;
    return KeyedSubtree(
      child: ClipRRect(
        key: ValueKey('plan-clip-${plan.id}'),
        borderRadius: BorderRadius.circular(ChatCardTokens.radius),
        child: withCoachChatPlanSaveUi(
          context,
          CoachPlanCard(
            cutoutTopInset: alphaHero ? 0 : null,
            // This batch's opaque card surface starts at its own top edge.
            surfaceTopInset: 0,
            plan: toCoachRoutine(
              plan,
              library,
              executionTiming: executionTiming,
              doseUnitLabels: ChatTheme.of(context).doseUnitLabels,
            ),
            library: CoachExerciseLibrary([
              for (final id in plan.exerciseIds)
                if (library[id] case final e?) toCoachExercise(context, e),
            ]),
            saved: saved,
            landing: landing,
            showNumbers: showNumbers,
            onStart: (_) => onStart(),
            onSave: onSave,
            onOpen: onOpen,
          ),
          planId: plan.id,
          saveLabel: saveLabel,
          savedLabel: savedLabel,
          onSaveCopy: onSaveCopy,
        ),
      ),
    );
  }
}
