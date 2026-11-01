/// Exact, immutable action authorization for the opt-in Coach scope boundary.
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

/// Invalid trusted scope configuration. Never means "use the entire library".
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

String _scopeHash(Object? value, String field) {
  final result = _scopeText(value, field);
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(result)) {
    _badScope('invalid_sha256', field);
  }
  return result;
}

Object? _scopeFreeze(Object? value) {
  if (value == null || value is String || value is bool) return value;
  if (value is num && value.isFinite) return value;
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(value.map(_scopeFreeze));
  }
  if (value is Map<Object?, Object?>) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) _badScope('non_string_json_key', 'catalog');
      result[key] = _scopeFreeze(entry.value);
    }
    return Map<String, Object?>.unmodifiable(result);
  }
  _badScope('unsupported_json_value', 'catalog');
}

Map<String, Object?> _scopeMap(Object? value, String field) {
  if (value is! Map<String, Object?>) _badScope('expected_object', field);
  return value;
}

Object? _scopeCanonical(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _scopeCanonical(value[key])};
  }
  if (value is List<Object?>) return value.map(_scopeCanonical).toList();
  return _scopeFreeze(value);
}

String _jsonScopeHash(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(_scopeCanonical(value)))).toString();

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

/// Logical planning identity, including raw dose/rhythm overlays and taxonomy.
/// It deliberately differs from a master delivery file's byte digest.
String computePlanningCatalogSha256(Catalog catalog) => _jsonScopeHash({
  'catalog': catalog.toJson(),
  'rawDrills': [for (final drill in catalog.drills) drill.raw],
  'problems': catalog.problems,
  'taxonomy': {
    'categories': catalog.taxonomy.categories,
    'muscleGroups': catalog.taxonomy.muscleGroups,
    'equipment': catalog.taxonomy.equipment,
    'equipmentScenes': catalog.taxonomy.equipmentScenes,
    'positions': catalog.taxonomy.positions,
    'floorPositions': catalog.taxonomy.floorPositions.toList()..sort(),
    'scenes': catalog.taxonomy.scenes,
    'cautions': catalog.taxonomy.cautions,
  },
});

/// A scope manifest binds the authorized master and the host's exact planning
/// projection separately. Construction validates every ID before any Agent is
/// created; an empty list never falls back to full catalogue behavior.
final class CoachActionScopeManifest {
  CoachActionScopeManifest._({
    required this.appId,
    required this.policyVersion,
    required this.catalogVersion,
    required this.catalogSha256,
    required this.planningCatalogSha256,
    required this.allowlistSha256,
    required this.allowedActionIds,
    required Map<String, _ScopeActionFact> facts,
    this.assetManifestSha256,
  }) : _facts = Map.unmodifiable(facts);

