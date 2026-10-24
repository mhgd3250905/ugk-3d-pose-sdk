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
  });
  final String id;
  final String name;
  final String poster;
  final CoachMediaPalette stage;
  final String categoryLabel;
  final List<String> cues;
  final String? cutout;
  final String? stillCutout;
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

enum CoachQuestionMode { text, choice }

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
  });
  final String id;
  final String question;
  final CoachQuestionMode mode;
  final List<String> options;
  final bool multiple;
  final bool answered;
  final List<String> answeredChoices;
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
