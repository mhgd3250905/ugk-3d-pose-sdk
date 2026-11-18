// Pose-Hub catalogue voice (2026-11-06): every catalogue action lists its
// own recorded lines under `voice.files` (name / primaryCue / phase.*, one
// m4a per language, with bytes + sha256 + durationSeconds). Apps used to
// play only their bundled packs, so actions without a local pack had no
// voice of their own. This file adds that catalogue as a second voice
// source:
//
//  * [CatalogVoiceIndex] reads `voice.files` (and the written name / key
//    point) from a catalogue JSON;
//  * [CatalogVoiceCache] downloads a clip on demand from the catalogue's
//    media root (`mediaDistribution.baseUrl` + path), checks size + SHA-256
//    and keeps it in an atomically written, content-addressed store shared
//    with the catalogue updater;
//  * [LayeredVoiceSource] keeps local pack precedence for legacy scripts.
//    Ready guides use verified re-recordings and shared vocabulary, with
//    the local voice as the fallback for shared phrases.
//
// Pure Dart except the default file store / HTTP client (conditional io).
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ugk_coach/ugk_coach.dart' show PoseHubVoiceGuide;

import '../pose_hub/pose_hub_catalog_io_stub.dart'
    if (dart.library.io) '../pose_hub/pose_hub_catalog_io_native.dart';
import '../pose_hub/pose_hub_catalog_io_types.dart';
import 'voice_source.dart';

/// One recorded catalogue line of one action in one language.
class CatalogVoiceClip {
  const CatalogVoiceClip({
    required this.actionId,
    required this.language,
    required this.clipId,
    required this.path,
    required this.bytes,
    required this.sha256,
    required this.seconds,
    required this.url,
    this.text,
  });

  final String actionId;
  final String language;

  /// `name`, `primaryCue`, `phase.start` …
  final String clipId;

  /// Relative object path (`voice/<id>/<lang>/<clip>.m4a`).
  final String path;
  final int bytes;
  final String sha256;
  final double seconds;
  final Uri url;
  final String? text;

  /// Name of the verified copy in the cache (content addressed, so a new
  /// recording under the same path never reads a stale file).
  String get cacheName => 'catalog-voice/${sha256.substring(0, 2)}/$sha256.m4a';
}

/// The catalogue's voice table: action → language → clip id → clip, plus the
/// written name and primary key point of every action (also those whose
/// voice is still pending).
class CatalogVoiceIndex {
  CatalogVoiceIndex._(
    this._clips,
    this._names,
    this._cues,
    this.pending,
    this._common,
    this._guides,
    this._sideSwitchSeconds,
  );

  static final empty = CatalogVoiceIndex._(
    const {},
    const {},
    const {},
    const {},
    const {},
    const {},
    const {},
  );

  static const _commonActionId = '_common';
  static final _sha256 = RegExp(r'^[0-9a-f]{64}$');