  factory CoachActionScopeManifest.fromCatalogBytes({
    required String appId,
    required List<int> catalogBytes,
    required Catalog planningCatalog,
    required Iterable<String> allowedActionIds,
    String policyVersion = '1',
    String? catalogSha256,
    String? planningCatalogSha256,
    String? allowlistSha256,
    String? assetManifestSha256,
  }) {
    _scopeId(appId, 'appId');
    _scopeText(policyVersion, 'policyVersion');
    final sourceHash = sha256.convert(catalogBytes).toString();
    if (catalogSha256 != null &&
        _scopeHash(catalogSha256, 'catalogSha256') != sourceHash) {
      _badScope('catalog_sha256_mismatch', 'catalogSha256');
    }
    final Map<String, Object?> source;
    try {
      source = _scopeMap(
        _scopeFreeze(jsonDecode(utf8.decode(catalogBytes))),
        'catalog',
      );
    } on CoachActionScopeConfigurationException {
      rethrow;
    } on Object {
      _badScope('invalid_catalog_json', 'catalog');
    }
    final delivery = source['format'] == 'pose-hub-app-test-catalog@1';
    if (!delivery && source['format'] != catalogFormat) {
      _badScope('unsupported_catalog_format', 'catalog.format');
    }
    final rows = source[delivery ? 'actions' : 'drills'];
    if (rows is! List<Object?> || rows.isEmpty) {
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
    final whitelistHash = computeAllowlistSha256(ids);
    for (final id in ids) {
      if (!facts.containsKey(id)) {
        _badScope('unknown_action_id', 'allowedActionIds');
      }
    }
    if (allowlistSha256 != null &&
        _scopeHash(allowlistSha256, 'allowlistSha256') != whitelistHash) {
      _badScope('allowlist_sha256_mismatch', 'allowlistSha256');
    }
    final planningIds = <String>{};
    for (final drill in planningCatalog.drills) {
      if (!planningIds.add(drill.id)) {
        _badScope('duplicate_planning_action_id', 'planningCatalog');
      }
      if (!facts.containsKey(drill.id)) {
        _badScope('unknown_planning_action_id', 'planningCatalog');
      }
    }
    if (planningCatalog.problems.isNotEmpty) {
      _badScope('invalid_planning_catalog', 'planningCatalog.problems');
    }
    final planningHash = computePlanningCatalogSha256(planningCatalog);
    if (planningCatalogSha256 != null &&
        _scopeHash(planningCatalogSha256, 'planningCatalogSha256') !=
            planningHash) {
      _badScope('planning_catalog_sha256_mismatch', 'planningCatalogSha256');
    }
    if (assetManifestSha256 != null) {
      _scopeHash(assetManifestSha256, 'assetManifestSha256');
    }
    final version = delivery
        ? _scopeText(
            _scopeMap(source['semanticCatalog'], 'semanticCatalog')['version'],
            'catalogVersion',
          )
        : _scopeText(source['version'], 'catalogVersion');
    return CoachActionScopeManifest._(
      appId: appId,
      policyVersion: policyVersion,
      catalogVersion: version,
      catalogSha256: sourceHash,
      planningCatalogSha256: planningHash,
      allowlistSha256: whitelistHash,
      allowedActionIds: Set.unmodifiable(ids.toList()..sort()),
      facts: facts,
      assetManifestSha256: assetManifestSha256,
    );
  }

  factory CoachActionScopeManifest.fromJson(
    Object? value, {
    required List<int> catalogBytes,
    required Catalog planningCatalog,
  }) {
    final json = _scopeMap(value, 'manifest');
    if (json['schemaVersion'] != 1) {
      _badScope('unsupported_scope_schema', 'schemaVersion');
    }
    final ids = json['allowedActionIds'];
    if (ids is! List<Object?> || ids.any((id) => id is! String)) {
      _badScope('invalid_allowlist', 'allowedActionIds');
    }
    final result = CoachActionScopeManifest.fromCatalogBytes(
      appId: _scopeText(json['appId'], 'appId'),
      policyVersion: _scopeText(json['policyVersion'], 'policyVersion'),
      catalogBytes: catalogBytes,
      planningCatalog: planningCatalog,
      allowedActionIds: ids.cast<String>(),
      catalogSha256: _scopeHash(json['catalogSha256'], 'catalogSha256'),
      planningCatalogSha256: _scopeHash(
        json['planningCatalogSha256'],
        'planningCatalogSha256',
      ),
      allowlistSha256: _scopeHash(json['allowlistSha256'], 'allowlistSha256'),
      assetManifestSha256: json['assetManifestSha256'] == null
          ? null
          : _scopeHash(json['assetManifestSha256'], 'assetManifestSha256'),
    );
    if (json['catalogVersion'] != result.catalogVersion) {
      _badScope('catalog_version_mismatch', 'catalogVersion');
    }
    return result;
  }

  final String appId;
  final String policyVersion;
  final String catalogVersion;
  final String catalogSha256;
  final String planningCatalogSha256;
  final String allowlistSha256;
  final String? assetManifestSha256;
  final Set<String> allowedActionIds;
  final Map<String, _ScopeActionFact> _facts;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'appId': appId,
    'policyVersion': policyVersion,
    'catalogVersion': catalogVersion,
    'catalogSha256': catalogSha256,
    'planningCatalogSha256': planningCatalogSha256,
    'allowlistSha256': allowlistSha256,
    'allowedActionIds': allowedActionIds.toList(),
    if (assetManifestSha256 != null) 'assetManifestSha256': assetManifestSha256,
  };

