/// 动作目录模型：Pose-Hub 统一目录 `pose-hub-catalog` format 1。
///
/// 一个动作（drill）= 定义 + 封面 + 示范视频 + 建模源（Pose-Hub spec）+ 语音。
/// 定义字段与 SmartFit drill-pack format 1 的 pack.json 同名同义；
/// 额外有 doseRange / purpose / apps / tags / assets / completeness。
/// 读取宽容：不认识的字段忽略；缺必填字段的动作跳过并记入 [Catalog.problems]。
library;

import '../util/json.dart';

const catalogFormat = 'pose-hub-catalog';
const supportedCatalogFormatVersion = 1;

class CatalogFormatException implements Exception {
  const CatalogFormatException(this.message);
  final String message;
  @override
  String toString() => 'CatalogFormatException: $message';
}

enum DoseMode { reps, time }

class Dose {
  const Dose({required this.mode, required this.sets, this.reps, this.seconds, required this.restSeconds});
  final DoseMode mode;
  final int sets;
  final int? reps;
  final int? seconds;
  final int restSeconds;

  static Dose? tryParse(Object? raw) {
    final j = asMap(raw);
    final mode = switch (j['mode']) { 'reps' => DoseMode.reps, 'time' => DoseMode.time, _ => null };
    final sets = asInt(j['sets']);
    if (mode == null || sets == null) return null;
    return Dose(
      mode: mode,
      sets: sets,
      reps: asInt(j['reps']),
      seconds: asInt(j['seconds']) ?? asInt(j['workSeconds']),
      restSeconds: asInt(j['restSeconds']) ?? 20,
    );
  }

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'sets': sets,
    if (reps != null) 'reps': reps,
    if (seconds != null) 'seconds': seconds,
    'restSeconds': restSeconds,
  };

  /// 提示词里的短写：`3×12次` / `1×30秒`。
  String get short => '$sets×${mode == DoseMode.reps ? '$reps次' : '$seconds秒'}';
}

/// 闭区间 [min, max]。
class IntRange {
  const IntRange(this.min, this.max);
  final int min;
  final int max;
  bool contains(int v) => v >= min && v <= max;
  static IntRange? tryParse(Object? v) {
    final l = asList(v);
    if (l.length != 2) return null;
    final a = asInt(l[0]), b = asInt(l[1]);
    return a == null || b == null ? null : IntRange(a, b);
  }

  List<int> toJson() => [min, max];
  @override
  String toString() => '$min–$max';
}

/// 动作自己的可调剂量范围（目录审阅过的），比全局硬限更窄。
class DoseRange {
  const DoseRange({this.sets, this.reps, this.seconds, this.restSeconds});
  final IntRange? sets;
  final IntRange? reps;
  final IntRange? seconds;
  final IntRange? restSeconds;

  factory DoseRange.fromJson(Object? raw) {
    final j = asMap(raw);
    return DoseRange(
      sets: IntRange.tryParse(j['sets']),
      reps: IntRange.tryParse(j['reps']),
      seconds: IntRange.tryParse(j['seconds']),
      restSeconds: IntRange.tryParse(j['restSeconds']),
    );
  }
  Map<String, Object?> toJson() => {
    if (sets != null) 'sets': sets!.toJson(),
    if (reps != null) 'reps': reps!.toJson(),
    if (seconds != null) 'seconds': seconds!.toJson(),
    if (restSeconds != null) 'restSeconds': restSeconds!.toJson(),
  };
}

/// 一个素材文件的来源（同一动作在不同 App / 发布版本里可有多份）。
class AssetSource {
  const AssetSource({
    required this.app,
    required this.path,
    this.variant,
    this.release,
    this.width,
    this.height,
    this.bytes,
    this.sha256,
    this.loopSeconds,
    this.repSeconds,
    this.coverSeconds,
    this.showsSide,
  });

  /// appId（smartfit / hiplab / flarelab）或 `pose-hub`（发布包内路径）。
  final String app;

