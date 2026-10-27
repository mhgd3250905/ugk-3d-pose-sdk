/// 这一轮的训练条件（App 从界面 / 设置 / 上一轮里得到）。全部可选，模型会追问缺的。
library;

import '../profile/coach_profile.dart';

class CoachContext {
  const CoachContext({
    this.scene,
    this.equipment,
    Set<String>? avoid,
    this.level,
    this.minutes,
    this.goal,
    this.language = 'zh',
    this.notes = const [],
  }) : avoid = avoid ?? const {},
       hasExplicitAvoid = avoid != null;

  /// home / office / gym；null = 未知（模型可追问，校验按 profile.defaultScene）。
  final String? scene;

  /// 用户或宿主明确可用的器械；null 表示未知，空集合表示明确徒手。
  /// 校验未知器械时按徒手处理，不把计划声明当作用户拥有的事实。
  final Set<String>? equipment;

  /// 要保护的部位（膝 / 腰 / 肩 / 手腕 …）。
  final Set<String> avoid;

  /// Whether the host explicitly supplied [avoid] for this update. An
  /// explicit empty set can clear host restrictions; an omitted value cannot.
  /// The persistent source of truth for host limits is the session state.
  final bool hasExplicitAvoid;
  final int? level;
  final int? minutes;
  final String? goal;
  final String language;

  /// App 想告诉模型的其他事实（如「用户刚完成一次训练」），逐条进上下文。
  final List<String> notes;

  String sceneOr(CoachProfile p) => scene ?? p.defaultScene;

  /// 用户明确提供的器械；未知时按徒手处理。
  ///
  /// [p]、[scene] 与 [declared] 为旧调用保留；场所和计划声明都不会
  /// 自动增加可用器械，也不会因健身房场景推定所有器械可用。
  Set<String>? availableEquipment(
    CoachProfile p, {
    String? scene,
    Iterable<String> declared = const [],
  }) {
    return {...?equipment};
  }

  CoachContext copyWith({
    String? scene,
    Set<String>? equipment,
    Set<String>? avoid,
    int? level,
    int? minutes,
    String? goal,
    String? language,
    List<String>? notes,
  }) => CoachContext(
    scene: scene ?? this.scene,
    equipment: equipment ?? this.equipment,
    avoid: avoid ?? (hasExplicitAvoid ? this.avoid : null),
    level: level ?? this.level,
    minutes: minutes ?? this.minutes,
    goal: goal ?? this.goal,
    language: language ?? this.language,
    notes: notes ?? this.notes,
  );

  Map<String, Object?> toJson() => {
    if (scene != null) 'scene': scene,
    if (equipment != null) 'equipment': equipment!.toList(),
    if (avoid.isNotEmpty) 'avoid': avoid.toList(),
    if (level != null) 'level': level,
    if (minutes != null) 'minutes': minutes,
    if (goal != null) 'goal': goal,
    'language': language,
    if (notes.isNotEmpty) 'notes': notes,
  };
}
