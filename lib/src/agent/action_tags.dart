/// Reversible catalogue codes used by structured agent tools.
///
/// These codes describe catalogue data, not the meaning of user messages.
library;

import '../catalog/catalog.dart';
import '../profile/coach_profile.dart';

class ActionTags {
  ActionTags(CoachProfile profile, Catalog catalog) {
    final drills = profile.scope(catalog);
    _actions = {
      for (final drill in drills) drill.id: Set.unmodifiable(_encode(drill)),
    };
    final allTags = <String>{for (final values in _actions.values) ...values};
    tags = _sorted(allTags);
    goalCodes = _sorted(
      allTags.where(
        (tag) => tag.startsWith('body.') || tag.startsWith('purpose.'),
      ),
    );

    // Taxonomy includes equipment a user may own even if this profile has no
    // corresponding action. Preserve that fact independently of search scope.
    final equipmentIds = <String>{
      ...catalog.taxonomy.equipment.keys,
      for (final drill in drills) ...drill.equipment,
    }..removeWhere((id) => id.isEmpty || id == 'none');
    _equipmentById = {for (final id in equipmentIds) id: 'equip.${_part(id)}'};
    _equipmentByCode = {};
    for (final entry in _equipmentById.entries) {
      if (entry.value.startsWith(_hostEquipmentPrefix)) {
        throw FormatException(
          'Equipment ID uses the reserved host namespace: ${entry.key}',
        );
      }
      final previous = _equipmentByCode[entry.value];
      if (previous != null && previous != entry.key) {
        throw FormatException(
          'Equipment IDs have the same code: $previous, ${entry.key}',
        );
      }
      _equipmentByCode[entry.value] = entry.key;
    }
    equipmentCodes = _sorted(_equipmentByCode.keys);

    final limits = <String>{
      ...catalog.taxonomy.cautions,
      for (final drill in drills) ...drill.cautions,
      for (final drill in drills) ...drill.contraindications,
    }..removeWhere((value) => value.isEmpty);
    limitCodes = _sorted(limits.map((value) => limitCode(value)!));
  }

  late final Map<String, Set<String>> _actions;
  late final Map<String, String> _equipmentById;
  late final Map<String, String> _equipmentByCode;

  /// Search tags are generated from actions actually in profile scope.
  late final List<String> tags;
  late final List<String> goalCodes;
  late final List<String> equipmentCodes;
  late final List<String> limitCodes;

  Set<String> forAction(Drill drill) => forActionId(drill.id);
  Set<String> forActionId(String id) => _actions[id] ?? const {};

  /// The host may retain an owned item absent from this catalogue. Such
  /// values use a reserved reversible namespace outside model-facing enums.
  String? equipmentCode(String rawId) {
    if (rawId.isEmpty || rawId == 'none') return null;
    return _equipmentById[rawId] ?? '$_hostEquipmentPrefix${_runeCode(rawId)}';
  }

  String? equipmentId(String code) =>
      _equipmentByCode[code] ?? _decodeRunes(code, _hostEquipmentPrefix);

  /// Unknown host-supplied restrictions retain every Unicode code point.
  /// They need not occur in [limitCodes], which describes catalogue values.
  String? limitCode(String rawValue) {
    if (rawValue.isEmpty) return null;
    return _knownLimits[rawValue] ?? 'limit.u_${_runeCode(rawValue)}';
  }

  String? limitValue(String code) {
    for (final entry in _knownLimits.entries) {
      if (entry.value == code) return entry.key;
    }
    return _decodeRunes(code, 'limit.u_');
  }

  /// Compares legacy host IDs and catalogue caution labels semantically
  /// without changing their separately stored, reversible representations.
  String? canonicalLimitCode(String rawOrCode) {
    if (_knownLimits.containsValue(rawOrCode)) return rawOrCode;
    final raw = limitValue(rawOrCode) ?? rawOrCode;
    return _knownLimits[raw] ??
        _limitAliases[raw.toLowerCase()] ??
        limitCode(raw);
  }

  static const _hostEquipmentPrefix = 'equip.host.';

  static String _runeCode(String raw) =>
      raw.runes.map((rune) => rune.toRadixString(16)).join('_');

  static String? _decodeRunes(String code, String prefix) {
    if (!code.startsWith(prefix)) return null;
    final parts = code.substring(prefix.length).split('_');
    if (parts.isEmpty || parts.any((part) => part.isEmpty)) return null;
    final runes = <int>[];
    for (final part in parts) {
      final rune = int.tryParse(part, radix: 16);
      if (rune == null ||
          rune < 0 ||
          rune > 0x10ffff ||
          (rune >= 0xd800 && rune <= 0xdfff)) {
        return null;
      }
      runes.add(rune);
    }
    return String.fromCharCodes(runes);
  }

  static const _knownLimits = <String, String>{
    '膝': 'limit.knee',
    '腰': 'limit.waist',
    '肩': 'limit.shoulder',
    '手腕': 'limit.wrist',
    '颈': 'limit.neck',
    '髋': 'limit.hip',
    '大腿内侧': 'limit.inner_thigh',
  };

  static const _limitAliases = <String, String>{
    'knee': 'limit.knee',
    'waist': 'limit.waist',
    'back': 'limit.waist',
    'shoulder': 'limit.shoulder',
    'wrist': 'limit.wrist',
    'neck': 'limit.neck',
    'hip': 'limit.hip',
    'inner_thigh': 'limit.inner_thigh',
  };

  static Set<String> _encode(Drill drill) => {
    'purpose.${_part(drill.category)}',
    // The source catalogue explicitly classifies these actions as core.
    if (drill.category == 'core') 'body.core',
    for (final group in drill.muscleGroups)
      'body.${group == 'adductors' ? 'inner_thigh' : _part(group)}',
    for (final id in drill.equipment)
      if (id.isNotEmpty && id != 'none') 'equip.${_part(id)}',
    for (final scene in drill.scenes) 'scene.${_part(scene)}',
    'pose.${_part(drill.position)}',
    'level.${drill.level}',
  };

  static String _part(String value) => value.replaceAll('-', '_');
  static List<String> _sorted(Iterable<String> values) =>
      List.unmodifiable(values.toSet().toList()..sort());
}