  static Map<String, Map<String, CatalogVoiceClip>> _readFiles(
    Object? files,
    String actionId,
    Uri? base, {
    required String keyField,
    required bool requireValidFiles,
  }) {
    void invalid() {
      if (requireValidFiles) {
        throw FormatException('Invalid Pose-Hub voice file for $actionId.');
      }
    }

    final result = <String, Map<String, CatalogVoiceClip>>{};
    if (files == null) return result;
    if (files is! List) {
      invalid();
      return result;
    }
    for (final file in files) {
      if (file is! Map) {
        invalid();
        continue;
      }
      final lang = file['language'];
      final key = file[keyField];
      final path = file['path'];
      final bytes = file['bytes'];
      final sha = file['sha256'];
      if (lang is! String ||
          key is! String ||
          path is! String ||
          bytes is! int ||
          bytes <= 0 ||
          sha is! String ||
          !_sha256.hasMatch(sha) ||
          path.startsWith('/') ||
          path.split('/').contains('..')) {
        invalid();
        continue;
      }
      final pathUri = Uri.tryParse(path);
      if (pathUri == null ||
          pathUri.hasScheme ||
          pathUri.hasAuthority ||
          (requireValidFiles &&
              (!path.startsWith('voice/') ||
                  pathUri.hasQuery ||
                  pathUri.hasFragment ||
                  pathUri.pathSegments.any(
                    (part) => part.isEmpty || part == '.' || part == '..',
                  )))) {
        invalid();
        continue;
      }
      final downloadUrl = file['downloadUrl'];
      final url =
          base?.resolveUri(pathUri) ??
          (downloadUrl is String ? Uri.tryParse(downloadUrl) : null);
      if (url == null || url.scheme != 'https' || url.host.isEmpty) {
        invalid();
        continue;
      }
      final secs = file['durationSeconds'];
      final text = file['text'];
      final languageClips = result[lang] ??= {};
      if (languageClips.containsKey(key)) invalid();
      languageClips[key] = CatalogVoiceClip(
        actionId: actionId,
        language: lang,
        clipId: key,
        path: path,
        bytes: bytes,
        sha256: sha,
        seconds: secs is num ? secs.toDouble() : estimateSeconds(key),
        url: url,
        text: text is String && text.isNotEmpty ? text : null,
      );
    }
    return result;
  }

  /// From a catalogue JSON map (`pose-hub-app-test-catalog@1`). [baseUrl]
  /// overrides `mediaDistribution.baseUrl`. [requireValidFiles] rejects
  /// invalid entries before an update can activate an incomplete voice pack.
  factory CatalogVoiceIndex.fromCatalogJson(
    Map<String, Object?> catalog, {
    Uri? baseUrl,
    bool requireValidFiles = false,
  }) {
    final dist = catalog['mediaDistribution'];
    final base =
        baseUrl ??
        (dist is Map && dist['baseUrl'] is String
            ? Uri.parse(dist['baseUrl'] as String)
            : null);
    final clips = <String, Map<String, Map<String, CatalogVoiceClip>>>{};
    final names = <String, Map<String, String>>{};
    final cues = <String, Map<String, String>>{};
    final pending = <String>{};
    final guides = <String, PoseHubVoiceGuide>{};
    final sideSwitchSeconds = <String, int>{};
    final common = catalog['voiceCommon'];
    final commonClips =
        common is Map && common['format'] == 'pose-hub-voice-common@1'
        ? _readFiles(
            common['files'],
            _commonActionId,
            base,
            keyField: 'key',
            requireValidFiles: requireValidFiles,
          )
        : <String, Map<String, CatalogVoiceClip>>{};
    if (requireValidFiles &&
        common != null &&
        (common is! Map || common['format'] != 'pose-hub-voice-common@1')) {
      throw const FormatException('Unsupported Pose-Hub common voice format.');
    }
    for (final raw in catalog['actions'] as List? ?? const []) {
      if (raw is! Map) continue;
      final id = raw['id'];
      if (id is! String) continue;
      final guide = PoseHubVoiceGuide.forAction(
        Map<Object?, Object?>.from(raw),
      );
      if (guide != null) {
        guides[id] = guide;
        final seconds = PoseHubVoiceGuide.sideSwitchSecondsOfAction(raw);
        if (seconds != null) sideSwitchSeconds[id] = seconds;
      }
      final n = <String, String>{
        if (raw['nameZh'] is String) 'zh': raw['nameZh'] as String,
        if (raw['nameEn'] is String) 'en': raw['nameEn'] as String,
      };
      if (n.isNotEmpty) names[id] = n;
      final primary = raw['primaryCue'] is int ? raw['primaryCue'] as int : 0;
      final c = <String, String>{};
      void cueOf(String lang, Object? list) {
        if (list is List && list.isNotEmpty) {
          final k = primary.clamp(0, list.length - 1);
          if (list[k] is String) c[lang] = list[k] as String;
        }
      }

      final byLang = raw['cues'];
      if (byLang is Map) {
        for (final e in byLang.entries) {
          cueOf('${e.key}', e.value);
        }
      }
      if (!c.containsKey('en')) cueOf('en', raw['cuesEn']);
      if (c.isNotEmpty) cues[id] = c;
      final voice = raw['voice'];
      final files = voice is Map ? voice['files'] : null;
      final out = _readFiles(
        files,
        id,
        base,
        keyField: 'clipId',
        requireValidFiles: requireValidFiles,
      );
      if (out.isEmpty) {
        pending.add(id);
      } else {
        clips[id] = out;
      }
    }
    return CatalogVoiceIndex._(
      clips,
      names,
      cues,
      pending,
      commonClips,
      guides,
      sideSwitchSeconds,
    );
  }

