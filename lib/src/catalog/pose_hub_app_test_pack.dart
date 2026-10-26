/// Read-only Pose-Hub app-test pack metadata, separate from the AI catalog.
///
/// Listing and preview do not imply that a training definition is complete or
/// that the upstream media has been reviewed. Original fields remain intact.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'catalog.dart';

/// An original, integrity-addressed file inside the external pack.
final class PoseHubPackFile {
  PoseHubPackFile._(this.raw)
    : path = _path(raw['path'], 'file.path'),
      bytes = _integer(raw['bytes'], 'file.bytes', minimum: 1),
      sha256 = _hash(raw['sha256'], 'file.sha256') {
    for (final dimension in ['width', 'height']) {
      if (raw.containsKey(dimension)) {
        _integer(raw[dimension], 'file.$dimension', minimum: 1);
      }
    }
    if (raw['downloadUrl'] != null) {
      _httpsUri(raw['downloadUrl'], 'file.downloadUrl');
    }
    if (raw['assetName'] != null &&
        _assetName(raw['assetName'], 'file.assetName') !=
            path.split('/').last) {
      throw const FormatException('File assetName differs from its basename');
    }
  }

  factory PoseHubPackFile.fromJson(Object? json) =>
      PoseHubPackFile._(_frozenMap(json, 'file'));

  final String path;
  final int bytes;
  final String sha256;
  final Map<String, Object?> raw;

  /// Optional public download location. Legacy catalogues do not declare one.
  /// Hosts verify [bytes] and [sha256], then store the file at its original
  /// [path]; [resolve] continues to address the installed or same-origin file.
  Uri? get downloadUri {
    final value = raw['downloadUrl'];
    if (value == null) return null;
    return _httpsUri(value, 'file.downloadUrl');
  }

  /// Resolves only beneath a directory base. Media bytes are not fetched here.
  /// HTTP(S), local file and relative asset-directory bases are supported.
  Uri resolve(Uri baseUri) {
    if (!['', 'http', 'https', 'file'].contains(baseUri.scheme) ||
        baseUri.userInfo.isNotEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment ||
        !baseUri.path.endsWith('/') ||
        baseUri.pathSegments.any((s) => s == '.' || s == '..') ||
        (['http', 'https'].contains(baseUri.scheme) &&
            (!baseUri.hasAuthority || baseUri.host.isEmpty)) ||
        (baseUri.scheme.isEmpty && baseUri.hasAuthority)) {
      throw const FormatException('Pack base must be a safe directory URI');
    }
    final result = baseUri.resolve(path);
    if (result.scheme != baseUri.scheme ||
        result.authority != baseUri.authority ||
        !result.path.startsWith(baseUri.path)) {
      throw const FormatException('Pack file escaped its base directory');
    }
    return result;
  }
}