  /// Rechecks the bound host projection, then applies the three-way
  /// intersection. A provider cannot replace doses under the same ID set.
  CoachActionScope restrict({
    required Catalog catalog,
    required CoachProfile profile,
  }) {
    if (profile.id != appId) _badScope('profile_app_mismatch', 'profile.id');
    if (computePlanningCatalogSha256(catalog) != planningCatalogSha256) {
      _badScope('planning_catalog_changed', 'catalog');
    }
    final selected = [
      for (final drill in profile.scope(catalog))
        if (allowedActionIds.contains(drill.id) &&
            _facts[drill.id]?.complete == true &&
            _planningDefinitionComplete(drill))
          drill,
    ];
    final ids = Set<String>.unmodifiable(selected.map((drill) => drill.id));
    final cleaner = _ScopeProjectionCleaner(
      allowed: ids,
      known: _facts.keys.toSet(),
      appId: appId,
    );
    final projected = Catalog(
      version: catalog.version,
      formatVersion: catalog.formatVersion,
      generatedAt: catalog.generatedAt,
      sourceCommit: catalog.sourceCommit,
      taxonomy: _freezeTaxonomy(catalog.taxonomy),
      drills: [for (final drill in selected) cleaner.drill(drill)],
      raw: _scopeMap(
        _scopeFreeze({
          'format': catalogFormat,
          'formatVersion': catalog.formatVersion,
          'version': catalog.version,
          if (catalog.raw['taxonomy'] != null)
            'taxonomy': cleaner.json(catalog.raw['taxonomy']),
          'drills': [
            for (final drill in selected) cleaner.drill(drill).toJson(),
          ],
          'scope': {'appId': appId, 'allowlistSha256': allowlistSha256},
        }),
        'projection',
      ),
    );
    final projectedProfile = _scopeProfile(profile, ids, cleaner);
    return CoachActionScope._(
      manifest: this,
      catalog: projected,
      profile: projectedProfile,
      plannableIds: ids,
      identity: _jsonScopeHash({
        'manifest': toJson(),
        'profile': projectedProfile.toJson(),
        'projection': computePlanningCatalogSha256(projected),
      }),
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
    required this.identity,
  });

  final CoachActionScopeManifest manifest;
  final Catalog catalog;
  final CoachProfile profile;
  final Set<String> plannableIds;
  final String identity;
  Set<String> get allowedActionIds => manifest.allowedActionIds;

  Map<String, Object?> get identityJson => {
    'appId': manifest.appId,
    'policyVersion': manifest.policyVersion,
    'catalogSha256': manifest.catalogSha256,
    'planningCatalogSha256': manifest.planningCatalogSha256,
    'allowlistSha256': manifest.allowlistSha256,
    'identity': identity,
  };

  bool contains(String actionId) => plannableIds.contains(actionId);

  /// All executable and resolvable plan references, including parent items,
  /// segments, replacement provenance and nested structured source references.
  List<PlanIssue> validatePlan(TrainingPlan plan) {
    final issues = validateReferences(plan.toJson(), root: 'plan');
    if (plan.blocks.isEmpty ||
        plan.blocks.every((block) => block.items.isEmpty)) {
      return [
        const PlanIssue('empty_plan', '范围准入不能接受空计划。', path: 'plan.blocks'),
        ...issues,
      ];
    }
    return issues;
  }

