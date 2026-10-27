/// 每个 App 一份 profile：用哪些动作、侧重什么、场所规则、剂量硬限、提示词版本。
/// 三个 App 共用同一套内核，差异只在 profile（和 App 自己的 UI）。
library;

import '../catalog/catalog.dart';
import '../util/json.dart';

/// 动作筛选：ids / idPrefixes / apps / tags / categories 取并集（全空 = 全库），再减 exclude。
class DrillSelector {
  const DrillSelector({
    this.ids = const {},
    this.idPrefixes = const [],
    this.apps = const {},
    this.tags = const {},
    this.categories = const {},
    this.exclude = const {},
    this.excludeTags = const {},
  });

  final Set<String> ids;
  final List<String> idPrefixes;
  final Set<String> apps;
  final Set<String> tags;
  final Set<String> categories;
  final Set<String> exclude;
  final Set<String> excludeTags;

  bool get selectsAll => ids.isEmpty && idPrefixes.isEmpty && apps.isEmpty && tags.isEmpty && categories.isEmpty;

  bool matches(Drill d) {
    if (exclude.contains(d.id) || d.tags.any(excludeTags.contains)) return false;
    if (selectsAll) return true;
    return ids.contains(d.id) ||
        idPrefixes.any(d.id.startsWith) ||
        d.apps.any(apps.contains) ||
        d.tags.any(tags.contains) ||
        categories.contains(d.category);
  }

  factory DrillSelector.fromJson(Object? raw) {
    final j = asMap(raw);
    return DrillSelector(
      ids: asStringList(j['ids']).toSet(),
      idPrefixes: asStringList(j['idPrefixes']),
      apps: asStringList(j['apps']).toSet(),
      tags: asStringList(j['tags']).toSet(),
      categories: asStringList(j['categories']).toSet(),
      exclude: asStringList(j['exclude']).toSet(),
      excludeTags: asStringList(j['excludeTags']).toSet(),
    );
  }

  Map<String, Object?> toJson() => {
    if (ids.isNotEmpty) 'ids': ids.toList(),
    if (idPrefixes.isNotEmpty) 'idPrefixes': idPrefixes,
    if (apps.isNotEmpty) 'apps': apps.toList(),
    if (tags.isNotEmpty) 'tags': tags.toList(),
    if (categories.isNotEmpty) 'categories': categories.toList(),
    if (exclude.isNotEmpty) 'exclude': exclude.toList(),
    if (excludeTags.isNotEmpty) 'excludeTags': excludeTags.toList(),
  };
}

/// 场所规则。内置场所不假设用户拥有任何器械。
class SceneRule {
  const SceneRule({
    this.label,
    this.assumedEquipment = const {},
    this.allEquipment = false,
    this.acceptDrillScenes = const {},
    this.forbidFloor = false,
    this.forbidPositions = const {},
  });

  final String? label;

  /// 用户没说也默认有的器械。
  final Set<String> assumedEquipment;

  /// 默认有全部器械（健身房）。
  final bool allEquipment;

  /// 动作 scenes 含其中任一即可用（空 = 只认场所自己的名字）。
  final Set<String> acceptDrillScenes;

  /// 不接受着地体位（taxonomy.positions.floor=true）。
  final bool forbidFloor;
  final Set<String> forbidPositions;

  factory SceneRule.fromJson(Object? raw) {
    final j = asMap(raw);
    return SceneRule(
      label: asString(j['label']),
      assumedEquipment: asStringList(j['assumedEquipment']).toSet(),
      allEquipment: asBool(j['allEquipment']) ?? false,
      acceptDrillScenes: asStringList(j['acceptDrillScenes']).toSet(),
      forbidFloor: asBool(j['forbidFloor']) ?? false,
      forbidPositions: asStringList(j['forbidPositions']).toSet(),
    );
  }

  Map<String, Object?> toJson() => {
    if (label != null) 'label': label,
    'assumedEquipment': assumedEquipment.toList(),
    if (allEquipment) 'allEquipment': true,
    if (acceptDrillScenes.isNotEmpty) 'acceptDrillScenes': acceptDrillScenes.toList(),
    if (forbidFloor) 'forbidFloor': true,
    if (forbidPositions.isNotEmpty) 'forbidPositions': forbidPositions.toList(),
  };