/// All source semantics, including null/unknown values, are preserved in [raw].
final class PoseHubPackAction {
  PoseHubPackAction._(this.raw)
    : id = _id(raw['id'], 'action.id'),
      nameZh = _text(raw['nameZh'], 'action.nameZh'),
      trainingDefinitionComplete = _boolean(
        raw['trainingDefinitionComplete'],
        'action.trainingDefinitionComplete',
      ),
      availableForTraining = _boolean(
        raw['availableForTraining'],
        'action.availableForTraining',
      ),
      availableForApp = _boolean(
        raw['availableForApp'],
        'action.availableForApp',
      ) {
    final sourceFiles = _map(raw['files'], '$id.files');
    if (sourceFiles.keys.toSet().difference(_mediaKinds).isNotEmpty ||
        _mediaKinds.difference(sourceFiles.keys.toSet()).isNotEmpty) {
      throw FormatException('$id must declare video, cover and thumbnail');
    }
    files = Map.unmodifiable({
      for (final kind in _mediaKinds)
        kind: PoseHubPackFile.fromJson(sourceFiles[kind]),
    });
    for (final entry in files.entries) {
      final extension = entry.key == 'video' ? '.mp4' : '.webp';
      if (!entry.value.path.startsWith('media/$id/') ||
          !entry.value.path.endsWith(extension)) {
        throw FormatException(
          '$id.${entry.key} has an invalid pack media path',
        );
      }
    }
    if (files.values.map((f) => f.path).toSet().length != files.length) {
      throw FormatException('$id repeats a media path');
    }
    final semantics = rawTrainingSemantics;
    final declared = _boolean(
      semantics['definitionComplete'],
      '$id.trainingSemantics.definitionComplete',
    );
    final missing = _strings(
      semantics['missingRequiredFields'],
      '$id.missingRequiredFields',
    );
    _list(semantics['unknownFields'], '$id.unknownFields');
    if (declared != trainingDefinitionComplete ||
        (availableForTraining && !availableForApp) ||
        (trainingDefinitionComplete && missing.isNotEmpty) ||
        (!trainingDefinitionComplete && missing.isEmpty)) {
      throw FormatException(
        '$id has contradictory training-completeness flags',
      );
    }
    final status = _text(semantics['status'], '$id.trainingSemantics.status');
    if ((trainingDefinitionComplete && !status.startsWith('complete-')) ||
        (!trainingDefinitionComplete && !status.startsWith('partial-'))) {
      throw FormatException('$id training status contradicts its definition');
    }
    _reviewFlags(raw, '$id media');
    _reviewFlags(semantics, '$id semantics');
    if (semantics['videoLoopIsTrainingDose'] != false ||
        _map(raw['rhythm'], '$id.rhythm')['videoLoopIsTrainingDose'] != false) {
      throw FormatException(
        '$id must not infer training dose from a video loop',
      );
    }
    if (trainingDefinitionComplete) {
      _validateDefinition(raw, id);
    }
    rawTrainingDefinition = Map.unmodifiable({
      for (final field in _definitionFields)
        if (raw.containsKey(field)) field: raw[field],
    });
  }

  final String id;
  final String nameZh;
  final bool trainingDefinitionComplete;

  /// Original source flag; semantic completeness does not rewrite approval.
  final bool availableForTraining;
  final bool availableForApp;
  final Map<String, Object?> raw;
  late final Map<String, PoseHubPackFile> files;
  late final Map<String, Object?> rawTrainingDefinition;
  Map<String, Object?> get rawTrainingSemantics =>
      _map(raw['trainingSemantics'], '$id.trainingSemantics');
  String get trainingStatusLabel =>
      trainingDefinitionComplete ? '训练说明完整' : '训练说明待补';
  PoseHubPackFile get video => files['video']!;
  PoseHubPackFile get cover => files['cover']!;
  PoseHubPackFile get thumbnail => files['thumbnail']!;
}

