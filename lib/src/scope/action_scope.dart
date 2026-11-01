/// Explicit action lists and the catalogue exposed by an opt-in App scope.
library;

import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../agent/action_tags.dart';
import '../agent/node_gates.dart';
import '../agent/session_state.dart';
import '../catalog/catalog.dart';
import '../plan/plan_issue.dart';
import '../plan/training_plan.dart';
import '../profile/coach_profile.dart';
import '../util/json.dart';

part 'scope_policy.dart';

/// A scope configuration error never means "use the entire catalogue".
class CoachActionScopeConfigurationException extends FormatException {
  const CoachActionScopeConfigurationException(this.code, this.field)
    : super('Invalid Coach action scope configuration: $code ($field)');
  final String code;
  final String field;
}

Never _badScope(String code, String field) =>
    throw CoachActionScopeConfigurationException(code, field);

String _scopeText(Object? value, String field) {
  if (value is! String || value.isEmpty || value.trim() != value) {
    _badScope('invalid_text', field);
  }
  return value;
}

String _scopeId(Object? value, String field) {
  final result = _scopeText(value, field);
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(result)) {
    _badScope('invalid_exact_action_id', field);
  }
  return result;
}

/// Uses the same sorted exact-ID, UTF-8/LF format as the asset closure tool.
/// Duplicate, blank or wildcard IDs are rejected instead of normalized away.
String computeAllowlistSha256(Iterable<String> actionIds) {
  final ids = <String>[];
  final unique = <String>{};
  for (final value in actionIds) {
    final id = _scopeId(value, 'allowedActionIds');
    if (!unique.add(id)) _badScope('duplicate_action_id', 'allowedActionIds');
    ids.add(id);
  }
  if (ids.isEmpty) _badScope('empty_allowlist', 'allowedActionIds');
  ids.sort();
  return sha256.convert(utf8.encode('${ids.join('\n')}\n')).toString();
}

Map<String, Object?> _scopeMap(Object? value, String field) {
  if (value is! Map<String, Object?>) _badScope('expected_object', field);
  return value;
}

/// Exact IDs and build-time catalogue/material-list metadata.
final class CoachActionScopeManifest {
  CoachActionScopeManifest._({
    required this.appId,
    required this.policyVersion,
    required this.catalogVersion,
    required this.catalogSha256,
    required this.allowlistSha256,
    required this.allowedActionIds,
    required Map<String, _ScopeActionFact> facts,
  }) : _facts = facts;

  factory CoachActionScopeManifest.fromCatalogBytes({
    required String appId,
    required List<int> catalogBytes,
    required Iterable<String> allowedActionIds,
    String policyVersion = '1',
    String? catalogSha256,
    String? allowlistSha256,
  }) {
    _scopeId(appId, 'appId');
    _scopeText(policyVersion, 'policyVersion');
    final sourceHash = sha256.convert(catalogBytes).toString();
    if (catalogSha256 != null && catalogSha256 != sourceHash) {
      _badScope('catalog_sha256_mismatch', 'catalogSha256');
    }
    final Map<String, Object?> source;
    try {
      source = _scopeMap(jsonDecode(utf8.decode(catalogBytes)), 'catalog');
    } on CoachActionScopeConfigurationException {
      rethrow;
    } on FormatException {
      _badScope('invalid_catalog_json', 'catalog');
    }
    final delivery = source['format'] == 'pose-hub-app-test-catalog@1';
    if (!delivery && source['format'] != catalogFormat) {
      _badScope('unsupported_catalog_format', 'catalog.format');
    }
    final rows = source[delivery ? 'actions' : 'drills'];
    if (rows is! List || rows.isEmpty) {
      _badScope('empty_master_catalog', 'catalog');
    }
    final facts = <String, _ScopeActionFact>{};
    for (final value in rows) {
      final row = _scopeMap(value, 'catalog.action');
      final id = _scopeId(row['id'], 'catalog.action.id');
      if (facts.containsKey(id)) {
        _badScope('duplicate_master_action_id', 'catalog.action.id');
      }
      facts[id] = _ScopeActionFact.fromJson(row, delivery: delivery);
    }
    final ids = allowedActionIds.toList();
    final listHash = computeAllowlistSha256(ids);
    for (final id in ids) {
      if (!facts.containsKey(id)) {
        _badScope('unknown_action_id', 'allowedActionIds');
      }
    }
    if (allowlistSha256 != null && allowlistSha256 != listHash) {
      _badScope('allowlist_sha256_mismatch', 'allowlistSha256');
    }
    return CoachActionScopeManifest._(
      appId: appId,
      policyVersion: policyVersion,
      catalogVersion: _scopeText(
        delivery
            ? _scopeMap(source['semanticCatalog'], 'semanticCatalog')['version']
            : source['version'],
        'catalogVersion',
      ),
      catalogSha256: sourceHash,
      allowlistSha256: listHash,
      allowedActionIds: Set.unmodifiable(ids),
      facts: facts,
    );
  }