  static const defaults = <String, SceneRule>{
    'home': SceneRule(label: '居家', acceptDrillScenes: {'home'}),
    'office': SceneRule(label: '办公室', acceptDrillScenes: {'office'}, forbidFloor: true),
    'gym': SceneRule(label: '健身房', acceptDrillScenes: {'gym', 'home'}),
  };
}

/// TrainingPlan v1 的剂量硬限（docs/plan-schema.md）。动作自己的 doseRange 更窄时以它为准。
class PlanLimits {
  const PlanLimits({
    this.sets = const IntRange(1, 6),
    this.reps = const IntRange(1, 30),
    this.workSeconds = const IntRange(10, 120),
    this.restSeconds = const IntRange(0, 180),
    this.rounds = const IntRange(1, 6),
    this.restBetweenRoundsSeconds = const IntRange(0, 300),
    this.minutes = const IntRange(3, 60),
    this.maxItems = 24,
    this.durationTolerance = 0.4,
  });

  final IntRange sets;
  final IntRange reps;
  final IntRange workSeconds;
  final IntRange restSeconds;
  final IntRange rounds;
  final IntRange restBetweenRoundsSeconds;
  final IntRange minutes;
  final int maxItems;

  /// 估算时长偏离 targetMinutes 超过这个比例给出警告（不判失败）。
  final double durationTolerance;

  factory PlanLimits.fromJson(Object? raw) {
    final j = asMap(raw);
    const d = PlanLimits();
    return PlanLimits(
      sets: IntRange.tryParse(j['sets']) ?? d.sets,
      reps: IntRange.tryParse(j['reps']) ?? d.reps,
      workSeconds: IntRange.tryParse(j['workSeconds']) ?? d.workSeconds,
      restSeconds: IntRange.tryParse(j['restSeconds']) ?? d.restSeconds,
      rounds: IntRange.tryParse(j['rounds']) ?? d.rounds,
      restBetweenRoundsSeconds: IntRange.tryParse(j['restBetweenRoundsSeconds']) ?? d.restBetweenRoundsSeconds,
      minutes: IntRange.tryParse(j['minutes']) ?? d.minutes,
      maxItems: asInt(j['maxItems']) ?? d.maxItems,
      durationTolerance: asDouble(j['durationTolerance']) ?? d.durationTolerance,
    );
  }

  Map<String, Object?> toJson() => {
    'sets': sets.toJson(),
    'reps': reps.toJson(),
    'workSeconds': workSeconds.toJson(),
    'restSeconds': restSeconds.toJson(),
    'rounds': rounds.toJson(),
    'restBetweenRoundsSeconds': restBetweenRoundsSeconds.toJson(),
    'minutes': minutes.toJson(),
    'maxItems': maxItems,
    'durationTolerance': durationTolerance,
  };
}

/// App 专属 skill（Agent 版，渐进式披露）：挂到虚拟文件系统 `<name>/SKILL.md`，
/// [files] 是它引用的资源文件（相对 `<name>/` 的路径 → 全文）。
class ProfileSkill {
  const ProfileSkill({required this.name, required this.description, required this.content, this.files = const {}});
  final String name;
  final String description;
  final String content;
  final Map<String, String> files;

  static ProfileSkill? tryParse(Object? raw) {
    final j = asMap(raw);
    final name = asString(j['name']);
    final content = asString(j['content']);
    if (name == null || name.isEmpty || content == null || !RegExp(r'^[a-z0-9][a-z0-9-]*$').hasMatch(name)) return null;
    return ProfileSkill(
      name: name,
      description: asString(j['description']) ?? '',
      content: content,
      files: {for (final e in asMap(j['files']).entries) if (e.value is String) e.key: e.value! as String},
    );
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'content': content,
    if (files.isNotEmpty) 'files': files,
  };
}