/// Strict pack index for all actions, plus an explicit complete-only AI view.
final class PoseHubAppTestCatalog {
  PoseHubAppTestCatalog._(this.raw, this._semanticCatalog) {
    if (raw['format'] != format) {
      throw const FormatException('Unsupported app-test catalog format');
    }
    id = _id(raw['id'], 'catalog.id');
    _reviewFlags(raw, 'catalog');
    final summary = _map(raw['trainingSemantics'], 'catalog.trainingSemantics');
    if (summary.containsKey('semanticRevision')) {
      _text(summary['semanticRevision'], 'trainingSemantics.semanticRevision');
    }
    semanticCatalogFile = PoseHubPackFile.fromJson(raw['semanticCatalog']);
    final semanticReference = _map(raw['semanticCatalog'], 'semanticCatalog');
    semanticCatalogVersion = _text(
      semanticReference['version'],
      'semanticCatalog.version',
    );
    final actions = <PoseHubPackAction>[];
    final byId = <String, PoseHubPackAction>{};
    final paths = <String>{};
    for (final entry in _list(raw['actions'], 'catalog.actions')) {
      final action = PoseHubPackAction._(_map(entry, 'action'));
      if (byId.containsKey(action.id)) {
        throw FormatException('Duplicate action id: ${action.id}');
      }
      for (final file in action.files.values) {
        if (!paths.add(file.path)) {
          throw FormatException('Duplicate media path: ${file.path}');
        }
      }
      actions.add(action);
      byId[action.id] = action;
    }
    if (actions.isEmpty) {
      throw const FormatException('App-test catalog must not be empty');
    }
    allActions = List.unmodifiable(actions);
    _byId = Map.unmodifiable(byId);
    semanticCompleteActions = List.unmodifiable(
      actions.where((a) => a.trainingDefinitionComplete),
    );
    pendingActions = List.unmodifiable(
      actions.where((a) => !a.trainingDefinitionComplete),
    );
    final total = _integer(raw['totalCount'], 'totalCount', minimum: 1);
    final ready = _integer(raw['readyCount'], 'readyCount');
    final pending = _integer(raw['pendingCount'], 'pendingCount');
    if (total != actions.length || ready + pending != total) {
      throw const FormatException(
        'App-test media counts disagree with its actions',
      );
    }
    _reviewFlags(summary, 'training semantics summary');
    if (summary['videoLoopIsTrainingDose'] != false ||
        _integer(
              summary['definitionCompleteCount'],
              'definitionCompleteCount',
            ) !=
            semanticCompleteActions.length ||
        !_sameIds(
          _strings(summary['definitionCompleteIds'], 'definitionCompleteIds'),
          semanticCompleteActions.map((a) => a.id),
        ) ||
        !_sameIds(
          _strings(summary['incompleteActionIds'], 'incompleteActionIds'),
          pendingActions.map((a) => a.id),
        )) {
      throw const FormatException(
        'Training-completeness summary disagrees with actions',
      );
    }
    if (raw.containsKey('mediaDistribution')) {
      _validateMediaDistribution();
    } else if (allActions.any(
      (action) => action.files.values.any(
        (file) =>
            file.raw['downloadUrl'] != null || file.raw['assetName'] != null,
      ),
    )) {
      throw const FormatException(
        'Per-file download receipts require a media distribution manifest',
      );
    }
    if (_semanticCatalog != null) {
      _validateSemanticCatalog(_semanticCatalog);
    }
  }

  factory PoseHubAppTestCatalog.fromJson(
    Object? json, {
    Object? semanticCatalog,
  }) => PoseHubAppTestCatalog._(
    _frozenMap(json, 'catalog'),
    semanticCatalog == null ? null : _canonical(semanticCatalog),
  );

  /// Verifies the exact canonical bytes against the untouched R1 reference.
  /// Media file contents are verified separately by the pack installer/loader.
  factory PoseHubAppTestCatalog.fromBytes(
    List<int> catalogBytes, {
    List<int>? semanticCatalogBytes,
  }) {
    final raw = _frozenMap(jsonDecode(utf8.decode(catalogBytes)), 'catalog');
    if (semanticCatalogBytes == null) {
      return PoseHubAppTestCatalog._(raw, null);
    }
    final reference = PoseHubPackFile.fromJson(raw['semanticCatalog']);
    if (semanticCatalogBytes.length != reference.bytes ||
        crypto.sha256.convert(semanticCatalogBytes).toString() !=
            reference.sha256) {
      throw const FormatException(
        'Canonical training catalog integrity mismatch',
      );
    }
    return PoseHubAppTestCatalog._(
      raw,
      _canonical(jsonDecode(utf8.decode(semanticCatalogBytes))),
    );
  }

  static const format = 'pose-hub-app-test-catalog@1';
  final Map<String, Object?> raw;
  final Catalog? _semanticCatalog;
  late final String id;
  late final String semanticCatalogVersion;
  late final PoseHubPackFile semanticCatalogFile;
  late final List<PoseHubPackAction> allActions;
  late final List<PoseHubPackAction> semanticCompleteActions;
  late final List<PoseHubPackAction> pendingActions;
  late final Map<String, PoseHubPackAction> _byId;
  PoseHubPackAction? tryGet(String id) => _byId[id];

