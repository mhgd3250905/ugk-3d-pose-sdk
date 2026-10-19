/// 这一轮的训练条件（App 从界面 / 设置 / 上一轮里得到）。全部可选，模型会追问缺的。
library;

import '../profile/coach_profile.dart';

class CoachContext {
  const CoachContext({
    this.scene,
    this.equipment = const {},
    this.avoid = const {},
    this.level,
    this.minutes,
    this.goal,
    this.language = 'zh',
    this.notes = const [],
  });

  /// home / office / gym；null = 未知（模型可追问，校验按 profile.defaultScene）。
  final String? scene;

  /// 用户额外有的器械（场所默认器械由 profile 补上）。
  final Set<String> equipment;

  /// 要保护的部位（膝 / 腰 / 肩 / 手腕 …）。
  final Set<String> avoid;
  final int? level;
  final int? minutes;
  final String? goal;
  final String language;

  /// App 想告诉模型的其他事实（如「用户刚完成一次训练」），逐条进上下文。
  final List<String> notes;

  String sceneOr(CoachProfile p) => scene ?? p.defaultScene;

  /// 实际可用器械 = 场所默认 + 用户额外。返回 null 表示「全部器械」（健身房）。
  Set<String>? availableEquipment(CoachProfile p) {
    final rule = p.sceneRule(sceneOr(p));
    if (rule.allEquipment) return null;
    return {...rule.assumedEquipment, ...equipment};
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
    avoid: avoid ?? this.avoid,
    level: level ?? this.level,
    minutes: minutes ?? this.minutes,
    goal: goal ?? this.goal,
    language: language ?? this.language,
    notes: notes ?? this.notes,
  );

  Map<String, Object?> toJson() => {
    if (scene != null) 'scene': scene,
    if (equipment.isNotEmpty) 'equipment': equipment.toList(),
    if (avoid.isNotEmpty) 'avoid': avoid.toList(),
    if (level != null) 'level': level,
    if (minutes != null) 'minutes': minutes,
    if (goal != null) 'goal': goal,
    'language': language,
    if (notes.isNotEmpty) 'notes': notes,
  };
}