  /// 相对该 App 仓库根（或 Pose-Hub 发布包）的路径。
  final String path;
  final String? variant;
  final String? release;
  final int? width;
  final int? height;
  final int? bytes;
  final String? sha256;
  final double? loopSeconds;
  final double? repSeconds;
  final double? coverSeconds;
  final String? showsSide;

  static AssetSource? tryParse(Object? raw) {
    final j = asMap(raw);
    final app = asString(j['app']), path = asString(j['path']);
    if (app == null || path == null) return null;
    return AssetSource(
      app: app,
      path: path,
      variant: asString(j['variant']),
      release: asString(j['release']),
      width: asInt(j['width']),
      height: asInt(j['height']),
      bytes: asInt(j['bytes']),
      sha256: asString(j['sha256']),
      loopSeconds: asDouble(j['loopSeconds']),
      repSeconds: asDouble(j['repSeconds']),
      coverSeconds: asDouble(j['coverSeconds']),
      showsSide: asString(j['showsSide']),
    );
  }

  Map<String, Object?> toJson() => {
    'app': app,
    'path': path,
    if (variant != null) 'variant': variant,
    if (release != null) 'release': release,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    if (bytes != null) 'bytes': bytes,
    if (sha256 != null) 'sha256': sha256,
    if (loopSeconds != null) 'loopSeconds': loopSeconds,
    if (repSeconds != null) 'repSeconds': repSeconds,
    if (coverSeconds != null) 'coverSeconds': coverSeconds,
    if (showsSide != null) 'showsSide': showsSide,
  };
}

/// 一条语音台词（文本 + 各语言时长）。音频路径由 [VoiceAudio.pathPattern] 拼出。
class VoiceLine {
  const VoiceLine({required this.id, required this.role, required this.text, this.ms = const {}});
  final String id;
  final String role;
  final LocalizedText text;
  final Map<String, int> ms;

  static VoiceLine? tryParse(Object? raw) {
    final j = asMap(raw);
    final id = asString(j['id']);
    if (id == null) return null;
    final ms = j['ms'];
    return VoiceLine(
      id: id,
      role: asString(j['role']) ?? id,
      text: LocalizedText.fromJson(j['text']),
      ms: ms is num
          ? {'zh': ms.toInt()}
          : {for (final e in asMap(ms).entries) if (asInt(e.value) != null) e.key: asInt(e.value)!},
    );
  }

  Map<String, Object?> toJson() => {'id': id, 'role': role, 'text': text.toJson(), 'ms': ms};
}

/// 某个 App 里语音文件的位置：`pathPattern` 含 `{lang}`、`{line}` 占位。
/// [keys] 非空时（HipLab）用 keys 作为 line，否则用台词 id。
class VoiceAudio {
  const VoiceAudio({required this.app, required this.pathPattern, this.languages = const [], this.keys = const []});
  final String app;
  final String pathPattern;
  final List<String> languages;
  final List<String> keys;

  static VoiceAudio? tryParse(Object? raw) {
    final j = asMap(raw);
    final app = asString(j['app']), p = asString(j['pathPattern']);
    if (app == null || p == null) return null;
    return VoiceAudio(app: app, pathPattern: p, languages: asStringList(j['languages']), keys: asStringList(j['keys']));
  }

  String path(String lang, String line) => pathPattern.replaceAll('{lang}', lang).replaceAll('{line}', line);

  Map<String, Object?> toJson() => {
    'app': app,
    'pathPattern': pathPattern,
    'languages': languages,
    if (keys.isNotEmpty) 'keys': keys,
  };
}

class SpecRef {
  const SpecRef({required this.status, this.path, this.sha256, this.revisionOf, this.modelProfile});
  final String status;
  final String? path;
  final String? sha256;
  final String? revisionOf;
  final String? modelProfile;
  bool get ok => status == 'ok' && path != null;

  factory SpecRef.fromJson(Object? raw) {
    final j = asMap(raw);
    return SpecRef(
      status: asString(j['status']) ?? (j['path'] != null ? 'ok' : 'missing'),
      path: asString(j['path']),
      sha256: asString(j['sha256']),
      revisionOf: asString(j['revisionOf']),
      modelProfile: asString(j['modelProfile']),
    );
  }
  Map<String, Object?> toJson() => {
    'status': status,
    if (path != null) 'path': path,
    if (sha256 != null) 'sha256': sha256,
    if (revisionOf != null) 'revisionOf': revisionOf,
    if (modelProfile != null) 'modelProfile': modelProfile,
  };
}