  /// Complete definitions from this catalogue, retaining matching canonical
  /// definitions when a canonical is supplied. No training dose is inferred.
  /// This is not approval of upstream media or a replacement for PlanValidator.
  Catalog toAiCatalog({Catalog? semanticCatalog}) {
    final canonical = semanticCatalog == null
        ? (_semanticCatalog == null
              ? null
              : Catalog.fromJson(_semanticCatalog.raw))
        : _canonical(semanticCatalog);
    if (canonical != null) {
      _validateSemanticCatalog(canonical);
    }
    final drills = [
      for (final action in semanticCompleteActions)
        canonical?[action.id] ?? _definition(action),
    ];
    final version = canonical?.version ?? semanticCatalogVersion;
    final formatVersion =
        canonical?.formatVersion ?? supportedCatalogFormatVersion;
    final taxonomy = canonical?.taxonomy ?? Taxonomy.fromJson(raw['taxonomy']);
    return Catalog(
      version: version,
      drills: drills,
      formatVersion: formatVersion,
      generatedAt: canonical?.generatedAt,
      sourceCommit: canonical?.sourceCommit,
      taxonomy: taxonomy,
      raw: Map.unmodifiable({
        if (canonical != null) ...canonical.raw,
        if (canonical == null && raw.containsKey('taxonomy'))
          'taxonomy': raw['taxonomy'],
        'format': catalogFormat,
        'formatVersion': formatVersion,
        'version': version,
        'drills': List.unmodifiable(drills.map((d) => d.raw)),
      }),
    );
  }

  void _validateSemanticCatalog(Catalog canonical) {
    if (canonical.problems.isNotEmpty ||
        canonical.version != semanticCatalogVersion) {
      throw const FormatException(
        'Canonical catalog has parse problems or a different version',
      );
    }
    for (final action in semanticCompleteActions) {
      final drill = canonical[action.id];
      if (drill == null) {
        if (_declaresCanonical(action)) {
          throw FormatException('Canonical definition missing: ${action.id}');
        }
        continue;
      }
      if (drill.name.of('zh') != action.nameZh) {
        throw FormatException('Canonical name differs for ${action.id}');
      }
      for (final field in _definitionFields) {
        if (action.raw.containsKey(field) &&
            !_sameJson(action.raw[field], drill.raw[field])) {
          throw FormatException('Canonical $field differs for ${action.id}');
        }
      }
    }
  }

  bool _declaresCanonical(PoseHubPackAction action) {
    final evidence = action.rawTrainingSemantics['evidence'];
    return evidence is List<Object?> &&
        evidence.any(
          (row) =>
              row is Map<String, Object?> &&
              row['path'] == semanticCatalogFile.path &&
              row['actionId'] == action.id,
        );
  }

