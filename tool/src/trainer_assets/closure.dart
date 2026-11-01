/// Exact, integrity-checked assets for one host; no network or player estimates.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ugk_coach/ugk_coach.dart';

typedef AssetJson = Map<String, Object?>;

class TrainerAssetConfigurationException implements Exception {
  const TrainerAssetConfigurationException(this.code, this.field);
  final String code;
  final String field;
  @override
  String toString() => 'TrainerAssetConfigurationException($code, $field)';
}

class TrainerAssetClosureResult {
  TrainerAssetClosureResult({
    required this.outputDirectory,
    required this.allowedActionIds,
    required this.files,
  });
  final Directory outputDirectory;
  final List<String> allowedActionIds;
  final List<AssetJson> files;
  int get totalBytes =>
      files.fold(0, (sum, file) => sum + (file['bytes'] as int));
}

/// Validates the entire closure before creating or writing the output.
///
/// Inputs are read-only. All runtime file references come from the declared
/// PoseHub delivery, selected kits, selected voice keys or explicit shared list.
/// Legacy cross-App source bindings in semantic metadata are projected to this
/// delivery; they are never mistaken for copied runtime resources.
Future<TrainerAssetClosureResult> generateTrainerAssetClosure({
  required File manifestFile,
  required Directory outputDirectory,
  String assetPrefix = 'assets/trainer',
}) async {
  final builder = _ClosureBuilder(
    manifestFile: manifestFile,
    outputDirectory: outputDirectory,
    assetPrefix: assetPrefix,
  );
  builder.prepare();
  return builder.write();
}

Never _fail(String code, String field) =>
    throw TrainerAssetConfigurationException(code, field);

AssetJson _object(Object? value, String field) {
  if (value is! Map<String, Object?>) _fail('invalid_object', field);
  return Map<String, Object?>.from(value);
}

List<Object?> _array(Object? value, String field) {
  if (value is! List<Object?>) _fail('invalid_array', field);
  return value;
}

String _text(Object? value, String field) {
  if (value is! String || value.isEmpty || value.trim() != value) {
    _fail('invalid_text', field);
  }
  return value;
}

String _relative(Object? value, String field) {
  final path = _text(value, field);
  if (path.startsWith('/') ||
      path.contains(RegExp(r'[\\:%?#\x00-\x20\x7f]')) ||
      path
          .split('/')
          .any((segment) => segment.isEmpty || segment.startsWith('.'))) {
    _fail('unsafe_relative_path', field);
  }
  return path;
}

String _safeId(Object? value, String field) {
  final id = _text(value, field);
  if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) _fail('invalid_id', field);
  return id;
}

List<String> _uniqueStrings(
  Object? value,
  String field, {
  bool nonempty = false,
}) {
  final list = [for (final entry in _array(value, field)) _text(entry, field)];
  if (nonempty && list.isEmpty) _fail('empty_allowlist', field);
  if (list.toSet().length != list.length) _fail('duplicate_value', field);
  return list;
}

Uint8List _encoded(Object? value) => Uint8List.fromList(
  utf8.encode('${const JsonEncoder.withIndent('  ').convert(value)}\n'),
);

String _digest(List<int> bytes) => sha256.convert(bytes).toString();

bool _inside(String candidate, String root) {
  final value = Platform.isWindows ? candidate.toLowerCase() : candidate;
  final parent = Platform.isWindows ? root.toLowerCase() : root;
  return value == parent ||
      value.startsWith('$parent${Platform.pathSeparator}');
}