/// 动作的全部素材指向。
class DrillAssets {
  const DrillAssets({
    this.spec = const SpecRef(status: 'missing'),
    this.releases = const [],
    this.covers = const [],
    this.videos = const [],
    this.voiceLanguages = const [],
    this.voiceLines = const [],
    this.voiceAudio = const [],
    this.drillPack,
  });

  /// 建模素材源（Pose-Hub drill-anim spec）。
  final SpecRef spec;

  /// 已发布的 Pose-Hub 素材版本。
  final List<String> releases;
  final List<AssetSource> covers;
  final List<AssetSource> videos;
  final List<String> voiceLanguages;
  final List<VoiceLine> voiceLines;
  final List<VoiceAudio> voiceAudio;

  /// SmartFit drill-pack 的 pack.json 位置（有就带上，App 可直接读整包）。
  final AssetSource? drillPack;

  factory DrillAssets.fromJson(Object? raw) {
    final j = asMap(raw);
    final voice = asMap(j['voice']);
    List<AssetSource> sources(Object? v) => [
      for (final s in asList(asMap(v)['sources'])) ?AssetSource.tryParse(s),
    ];
    final dp = asMap(j['drillPack']);
    return DrillAssets(
      spec: SpecRef.fromJson(j['spec']),
      releases: asStringList(j['releases']),
      covers: sources(j['cover']),
      videos: sources(j['video']),
      voiceLanguages: asStringList(voice['languages']),
      voiceLines: [for (final l in asList(voice['lines'])) ?VoiceLine.tryParse(l)],
      voiceAudio: [for (final a in asList(voice['audio'])) ?VoiceAudio.tryParse(a)],
      drillPack: dp.isEmpty
          ? null
          : AssetSource(app: asString(dp['app']) ?? 'smartfit', path: asString(dp['path']) ?? '', release: asString(dp['version'])),
    );
  }

  Map<String, Object?> toJson() => {
    'spec': spec.toJson(),
    'releases': releases,
    'cover': {'status': covers.isEmpty ? 'missing' : 'ok', 'sources': [for (final c in covers) c.toJson()]},
    'video': {'status': videos.isEmpty ? 'missing' : 'ok', 'sources': [for (final v in videos) v.toJson()]},
    'voice': {
      'status': voiceLanguages.contains('zh') ? 'ok' : 'missing',
      'languages': voiceLanguages,
      if (voiceLines.isNotEmpty) 'lines': [for (final l in voiceLines) l.toJson()],
      if (voiceAudio.isNotEmpty) 'audio': [for (final a in voiceAudio) a.toJson()],
    },
    'drillPack': drillPack == null
        ? null
        : {'app': drillPack!.app, 'path': drillPack!.path, if (drillPack!.release != null) 'version': drillPack!.release},
  };
}

/// 目录里的一个动作。
class Drill {
  const Drill({
    required this.id,
    required this.name,
    this.purpose = '',
    required this.category,
    this.muscles = const [],
    this.muscleGroups = const [],
    this.equipment = const [],
    required this.position,
    required this.unilateral,
    required this.level,
    this.scenes = const [],
    required this.defaultDose,
    this.doseRange = const DoseRange(),
    this.cues = const {},
    this.primaryCue = 0,
    this.cautions = const [],
    this.contraindications = const [],
    this.alternative,
    this.apps = const [],
    this.tags = const [],
    this.assets = const DrillAssets(),
    this.missing = const [],
    this.reviewStatus,
    this.raw = const {},
  });

  final String id;
  final LocalizedText name;
  final String purpose;

  /// strength | core | cardio | mobility | stretch
  final String category;
  final List<String> muscles;
  final List<String> muscleGroups;

  /// 器械 id；[] = 徒手。
  final List<String> equipment;
  final String position;