  factory CoachActionScopeManifest.fromJson(
    Object? value, {
    required List<int> catalogBytes,
  }) {
    final json = _scopeMap(value, 'manifest');
    if (json['schemaVersion'] != 1) {
      _badScope('unsupported_scope_schema', 'schemaVersion');
    }
    final ids = json['allowedActionIds'];
    if (ids is! List || ids.any((id) => id is! String)) {
      _badScope('invalid_allowlist', 'allowedActionIds');
    }
    return CoachActionScopeManifest.fromCatalogBytes(
      appId: _scopeText(json['appId'], 'appId'),
      catalogBytes: catalogBytes,
      allowedActionIds: ids.cast<String>(),
      policyVersion: _scopeText(json['policyVersion'], 'policyVersion'),
      catalogSha256: json['catalogSha256'] as String?,
      allowlistSha256: json['allowlistSha256'] as String?,
    );
  }

  final String appId;
  final String policyVersion;
  final String catalogVersion;
  final String catalogSha256;
  final String allowlistSha256;
  final Set<String> allowedActionIds;
  final Map<String, _ScopeActionFact> _facts;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'appId': appId,
    'policyVersion': policyVersion,
    'catalogVersion': catalogVersion,
    'catalogSha256': catalogSha256,
    'allowlistSha256': allowlistSha256,
    'allowedActionIds': allowedActionIds.toList(),
  };

  /// The allowed list, complete definitions and App profile form the tool catalogue.
  /// Authored doses and rhythm values remain the host catalogue's values.
  CoachActionScope restrict({
    required Catalog catalog,
    required CoachProfile profile,
  }) {
    if (profile.id != appId) _badScope('profile_app_mismatch', 'profile.id');
    final selected = [
      for (final drill in profile.scope(catalog))
        if (allowedActionIds.contains(drill.id) &&
            _facts[drill.id]?.complete == true &&
            _planningDefinitionComplete(drill))
          drill,
    ];
    final ids = Set<String>.unmodifiable(selected.map((drill) => drill.id));
    final drills = [for (final drill in selected) _projectDrill(drill, ids)];
    return CoachActionScope._(
      manifest: this,
      plannableIds: ids,
      profile: CoachProfile.fromJson({
        ...profile.toJson(),
        'select': {'ids': ids.toList()},
      }),
      catalog: Catalog(
        version: catalog.version,
        formatVersion: catalog.formatVersion,
        generatedAt: catalog.generatedAt,
        sourceCommit: catalog.sourceCommit,
        taxonomy: catalog.taxonomy,
        drills: drills,
        raw: {
          'format': catalogFormat,
          'formatVersion': catalog.formatVersion,
          'version': catalog.version,
          if (catalog.raw['taxonomy'] != null)
            'taxonomy': catalog.raw['taxonomy'],
          'drills': [for (final drill in drills) drill.toJson()],
        },
      ),
    );
  }
}

bool _planningDefinitionComplete(Drill drill) =>
    drill.name.of().trim().isNotEmpty &&
    drill.purpose.trim().isNotEmpty &&
    drill.category.isNotEmpty &&
    drill.position.isNotEmpty &&
    drill.level >= 1 &&
    drill.level <= 3 &&
    drill.scenes.isNotEmpty &&
    (drill.cues['zh']?.isNotEmpty ?? false) &&
    drill.defaultDose.sets > 0 &&
    drill.defaultDose.restSeconds >= 0 &&
    (drill.defaultDose.mode == DoseMode.reps
        ? (drill.defaultDose.reps ?? 0) > 0
        : (drill.defaultDose.seconds ?? 0) > 0) &&
    drill.raw['trainingDefinitionComplete'] != false &&
    asMap(drill.raw['trainingSemantics'])['definitionComplete'] != false;