  List<PlanIssue> validateReferences(Object? value, {String root = 'state'}) {
    final issues = <PlanIssue>[];
    void action(Object? id, String path) {
      if (id is String && contains(id)) return;
      issues.add(
        PlanIssue(
          'action_scope_violation',
          '动作引用不在本 App 当前受限可规划目录中。',
          path: path,
          exerciseId: id is String ? id : null,
          actual: id is String ? id : 'invalid action reference',
          expected: '显式白名单、完整语义与 profile 的交集',
          fix: '从当前 search_actions 的范围内候选重新提交草稿。',
        ),
      );
    }

    void visit(Object? current, String path, String? field) {
      if (current is String &&
          _scopeExecutableReferenceFields.contains(field)) {
        for (final prefix in ['drill.', 'point.']) {
          if (current.startsWith(prefix)) {
            action(current.substring(prefix.length), path);
            return;
          }
        }
        for (final id in manifest._facts.keys) {
          if (!contains(id) && _mentionsExact(current, id, identifier: true)) {
            action(id, path);
            return;
          }
        }
      }
      if (_scopeActionRefFields.contains(field) && current != null) {
        action(current, path);
        return;
      }
      if (_scopeActionListFields.contains(field)) {
        if (current is! List<Object?>) {
          action(current, path);
          return;
        }
        for (var i = 0; i < current.length; i++) {
          final entry = current[i];
          if (entry is String) {
            action(entry, '$path[$i]');
          } else if (entry is List<Object?>) {
            action(entry.firstOrNull, '$path[$i][0]');
          } else {
            visit(entry, '$path[$i]', 'action');
          }
        }
        return;
      }
      if (current is Map<String, Object?>) {
        for (final entry in current.entries) {
          if (entry.key == 'id' &&
              {'action', 'recommendation', 'drill'}.contains(field)) {
            action(entry.value, '$path.id');
          } else {
            visit(entry.value, '$path.${entry.key}', entry.key);
          }
        }
      } else if (current is List<Object?>) {
        for (var i = 0; i < current.length; i++) {
          visit(current[i], '$path[$i]', switch (field) {
            'recommendations' => 'recommendation',
            'actions' => 'action',
            'drills' => 'drill',
            _ => field,
          });
        }
      }
    }

    visit(value, root, null);
    return List.unmodifiable(issues);
  }
}

const _scopeActionRefFields = {
  'exerciseId',
  'actionId',
  'action_id',
  'exercise_id',
  'replacedFrom',
  'alternative',
  'sourceActionId',
  'sourceExerciseId',
  'referenceActionId',
  'replacementActionId',
  'alternativeId',
};
const _scopeActionListFields = {
  'actionIds',
  'selectedActionIds',
  'seenActionIds',
  'pendingSearchIds',
  'pickedActionIds',
  'relatedActionIds',
  'referenceActionIds',
  'candidateIds',
  'candidateRows',
  'candidates',
  'picks',
  'alternatives',
};
const _scopeExecutableReferenceFields = {
  'cue',
  'voiceKey',
  'audioKey',
  'asset',
  'assetName',
  'path',
  'url',
};

Taxonomy _freezeTaxonomy(Taxonomy taxonomy) => Taxonomy(
  categories: Map.unmodifiable(taxonomy.categories),
  muscleGroups: Map.unmodifiable(taxonomy.muscleGroups),
  equipment: Map.unmodifiable(taxonomy.equipment),
  equipmentScenes: Map<String, List<String>>.unmodifiable({
    for (final entry in taxonomy.equipmentScenes.entries)
      entry.key: List<String>.unmodifiable(entry.value),
  }),
  positions: Map.unmodifiable(taxonomy.positions),
  floorPositions: Set.unmodifiable(taxonomy.floorPositions),
  scenes: Map.unmodifiable(taxonomy.scenes),
  cautions: List.unmodifiable(taxonomy.cautions),
);