class CoachProfile {
  const CoachProfile({
    required this.id,
    required this.appName,
    this.promptVersion = '1',
    this.focus = '',
    this.rules = const [],
    this.select = const DrillSelector(),
    this.scenes = SceneRule.defaults,
    this.defaultScene = 'home',
    this.goals = const ['relax', 'mobility', 'strength', 'core', 'fullbody', 'warmup', 'cooldown'],
    this.limits = const PlanLimits(),
    this.minActions = 3,
    this.legacyGoalMap = const [],
    this.assetApps = const [],
    this.vars = const {},
    this.skills = const [],
  });

  /// flarelab / hiplab / smartfit …（随调用记录）。
  final String id;

  /// 给模型看的 App 名称，如「开胯训练助手」。
  final String appName;

  /// profile 自己的提示词版本，与 PromptSet.version 拼成调用记录里的 promptVersion。
  final String promptVersion;

  /// 这个 App 的侧重（一段话，进系统提示词）。
  final String focus;

  /// App 额外规则（逐条进系统提示词）。
  final List<String> rules;
  final DrillSelector select;
  final Map<String, SceneRule> scenes;
  final String defaultScene;

  /// 允许的 goal 值。
  final List<String> goals;
  final PlanLimits limits;

  /// Minimum distinct actions required for an action node.
  final int minActions;

  /// Ordered structured-to-legacy goal rules, including an explicit fallback.
  final List<Map<String, Object?>> legacyGoalMap;

  /// 素材来源优先级（[AssetResolver.appOrder]），空 = `[id, 'pose-hub']`。
  final List<String> assetApps;

  /// 自定义提示词变量。
  final Map<String, String> vars;

  /// App 专属 skill（Agent 版，渐进式披露）。
  final List<ProfileSkill> skills;

  /// 本 App 可用的动作（保持目录顺序）。
  List<Drill> scope(Catalog c) => [for (final d in c.drills) if (select.matches(d)) d];

  SceneRule sceneRule(String scene) => scenes[scene] ?? const SceneRule();

  List<String> get resolvedAssetApps => assetApps.isEmpty ? [id, 'pose-hub'] : assetApps;

  factory CoachProfile.fromJson(Object? raw) {
    final j = asMap(raw);
    final id = asString(j['id']);
    if (id == null) throw const FormatException('profile 缺 id');
    final scenesJson = asMap(j['scenes']);
    return CoachProfile(
      id: id,
      appName: asString(j['appName']) ?? id,
      promptVersion: asString(j['promptVersion']) ?? '1',
      focus: asString(j['focus']) ?? '',
      rules: asStringList(j['rules']),
      select: DrillSelector.fromJson(j['select']),
      scenes: scenesJson.isEmpty
          ? SceneRule.defaults
          : {for (final e in scenesJson.entries) e.key: SceneRule.fromJson(e.value)},
      defaultScene: asString(j['defaultScene']) ?? 'home',
      goals: j['goals'] == null ? const CoachProfile(id: '', appName: '').goals : asStringList(j['goals']),
      limits: PlanLimits.fromJson(j['limits']),
      minActions: asInt(j['minActions']) ?? 3,
      legacyGoalMap: [for (final rule in asList(j['legacyGoalMap'])) asMap(rule)],
      assetApps: asStringList(j['assetApps']),
      vars: {for (final e in asMap(j['vars']).entries) if (e.value is String) e.key: e.value! as String},
      skills: [for (final x in asList(j['skills'])) ?ProfileSkill.tryParse(x)],
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'appName': appName,
    'promptVersion': promptVersion,
    'focus': focus,
    'rules': rules,
    'select': select.toJson(),
    'scenes': {for (final e in scenes.entries) e.key: e.value.toJson()},
    'defaultScene': defaultScene,
    'goals': goals,
    'limits': limits.toJson(),
    'minActions': minActions,
    if (legacyGoalMap.isNotEmpty) 'legacyGoalMap': legacyGoalMap,
    if (assetApps.isNotEmpty) 'assetApps': assetApps,
    if (vars.isNotEmpty) 'vars': vars,
    if (skills.isNotEmpty) 'skills': [for (final x in skills) x.toJson()],
  };
}