  /// From catalogue bytes.
  factory CatalogVoiceIndex.fromBytes(List<int> bytes, {Uri? baseUrl}) =>
      CatalogVoiceIndex.fromCatalogJson(
        Map<String, Object?>.from(jsonDecode(utf8.decode(bytes)) as Map),
        baseUrl: baseUrl,
      );

  final Map<String, Map<String, Map<String, CatalogVoiceClip>>> _clips;
  final Map<String, Map<String, String>> _names;
  final Map<String, Map<String, String>> _cues;
  final Map<String, Map<String, CatalogVoiceClip>> _common;
  final Map<String, PoseHubVoiceGuide> _guides;
  final Map<String, int> _sideSwitchSeconds;

  /// Actions without any recorded catalogue line (voice still pending).
  final Set<String> pending;

  Iterable<String> get actionIds => {
    ..._clips.keys,
    ...pending,
    ..._names.keys,
  };

  /// Every published clip, including shared phrases in every language.
  Iterable<CatalogVoiceClip> get allClips sync* {
    for (final action in _clips.values) {
      for (final language in action.values) {
        yield* language.values;
      }
    }
    for (final language in _common.values) {
      yield* language.values;
    }
  }

  Set<String> get languages => {
    for (final a in _clips.values) ...a.keys,
    if (_guides.isNotEmpty) ..._common.keys,
  };

  CatalogVoiceClip? commonClip(String key, String lang) => _common[lang]?[key];

  PoseHubVoiceGuide? guide(String actionId) => _guides[actionId];

  int? sideSwitchSeconds(String actionId) => _sideSwitchSeconds[actionId];

  String? guideText(String actionId, String clipId, String lang) {
    final source = guide(actionId);
    if (source == null) return null;
    for (final line in [...source.set, ...source.reminders, ...source.steps]) {
      if (line.clipId == clipId) return line.text(lang);
    }
    return null;
  }

  CatalogVoiceClip? clip(String actionId, String clipId, String lang) =>
      _clips[actionId]?[lang]?[clipId];

  List<CatalogVoiceClip> clipsOf(String actionId, String lang) => [
    ...?_clips[actionId]?[lang]?.values,
  ];

  Iterable<CatalogVoiceClip> commonClipsOf(String lang) =>
      _common[lang]?.values ?? const [];

  /// Written name of an action.
  String? name(String actionId, String lang) =>
      _names[actionId]?[lang] ?? _names[actionId]?['zh'];

  /// Written primary key point of an action.
  String? primaryCue(String actionId, String lang) =>
      _cues[actionId]?[lang] ?? _cues[actionId]?['zh'];
}

/// Outcome of a prefetch: downloaded or already cached, and failed clips.
class CatalogVoicePrefetch {
  const CatalogVoicePrefetch(this.ready, this.failed);
  final int ready;
  final List<String> failed;
}

/// Verified on-demand cache of catalogue clips.
class CatalogVoiceCache {
  CatalogVoiceCache({
    required this.store,
    required this.pathOf,
    PoseHubCatalogHttpClient? http,
  }) : _directory = null,
       http = http ?? createPoseHubCatalogHttpClient();

