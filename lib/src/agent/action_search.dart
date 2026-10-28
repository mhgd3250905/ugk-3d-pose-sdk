/// Local catalogue search: matching and safety use structured catalogue data.
library;

import '../catalog/catalog.dart';
import '../plan/training_plan.dart';
import '../profile/coach_profile.dart';
import 'agent_task.dart';
import 'node_gates.dart';
import 'session_state.dart';

class ActionSearchResult {
  const ActionSearchResult(
    this.state, {
    this.items = const [],
    this.filter = const {},
    this.format = const {},
    this.summary = '',
    this.warnings = const [],
    this.error,
  });
  final CoachSessionState state;
  final List<Map<String, Object?>> items;
  final Map<String, Object?> filter;
  final Map<String, Object?> format;
  final String summary;
  final List<String> warnings;
  final Map<String, Object?>? error;
  bool get ok => error == null;
  Map<String, Object?> toJson() =>
      error ??
      {
        'ok': true,
        'items': items,
        if (filter.isNotEmpty) 'filter': filter,
        if (format.isNotEmpty) 'format': format,
        if (summary.isNotEmpty) 'summary': summary,
        if (warnings.isNotEmpty) 'warnings': warnings,
      };
}

class ActionSearch {
  ActionSearch(CoachProfile profile, this.catalog, {required int minPicks})
    : gate = NodeGates(profile, catalog, minPicks: minPicks),
      _drills = List.unmodifiable(profile.scope(catalog)) {
    _bodies = List.unmodifiable(
      gate.tags.tags.where((t) => t.startsWith('body.')).toList()..sort(),
    );
    _equipment = List.unmodifiable(gate.tags.equipmentCodes.toList()..sort());
    _positions = List.unmodifiable(
      {for (final d in _drills) d.position}.toList()..sort(),
    );
    _scenes = List.unmodifiable(
      {for (final d in _drills) ...d.scenes}.toList()..sort(),
    );
  }

  final Catalog catalog;
  final NodeGates gate;
  final List<Drill> _drills;
  late final List<String> _bodies, _equipment, _positions, _scenes;
  List<String> get tags => gate.tags.tags;

