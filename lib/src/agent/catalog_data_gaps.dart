/// Directory completeness diagnostics are distinct from user safety limits.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import '../catalog/catalog.dart';
import 'action_tags.dart';
import 'session_state.dart';

/// A developer-only structured log. It never enters persisted conversation
/// state, model tool receipts or a plan card. A scoped sink supports host
/// diagnostics and tests without a process-wide mutable callback.
class CatalogDataGapLog {
  static final _sinkKey = Object();

  static T capture<T>(
    void Function(Map<String, Object?>) sink,
    T Function() body,
  ) => runZoned(body, zoneValues: {_sinkKey: sink});

  static void write(Map<String, Object?> entry) {
    final frozen = Map<String, Object?>.unmodifiable(entry);
    developer.log(jsonEncode(frozen), name: 'ugk_coach.catalog_data_gap');
    final sink = Zone.current[_sinkKey];
    if (sink is void Function(Map<String, Object?>)) sink(frozen);
  }
}

class CatalogDataGaps {
  CatalogDataGaps(this.tags);
  final ActionTags tags;

  static String warning(String id, String field) =>
      '$id 的 $field 尚未明确，不能视为已验证。';

  Iterable<({String field, Map<Object?, Object?> entry})> _entries(
    Drill drill,
  ) sync* {
    final semantics = drill.raw['trainingSemantics'];
    final fields = semantics is Map ? semantics['unknownFields'] : null;
    if (fields is! List) return;
    for (final entry in fields) {
      if (entry is Map && entry['field'] is String) {
        yield (
          field: entry['field'] as String,
          entry: entry.cast<Object?, Object?>(),
        );
      }
    }
  }

  /// Cautions and contraindications are general safety fields: a declared
  /// gap relates to every nonempty restriction ledger, independently of the
  /// action's target body part. Other completeness fields are diagnostics.
  Set<String> relatedLimits(
    CoachSessionState state,
    Drill drill,
    String field,
  ) {
    if (field != 'cautions' && field != 'contraindications') return const {};
    final limits =
        ((state.params['limits']?.value as List<Object?>?) ?? const [])
            .cast<String>()
            .map((code) => tags.canonicalLimitCode(code) ?? code)
            .toSet();
    if (limits.isEmpty) return const {};
    return limits;
  }

  List<String> warnings(CoachSessionState state, Iterable<String> ids) {
    final warnings = <String>[];
    for (final id in ids.toSet()) {
      final drill = tags.catalog[id];
      if (drill == null) continue;
      for (final gap in _entries(drill)) {
        final related = relatedLimits(state, drill, gap.field);
        CatalogDataGapLog.write({
          'code': 'catalog_data_gap',
          'catalogVersion': tags.catalog.version,
          'actionId': id,
          'field': gap.field,
          if (gap.entry['reason'] is String) 'reason': gap.entry['reason'],
          'relatedLimits': related.toList()..sort(),
          'modelVisible': related.isNotEmpty,
        });
        if (related.isNotEmpty) warnings.add(warning(id, gap.field));
      }
    }
    return warnings;
  }

  /// Previously persisted, exact catalogue-template warnings follow the same
  /// current ledger policy after restore. Unknown/host safety text is retained.
  List<String> filterWarnings(
    CoachSessionState state,
    Iterable<String> values,
  ) {
    final bindings = <String, ({Drill drill, String field})>{};
    for (final drill in tags.catalog.drills) {
      for (final gap in _entries(drill)) {
        bindings[warning(drill.id, gap.field)] = (
          drill: drill,
          field: gap.field,
        );
      }
    }
    bool keep(String value) {
      final binding = bindings[value];
      if (binding == null ||
          relatedLimits(state, binding.drill, binding.field).isNotEmpty) {
        return true;
      }
      CatalogDataGapLog.write({
        'code': 'catalog_data_gap',
        'catalogVersion': tags.catalog.version,
        'actionId': binding.drill.id,
        'field': binding.field,
        'relatedLimits': const <String>[],
        'modelVisible': false,
        'source': 'restored_warning',
      });
      return false;
    }

    return [
      for (final value in values)
        if (keep(value)) value,
    ];
  }
}