  /// true = 左右各做一遍；计划里 perSide 必须等于它。
  final bool unilateral;

  /// 1 入门 · 2 基础 · 3 进阶
  final int level;
  final List<String> scenes;
  final Dose defaultDose;
  final DoseRange doseRange;
  final Map<String, List<String>> cues;
  final int primaryCue;

  /// 需要留意的部位（膝 / 腰 / 肩 …）；用户要保护的部位命中即不可用。
  final List<String> cautions;
  final List<String> contraindications;
  final String? alternative;

  /// 哪些 App 已收录（有可播放素材）。
  final List<String> apps;
  final List<String> tags;
  final DrillAssets assets;

  /// 目录声明的缺失素材（`voice.zh`、`release` …）。
  final List<String> missing;
  final String? reviewStatus;

  /// 原始 JSON（保留未建模字段，如 flarelab 段）。
  final Map<String, Object?> raw;

  bool get bodyweight => equipment.isEmpty;

  static Drill? tryParse(Object? json, List<String> problems) {
    final j = asMap(json);
    final id = asString(j['id']);
    final dose = Dose.tryParse(j['defaultDose']);
    final need = {
      'id': id,
      'name': j['name'],
      'category': asString(j['category']),
      'position': asString(j['position']),
      'unilateral': asBool(j['unilateral']),
      'level': asInt(j['level']),
      'defaultDose': dose,
    };
    final lack = [for (final e in need.entries) if (e.value == null) e.key];
    if (lack.isNotEmpty) {
      problems.add('动作 ${id ?? '(无 id)'} 缺字段：${lack.join(', ')}，已跳过');
      return null;
    }
    final completeness = asMap(j['completeness']);
    return Drill(
      id: id!,
      name: LocalizedText.fromJson(j['name']),
      purpose: asString(j['purpose']) ?? '',
      category: asString(j['category'])!,
      muscles: asStringList(j['muscles']),
      muscleGroups: asStringList(j['muscleGroups']),
      equipment: asStringList(j['equipment']),
      position: asString(j['position'])!,
      unilateral: asBool(j['unilateral'])!,
      level: asInt(j['level'])!,
      scenes: asStringList(j['scenes']),
      defaultDose: dose!,
      doseRange: DoseRange.fromJson(j['doseRange']),
      cues: {for (final e in asMap(j['cues']).entries) e.key: asStringList(e.value)},
      primaryCue: asInt(j['primaryCue']) ?? 0,
      cautions: asStringList(j['cautions']),
      contraindications: asStringList(j['contraindications']),
      alternative: asString(j['alternative']),
      apps: asStringList(j['apps']),
      tags: asStringList(j['tags']),
      assets: DrillAssets.fromJson(j['assets']),
      missing: asStringList(completeness['missing']),
      reviewStatus: asString(asMap(j['review'])['status']),
      raw: j,
    );
  }

  Map<String, Object?> toJson() => {
    ...raw,
    'id': id,
    'name': name.toJson(),
    'purpose': purpose,
    'category': category,
    'muscles': muscles,
    'muscleGroups': muscleGroups,
    'equipment': equipment,
    'position': position,
    'unilateral': unilateral,
    'level': level,
    'scenes': scenes,
    'defaultDose': defaultDose.toJson(),
    'doseRange': doseRange.toJson(),
    'cues': cues,
    'primaryCue': primaryCue,
    'cautions': cautions,
    'contraindications': contraindications,
    'alternative': alternative,
    'apps': apps,
    'tags': tags,
    'assets': assets.toJson(),
  };
}

/// 分类字典（taxonomy）：枚举值的中文名，以及体位是否着地、器械常见场所。
class Taxonomy {
  const Taxonomy({
    this.categories = const {},
    this.muscleGroups = const {},
    this.equipment = const {},
    this.equipmentScenes = const {},
    this.positions = const {},
    this.floorPositions = defaultFloorPositions,
    this.scenes = const {},
    this.cautions = const [],
  });

  static const defaultFloorPositions = {'supine', 'prone', 'quadruped', 'kneeling', 'side_lying'};