CoachProfile _scopeProfile(
  CoachProfile source,
  Set<String> ids,
  _ScopeProjectionCleaner cleaner,
) => CoachProfile(
  id: source.id,
  appName: cleaner.text(source.appName),
  promptVersion: source.promptVersion,
  focus: cleaner.text(source.focus),
  rules: List.unmodifiable(source.rules.map(cleaner.text)),
  select: DrillSelector(ids: ids),
  scenes: Map.unmodifiable({
    for (final entry in source.scenes.entries)
      entry.key: SceneRule(
        label: entry.value.label,
        assumedEquipment: Set.unmodifiable(entry.value.assumedEquipment),
        allEquipment: entry.value.allEquipment,
        acceptDrillScenes: Set.unmodifiable(entry.value.acceptDrillScenes),
        forbidFloor: entry.value.forbidFloor,
        forbidPositions: Set.unmodifiable(entry.value.forbidPositions),
      ),
  }),
  defaultScene: source.defaultScene,
  goals: List.unmodifiable(source.goals),
  limits: source.limits,
  minActions: source.minActions,
  planRules: PlanRules(
    warmupFromMinutes: source.planRules.warmupFromMinutes,
    cooldownFromMinutes: source.planRules.cooldownFromMinutes,
    exemptWarmupForPureStretch: source.planRules.exemptWarmupForPureStretch,
    focusRatio: source.planRules.focusRatio,
    maxSameMuscleInRow: source.planRules.maxSameMuscleInRow,
    replaceAllMinDiff: source.planRules.replaceAllMinDiff,
    derivedStep: source.planRules.derivedStep,
    antagonisticPairs: List.unmodifiable([
      for (final pair in source.planRules.antagonisticPairs)
        AntagonistPair(
          first: List.unmodifiable(pair.first),
          second: List.unmodifiable(pair.second),
        ),
    ]),
  ),
  legacyGoalMap: List.unmodifiable([
    for (final rule in source.legacyGoalMap)
      _scopeMap(_scopeFreeze(rule), 'legacyGoalMap'),
  ]),
  bodyGroups: Map<String, List<String>>.unmodifiable({
    for (final entry in source.bodyGroups.entries)
      entry.key: List<String>.unmodifiable(entry.value),
  }),
  ambientEquipment: Map<String, Set<String>>.unmodifiable({
    for (final entry in source.ambientEquipment.entries)
      entry.key: Set<String>.unmodifiable(entry.value),
  }),
  ambientEquipmentUnknown: Set.unmodifiable(source.ambientEquipmentUnknown),
  assetApps: List.unmodifiable(
    source.resolvedAssetApps.where(
      (app) => app == source.id || app == 'pose-hub',
    ),
  ),
  vars: Map.unmodifiable({
    for (final entry in source.vars.entries)
      entry.key: cleaner.text(entry.value),
  }),
  skills: List.unmodifiable([
    for (final skill in source.skills)
      if (!cleaner.foreignReference(skill.content) &&
          !skill.files.values.any(cleaner.foreignReference))
        ProfileSkill(
          name: skill.name,
          description: cleaner.text(skill.description),
          content: cleaner.text(skill.content),
          files: Map.unmodifiable({
            for (final entry in skill.files.entries)
              if (!cleaner.foreignReference(entry.key))
                entry.key: cleaner.text(entry.value),
          }),
        ),
  ]),
);

final class _ScopeProjectionCleaner {
  _ScopeProjectionCleaner({
    required this.allowed,
    required this.known,
    required this.appId,
  }) : foreign = RegExp(
         known.difference(allowed).isEmpty
             ? r'(?!)'
             : '(?<![A-Za-z0-9_-])(?:${known.difference(allowed).map(RegExp.escape).join('|')})(?![A-Za-z0-9_-])',
       );

  final Set<String> allowed;
  final Set<String> known;
  final String appId;
  final RegExp foreign;
  bool foreignReference(String value) => foreign.hasMatch(value);
  String text(String value) => value.replaceAll(foreign, '[范围外动作]');

  Object? json(Object? value, [String? field]) {
    if (_scopeActionRefFields.contains(field) &&
        value is String &&
        !allowed.contains(value)) {
      return null;
    }
    if (value is String) return text(value);
    if (value is List<Object?>) {
      return [
        for (final entry in value)
          if (!_scopeActionListFields.contains(field) ||
              entry is! String ||
              allowed.contains(entry))
            json(entry),
      ];
    }
    if (value is Map<String, Object?>) {
      final id = value['id'];
      if (id is String &&
          !allowed.contains(id) &&
          (known.contains(id) || value.containsKey('defaultDose'))) {
        return null;
      }
      if (!(id is String && allowed.contains(id)) &&
          value.entries.any(
            (entry) =>
                _scopeActionRefFields.contains(entry.key) &&
                entry.value is String &&
                !allowed.contains(entry.value),
          )) {
        return null;
      }
      return {
        for (final entry in value.entries)
          if (!foreignReference(entry.key) &&
              !{'apps', 'problems'}.contains(entry.key))
            entry.key: json(entry.value, entry.key),
      };
    }
    return value;
  }