  /// Cache under [directory] on the device file system (app support dir).
  CatalogVoiceCache.files(String directory, {PoseHubCatalogHttpClient? http})
    : store = createPoseHubCatalogFileStore(directory),
      pathOf = ((name) => '$directory/$name'),
      _directory = directory,
      http = http ?? createPoseHubCatalogHttpClient();

  final PoseHubCatalogStore store;

  /// File path the player opens for a cache name.
  final String Function(String name) pathOf;
  final PoseHubCatalogHttpClient http;

  final String? _directory;
  final _ready = <(String, int)>{};
  final _running = <(String, int), Future<bool>>{};
  static final _fileJobs = <(String, String, int), Future<bool>>{};
  static final _voiceSources =
      <String, List<WeakReference<LayeredVoiceSource>>>{};

  /// The clip is in the cache and verified (synchronous, for the script).
  bool isReady(CatalogVoiceClip c) => _ready.contains((c.sha256, c.bytes));

  /// Path of a ready clip.
  String path(CatalogVoiceClip c) => pathOf(c.cacheName);

  /// Make [c] ready: a verified cached copy, else a verified download.
  /// Never throws; false when it could not be made ready.
  Future<bool> ensure(CatalogVoiceClip c) async {
    if (isReady(c)) return true;
    final key = (c.sha256, c.bytes);
    final directory = _directory;
    final Future<bool> job;
    // File-backed updater and player instances share in-flight verification.
    // In-memory stores are independent, even when their paths look the same.
    if (directory != null) {
      final fileKey = (directory, c.sha256, c.bytes);
      job = _fileJobs[fileKey] ??= _ensure(c).whenComplete(() {
        _fileJobs.remove(fileKey);
      });
    } else {
      job = _running[key] ??= _ensure(c).whenComplete(() {
        _running.remove(key);
      });
    }
    final ready = await job;
    if (ready) _ready.add(key);
    return ready;
  }

  void _retain(LayeredVoiceSource source) {
    final directory = _directory;
    if (directory == null) return;
    final sources = _voiceSources.putIfAbsent(directory, () => []);
    sources
      ..removeWhere((reference) => reference.target == null)
      ..add(WeakReference(source));
  }

  /// Deletes obsolete voice objects after a successful catalogue switch.
  /// Active voice sources may still be playing an older catalogue.
  Future<void> prune(Iterable<CatalogVoiceClip> keep) async {
    final directory = _directory;
    if (directory == null) {
      throw StateError('Voice pruning requires a file-backed cache.');
    }
    final filenames = {for (final clip in keep) '${clip.sha256}.m4a'};
    final sources = _voiceSources[directory];
    if (sources != null) {
      sources.removeWhere((reference) => reference.target == null);
      for (final reference in sources) {
        final source = reference.target;
        if (source == null) continue;
        filenames.addAll(
          source.catalog.allClips.map((clip) => '${clip.sha256}.m4a'),
        );
      }
      if (sources.isEmpty) _voiceSources.remove(directory);
    }

    final prefixPattern = RegExp(r'^[a-f0-9]{2}$');
    final filenamePattern = RegExp(r'^[a-f0-9]{64}\.m4a$');
    for (final prefix in await store.list('catalog-voice')) {
      if (!prefixPattern.hasMatch(prefix)) continue;
      final shard = 'catalog-voice/$prefix';
      for (final filename in await store.list(shard)) {
        if (!filename.startsWith(prefix) ||
            !filenamePattern.hasMatch(filename) ||
            filenames.contains(filename) ||
            _fileJobs.keys.any(
              (job) => job.$1 == directory && '${job.$2}.m4a' == filename,
            )) {
          continue;
        }
        await store.delete('$shard/$filename');
      }
    }
  }

  static bool _valid(List<int> b, CatalogVoiceClip c) =>
      b.length == c.bytes && crypto.sha256.convert(b).toString() == c.sha256;

