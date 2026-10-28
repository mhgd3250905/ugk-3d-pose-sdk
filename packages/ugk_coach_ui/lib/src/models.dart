import 'package:flutter/material.dart';

/// Resolved media colours, supplied by the host alongside its media assets.
@immutable
class CoachMediaPalette {
  const CoachMediaPalette({
    required this.mediaStage,
    required this.onStage,
    required this.onStageMuted,
  });
  final Color mediaStage;
  final Color onStage;
  final Color onStageMuted;
}

@immutable
class CoachExercise {
  const CoachExercise({
    required this.id,
    required this.name,
    required this.poster,
    required this.stage,
    this.categoryLabel = '',
    this.cues = const [],
    this.cutout,
    this.stillCutout,
    this.levelLabel = '',
    this.equipmentLabel = '',
  });
  final String id;
  final String name;
  final String poster;
  final CoachMediaPalette stage;
  final String categoryLabel;
  final List<String> cues;
  final String? cutout;
  final String? stillCutout;

  /// Localized catalogue facts; the recommendation never infers these from
  /// the model's explanation. Existing routine adapters may leave them empty.
  final String levelLabel;
  final String equipmentLabel;
}

/// Trusted host media selected by the card, including its still during flight.
/// Returning null from the host builder keeps the SDK's existing asset image.
@immutable
class CoachMediaRequest {
  const CoachMediaRequest({
    required this.exercise,
    required this.asset,
    required this.cutout,
    required this.still,
    required this.landing,
    required this.fit,
    required this.alignment,
    this.semanticLabel,
  });
  final CoachExercise exercise;
  final String asset;
  final bool cutout, still, landing;
  final BoxFit fit;
  final Alignment alignment;
  final String? semanticLabel;
}

/// Resolves trusted App catalog entries, never model supplied asset paths.
class CoachExerciseLibrary {
  CoachExerciseLibrary(Iterable<CoachExercise> exercises)
    : _exercises = {for (final e in exercises) e.id: e};
  final Map<String, CoachExercise> _exercises;
  CoachExercise? tryGet(String id) => _exercises[id];
}

@immutable
class CoachRoutineItem {
  const CoachRoutineItem({
    required this.exerciseId,
    required this.dose,
    String? detailDose,
  }) : detailDose = detailDose ?? dose;
  final String exerciseId;

  /// Already localized by the App, including units and circuit semantics.
  final String dose;
  final String detailDose;
  String doseText() => dose;
}

@immutable
class CoachRoutine {
  const CoachRoutine({
    required this.id,
    required this.title,
    required this.items,
    required this.durationLabel,
    required this.gearLabel,
    required this.levelLabel,
    required this.metaLabel,
    this.adjustmentsLabel,
  });
  final String id;
  final String title;
  final List<CoachRoutineItem> items;
  final String durationLabel;
  final String gearLabel;
  final String levelLabel;
  final String metaLabel;
  final String? adjustmentsLabel;
}

@immutable
class CoachBubbleData {
  const CoachBubbleData({
    required this.id,
    required this.text,
    this.isUser = false,
    this.options = const [],
    this.chosen,
    this.caption,
  });
  final String id;
  final String text;
  final bool isUser;
  final List<String> options;
  final int? chosen;

  /// Optional localized context, e.g. a safety check step.
  final String? caption;
}

enum CoachQuestionMode { text, choice, form }

@immutable
class CoachQuestionField {
  const CoachQuestionField({
    required this.key,
    required this.label,
    required this.options,
    this.multiple = false,
    this.initialSelections = const [],
    this.previousSelections = const [],
    this.optionsByScene = const {},
  });
  final String key, label;
  final List<String> options;
  final bool multiple;

  /// Values already known for this request; unknown options are ignored.
  final List<String> initialSelections;

  /// Previously used values among [initialSelections], labelled “上次”.
  final List<String> previousSelections;

  /// Equipment options by scene; empty means that no filter was supplied.
  final Map<String, List<String>> optionsByScene;
}

/// UI-only snapshot. The App validates and submits answers to its agent.
@immutable
class CoachQuestionData {
  const CoachQuestionData({
    required this.id,
    required this.question,
    required this.mode,
    this.options = const [],
    this.multiple = false,
    this.answered = false,
    this.answeredChoices = const [],
    this.fields = const [],
    this.skipLabel = '直接出方案',
    this.showSkip = true,
    this.submitLabel,
    this.answeredForm = const {},
    this.isConfirmation = false,
    this.focus,
    this.defaultSelections = const {},
  });
  final String id;
  final String question;
  final CoachQuestionMode mode;
  final List<String> options;
  final bool multiple;
  final bool answered;
  final List<String> answeredChoices;
  final List<CoachQuestionField> fields;
  final String skipLabel;
  final bool showSkip;
  final String? submitLabel;

  /// Confirmed form values for restoring an answered conversation card.
  final Map<String, List<String>> answeredForm;

  /// Opt in to the compact training-condition confirmation card.
  final bool isConfirmation;
  final String? focus;

  /// Effective defaults for the summary after “按默认来”.
  final Map<String, List<String>> defaultSelections;
}

typedef CoachOriginRect = Rect? Function();

Rect? coachRectOf(BuildContext? context) {
  if (context == null || !context.mounted) return null;
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  try {
    return box.localToGlobal(Offset.zero) & box.size;
  } on Object {
    return null;
  }
}