  AssetSource? asset(AssetSource source, {bool keepTiming = false}) {
    if (foreignReference(source.path) ||
        (source.app != appId && source.app != 'pose-hub')) {
      if (!keepTiming) return null;
      // Timing is authored input, not a cross-App material permission. Retain
      // all timing slots/order while removing a foreign downloadable address.
      return AssetSource(
        app: 'pose-hub',
        path: '',
        loopSeconds: source.loopSeconds,
        repSeconds: source.repSeconds,
        coverSeconds: source.coverSeconds,
        showsSide: source.showsSide,
      );
    }
    return source;
  }

  Drill drill(Drill source) {
    final safeAssets = _assets(source);
    final safeRaw = _scopeMap(json(source.raw), 'drill.raw');
    safeRaw['assets'] = safeAssets.toJson();
    safeRaw['apps'] = source.apps.where((app) => app == appId).toList();
    for (final app in const ['smartfit', 'hiplab', 'flarelab']) {
      if (app != appId) safeRaw.remove(app);
    }
    return Drill(
      id: source.id,
      name: LocalizedText(
        Map.unmodifiable({
          for (final entry in source.name.values.entries)
            entry.key: text(entry.value),
        }),
      ),
      purpose: text(source.purpose),
      category: source.category,
      muscles: List.unmodifiable(source.muscles),
      muscleGroups: List.unmodifiable(source.muscleGroups),
      equipment: List.unmodifiable(source.equipment),
      position: source.position,
      unilateral: source.unilateral,
      level: source.level,
      scenes: List.unmodifiable(source.scenes),
      defaultDose: source.defaultDose,
      doseRange: source.doseRange,
      cues: Map<String, List<String>>.unmodifiable({
        for (final entry in source.cues.entries)
          entry.key: List<String>.unmodifiable(entry.value.map(text)),
      }),
      primaryCue: source.primaryCue,
      cautions: List.unmodifiable(source.cautions),
      contraindications: List.unmodifiable(source.contraindications),
      alternative: allowed.contains(source.alternative)
          ? source.alternative
          : null,
      apps: List.unmodifiable(source.apps.where((app) => app == appId)),
      tags: List.unmodifiable(source.tags.map(text)),
      assets: safeAssets,
      missing: List.unmodifiable(source.missing.map(text)),
      reviewStatus: source.reviewStatus,
      raw: _scopeMap(_scopeFreeze(safeRaw), 'drill.raw'),
    );
  }

  DrillAssets _assets(Drill source) => DrillAssets(
    spec:
        foreignReference(source.assets.spec.path ?? '') ||
            foreignReference(source.assets.spec.revisionOf ?? '')
        ? const SpecRef(status: 'missing')
        : source.assets.spec,
    releases: List.unmodifiable(source.assets.releases.map(text)),
    covers: List.unmodifiable([
      for (final item in source.assets.covers) ?asset(item),
    ]),
    videos: List.unmodifiable([
      for (final item in source.assets.videos) ?asset(item, keepTiming: true),
    ]),
    voiceLanguages: List.unmodifiable(source.assets.voiceLanguages),
    voiceLines: List.unmodifiable([
      for (final line in source.assets.voiceLines)
        if (!foreignReference(line.id))
          VoiceLine(
            id: line.id,
            role: line.role,
            text: LocalizedText(
              Map.unmodifiable({
                for (final entry in line.text.values.entries)
                  entry.key: text(entry.value),
              }),
            ),
            ms: Map.unmodifiable(line.ms),
          ),
    ]),
    voiceAudio: List.unmodifiable([
      for (final audio in source.assets.voiceAudio)
        if ((audio.app == appId || audio.app == 'pose-hub') &&
            !foreignReference(audio.pathPattern))
          VoiceAudio(
            app: audio.app,
            pathPattern: audio.pathPattern,
            languages: List.unmodifiable(audio.languages),
            keys: List.unmodifiable(
              audio.keys.where((key) => !foreignReference(key)),
            ),
          ),
    ]),
    drillPack: source.assets.drillPack == null
        ? null
        : asset(source.assets.drillPack!),
  );
}

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