  Future<bool> _ensure(CatalogVoiceClip c) async {
    try {
      final cached = await store.read(c.cacheName);
      // A contradictory byte count is a bad descriptor. Keep the verified
      // object available to its previous catalogue if the update fails.
      if (cached != null &&
          crypto.sha256.convert(cached).toString() == c.sha256) {
        return cached.length == c.bytes;
      }
      final r = await http.get(c.url, maxBytes: c.bytes + 1024);
      if (r.statusCode != 200 || !_valid(r.body, c)) return false;
      await store.writeAtomic(c.cacheName, r.body);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Make every clip of [clips] ready, a few at a time. Never throws.
  Future<CatalogVoicePrefetch> prefetch(
    Iterable<CatalogVoiceClip> clips, {
    int parallel = 3,
  }) async {
    final queue = clips.iterator;
    var ready = 0;
    final failed = <String>[];
    Future<void> worker() async {
      while (queue.moveNext()) {
        final c = queue.current;
        if (await ensure(c)) {
          ready++;
        } else {
          failed.add('${c.actionId}/${c.language}/${c.clipId}');
        }
      }
    }

    await Future.wait([for (var i = 0; i < parallel; i++) worker()]);
    return CatalogVoicePrefetch(ready, failed);
  }
}

/// A voice source the player can warm up for a plan before it speaks.
abstract interface class PreparableVoiceSource {
  /// Fetch what [exerciseIds] need in [lang]. Must not throw; training
  /// never waits on it beyond what the player allows.
  Future<void> prepare(Iterable<String> exerciseIds, {required String lang});
}

/// The app's own voice ([primary], bundled packs) with the catalogue's
/// recorded lines behind it. Local pack first, line by line; then the
/// catalogue (`name` → name, `primaryCue` → the first key point); an action
/// with neither keeps the generic calls and its written intro.
class LayeredVoiceSource extends VoiceSource implements PreparableVoiceSource {
  LayeredVoiceSource({
    required this.primary,
    required this.catalog,
    required this.cache,
  }) {
    cache._retain(this);
  }

  final VoiceSource primary;
  final CatalogVoiceIndex catalog;
  final CatalogVoiceCache cache;

  static const _prefix = 'catalog:';

  /// Key of a catalogue clip (`catalog:<id>/<clipId>`).
  static String keyOf(String actionId, String clipId) =>
      '$_prefix$actionId/$clipId';

  static (String, String)? _parse(String key) {
    if (!key.startsWith(_prefix)) return null;
    final rest = key.substring(_prefix.length);
    final slash = rest.indexOf('/');
    if (slash <= 0) return null;
    return (rest.substring(0, slash), rest.substring(slash + 1));
  }

  CatalogVoiceClip? _clip(String key, String lang) {
    final p = _parse(key);
    if (p == null) return null;
    return p.$1 == CatalogVoiceIndex._commonActionId
        ? catalog.commonClip(p.$2, lang)
        : catalog.clip(p.$1, p.$2, lang);
  }

  static String? _clipIdOf(DrillLine line) => switch (line) {
    DrillLine.name => 'name',
    DrillLine.cue1 => 'primaryCue',
    _ => null,
  };

  @override
  Set<String> get languages => {...primary.languages, ...catalog.languages};

  @override
  bool has(String key, {required String lang}) {
    final c = _clip(key, lang);
    if (c != null) return cache.isReady(c);
    return !key.startsWith(_prefix) && primary.has(key, lang: lang);
  }

  @override
  bool expected(String key, {required String lang}) =>
      _clip(key, lang) != null || primary.expected(key, lang: lang);

  @override
  double seconds(String key, {required String lang}) =>
      _clip(key, lang)?.seconds ?? primary.seconds(key, lang: lang);

  @override
  String asset(String key, {required String lang}) {
    final c = _clip(key, lang);
    return c != null ? cache.path(c) : primary.asset(key, lang: lang);
  }

  @override
  String? line(String key, {required String lang}) {
    final p = _parse(key);
    if (p == null) return primary.line(key, lang: lang);
    final clip = _clip(key, lang);
    final text = clip?.text;
    if (text != null &&
        (p.$1 == CatalogVoiceIndex._commonActionId ||
            catalog.guide(p.$1) != null)) {
      return text;
    }
    return switch (p.$2) {
      'name' => catalog.name(p.$1, lang),
      'primaryCue' => catalog.primaryCue(p.$1, lang),
      _ => catalog.guideText(p.$1, p.$2, lang),
    };
  }

  @override
  PoseHubVoiceGuide? voiceGuide(String exerciseId) => catalog.guide(exerciseId);

  @override
  int? sideSwitchSecondsFor(String exerciseId) =>
      catalog.sideSwitchSeconds(exerciseId);

  @override
  String? voiceGuideClipKey(
    String exerciseId,
    String clipId, {
    required String lang,
  }) {
    if (catalog.guide(exerciseId) == null) return null;
    final key = keyOf(exerciseId, clipId);
    return has(key, lang: lang) ? key : null;
  }

  @override
  List<String> voiceGuideCommonKeys(String key, {required String lang}) {
    final packed = keyOf(CatalogVoiceIndex._commonActionId, key);
    return has(packed, lang: lang)
        ? [packed]
        : primary.voiceGuideCommonKeys(key, lang: lang);
  }

  /// Which language a drill line is looked up in is the script's; this
  /// source answers per key, so it resolves the local key first and falls
  /// back to the catalogue key only when the local pack has no such line in
  /// any of its languages.
  @override
  String? drill(String exerciseId, DrillLine line) {
    final local = primary.drill(exerciseId, line);
    if (local != null &&
        primary.languages.any((l) => primary.has(local, lang: l))) {
      return local;
    }
    final clip = _clipIdOf(line);
    if (clip == null) return local;
    final listed = catalog.languages.any(
      (l) => catalog.clip(exerciseId, clip, l) != null,
    );
    return listed ? keyOf(exerciseId, clip) : local;
  }

  @override
  String? drillText(
    String exerciseId,
    DrillLine line, {
    required String lang,
  }) =>
      primary.drillText(exerciseId, line, lang: lang) ??
      switch (line) {
        DrillLine.name => catalog.name(exerciseId, lang),
        DrillLine.cue1 ||
        DrillLine.intro => catalog.primaryCue(exerciseId, lang),
        _ => null,
      };

  @override
  Future<void> prepare(
    Iterable<String> exerciseIds, {
    required String lang,
  }) async {
    final p = primary;
    if (p is PreparableVoiceSource) {
      await (p as PreparableVoiceSource).prepare(exerciseIds, lang: lang);
    }
    final ids = exerciseIds.toSet();
    final hasGuide = ids.any((id) => catalog.guide(id) != null);
    await cache.prefetch([
      if (hasGuide) ...catalog.commonClipsOf(lang),
      for (final id in ids)
        for (final c in catalog.clipsOf(id, lang))
          if (catalog.guide(id) != null ||
              ((c.clipId == 'name' || c.clipId == 'primaryCue') &&
                  drill(
                        id,
                        c.clipId == 'name' ? DrillLine.name : DrillLine.cue1,
                      ) ==
                      keyOf(id, c.clipId)))
            c,
    ]);
  }

  @override
  String? call(VoiceCall c) => primary.call(c);
  @override
  String? sideWord(String side) => primary.sideWord(side);
  @override
  KitVoice? kitVoice(String exerciseId) => primary.kitVoice(exerciseId);
  @override
  List<String> number(int n) => primary.number(n);
  @override
  List<String> secondsPhrase(int n) => primary.secondsPhrase(n);
  @override
  List<String> minutesPhrase(int n) => primary.minutesPhrase(n);
  @override
  List<String> setsPhrase(int n) => primary.setsPhrase(n);
  @override
  List<String> repsPhrase(int n) => primary.repsPhrase(n);
  @override
  List<String> ordinalSet(int n, {String lang = 'zh'}) =>
      primary.ordinalSet(n, lang: lang);
  @override
  List<String> ordinalRound(int n, {String lang = 'zh'}) =>
      primary.ordinalRound(n, lang: lang);
}
