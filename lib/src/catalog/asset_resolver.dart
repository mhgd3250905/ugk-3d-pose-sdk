/// id → 整套素材。一个动作 id 带出：封面、示范视频、建模源（spec）、语音（每句台词的音频路径与时长）。
library;

import '../util/version.dart';
import 'catalog.dart';

enum AssetKind { cover, video, voice, spec }

class ResolvedAsset {
  const ResolvedAsset(this.source, this.uri);
  final AssetSource source;

  /// 可直接加载的路径：App 资源路径，或拼了 [AssetResolver.baseByApp] 的 URL。
  final String uri;
}

class ResolvedVoiceLine {
  const ResolvedVoiceLine({required this.line, required this.uri, this.ms});
  final VoiceLine line;
  final String uri;
  final int? ms;
}

class ResolvedDrill {
  const ResolvedDrill({
    required this.drill,
    this.cover,
    this.video,
    this.spec,
    this.voice = const {},
    this.voiceKeys = const [],
    this.missing = const {},
  });

  final Drill drill;
  final ResolvedAsset? cover;
  final ResolvedAsset? video;

  /// Pose-Hub spec 路径（相对 Pose-Hub 仓库）。
  final String? spec;

  /// 台词 id → 音频（drill-pack 风格：name / intro / cue1 …）。
  final Map<String, ResolvedVoiceLine> voice;

  /// key 风格的语音（HipLab：`drill.<id>` → 路径）。
  final List<ResolvedAsset> voiceKeys;

  /// 按当前 App 偏好找不到的素材。
  final Set<AssetKind> missing;

  bool get complete => missing.isEmpty;
}

class AssetResolver {
  /// [appOrder]：按顺序挑素材来源，如 `['smartfit', 'pose-hub']`。
  /// [variant]：偏好的明暗版本（HipLab 有 dark/light）；没有就取不带 variant 的或第一份。
  /// [baseByApp]：给来源加前缀，如 `{'pose-hub': 'https://cdn.example.com/pose-hub/0.2.0/'}`；
  /// 不给则原样返回目录里的路径（App 自己的资源路径）。
  const AssetResolver({
    required this.appOrder,
    this.variant,
    this.language = 'zh',
    this.baseByApp = const {},
  });

  final List<String> appOrder;
  final String? variant;
  final String language;
  final Map<String, String> baseByApp;

  String _uri(String app, String path) {
    final base = baseByApp[app];
    if (base == null || base.isEmpty) return path;
    return base.endsWith('/') ? '$base$path' : '$base/$path';
  }

  /// 按 [appOrder] 找第一个有素材的来源；同一来源里先挑明暗版本
  /// （指定了就用它，没指定用不带版本的，再不行用列出的第一种），再取最新发布版。
  ResolvedAsset? _pick(List<AssetSource> sources) {
    for (final app in appOrder) {
      final mine = sources.where((s) => s.app == app).toList();
      if (mine.isEmpty) continue;
      List<AssetSource> cand;
      if (variant != null) {
        cand = mine.where((s) => s.variant == variant || s.variant == null).toList();
        if (cand.isEmpty) cand = mine;
      } else {
        cand = mine.where((s) => s.variant == null || s.variant == 'default').toList();
        if (cand.isEmpty) cand = mine.where((s) => s.variant == mine.first.variant).toList();
      }
      var best = cand.first;
      for (final s in cand.skip(1)) {
        if (s.release != null && best.release != null && compareVersions(s.release!, best.release!) > 0) best = s;
      }
      return ResolvedAsset(best, _uri(app, best.path));
    }
    return null;
  }

  ResolvedDrill resolve(Drill d) {
    final missing = <AssetKind>{};
    final cover = _pick(d.assets.covers);
    final video = _pick(d.assets.videos);
    if (cover == null) missing.add(AssetKind.cover);
    if (video == null) missing.add(AssetKind.video);
    final spec = d.assets.spec.ok ? d.assets.spec.path : null;
    if (spec == null) missing.add(AssetKind.spec);

    final voice = <String, ResolvedVoiceLine>{};
    final keys = <ResolvedAsset>[];
    for (final app in appOrder) {
      final audio = d.assets.voiceAudio.where((a) => a.app == app && a.languages.contains(language));
      if (audio.isEmpty) continue;
      final a = audio.first;
      if (a.keys.isNotEmpty) {
        for (final k in a.keys) {
          keys.add(ResolvedAsset(AssetSource(app: app, path: a.path(language, k)), _uri(app, a.path(language, k))));
        }
      } else {
        for (final l in d.assets.voiceLines) {
          final p = a.path(language, l.id);
          voice[l.id] = ResolvedVoiceLine(line: l, uri: _uri(app, p), ms: l.ms[language]);
        }
      }
      break;
    }
    if (voice.isEmpty && keys.isEmpty) missing.add(AssetKind.voice);
    return ResolvedDrill(drill: d, cover: cover, video: video, spec: spec, voice: voice, voiceKeys: keys, missing: missing);
  }

  ResolvedDrill? resolveId(Catalog c, String id) {
    final d = c[id];
    return d == null ? null : resolve(d);
  }

  /// 缺素材清单：id → 缺哪些。只列有缺的。
  Map<String, Set<AssetKind>> missingReport(Iterable<Drill> drills) => {
    for (final d in drills)
      if (resolve(d).missing case final m when m.isNotEmpty) d.id: m,
  };
}
