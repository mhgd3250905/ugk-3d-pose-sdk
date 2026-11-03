import 'package:flutter/foundation.dart';

/// Which sides a library action trains, from the catalogue `unilateral` flag.
enum TrainingLibrarySide { any, bilateral, unilateral }

/// One library selection: the search text plus every facet the browser
/// offers. Facet values are the catalogue facet keys the browser shows
/// ([TrainingLibraryFilter.all] means "no restriction").
///
/// Hosts pass one as `initialFilter` to open the library pre-filtered, for
/// example from a muscle detail page (`TrainingLibraryFilter(muscle: 'lats')`).
@immutable
class TrainingLibraryFilter {
  const TrainingLibraryFilter({
    this.query = '',
    this.equipment = all,
    this.bodyPart = all,
    this.type = all,
    this.level,
    this.side = TrainingLibrarySide.any,
    this.muscle,
  });

  /// The "no restriction" value of [equipment], [bodyPart] and [type].
  static const all = '全部';

  /// Free text matched against Chinese and English names and aliases.
  final String query;

  /// [all], `徒手`, `需要器械` or one catalogue equipment id (`dumbbell`).
  final String equipment;

  /// [all] or one body part (`胸` `背` `肩` `手臂` `核心` `臀腿` `全身`).
  final String bodyPart;

  /// [all] or one library type (`力量`, `拉伸放松`).
  final String type;

  /// Catalogue difficulty (1 入门, 2 基础, 3 进阶); null is any.
  final int? level;
  final TrainingLibrarySide side;

  /// One catalogue muscle-group id (`glute-max`); null is any.
  final String? muscle;

  /// Facet restrictions in force (the search text is not counted).
  int get activeCount =>
      (equipment != all ? 1 : 0) +
      (bodyPart != all ? 1 : 0) +
      (type != all ? 1 : 0) +
      (level != null ? 1 : 0) +
      (side != TrainingLibrarySide.any ? 1 : 0) +
      (muscle != null ? 1 : 0);

  bool get isEmpty => query.trim().isEmpty && activeCount == 0;

  TrainingLibraryFilter copyWith({
    String? query,
    String? equipment,
    String? bodyPart,
    String? type,
    int? level,
    bool clearLevel = false,
    TrainingLibrarySide? side,
    String? muscle,
    bool clearMuscle = false,
  }) => TrainingLibraryFilter(
    query: query ?? this.query,
    equipment: equipment ?? this.equipment,
    bodyPart: bodyPart ?? this.bodyPart,
    type: type ?? this.type,
    level: clearLevel ? null : level ?? this.level,
    side: side ?? this.side,
    muscle: clearMuscle ? null : muscle ?? this.muscle,
  );

  /// Keeps only the search text.
  TrainingLibraryFilter cleared() => TrainingLibraryFilter(query: query);

  @override
  bool operator ==(Object other) =>
      other is TrainingLibraryFilter &&
      other.query == query &&
      other.equipment == equipment &&
      other.bodyPart == bodyPart &&
      other.type == type &&
      other.level == level &&
      other.side == side &&
      other.muscle == muscle;

  @override
  int get hashCode =>
      Object.hash(query, equipment, bodyPart, type, level, side, muscle);

  @override
  String toString() =>
      'TrainingLibraryFilter(query: $query, equipment: $equipment, '
      'bodyPart: $bodyPart, type: $type, level: $level, side: ${side.name}, '
      'muscle: $muscle)';
}