  ActionSearchResult search(
    CoachSessionState state, {
    List<String> tags = const [],
    String keywords = '',
    int limit = 20,
    String language = 'zh',
  }) {
    final task = state.task;
    if (task == null ||
        !{'recommend', 'plan'}.contains(task.type) ||
        task.nodes.lastOrNull?.id != 'output' ||
        task.nodes.lastOrNull?.status == 'done') {
      return ActionSearchResult(
        state,
        error: nodeError(
          'task_required',
          'task',
          '进行中的 recommend 或 plan 任务',
          task?.toJson(),
          '先调用 start_task，可以和搜索放在同一批',
        ),
      );
    }
    final invalid = tags.where((tag) => !this.tags.contains(tag)).toList();
    if (invalid.isNotEmpty) {
      return ActionSearchResult(
        state,
        error: nodeError(
          'invalid_tags',
          'tags',
          this.tags,
          invalid,
          '从目录标签枚举中选择标签。',
        ),
      );
    }
    if (limit < 1 || limit > 20) {
      return ActionSearchResult(
        state,
        error: nodeError(
          'invalid_limit',
          'limit',
          '1–20',
          limit,
          '将 limit 设置为 1 到 20。',
        ),
      );
    }
    final query = keywords.trim().toLowerCase();
    final grouped = <String, Set<String>>{};
    final expandedTags = <Set<String>>[];
    for (final tag in tags) {
      final prefix = tag.split('.').first;
      final expanded = gate.tags.expandCodes([tag]);
      if (const {'purpose', 'body', 'pose', 'level'}.contains(prefix)) {
        (grouped[prefix] ??= <String>{}).addAll(expanded);
      } else {
        expandedTags.add(expanded);
      }
    }
    expandedTags.addAll(grouped.values);
    bool matches(Drill drill) =>
        expandedTags.every(
          (group) => gate.tags.forAction(drill).intersection(group).isNotEmpty,
        ) &&
        (query.isEmpty ||
            [
              ...drill.name.values.values,
              ..._strings(drill.raw['aliases']),
            ].any((s) => s.toLowerCase().contains(query)));
    final selected = <Drill>[];
    var hiddenGear = 0;
    final hiddenEquipment = <String, int>{};
    for (final drill in _drills.where(matches)) {
      final problem = gate.actionProblem(state, drill.id);
      if (problem == null) {
        if (selected.length < limit) selected.add(drill);
      } else if (problem == '器械不符合' && _passesWithGear(state, drill)) {
        hiddenGear++;
        for (final raw in drill.equipment) {
          final code = gate.tags.equipmentCode(raw);
          if (code != null && !gate.effectiveEquipment(state).contains(code)) {
            hiddenEquipment.update(
              code,
              (count) => count + 1,
              ifAbsent: () => 1,
            );
          }
        }
      }
    }
    final en = language.toLowerCase().startsWith('en');
    final equipmentParam = state.params['equipment'];
    final gear = (equipmentParam?.value as List<Object?>? ?? const [])
        .cast<String>();
    final equipmentLabel = gear.isEmpty
        ? (en ? 'bodyweight' : '徒手')
        : gear
              .map((code) {
                final id = gate.tags.equipmentId(code) ?? code;
                return en ? id : catalog.taxonomy.equipmentLabel(id);
              })
              .join(en ? ', ' : '、');
    final filter = <String, Object?>{
      'scene': state.params['scene']?.value,
      'equipment': gear.isEmpty && equipmentParam == null
          ? (en ? 'bodyweight (default)' : '徒手（默认）')
          : equipmentLabel,
      'limits': state.params['limits']?.value ?? <String>[],
      'hiddenEquipmentCount': hiddenGear,
    };
    final scene = state.params['scene']?.value ?? (en ? 'any scene' : '不限场景');
    final limits = (state.params['limits']?.value as List<Object?>? ?? const [])
        .cast<String>();
    final limitsLabel = limits.isEmpty
        ? (en ? 'no restrictions' : '无伤痛')
        : limits.map((v) => gate.tags.limitValue(v) ?? v).join(en ? ', ' : '、');
    final repeated = selected
        .where((drill) => state.seenActionIds.contains(drill.id))
        .length;
    var summary =
        (en
            ? 'Filtered by $scene / $equipmentLabel / $limitsLabel; $hiddenGear matching actions need other equipment.'
            : '已按 $scene / $equipmentLabel / $limitsLabel 过滤，另有 $hiddenGear 个需要器材的动作未显示。') +
        (repeated == 0
            ? ''
            : en
            ? ' The following $repeated IDs were returned before.'
            : '以下 $repeated 个之前已返回，仅列 id。');
    if (selected.length < 3 && hiddenGear >= 5) {
      final codes = hiddenEquipment.keys.toList()
        ..sort((a, b) {
          final count = hiddenEquipment[b]!.compareTo(hiddenEquipment[a]!);
          return count == 0 ? a.compareTo(b) : count;
        });
      final names = codes
          .take(2)
          .map((code) => gate.tags.localizedLabel(code, language))
          .join(en ? ', ' : '、');
      summary += en
          ? ' Another $hiddenGear actions require $names; if their availability is unknown, ask once with ask_user.'
          : '另有 $hiddenGear 个需要 $names，如果不确定用户有没有，可以用 ask_user 问一次。';
    }
    final emptySearches = selected.length == repeated
        ? state.consecutiveEmptySearches + 1
        : 0;
    final next = state.copyWith(
      seenActionIds: {...state.seenActionIds, for (final d in selected) d.id},
      consecutiveEmptySearches: emptySearches,
    );
    if (emptySearches >= 2) {
      final count = candidateRows(next, language: language).length;
      final deliver = state.task?.type == 'plan'
          ? 'draft_plan'
          : 'show_actions';
      summary += en
          ? ' The candidate pool already has $count ${count == 1 ? 'action' : 'actions'}; choose from candidates and call $deliver.'
          : '候选池已有 $count 个，请从 candidates 中选择并调用 $deliver。';
    }
    final items = [
      for (final drill in selected)
        state.seenActionIds.contains(drill.id)
            ? <String, Object?>{'id': drill.id, 'doseMode': _doseMode(drill)}
            : _row(drill, language),
    ];
    return ActionSearchResult(
      next,
      items: List.unmodifiable(items),
      filter: Map.unmodifiable(filter),
      format: {
        'data': [
          'body_index',
          'equipment_indices',
          'position_index',
          'scene_indices',
          'mode',
          'dose',
          'range',
          'set_seconds',
        ],
        'body': _bodies,
        'equipment': _equipment,
        'position': _positions,
        'scene': _scenes,
        'mode': ['reps', 'seconds'],
        'dose': ['sets', 'reps_or_seconds_per_side', 'rest_seconds'],
        'range': ['sets', 'reps_or_seconds_per_side', 'rest_seconds'],
        'set_seconds':
            'estimated seconds for one set, including both sides and side switch',
      },
      summary: summary,
      warnings: List.unmodifiable(_warnings(state, selected)),
    );
  }

  /// Only previously returned IDs are disclosed, in their first-seen order.
  /// Recheck the current ledger on every composition, including after changes.
  List<List<String?>> candidateRows(
    CoachSessionState state, {
    String language = 'zh',
  }) => [
    for (final id in state.seenActionIds)
      if (gate.actionProblem(state, id) == null)
        [
          id,
          catalog[id]!.name.of(language),
          _primaryBody(catalog[id]!),
          _doseMode(catalog[id]!),
        ],
  ].take(40).toList(growable: false);