final class CoachActionScope {
  CoachActionScope._({
    required this.manifest,
    required this.catalog,
    required this.profile,
    required this.plannableIds,
  });
  final CoachActionScopeManifest manifest;
  final Catalog catalog;
  final CoachProfile profile;
  final Set<String> plannableIds;
  Set<String> get allowedActionIds => manifest.allowedActionIds;
  bool contains(String actionId) => plannableIds.contains(actionId);

  /// Plan admission checks only its parent, segment and replacement action IDs.
  List<PlanIssue> validatePlan(TrainingPlan plan) {
    final issues = <PlanIssue>[];
    if (plan.items.isEmpty) {
      issues.add(
        const PlanIssue('empty_plan', '计划必须包含动作。', path: 'plan.blocks'),
      );
    }
    void check(String id, String path) {
      if (!contains(id)) {
        issues.add(
          PlanIssue(
            'action_scope_violation',
            '动作不在本 App 当前可规划目录中。',
            path: path,
            exerciseId: id,
          ),
        );
      }
    }

    for (var block = 0; block < plan.blocks.length; block++) {
      final items = plan.blocks[block].items;
      for (var index = 0; index < items.length; index++) {
        final item = items[index];
        final path = 'plan.blocks[$block].items[$index]';
        check(item.exerciseId, '$path.exerciseId');
        if (item.replacedFrom != null) {
          check(item.replacedFrom!, '$path.replacedFrom');
        }
        for (var segment = 0; segment < item.segments.length; segment++) {
          check(
            item.segments[segment].exerciseId,
            '$path.segments[$segment].exerciseId',
          );
        }
      }
    }
    return issues;
  }
}

Drill _projectDrill(Drill source, Set<String> ids) => Drill(
  id: source.id,
  name: source.name,
  purpose: source.purpose,
  category: source.category,
  muscles: source.muscles,
  muscleGroups: source.muscleGroups,
  equipment: source.equipment,
  position: source.position,
  unilateral: source.unilateral,
  level: source.level,
  scenes: source.scenes,
  defaultDose: source.defaultDose,
  doseRange: source.doseRange,
  cues: source.cues,
  primaryCue: source.primaryCue,
  cautions: source.cautions,
  contraindications: source.contraindications,
  alternative: ids.contains(source.alternative) ? source.alternative : null,
  apps: source.apps,
  tags: source.tags,
  assets: source.assets,
  missing: source.missing,
  reviewStatus: source.reviewStatus,
  raw: {
    ...source.raw,
    'alternative': ids.contains(source.alternative) ? source.alternative : null,
  },
);

final class _ScopeActionFact {
  _ScopeActionFact({
    required this.id,
    required this.names,
    required this.complete,
    required this.body,
    required this.scenes,
    required this.equipment,
    required this.category,
    required this.level,
  });

  factory _ScopeActionFact.fromJson(
    Map<String, Object?> source, {
    required bool delivery,
  }) {
    final name = delivery
        ? LocalizedText({'zh': asString(source['nameZh']) ?? ''})
        : LocalizedText.fromJson(source['name']);
    final probe = Drill.tryParse({
      ...source,
      if (delivery) 'name': name.toJson(),
    }, []);
    final complete = delivery
        ? source['trainingDefinitionComplete'] == true
        : probe != null && _planningDefinitionComplete(probe);
    return _ScopeActionFact(
      id: source['id']! as String,
      names: List.unmodifiable(name.values.values.where((s) => s.isNotEmpty)),
      complete: complete,
      body: Set.unmodifiable({
        for (final body in asStringList(source['muscleGroups']))
          'body.${body == 'adductors' ? 'inner_thigh' : body.replaceAll('-', '_')}',
        if (source['category'] == 'core') 'body.core',
      }),
      scenes: Set.unmodifiable(asStringList(source['scenes'])),
      equipment: Set.unmodifiable(
        asStringList(
          source['equipment'],
        ).where((e) => e.isNotEmpty && e != 'none'),
      ),
      category: asString(source['category']) ?? '',
      level: asInt(source['level']) ?? 1,
    );
  }

  final String id;
  final List<String> names;
  final bool complete;
  final Set<String> body;
  final Set<String> scenes;
  final Set<String> equipment;
  final String category;
  final int level;
}