  final Map<String, String> categories;
  final Map<String, String> muscleGroups;
  final Map<String, String> equipment;
  final Map<String, List<String>> equipmentScenes;
  final Map<String, String> positions;
  final Set<String> floorPositions;
  final Map<String, String> scenes;
  final List<String> cautions;

  factory Taxonomy.fromJson(Object? raw) {
    final j = asMap(raw);
    Map<String, String> labels(Object? v) => {
      for (final e in asMap(v).entries) e.key: LocalizedText.fromJson(asMap(e.value)['zh'] ?? e.value).of(),
    };
    final pos = asMap(j['positions']);
    final floor = {for (final e in pos.entries) if (asMap(e.value)['floor'] == true) e.key};
    return Taxonomy(
      categories: labels(j['categories']),
      muscleGroups: labels(j['muscleGroups']),
      equipment: labels(j['equipment']),
      equipmentScenes: {for (final e in asMap(j['equipment']).entries) e.key: asStringList(asMap(e.value)['scenes'])},
      positions: labels(pos),
      floorPositions: pos.isEmpty ? defaultFloorPositions : floor,
      scenes: labels(j['scenes']),
      cautions: asStringList(j['cautions']),
    );
  }

  String equipmentLabel(String id) => equipment[id] ?? id;
  String positionLabel(String id) => positions[id] ?? id;
  String categoryLabel(String id) => categories[id] ?? id;
}

class Catalog {
  Catalog({
    required this.version,
    required List<Drill> drills,
    this.formatVersion = supportedCatalogFormatVersion,
    this.generatedAt,
    this.sourceCommit,
    this.taxonomy = const Taxonomy(),
    this.problems = const [],
    this.raw = const {},
  }) : drills = List.unmodifiable(drills),
       _byId = {for (final d in drills) d.id: d};

  final int formatVersion;

  /// 目录内容版本（MAJOR.MINOR.PATCH）；随调用记录、提示词版本走。
  final String version;
  final String? generatedAt;
  final String? sourceCommit;
  final Taxonomy taxonomy;
  final List<Drill> drills;

  /// 解析时跳过 / 修正的条目。
  final List<String> problems;
  final Map<String, Object?> raw;
  final Map<String, Drill> _byId;

  Drill? operator [](String id) => _byId[id];
  bool contains(String id) => _byId.containsKey(id);
  Iterable<String> get ids => _byId.keys;
  int get length => drills.length;

  /// 解析 `pose-hub-catalog` JSON。格式不符或 formatVersion 不支持时抛 [CatalogFormatException]。
  factory Catalog.fromJson(Object? json) {
    final j = asMap(json);
    if (j['format'] != catalogFormat) {
      throw CatalogFormatException('format 应为 $catalogFormat，实际 ${j['format']}');
    }
    final fv = asInt(j['formatVersion']);
    if (fv != supportedCatalogFormatVersion) {
      throw CatalogFormatException('不支持的 formatVersion：$fv（本 SDK 支持 $supportedCatalogFormatVersion）');
    }
    final version = asString(j['version']);
    if (version == null || version.isEmpty) throw const CatalogFormatException('缺 version');
    final problems = <String>[];
    final drills = <Drill>[];
    final seen = <String>{};
    for (final d in asList(j['drills'])) {
      final drill = Drill.tryParse(d, problems);
      if (drill == null) continue;
      if (!seen.add(drill.id)) {
        problems.add('重复的动作 id：${drill.id}，保留第一条');
        continue;
      }
      drills.add(drill);
    }
    return Catalog(
      formatVersion: fv!,
      version: version,
      generatedAt: asString(j['generatedAt']),
      sourceCommit: asString(asMap(j['source'])['commit']),
      taxonomy: Taxonomy.fromJson(j['taxonomy']),
      drills: drills,
      problems: problems,
      raw: j,
    );
  }

  Map<String, Object?> toJson() => {
    ...raw,
    'format': catalogFormat,
    'formatVersion': formatVersion,
    'version': version,
    if (generatedAt != null) 'generatedAt': generatedAt,
    'drills': [for (final d in drills) d.toJson()],
  };
}