  ActionSearchResult getActions(
    CoachSessionState state,
    List<String> ids, {
    String language = 'zh',
  }) {
    if (ids.isEmpty || ids.length > 10 || ids.toSet().length != ids.length) {
      return ActionSearchResult(
        state,
        error: nodeError(
          'invalid_ids',
          'ids',
          '1–10 个不同动作 id',
          ids,
          '提供 1 到 10 个不同的动作 id。',
        ),
      );
    }
    final errors = {for (final id in ids) id: ?gate.actionProblem(state, id)};
    if (errors.isNotEmpty) {
      return ActionSearchResult(
        state,
        error: nodeError(
          'incompatible_actions',
          'ids',
          '符合当前场景、器械与伤痛限制且在范围内的动作',
          errors,
          '搜索并选择符合条件的动作。',
        ),
      );
    }
    final drills = [for (final id in ids) catalog[id]!];
    final items = [
      for (final drill in drills)
        {
          'id': drill.id,
          'name': drill.name.of(language),
          'cues': drill.cues[language] ?? drill.cues['zh'] ?? <String>[],
          'cautions': drill.cautions,
          'contraindications': drill.contraindications,
        },
    ];
    return ActionSearchResult(
      state,
      items: List.unmodifiable(items),
      warnings: List.unmodifiable(_warnings(state, drills)),
    );
  }

  bool _passesWithGear(CoachSessionState state, Drill drill) {
    final equipped = <String>{
      ...((state.params['equipment']?.value as List<Object?>?) ?? const [])
          .cast<String>(),
      for (final raw in drill.equipment) ?gate.tags.equipmentCode(raw),
    }.toList();
    final params = Map<String, CoachParamValue>.of(state.params)
      ..['equipment'] = CoachParamValue(
        value: equipped,
        source: 'default',
        turn: 0,
      );
    return gate.actionProblem(state.copyWith(params: params), drill.id) == null;
  }

  Map<String, Object?> _row(Drill drill, String language) {
    final duration = const PlanDuration();
    final dose = drill.defaultDose;
    final value = dose.mode == DoseMode.reps
        ? (dose.reps ?? 10)
        : (dose.seconds ?? 30);
    final seconds =
        (dose.mode == DoseMode.reps
                ? value * duration.repSeconds(drill)
                : value.toDouble()) *
            (drill.unilateral ? 2 : 1) +
        (drill.unilateral ? duration.switchSideSeconds : 0);
    final range = [
      drill.doseRange.sets?.toJson(),
      (dose.mode == DoseMode.reps
              ? drill.doseRange.reps
              : drill.doseRange.seconds)
          ?.toJson(),
      drill.doseRange.restSeconds?.toJson(),
    ];
    final body = _primaryBody(drill);
    final firstSentence =
        (drill.purpose.isNotEmpty ? drill.purpose : drill.name.of(language))
            .split(RegExp(r'[\r\n，；。！？,;!?]'))
            .where((part) => part.trim().isNotEmpty)
            .firstOrNull
            ?.trim() ??
        drill.name.of(language);
    final row = <String, Object?>{
      'id': drill.id,
      'name': drill.name.of(language),
      'doseMode': _doseMode(drill),
      'summary': firstSentence,
      'data': [
        body == null ? null : _bodies.indexOf(body),
        [
          for (final id in drill.equipment)
            if (gate.tags.equipmentCode(id) case final code?)
              _equipment.indexOf(code),
        ],
        _positions.indexOf(drill.position),
        [for (final scene in drill.scenes) _scenes.indexOf(scene)],
        dose.mode == DoseMode.reps ? 0 : 1,
        [dose.sets, value, dose.restSeconds],
        range,
        seconds,
      ],
    };
    return Map.unmodifiable(row);
  }

  String _doseMode(Drill drill) =>
      drill.defaultDose.mode == DoseMode.reps ? 'reps' : 'seconds';

  String? _primaryBody(Drill drill) {
    final tags = gate.tags.forAction(drill);
    final primary = drill.muscleGroups.isEmpty
        ? null
        : drill.muscleGroups.first;
    final primaryCode = primary == null
        ? null
        : 'body.${primary == 'adductors' ? 'inner_thigh' : primary.replaceAll('-', '_')}';
    return primaryCode ??
        tags.where((tag) => tag.startsWith('body.')).firstOrNull;
  }

  List<String> _warnings(CoachSessionState state, Iterable<Drill> drills) => [
    for (final code
        in ((state.hostValues['limitsOpaque'] as List<Object?>?) ?? const [])
            .cast<String>())
      '目录缺少限制 ${gate.tags.limitValue(code) ?? code} 的可核对禁忌，不能确认其安全性。',
    for (final drill in drills)
      if (drill.raw['trainingSemantics'] is Map)
        for (final item
            in ((drill.raw['trainingSemantics'] as Map)['unknownFields'] is List
                ? (drill.raw['trainingSemantics'] as Map)['unknownFields']
                      as List
                : const []))
          if (item is Map && item['field'] is String)
            '${drill.id} 的 ${item['field']} 尚未明确，不能视为已验证。',
  ];

  static Iterable<String> _strings(Object? value) sync* {
    if (value is String) {
      yield value;
    } else if (value is Iterable) {
      for (final item in value) {
        yield* _strings(item);
      }
    } else if (value is Map) {
      for (final item in value.values) {
        yield* _strings(item);
      }
    }
  }
}