String _sourceRoot(Directory base, String path) {
  final absolute = Platform.isWindows
      ? RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path) || path.startsWith(r'\\')
      : path.startsWith('/');
  final directory = absolute
      ? Directory(path)
      : Directory.fromUri(base.uri.resolve(path.replaceAll(r'\', '/')));
  if (!directory.existsSync()) _fail('missing_source_root', 'sourceRoots');
  return directory.resolveSymbolicLinksSync();
}

class _Entry {
  _Entry(this.path, this.bytes, {required this.generated});
  final String path;
  final Uint8List bytes;
  final bool generated;
  final Set<String> owners = {};
  final Set<String> kinds = {};
  AssetJson proof(String prefix) => {
    'path': path,
    'assetKey': '$prefix/$path',
    'bytes': bytes.length,
    'sha256': _digest(bytes),
    'owners': owners.toList()..sort(),
    'kinds': kinds.toList()..sort(),
    'generated': generated,
  };
}

class _ClosureBuilder {
  _ClosureBuilder({
    required this.manifestFile,
    required this.outputDirectory,
    required String assetPrefix,
  }) : prefix = _relative(assetPrefix, 'assetPrefix');

  final File manifestFile;
  final Directory outputDirectory;
  final String prefix;
  late AssetJson manifest;
  late String appId;
  late List<String> ids;
  late Set<String> allowed;
  late List<String> roots;
  late AssetJson integrity;
  final Map<String, _Entry> entries = {};
  final Set<String> foldedPaths = {};
  final List<AssetJson> sourceMetadata = [];
  final Set<String> neededVoiceKeys = {};
  final Map<String, Set<String>> voiceOwners = {};
  final Map<String, Set<String>> knownAssetOwners = {};
  final Set<String> selectedKitIds = {};
  final List<AssetJson> omittedLegacyBindings = [];
  late String originalCatalogSha;
  late AssetJson originalCatalog;
  late AssetJson semantic;
  late Map<String, AssetJson> actionById;
  late List<AssetJson> selected;
  AssetJson? voiceConfig;
  late String voicePolicy;
  late String kitPolicy;

  void prepare() {
    if (outputDirectory.existsSync() && outputDirectory.listSync().isNotEmpty) {
      _fail('output_not_empty', 'out');
    }
    manifest = _object(jsonDecode(manifestFile.readAsStringSync()), 'manifest');
    if (manifest['schemaVersion'] != 1) {
      _fail('unsupported_schema', 'schemaVersion');
    }
    if (manifest.containsKey('sharedAssets')) {
      _fail('unsupported_shared_assets', 'sharedAssets');
    }
    if (manifest['includeStanding'] != null &&
        manifest['includeStanding'] is! bool) {
      _fail('invalid_flag', 'includeStanding');
    }
    if (manifest['adapter'] != 'pose-hub-delivery@1') {
      _fail('unsupported_adapter', 'adapter');
    }
    voicePolicy = _text(manifest['voicePolicy'], 'voicePolicy');
    kitPolicy = _text(manifest['kitPolicy'], 'kitPolicy');
    if (!{'silent', 'manifest'}.contains(voicePolicy) ||
        (voicePolicy == 'manifest') != (manifest['voice'] != null)) {
      _fail('invalid_voice_policy', 'voicePolicy');
    }
    if (!{'none', 'index'}.contains(kitPolicy) ||
        (kitPolicy == 'index') != (manifest['actionKitIndex'] != null)) {
      _fail('invalid_kit_policy', 'kitPolicy');
    }
    appId = _safeId(manifest['appId'], 'appId');
    ids = _uniqueStrings(
      manifest['allowedActionIds'],
      'allowedActionIds',
      nonempty: true,
    )..sort();
    for (final id in ids) {
      _safeId(id, 'allowedActionIds');
    }
    allowed = ids.toSet();
    final base = manifestFile.absolute.parent;
    roots = [
      for (final value in _array(manifest['sourceRoots'], 'sourceRoots'))
        _sourceRoot(base, _text(value, 'sourceRoots')),
    ];
    if (roots.isEmpty || roots.toSet().length != roots.length) {
      _fail('invalid_source_roots', 'sourceRoots');
    }
    integrity = manifest['integrity'] == null
        ? {}
        : _object(manifest['integrity'], 'integrity');
    for (final key in integrity.keys) {
      _relative(key, 'integrity');
    }
    final catalogPath = _relative(manifest['catalog'], 'catalog');
    final catalogBytes = _source(catalogPath);
    originalCatalogSha = _digest(catalogBytes);
    if (manifest['catalogSha256'] != null &&
        manifest['catalogSha256'] != originalCatalogSha) {
      _fail('hash_mismatch', 'catalogSha256');
    }
    originalCatalog = _object(jsonDecode(utf8.decode(catalogBytes)), 'catalog');
    final semanticRef = _object(
      originalCatalog['semanticCatalog'],
      'semanticCatalog',
    );
    final semanticPath = _relative(semanticRef['path'], 'semanticCatalog.path');
    final semanticBytes = _source(semanticPath, receipt: semanticRef);
    semantic = _object(
      jsonDecode(utf8.decode(semanticBytes)),
      'semanticCatalog',
    );
    try {
      PoseHubAppTestCatalog.fromBytes(
        catalogBytes,
        semanticCatalogBytes: semanticBytes,
      );
    } on Object {
      _fail('invalid_source_catalog', 'catalog');
    }
    sourceMetadata.addAll([
      {
        'path': catalogPath,
        'sha256': originalCatalogSha,
        'bytes': catalogBytes.length,
      },
      {
        'path': semanticPath,
        'sha256': _digest(semanticBytes),
        'bytes': semanticBytes.length,
      },
    ]);
    actionById = {
      for (final value in _array(originalCatalog['actions'], 'actions'))
        _text(_object(value, 'action')['id'], 'action.id'): _object(
          value,
          'action',
        ),
    };
    for (final action in actionById.values) {
      final id = action['id']! as String;
      for (final raw in _object(action['files'], 'action.files').values) {
        final path = _relative(
          _object(raw, 'action.file')['path'],
          'action.file.path',
        );
        (knownAssetOwners[path] ??= {}).add(id);
      }
      (knownAssetOwners['standing/$id.webp'] ??= {}).add(id);
    }
    for (final raw in _array(semantic['drills'], 'semantic.drills')) {
      final drill = _object(raw, 'semantic.drill');
      final id = _text(drill['id'], 'semantic.drill.id');
      final assets = _object(drill['assets'] ?? {}, 'semantic.assets');
      for (final kind in ['cover', 'video']) {
        final category = _object(assets[kind] ?? {}, 'semantic.assets.$kind');
        for (final raw in _array(
          category['sources'] ?? [],
          'semantic.asset.sources',
        )) {
          final path = _object(raw, 'semantic.asset.source')['path'];
          if (path is String) {
            (knownAssetOwners[path] ??= {}).add(id);
          }
        }
      }
    }
    if (ids.any((id) => !actionById.containsKey(id))) {
      _fail('unknown_action_id', 'allowedActionIds');
    }
    selected = [for (final id in ids) _clone(actionById[id]!)];
    for (final action in selected) {
      final id = action['id']! as String;
      final files = _object(action['files'], 'action.files');
      for (final kind in ['video', 'cover', 'thumbnail']) {
        final receipt = _object(files[kind], 'action.files.$kind');
        _copy(
          _relative(receipt['path'], 'action.files.$kind.path'),
          id,
          kind,
          receipt: receipt,
        );
      }
      if (manifest['includeStanding'] == true) {
        _copy('standing/$id.webp', id, 'standing');
      }
      _filterActionReferences(action);
    }
    if (manifest['actionKitIndex'] != null) _kits();
    if (manifest['voice'] != null) _voice();
    _project(catalogPath, semanticPath);
  }

  AssetJson _clone(AssetJson value) =>
      _object(jsonDecode(jsonEncode(value)), 'clone');

  Uint8List _source(
    String path, {
    AssetJson? receipt,
    bool requireReceipt = false,
  }) {
    final matches = <Uint8List>[];
    for (final root in roots) {
      final file = File.fromUri(Directory(root).uri.resolve(path));
      if (!file.existsSync()) continue;
      final resolved = file.resolveSymbolicLinksSync();
      if (!_inside(resolved, root)) _fail('source_escaped_root', path);
      matches.add(File(resolved).readAsBytesSync());
    }
    if (matches.isEmpty) _fail('missing_asset', path);
    final bytes = matches.first;
    if (bytes.isEmpty) _fail('empty_asset', path);
    if (matches.skip(1).any((other) => _digest(other) != _digest(bytes))) {
      _fail('ambiguous_source_asset', path);
    }
    final declared =
        receipt ??
        (integrity[path] == null
            ? null
            : _object(integrity[path], 'integrity.$path'));
    if (declared == null && requireReceipt) _fail('missing_integrity', path);
    if (declared != null) {
      final hash = declared['sha256'];
      final length = declared['bytes'];
      if (hash is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
          length is! int ||
          length <= 0) {
        _fail('invalid_integrity', path);
      }
      if (bytes.length != length) _fail('size_mismatch', path);
      if (_digest(bytes) != hash) _fail('hash_mismatch', path);
    }
    return bytes;
  }

  void _copy(String path, String? owner, String kind, {AssetJson? receipt}) {
    final knownOwners = knownAssetOwners[path] ?? const <String>{};
    if (knownOwners.any((id) => !allowed.contains(id))) {
      _fail('asset_owner_outside_allowlist', path);
    }
    final extension = path.split('.').last.toLowerCase();
    if ((kind == 'kit-poster' &&
            !{'png', 'webp', 'jpg', 'jpeg', 'avif'}.contains(extension)) ||
        (kind == 'kit-video' && !{'mp4', 'webm'}.contains(extension))) {
      _fail('invalid_kit_media_extension', path);
    }
    final bytes = _source(path, receipt: receipt, requireReceipt: true);
    _add(path, bytes, owner, kind, generated: false);
  }

  void _add(
    String path,
    Uint8List bytes,
    String? owner,
    String kind, {
    required bool generated,
  }) {
    _relative(path, 'output.path');
    final key = path.toLowerCase();
    final existing = entries[path];
    if (existing != null) {
      if (existing.generated != generated ||
          _digest(existing.bytes) != _digest(bytes)) {
        _fail('conflicting_asset', path);
      }
      if (owner != null) existing.owners.add(owner);
      existing.kinds.add(kind);
      return;
    }
    if (!foldedPaths.add(key) ||
        {'asset-closure.json', 'pubspec-assets.yaml'}.contains(path)) {
      _fail('duplicate_output_path', path);
    }
    final entry = _Entry(path, bytes, generated: generated)..kinds.add(kind);
    if (owner != null) entry.owners.add(owner);
    entries[path] = entry;
  }

  void _filterActionReferences(AssetJson action) {
    for (final field in ['alternative', 'replacedFrom']) {
      final value = action[field];
      if (value is String && !allowed.contains(value)) action[field] = null;
    }
    if (action['alternatives'] case final List<Object?> values) {
      action['alternatives'] = values.where(allowed.contains).toList();
    }
  }

  void _kits() {
    final indexPath = _relative(manifest['actionKitIndex'], 'actionKitIndex');
    final rawBytes = _source(indexPath, requireReceipt: true);
    final index = _object(jsonDecode(utf8.decode(rawBytes)), 'kitIndex');
    final byId = <String, (String, AssetJson?)>{};
    final paths = <String>{};
    for (final value in _array(index['kits'], 'kitIndex.kits')) {
      final receipt = value is String ? null : _object(value, 'kitIndex.kit');
      final path = _relative(
        receipt == null ? value : receipt['path'],
        'kitIndex.kit.path',
      );
      final name = path.split('/').last;
      if (receipt == null && !name.endsWith('.json')) {
        _fail('invalid_kit_index_path', path);
      }
      final id = _safeId(
        receipt == null ? name.substring(0, name.length - 5) : receipt['id'],
        'kitIndex.kit.id',
      );
      if (byId.containsKey(id)) _fail('duplicate_action_kit', 'actionKit.id');
      if (!paths.add(path.toLowerCase())) _fail('duplicate_kit_path', path);
      if (!actionById.containsKey(id)) _fail('unknown_action_kit', id);
      byId[id] = (path, receipt);
    }
    final selectedPaths = <String>[];
    for (final id in ids) {
      final source = byId[id];
      if (source == null) _fail('missing_action_kit', id);
      final (path, receipt) = source;
      final bytes = _source(path, receipt: receipt, requireReceipt: true);
      final kit = _object(jsonDecode(utf8.decode(bytes)), 'actionKit');
      if (kit['schema'] != 'action-kit@1' || kit['id'] != id) {
        _fail('invalid_action_kit', id);
      }
      sourceMetadata.add({
        'path': path,
        'sha256': _digest(bytes),
        'bytes': bytes.length,
      });
      _filterActionReferences(kit);
      final display = _object(kit['display'], 'actionKit.display');
      final posters = _object(display['poster'], 'actionKit.display.poster');
      for (final key in posters.keys.toList()) {
        final poster = posters[key];
        if (poster is String) {
          final asset = _relative(poster, 'actionKit.poster');
          _copy(asset, id, 'kit-poster');
          posters[key] = '$prefix/$asset';
        } else {
          final receipt = _object(poster, 'actionKit.poster');
          final asset = _relative(receipt['asset'], 'actionKit.poster.asset');
          _copy(asset, id, 'kit-poster', receipt: receipt);
          posters[key] = {...receipt, 'asset': '$prefix/$asset'};
        }
      }
      display['poster'] = posters;
      kit['display'] = display;
      final media = _object(kit['media'], 'actionKit.media');
      final videos = _object(media['video'], 'actionKit.media.video');
      for (final key in videos.keys.toList()) {
        final receipt = _object(videos[key], 'actionKit.video');
        final asset = _relative(receipt['asset'], 'actionKit.video.asset');
        _copy(
          asset,
          id,
          'kit-video',
          receipt: receipt.containsKey('sha256') ? receipt : null,
        );
        videos[key] = {...receipt, 'asset': '$prefix/$asset'};
      }
      media['video'] = videos;
      kit['media'] = media;
      final voice = _object(kit['voice'], 'actionKit.voice');
      void addVoice(Object? raw) {
        final key = _text(raw, 'actionKit.voice.key');
        neededVoiceKeys.add(key);
        (voiceOwners[key] ??= {}).add(id);
      }

      for (final key in _object(
        voice['lines'] ?? {},
        'actionKit.voice.lines',
      ).keys) {
        addVoice(key);
      }
      for (final field in ['prepare', 'coach']) {
        for (final key in _uniqueStrings(
          voice[field] ?? const [],
          'actionKit.voice.$field',
        )) {
          addVoice(key);
        }
      }
      for (final field in [
        'go',
        'count',
        'lastRep',
        'nextSet',
        'end',
        'firstSide',
      ]) {
        if (voice[field] != null) {
          addVoice(voice[field]);
        }
      }
      for (final field in ['switch', 'midHold']) {
        if (voice[field] case final Map<String, Object?> values) {
          for (final value in values.values.whereType<String>()) {
            addVoice(value);
          }
        }
      }
      final training = _object(kit['training'], 'actionKit.training');
      if (training['cycle'] case final Map<String, Object?> cycle) {
        for (final raw in _array(
          cycle['phases'] ?? const [],
          'actionKit.training.phases',
        )) {
          final phase = _object(raw, 'actionKit.training.phase');
          if (phase['cue'] != null) {
            addVoice(phase['cue']);
          }
        }
      }
      kit.remove('voiceLegacy');
      _add(path, _encoded(kit), id, 'action-kit', generated: true);
      selectedKitIds.add(id);
      selectedPaths.add('$prefix/$path');
    }
    if (neededVoiceKeys.isNotEmpty && manifest['voice'] == null) {
      _fail('missing_voice_configuration', 'voice');
    }
    _add(
      indexPath,
      _encoded({
        'schema': index['schema'] ?? 'action-kit-index@1',
        'kits': selectedPaths,
      }),
      null,
      'kit-index',
      generated: true,
    );
    sourceMetadata.add({
      'path': indexPath,
      'sha256': _digest(rawBytes),
      'bytes': rawBytes.length,
    });
  }

  void _voice() {
    final config = _object(manifest['voice'], 'voice');
    voiceConfig = config;
    final manifestPath = _relative(config['manifest'], 'voice.manifest');
    final voiceRoot = _relative(config['root'], 'voice.root');
    final languages = _uniqueStrings(
      config['languages'],
      'voice.languages',
      nonempty: true,
    );
    for (final lang in languages) {
      _safeId(lang, 'voice.languages');
    }
    final shared = _uniqueStrings(
      config['sharedKeys'] ?? const [],
      'voice.sharedKeys',
    );
    for (final key in shared) {
      final owner = _voiceOwner(key);
      if ((key.startsWith('drill.') || key.startsWith('point.')) &&
          owner == null) {
        _fail('voice_owner_outside_allowlist', key);
      }
      if (owner == null && !_sharedVoiceKey(key)) {
        _fail('unsupported_shared_voice_key', key);
      }
    }
    final chimes = _uniqueStrings(
      config['chimes'] ?? const [],
      'voice.chimes',
    ).toSet();
    final bytes = _source(manifestPath, requireReceipt: true);
    final source = _object(jsonDecode(utf8.decode(bytes)), 'voiceManifest');
    final clips = _object(source['clips'], 'voice.clips');
    final sourceKeys = <String>{
      for (final lang in languages)
        ..._object(clips[lang], 'voice.clips.$lang').keys,
    };
    final keys = <String>{...shared};
    for (final id in ids) {
      for (final key in ['drill.$id', 'point.$id']) {
        keys.add(key);
        (voiceOwners[key] ??= {}).add(id);
      }
    }
    for (final pattern in neededVoiceKeys) {
      if (pattern.startsWith('chime.')) {
        chimes.add(pattern.substring(6));
        continue;
      }
      if (pattern.contains('{k}')) {
        final regex = RegExp(
          '^${RegExp.escape(pattern).replaceAll(r'\{k\}', r'[0-9]+')}\$',
        );
        final expanded = sourceKeys.where(regex.hasMatch).toList();
        if (expanded.isEmpty) _fail('missing_voice_pattern', pattern);
        keys.addAll(expanded);
        for (final key in expanded) {
          (voiceOwners[key] ??= {}).addAll(voiceOwners[pattern] ?? {});
        }
      } else {
        keys.add(pattern);
      }
    }
    for (final key in keys) {
      _relative(key, 'voice.key');
      for (final namedPrefix in ['drill.', 'point.']) {
        if (key.startsWith(namedPrefix) &&
            !allowed.contains(key.substring(namedPrefix.length))) {
          _fail('voice_owner_outside_allowlist', key);
        }
      }
    }
    final selectedClips = <String, Object?>{};
    for (final lang in languages) {
      final available = _object(clips[lang], 'voice.clips.$lang');
      final kept = <String, Object?>{};
      for (final key in keys.toList()..sort()) {
        if (!available.containsKey(key)) {
          _fail('missing_voice_key', '$lang/$key');
        }
        _copy('$voiceRoot/$lang/$key.m4a', _voiceOwner(key), 'voice');
        entries['$voiceRoot/$lang/$key.m4a']!.owners.addAll(
          voiceOwners[key] ?? {},
        );
        kept[key] = _voiceDuration(available[key], '$lang/$key');
      }
      selectedClips[lang] = kept;
    }
    final sourceChimes = _object(source['chimes'] ?? {}, 'voice.chimes');
    final keptChimes = <String, Object?>{};
    for (final key in chimes) {
      _relative(key, 'voice.chimes');
      if (!sourceChimes.containsKey(key)) _fail('missing_chime', key);
      _copy('$voiceRoot/chime/$key.m4a', null, 'chime');
      keptChimes[key] = _voiceDuration(sourceChimes[key], key);
    }
    final lines = _object(source['lines'] ?? {}, 'voice.lines');
    final texts = _object(source['texts'] ?? {}, 'voice.texts');
    _add(
      manifestPath,
      _encoded({
        'clips': selectedClips,
        'chimes': keptChimes,
        'lines': {
          for (final entry in lines.entries)
            if (keys.contains(entry.key))
              entry.key: {
                for (final lang in languages)
                  if (_object(entry.value, 'voice.line').containsKey(lang))
                    lang: _object(entry.value, 'voice.line')[lang],
              },
        },
        'texts': {
          for (final entry in texts.entries)
            entry.key: {
              for (final text in _object(entry.value, 'voice.text').entries)
                if (keys.contains(text.value)) text.key: text.value,
            },
        },
      }),
      null,
      'voice-manifest',
      generated: true,
    );
    sourceMetadata.add({
      'path': manifestPath,
      'sha256': _digest(bytes),
      'bytes': bytes.length,
    });
  }

  String? _voiceOwner(String key) {
    for (final id in ids) {
      if (key == 'drill.$id' || key == 'point.$id') return id;
    }
    return null;
  }

  num _voiceDuration(Object? value, String key) {
    if (value is! num || !value.isFinite || value <= 0) {
      _fail('invalid_voice_duration', key);
    }
    return value;
  }

  bool _sharedVoiceKey(String key) =>
      const {
        'p.welcome',
        'p.total',
        'p.first',
        'p.next',
        'p.last',
        'p.rest',
        'p.go',
        'p.go_right',
        'p.right_first',
        'p.switch_left',
        'p.switch_right',
        'p.finish',
        'p.nice',
        'p.ready',
        'p.half',
        'p.last10',
        'p.each_side',
        'p.last_rep',
        'p.again',
        'p.paused',
        'p.resume',
      }.contains(key) ||
      RegExp(r'^(?:n|sec|min)\.[1-9][0-9]*$').hasMatch(key);

  void _project(String catalogPath, String semanticPath) {
    final semantics = _clone(semantic);
    final projectedDrills = <AssetJson>[];
    for (final raw in _array(semantic['drills'], 'semantic.drills')) {
      final drill = _object(raw, 'semantic.drill');
      final id = _text(drill['id'], 'semantic.drill.id');
      if (!allowed.contains(id)) continue;
      final kept = _clone(drill);
      _filterActionReferences(kept);
      final action = actionById[id]!;
      final files = _object(action['files'], 'action.files');
      final priorAssets = _object(drill['assets'] ?? {}, 'semantic.assets');
      omittedLegacyBindings.add({
        'actionId': id,
        'fields': priorAssets.keys.toList()..sort(),
        'reason': 'replaced by explicit delivery/kit/voice policies',
      });
      final priorSources = _object(
        priorAssets['video'] ?? {},
        'semantic.video',
      )['sources'];
      num? repSeconds;
      for (final value
          in priorSources is List<Object?> ? priorSources : const <Object?>[]) {
        final seconds = _object(value, 'semantic.video.source')['repSeconds'];
        if (seconds is num && seconds > 0) {
          repSeconds = seconds;
          break;
        }
      }
      AssetJson source(String kind) => {
        ..._object(files[kind], 'action.file'),
        'app': appId,
        'path': '$prefix/${_object(files[kind], 'action.file')['path']}',
        if (kind == 'video' && repSeconds != null) 'repSeconds': repSeconds,
      };
      kept['assets'] = {
        'cover': {
          'status': 'ok',
          'sources': [source('cover')],
        },
        'video': {
          'status': 'ok',
          'sources': [source('video')],
        },
        'voice': {
          'status': voicePolicy == 'silent' ? 'missing' : 'ok',
          'languages': voiceConfig?['languages'] ?? const [],
          if (voiceConfig != null) ...{
            'manifest': '$prefix/${voiceConfig!['manifest']}',
            'keys': ['drill.$id', 'point.$id'],
          },
        },
        if (selectedKitIds.contains(id))
          'drillPack': {'status': 'ok', 'app': appId, 'kind': 'action-kit@1'},
      };
      projectedDrills.add(kept);
    }
    semantics['drills'] = projectedDrills;
    semantics.remove('apps');
    final semanticBytes = _encoded(semantics);
    final semanticHash = _digest(semanticBytes);
    _add(
      semanticPath,
      semanticBytes,
      null,
      'semantic-catalog',
      generated: true,
    );
    for (final action in selected) {
      final rhythm = _object(action['rhythm'], 'action.rhythm');
      if (rhythm['executionSource'] case final Map<String, Object?> source) {
        rhythm['executionSource'] = {...source, 'sha256': semanticHash};
      }
      action['rhythm'] = rhythm;
      final training = _object(
        action['trainingSemantics'],
        'action.trainingSemantics',
      );
      training['evidence'] = [
        for (final value in _array(
          training['evidence'] ?? const [],
          'training.evidence',
        ))
          if (_object(value, 'evidence')['actionId'] == null ||
              allowed.contains(_object(value, 'evidence')['actionId']))
            {
              ..._object(value, 'evidence'),
              if (_object(value, 'evidence')['path'] == semanticPath) ...{
                'sha256': semanticHash,
                'bytes': semanticBytes.length,
              },
            },
      ];
      action['trainingSemantics'] = training;
    }
    final summary = _object(
      originalCatalog['trainingSemantics'],
      'trainingSemantics',
    );
    final complete = [
      for (final a in selected)
        if (a['trainingDefinitionComplete'] == true) a['id'],
    ];
    final incomplete = [
      for (final a in selected)
        if (a['trainingDefinitionComplete'] != true) a['id'],
    ];
    final distribution = _object(
      originalCatalog['mediaDistribution'],
      'mediaDistribution',
    );
    final media = [
      for (final a in selected)
        ..._object(a['files'], 'files').values.map((v) => _object(v, 'file')),
    ];
    final projected = <String, Object?>{
      for (final field in [
        'format',
        'id',
        'status',
        'reviewed',
        'releaseEligible',
        'sourceCommit',
        'snapshotSha256',
        'releaseManifestSha256',
      ])
        if (originalCatalog.containsKey(field)) field: originalCatalog[field],
      'scope': {'total': ids.length, 'allowedActionIds': ids},
      'latestOverrides': {
        for (final entry in _object(
          originalCatalog['latestOverrides'] ?? {},
          'latestOverrides',
        ).entries)
          if (allowed.contains(entry.key)) entry.key: entry.value,
      },
      'actions': selected,
      'semanticCatalog': {
        ..._object(originalCatalog['semanticCatalog'], 'semanticCatalog'),
        'path': semanticPath,
        'bytes': semanticBytes.length,
        'sha256': semanticHash,
      },
      'trainingSemantics': {
        for (final field in [
          'format',
          'status',
          'reviewed',
          'releaseEligible',
          'semanticRevision',
        ])
          if (summary.containsKey(field)) field: summary[field],
        'definitionCompleteIds': complete,
        'definitionCompleteCount': complete.length,
        'incompleteActionIds': incomplete,
        'videoLoopIsTrainingDose': false,
      },
      'readyCount': ids.length,
      'pendingCount': 0,
      'totalCount': ids.length,
      'pendingIds': const [],
      'mediaDistribution': {
        ...distribution,
        'mediaFiles': media.length,
        'mediaBytes': media.fold<int>(
          0,
          (sum, file) => sum + (file['bytes'] as int),
        ),
      },
    };
    final catalogBytes = _encoded(projected);
    try {
      PoseHubAppTestCatalog.fromBytes(
        catalogBytes,
        semanticCatalogBytes: semanticBytes,
      );
    } on Object {
      _fail('invalid_projected_catalog', 'output.catalog');
    }
    _add(catalogPath, catalogBytes, null, 'delivery-catalog', generated: true);
  }

  Future<TrainerAssetClosureResult> write() async {
    final paths = entries.keys.toList()..sort();
    final proofFiles = [for (final path in paths) entries[path]!.proof(prefix)];
    await outputDirectory.create(recursive: true);
    final resolvedOut = outputDirectory.resolveSymbolicLinksSync();
    for (final path in paths) {
      final file = File.fromUri(Directory(resolvedOut).uri.resolve(path));
      if (!_inside(file.absolute.path, resolvedOut)) {
        _fail('output_escaped_root', path);
      }
      await file.parent.create(recursive: true);
      await file.writeAsBytes(entries[path]!.bytes, flush: true);
    }
    await File.fromUri(
      outputDirectory.uri.resolve('asset-closure.json'),
    ).writeAsBytes(
      _encoded({
        'schemaVersion': 1,
        'appId': appId,
        'allowedActionIds': ids,
        'allowlistSha256': _digest(utf8.encode('${ids.join('\n')}\n')),
        'sourceCatalogSha256': originalCatalogSha,
        'sourceMetadata': sourceMetadata,
        'assetPrefix': prefix,
        'projection': {
          'kind': 'pose-hub-delivery@1',
          'semanticRuntimeAssets':
              'selected delivery media, not historical cross-App source bindings',
          'doseAndRhythm':
              'preserved; first declared positive repSeconds retained',
          'voicePolicy': voicePolicy,
          'kitPolicy': kitPolicy,
          'voiceRoot': voiceConfig == null
              ? null
              : '$prefix/${voiceConfig!['root']}',
          'actionKitIds': selectedKitIds.toList()..sort(),
          'omittedLegacyBindings': omittedLegacyBindings,
        },
        'files': proofFiles,
        'generatedMetadata': proofFiles
            .where((file) => file['generated'] == true)
            .toList(),
      }),
      flush: true,
    );
    await File.fromUri(
      outputDirectory.uri.resolve('pubspec-assets.yaml'),
    ).writeAsString(
      'flutter:\n  assets:\n${proofFiles.map((file) => '    - ${file['assetKey']}').join('\n')}\n',
      flush: true,
    );
    return TrainerAssetClosureResult(
      outputDirectory: outputDirectory,
      allowedActionIds: List.unmodifiable(ids),
      files: List.unmodifiable(proofFiles),
    );
  }
}