  void _validateMediaDistribution() {
    final distribution = _map(raw['mediaDistribution'], 'mediaDistribution');
    final version = _text(distribution['version'], 'mediaDistribution.version');
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._+-]*$').hasMatch(version)) {
      throw const FormatException('Invalid media distribution version');
    }
    final base = _httpsUri(
      distribution['baseUrl'],
      'mediaDistribution.baseUrl',
    );
    final kind = _text(distribution['kind'], 'mediaDistribution.kind');
    switch (kind) {
      case 'github-release-assets@1':
        if (distribution['assetNameRule'] != 'basename(path)' ||
            !base.path.endsWith('/$version/')) {
          throw const FormatException(
            'GitHub media URL or basename rule differs from its manifest',
          );
        }
      case 'r2-objects@1':
        final prefix = _text(
          distribution['objectKeyPrefix'],
          'mediaDistribution.objectKeyPrefix',
        );
        if (distribution['pathRule'] != 'relative-path' ||
            !prefix.endsWith('/') ||
            base.path != '/$prefix') {
          throw const FormatException('R2 media prefix or path rule differs');
        }
        _path(
          prefix.substring(0, prefix.length - 1),
          'mediaDistribution.objectKeyPrefix',
        );
      default:
        throw const FormatException('Unsupported media distribution protocol');
    }
    if (distribution.containsKey('sourceCatalogSha256')) {
      _hash(
        distribution['sourceCatalogSha256'],
        'mediaDistribution.sourceCatalogSha256',
      );
    }
    final assets = <String>{};
    var mediaFiles = 0;
    var mediaBytes = 0;
    for (final action in allActions) {
      for (final file in action.files.values) {
        final location = kind == 'github-release-assets@1'
            ? _assetName(file.raw['assetName'], 'file.assetName')
            : file.path;
        final identity = kind == 'github-release-assets@1'
            ? location.toLowerCase()
            : location;
        if (!assets.add(identity) ||
            file.downloadUri != base.resolve(location)) {
          throw FormatException('Invalid media download receipt: ${file.path}');
        }
        mediaFiles++;
        mediaBytes = _integer(mediaBytes + file.bytes, 'media byte total');
      }
    }
    if (_integer(distribution['mediaFiles'], 'mediaFiles', minimum: 1) !=
            mediaFiles ||
        _integer(distribution['mediaBytes'], 'mediaBytes', minimum: 1) !=
            mediaBytes) {
      throw const FormatException(
        'Media distribution totals differ from files',
      );
    }
  }

  Drill _definition(PoseHubPackAction action) {
    if (!action.trainingDefinitionComplete) {
      throw FormatException('Incomplete training definition: ${action.id}');
    }
    final problems = <String>[];
    final drill = Drill.tryParse(
      Map<String, Object?>.unmodifiable({
        ...action.raw,
        'name': Map<String, Object?>.unmodifiable({'zh': action.nameZh}),
      }),
      problems,
    );
    if (drill == null || problems.isNotEmpty) {
      throw FormatException('Invalid complete definition: ${action.id}');
    }
    return drill;
  }
}

const _mediaKinds = {'video', 'cover', 'thumbnail'};
const _definitionFields = [
  'purpose',
  'category',
  'muscles',
  'muscleGroups',
  'equipment',
  'position',
  'unilateral',
  'level',
  'scenes',
  'defaultDose',
  'doseRange',
  'cues',
  'primaryCue',
  'cautions',
  'contraindications',
  'alternative',
];

void _validateDefinition(Map<String, Object?> raw, String id) {
  for (final key in ['purpose', 'category', 'position']) {
    _text(raw[key], '$id.$key');
  }
  final level = _integer(raw['level'], '$id.level', minimum: 1);
  if (level > 3) {
    throw FormatException('$id has an invalid level');
  }
  _boolean(raw['unilateral'], '$id.unilateral');
  if (_strings(raw['scenes'], '$id.scenes').isEmpty ||
      _strings(_map(raw['cues'], '$id.cues')['zh'], '$id.cues.zh').isEmpty) {
    throw FormatException('$id lacks complete scene/cue semantics');
  }
  final dose = _map(raw['defaultDose'], '$id.defaultDose');
  _integer(dose['sets'], '$id.defaultDose.sets', minimum: 1);
  _integer(dose['restSeconds'], '$id.defaultDose.restSeconds');
  switch (dose['mode']) {
    case 'reps':
      _integer(dose['reps'], '$id.defaultDose.reps', minimum: 1);
    case 'time':
      _integer(dose['seconds'], '$id.defaultDose.seconds', minimum: 1);
    default:
      throw FormatException('$id has an invalid defaultDose.mode');
  }
}

Catalog _canonical(Object? value) {
  final raw = value is Catalog ? value.raw : value;
  final frozen = _frozenMap(raw, 'canonical catalog');
  final ids = <String>{};
  for (final entry in _list(frozen['drills'], 'canonical drills')) {
    final drill = _map(entry, 'canonical drill');
    final id = _id(drill['id'], 'canonical drill.id');
    if (!ids.add(id)) {
      throw FormatException('Duplicate canonical action id: $id');
    }
    _validateDefinition(drill, id);
  }
  late final Catalog result;
  try {
    result = Catalog.fromJson(frozen);
  } on CatalogFormatException catch (error) {
    throw FormatException('Invalid canonical catalog: ${error.message}');
  }
  if (result.problems.isNotEmpty) {
    throw const FormatException('Canonical catalog has invalid definitions');
  }
  return result;
}

