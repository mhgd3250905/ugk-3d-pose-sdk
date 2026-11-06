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
//    and keeps it in an atomically written cache (the hot-update store);
//  * [LayeredVoiceSource] puts it behind the app's own source: the local
//    pack wins line by line, then the catalogue, and an action with neither
//    keeps the generic calls plus its written intro (subtitle / screen).
//
// Pure Dart except the default file store / HTTP client (conditional io).
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

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

  /// Name of the verified copy in the cache (content addressed, so a new
  /// recording under the same path never reads a stale file).
  String get cacheName => 'catalog-voice/${sha256.substring(0, 2)}/$sha256.m4a';
}

/// The catalogue's voice table: action → language → clip id → clip, plus the
/// written name and primary key point of every action (also those whose
/// voice is still pending).
class CatalogVoiceIndex {
  CatalogVoiceIndex._(this._clips, this._names, this._cues, this.pending);

  static final empty = CatalogVoiceIndex._(
    const {},
    const {},
    const {},
    const {},
  );

  /// From a catalogue JSON map (`pose-hub-app-test-catalog@1`). [baseUrl]
  /// overrides `mediaDistribution.baseUrl`.
  factory CatalogVoiceIndex.fromCatalogJson(
    Map<String, Object?> catalog, {
    Uri? baseUrl,
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
    for (final raw in catalog['actions'] as List? ?? const []) {
      if (raw is! Map) continue;
      final id = raw['id'];
      if (id is! String) continue;
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
      final out = <String, Map<String, CatalogVoiceClip>>{};
      for (final f in files is List ? files : const []) {
        if (f is! Map) continue;
        final lang = f['language'], clip = f['clipId'], path = f['path'];
        final bytes = f['bytes'], sha = f['sha256'];
        if (lang is! String ||
            clip is! String ||
            path is! String ||
            bytes is! int ||
            sha is! String ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) ||
            path.startsWith('/') ||
            path.split('/').contains('..')) {
          continue;
        }
        final url = base != null
            ? base.resolve(path)
            : f['downloadUrl'] is String
            ? Uri.parse(f['downloadUrl'] as String)
            : null;
        if (url == null || url.scheme != 'https') continue;
        final secs = f['durationSeconds'];
        (out[lang] ??= {})[clip] = CatalogVoiceClip(
          actionId: id,
          language: lang,
          clipId: clip,
          path: path,
          bytes: bytes,
          sha256: sha,
          seconds: secs is num ? secs.toDouble() : estimateSeconds(clip),
          url: url,
        );
      }
      if (out.isEmpty) {
        pending.add(id);
      } else {
        clips[id] = out;
      }
    }
    return CatalogVoiceIndex._(clips, names, cues, pending);
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

  /// Actions without any recorded catalogue line (voice still pending).
  final Set<String> pending;

  Iterable<String> get actionIds => {
    ..._clips.keys,
    ...pending,
    ..._names.keys,
  };

  Set<String> get languages => {for (final a in _clips.values) ...a.keys};

  CatalogVoiceClip? clip(String actionId, String clipId, String lang) =>
      _clips[actionId]?[lang]?[clipId];

  List<CatalogVoiceClip> clipsOf(String actionId, String lang) => [
    ...?_clips[actionId]?[lang]?.values,
  ];

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
  }) : http = http ?? createPoseHubCatalogHttpClient();

  /// Cache under [directory] on the device file system (app support dir).
  factory CatalogVoiceCache.files(
    String directory, {
    PoseHubCatalogHttpClient? http,
  }) => CatalogVoiceCache(
    store: createPoseHubCatalogFileStore(directory),
    pathOf: (name) => '$directory/$name',
    http: http,
  );

  final PoseHubCatalogStore store;

  /// File path the player opens for a cache name.
  final String Function(String name) pathOf;
  final PoseHubCatalogHttpClient http;

  final Set<String> _ready = {};
  final Map<String, Future<bool>> _running = {};

  /// The clip is in the cache and verified (synchronous, for the script).
  bool isReady(CatalogVoiceClip c) => _ready.contains(c.sha256);

  /// Path of a ready clip.
  String path(CatalogVoiceClip c) => pathOf(c.cacheName);

  /// Make [c] ready: a verified cached copy, else a verified download.
  /// Never throws; false when it could not be made ready.
  Future<bool> ensure(CatalogVoiceClip c) {
    if (isReady(c)) return Future.value(true);
    // The block body matters: whenComplete waits for a returned future, and
    // remove() would return this very future.
    return _running[c.sha256] ??= _ensure(c).whenComplete(() {
      _running.remove(c.sha256);
    });
  }

  static bool _valid(List<int> b, CatalogVoiceClip c) =>
      b.length == c.bytes && crypto.sha256.convert(b).toString() == c.sha256;

  Future<bool> _ensure(CatalogVoiceClip c) async {
    try {
      final cached = await store.read(c.cacheName);
      if (cached != null && _valid(cached, c)) {
        _ready.add(c.sha256);
        return true;
      }
      if (cached != null) await store.delete(c.cacheName);
      final r = await http.get(c.url, maxBytes: c.bytes + 1024);
      if (r.statusCode != 200 || !_valid(r.body, c)) return false;
      await store.writeAtomic(c.cacheName, r.body);
      _ready.add(c.sha256);
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
    final queue = [...clips];
    var ready = 0;
    final failed = <String>[];
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final c = queue.removeAt(0);
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
  });

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
    return p == null ? null : catalog.clip(p.$1, p.$2, lang);
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
    return switch (p.$2) {
      'name' => catalog.name(p.$1, lang),
      'primaryCue' => catalog.primaryCue(p.$1, lang),
      _ => null,
    };
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
    await cache.prefetch([
      for (final id in ids)
        for (final c in catalog.clipsOf(id, lang))
          if (c.clipId == 'name' || c.clipId == 'primaryCue')
            if (drill(
                  id,
                  c.clipId == 'name' ? DrillLine.name : DrillLine.cue1,
                ) ==
                keyOf(id, c.clipId))
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