Map<String, Object?> _map(Object? value, String field) {
  if (value is! Map<String, Object?>) {
    throw FormatException('$field must be a JSON object');
  }
  return value;
}

Map<String, Object?> _frozenMap(Object? value, String field) =>
    _map(_freeze(value), field);

Object? _freeze(Object? value) {
  if (value == null || value is String || value is bool) {
    return value;
  }
  if (value is num) {
    if (!value.isFinite) {
      throw const FormatException('Non-finite JSON number');
    }
    return value;
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(value.map(_freeze));
  }
  if (value is Map<Object?, Object?>) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const FormatException('JSON object keys must be strings');
      }
      result[entry.key! as String] = _freeze(entry.value);
    }
    return Map<String, Object?>.unmodifiable(result);
  }
  throw const FormatException('Unsupported non-JSON value');
}

List<Object?> _list(Object? value, String field) {
  if (value is! List<Object?>) {
    throw FormatException('$field must be an array');
  }
  return value;
}

List<String> _strings(Object? value, String field) => [
  for (final entry in _list(value, field)) _text(entry, field),
];

String _text(Object? value, String field) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$field must be a nonempty string');
  }
  return value;
}

Uri _httpsUri(Object? value, String field) {
  final uri = Uri.tryParse(_text(value, field));
  if (uri == null ||
      !uri.isAbsolute ||
      uri.scheme != 'https' ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw FormatException(
      '$field must be an absolute HTTPS URL without credentials, '
      'query or fragment',
    );
  }
  return uri;
}

String _assetName(Object? value, String field) {
  final name = _path(value, field);
  if (name.contains('/')) {
    throw FormatException('$field must be a single basename');
  }
  return name;
}

String _id(Object? value, String field) {
  final id = _text(value, field);
  if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
    throw FormatException('$field is not a safe exact ID');
  }
  return id;
}

String _hash(Object? value, String field) {
  if (value is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw FormatException('$field must be a lowercase SHA-256 digest');
  }
  return value;
}

String _path(Object? value, String field) {
  final path = _text(value, field);
  if (path.startsWith('/') ||
      path.contains(RegExp(r'[\\:%?#\x00-\x20\x7f]')) ||
      path.split('/').any((s) => s.isEmpty || s.startsWith('.'))) {
    throw FormatException('$field must remain inside the original pack');
  }
  return path;
}

int _integer(Object? value, String field, {int minimum = 0}) {
  if (value is! int || value < minimum || value > 0x1fffffffffffff) {
    throw FormatException('$field must be an in-range integer');
  }
  return value;
}

bool _boolean(Object? value, String field) {
  if (value is! bool) {
    throw FormatException('$field must be boolean');
  }
  return value;
}

void _reviewFlags(Map<String, Object?> raw, String field) {
  final reviewed = _boolean(raw['reviewed'], '$field.reviewed');
  final eligible = _boolean(raw['releaseEligible'], '$field.releaseEligible');
  final status = raw['status'] ?? raw['state'];
  if ((eligible && !reviewed) ||
      (reviewed && status is String && status.contains('unreviewed'))) {
    throw FormatException('$field has contradictory review/release flags');
  }
}

bool _sameIds(List<String> declared, Iterable<String> actual) {
  final ids = actual.toSet();
  return declared.length == declared.toSet().length &&
      declared.length == ids.length &&
      ids.containsAll(declared);
}

bool _sameJson(Object? a, Object? b) {
  if (a is List<Object?> && b is List<Object?>) {
    return a.length == b.length &&
        List.generate(a.length, (i) => i).every((i) => _sameJson(a[i], b[i]));
  }
  if (a is Map<String, Object?> && b is Map<String, Object?>) {
    return a.length == b.length &&
        a.entries.every(
          (e) => b.containsKey(e.key) && _sameJson(e.value, b[e.key]),
        );
  }
  return a == b;
}
