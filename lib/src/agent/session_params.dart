/// Structured parameter provenance and validation for a coaching session.
library;

import 'dart:convert';

import '../plan/coach_context.dart';
import 'action_tags.dart';
import 'session_state.dart';
import 'user_memory.dart';

class ParamMutation {
  const ParamMutation._(
    this.state,
    this.error,
    this.changedFields,
    this.valueChangedFields, {
    this.kept = const {},
    this.ignoredEquipmentExclude = const [],
    this.notes = const [],
    this.feasibility,
  });

  final CoachSessionState state;
  final Map<String, Object?>? error;
  final Set<String> changedFields;

  /// Fields whose structured value changed, excluding provenance-only writes.
  final Set<String> valueChangedFields;
  final Set<String> kept;
  final List<String> ignoredEquipmentExclude;
  final List<String> notes;
  final Map<String, Object?>? feasibility;
  bool get ok => error == null;

  Map<String, Object?> toJson() =>
      error ??
      {
        'ok': true,
        if (notes.isNotEmpty) 'notes': notes,
        if (feasibility != null) ...{
          'status': 'infeasible',
          'needsUserChoice': true,
          'feasibility': feasibility,
        },
        if (kept.isNotEmpty) 'kept': kept.toList(),
        if (ignoredEquipmentExclude.isNotEmpty) ...{
          'ignoredEquipmentExclude': ignoredEquipmentExclude,
          'note': '非当前场景环境物的排除已忽略；原有条件保留。',
        },
        'params': {
          for (final entry in state.params.entries)
            entry.key: entry.value.toJson(),
        },
      };
}

/// Only checks structured fields and literal quote provenance, not intent.
class SessionParams {
  SessionParams(this.tags);

  final ActionTags tags;
  static const fields = {
    'scene',
    'goal',
    'equipment',
    'equipment_exclude',
    'minutes',
    'level',
    'limits',
    'dose',
    'operation',
  };
  static const sources = {'user', 'preselect', 'default', 'derived'};

  /// Profile scenes that have at least one matching scoped catalogue action.
  /// The profile's accepted scenes and posture rules are the same rules used
  /// during action admission; no scene is invented from an empty directory.
  List<String> get sceneCodes {
    final profile = tags.profile;
    final catalog = tags.catalog;
    final drills = profile.scope(catalog);
    return [
      for (final entry in profile.scenes.entries)
        if (drills.any((drill) {
          final rule = entry.value;
          final acceptable = rule.acceptDrillScenes.isEmpty
              ? {entry.key}
              : rule.acceptDrillScenes;
          return drill.scenes.any(acceptable.contains) &&
              !(rule.forbidFloor &&
                  catalog.taxonomy.floorPositions.contains(drill.position)) &&
              !rule.forbidPositions.contains(drill.position);
        }))
          entry.key,
    ]..sort();
  }

  /// Existing host-only equipment may be kept or removed by the model, but
  /// a new opaque code cannot be introduced through the model-facing tool.
  List<String> equipmentCodes(CoachSessionState state) {
    final current =
        (state.params['equipment']?.value as List<Object?>? ?? const [])
            .cast<String>();
    final host = (state.hostValues['equipment'] as List<Object?>? ?? const [])
        .cast<String>()
        .toSet();
    return ({
      ...tags.equipmentCodes,
      for (final value in current)
        if (host.contains(value) && tags.equipmentId(value) != null) value,
    }.toList()..sort());
  }

  /// All field updates are committed together, or none are committed.
  ParamMutation set(
    CoachSessionState state,
    Object? arguments, {
    List<MemoryEntry> memory = const [],
  }) {
    if (arguments is! Map<Object?, Object?> ||
        arguments['fields'] is! Map<Object?, Object?>) {
      return _failure(
        state,
        'invalid_fields',
        'fields',
        '非空字段对象',
        arguments,
        '提供仅含 fields 的对象。',
      );
    }
    final rawFields = arguments['fields']! as Map<Object?, Object?>;
    if (rawFields.isEmpty) {
      return ParamMutation._(
        state,
        null,
        const {},
        const {},
        notes: const ['空更新，已保留当前条件。'],
      );
    }
    final next = Map<String, CoachParamValue>.of(state.params);
    final changed = <String>{};
    final valueChanged = <String>{};
    final kept = <String>{};
    final ignoredEquipmentExclude = <String>[];
    final notes = <String>[];
    Map<String, Object?>? feasibility;
    if (arguments.keys.any((key) => key != 'fields')) {
      notes.add('已忽略 fields 以外的附加字段。');
    }
    final orderedFields = [
      if (rawFields.containsKey('scene')) MapEntry('scene', rawFields['scene']),
      ...rawFields.entries.where((entry) => entry.key != 'scene'),
    ];
    for (final entry in orderedFields) {
      final name = entry.key;
      if (name is! String || !fields.contains(name)) {
        return _failure(
          state,
          'unknown_field',
          'fields',
          fields.toList(),
          name,
          '只设置列出的参数字段。',
        );
      }
      final raw = entry.value;
      if (raw is! Map<Object?, Object?> ||
          (!raw.containsKey('value') &&
              !(name == 'minutes' && raw['source'] == 'derived')) ||
          !raw.containsKey('source')) {
        return _failure(
          state,
          'invalid_parameter',
          'fields.$name',
          '含 value、source 和可选 quote 的对象',
          raw,
          '提供 value 和 source，引用原话时填写 quote。',
        );
      }
      if (raw.keys.any(
        (key) => !{'value', 'source', 'quote', 'direction'}.contains(key),
      )) {
        notes.add('$name：已忽略附加参数。');
      }
      var value = raw['value'];
      if (value is String &&
          {
            'goal',
            'equipment',
            'equipment_exclude',
            'limits',
            'dose',
          }.contains(name)) {
        try {
          final parsed = jsonDecode(value);
          if (parsed is List) {
            value = parsed;
            notes.add('$name：已解析数组字符串。');
          }
        } on FormatException {
          /* Real enum validation remains below. */
        }
      }
      if (value is List && name != 'dose') {
        final unique = value.toSet().toList();
        if (unique.length != value.length) notes.add('$name：已合并重复值。');
        value = unique;
      }
      if (name == 'dose' && value is List) {
        value = [
          for (final entry in value)
            if (entry is Map)
              {
                ...entry,
                'value': entry['value'] is String
                    ? int.tryParse((entry['value'] as String).trim()) ??
                          entry['value']
                    : entry['value'] is num &&
                          (entry['value'] as num).isFinite &&
                          entry['value'] ==
                              (entry['value'] as num).roundToDouble()
                    ? (entry['value'] as num).toInt()
                    : entry['value'],
              }
            else
              entry,
        ];
      }
      if ({'minutes', 'level'}.contains(name)) {
        final normalized = value is String
            ? int.tryParse(value.trim())
            : value is num && value.isFinite && value == value.roundToDouble()
            ? value.toInt()
            : value;
        if (normalized != null && normalized != value) {
          notes.add('$name：已规范化整数。');
        }
        value = normalized ?? value;
      }
      Object? effectiveValue = value;
      CoachParamValue? derivedBaseline;
      final source = raw['source'];
      var old = state.params[name];
      if (source is! String || !sources.contains(source)) {
        return _failure(
          state,
          'invalid_source',
          'fields.$name.source',
          sources.toList(),
          source,
          '从 user、preselect、default 中选择来源；推测场景或相对时长可使用 derived。',
        );
      }
      if ((old?.source == 'user' ||
              old?.source == 'host' ||
              old?.source == 'derived') &&
          (source == 'default' || source == 'preselect')) {
        kept.add(name);
        continue;
      }
      if ({'dose', 'operation'}.contains(name) && source != 'user') {
        return _failure(
          state,
          'invalid_source',
          'fields.$name.source',
          'user',
          source,
          '明确剂量只记录用户原话，不预设为用户要求。',
        );
      }
      if (name == 'equipment_exclude' && source != 'user') {
        return _failure(
          state,
          'invalid_source',
          'fields.equipment_exclude.source',
          'user',
          source,
          '明确排除环境物时，引用用户本轮原话并使用 user 来源。',
        );
      }
      final direction = raw['direction'];
      if (source == 'derived' && name != 'minutes' && name != 'scene') {
        return _failure(
          state,
          'invalid_source',
          'fields.$name.source',
          'derived 仅用于 minutes 或 scene',
          source,
          '其他参数使用 user、preselect 或 default。',
        );
      }
      if ((source != 'derived' || name != 'minutes') && direction != null) {
        notes.add('$name：已忽略不适用的 direction。');
      }
      if (source == 'derived' &&
          name == 'minutes' &&
          !{'shorter', 'longer'}.contains(direction)) {
        return _failure(
          state,
          'invalid_direction',
          'fields.minutes.direction',
          ['shorter', 'longer'],
          direction,
          '提供 shorter 或 longer。',
        );
      }
      if (source == 'derived' && name == 'minutes') {
        if (old == null) {
          final defaultMinutes = int.tryParse(
            tags.profile.vars['defaultMinutes'] ?? '',
          );
          if (defaultMinutes != null && defaultMinutes > 0) {
            final turn = state.userTurns.lastOrNull?.turn ?? 0;
            old = CoachParamValue(
              value: defaultMinutes,
              source: 'default',
              turn: turn > 0 ? turn - 1 : 0,
            );
            notes.add('minutes：使用 profile 默认 $defaultMinutes 分钟作为派生基准。');
          }
        }
        if (old?.value is! int || (old!.value! as int) <= 0) {
          final q = raw['quote'];
          if (old == null &&
              q is String &&
              _normalize(q).isNotEmpty &&
              state.userTurns.lastOrNull != null &&
              _normalize(state.userTurns.last.text).contains(_normalize(q))) {
            return ParamMutation._(
              state,
              null,
              const {},
              const {},
              feasibility: {
                'reason': 'derived_missing_baseline',
                'fix': '请确认作为调整基准的分钟数。',
              },
            );
          }
          return _failure(
            state,
            'derived_missing_baseline',
            'fields.minutes',
            '已设置的正整数时长',
            old?.value,
            '先设置明确的基准时长。',
          );
        }
        final range = tags.profile.planRules.derivedStep;
        final allowedMinutes = tags.profile.limits.minutes;
        if (!range.min.isFinite ||
            !range.max.isFinite ||
            range.min <= 0 ||
            range.max < range.min ||
            range.max > 1 ||
            allowedMinutes.min <= 0 ||
            allowedMinutes.max < allowedMinutes.min) {
          return _failure(
            state,
            'invalid_derived_config',
            'profile.planRules.derivedStep',
            '0 < min ≤ max ≤ 1 且 profile 时长范围有效',
            range.toJson(),
            '修正派生比例和 profile 时长范围。',
          );
        }
        derivedBaseline =
            old.source == 'derived' &&
                old.turn == (state.userTurns.lastOrNull?.turn ?? 0) &&
                old.direction == direction &&
                _normalize(old.quote ?? '') ==
                    (raw['quote'] is String
                        ? _normalize(
                            String.fromCharCodes(
                              (raw['quote'] as String).runes.take(30),
                            ),
                          )
                        : '')
            ? old.basedOn ?? old
            : old;
        final base = derivedBaseline.value! as int;
        final low = direction == 'shorter'
            ? base * (1 - range.max)
            : base * (1 + range.min);
        final high = direction == 'shorter'
            ? base * (1 - range.min)
            : base * (1 + range.max);
        final minValue = (((low - 1e-9) / 5).ceil() * 5).clamp(
          allowedMinutes.min,
          allowedMinutes.max + 5,
        );
        final maxValue = (((high + 1e-9) / 5).floor() * 5).clamp(
          allowedMinutes.min - 5,
          allowedMinutes.max,
        );
        // Profile endpoints need not themselves be multiples of five.
        final first = ((minValue + 4) ~/ 5) * 5;
        final last = (maxValue ~/ 5) * 5;
        final requested = value is int && value > 0
            ? ((value + 2) ~/ 5) * 5
            : null;
        if (first > last) {
          final q = raw['quote'];
          if (q is! String ||
              _normalize(q).isEmpty ||
              state.userTurns.lastOrNull == null ||
              !_normalize(state.userTurns.last.text).contains(_normalize(q)) ||
              old.turn >= state.userTurns.last.turn) {
            return _failure(
              state,
              'quote_not_found',
              'fields.minutes.quote',
              '本轮真实的新用户原话',
              q,
              '引用本轮用户调整时长的原话。',
            );
          }
          feasibility = {
            'reason': 'derived_minutes_unavailable',
            'basedOn': base,
            'direction': direction,
            'fix': '当前时长没有符合范围的调整值，请选择明确时长。',
          };
          continue;
        }
        final preferred = direction == 'shorter'
            ? base * (1 - range.min)
            : base * (1 + range.min);
        final rounded =
            requested != null && requested >= first && requested <= last
            ? requested
            : (((preferred / 5).round() * 5).clamp(first, last));
        if (rounded != value) notes.add('minutes：已按方向和允许范围计算为 $rounded 分钟。');
        effectiveValue = rounded;
      }
      final valueIssue = _valueError(name, effectiveValue, state);
      if (valueIssue != null) {
        return _failure(
          state,
          'invalid_value',
          'fields.$name.value',
          valueIssue,
          value,
          '使用工具枚举中的合法编码和数值。',
        );
      }
      var quote = raw['quote'];
      int sourceTurn = state.userTurns.isEmpty ? 0 : state.userTurns.last.turn;
      if (quote != null && quote is! String) {
        return _failure(
          state,
          'invalid_quote',
          'fields.$name.quote',
          '不超过30字的原话字符串',
          quote,
          '提供一段实际用户原话。',
        );
      }
      if (source == 'user' || source == 'derived') {
        if (quote is! String || _normalize(quote).isEmpty) {
          return _failure(
            state,
            'invalid_quote',
            'fields.$name.quote',
            '1–30字且包含非标点内容的用户原话',
            quote,
            '引用本会话中的一段用户原话。',
          );
        }
        final normalized = _normalize(quote);
        final matching = state.userTurns
            .where((turn) => _normalize(turn.text).contains(normalized))
            .toList();
        if (matching.isEmpty) {
          return _failure(
            state,
            'quote_not_found',
            'fields.$name.quote',
            '本会话用户消息中存在的片段',
            quote,
            '逐字引用本会话里的用户消息。',
          );
        }
        sourceTurn = matching.last.turn;
        if (quote.runes.length > 30) {
          quote = String.fromCharCodes(quote.runes.take(30));
          notes.add('$name：原话已核对，保存前30字符作为短引用。');
        }
      }
      if (name == 'equipment_exclude') {
        final rawWanted = (value! as List<Object?>).cast<String>().toSet();
        final ambient = tags.profile.ambientEquipmentFor(
          next['scene']?.value as String?,
        );
        final wanted = rawWanted.intersection(ambient);
        final previousAll = old == null
            ? <String>{}
            : (old.value! as List<Object?>).cast<String>().toSet();
        final previous = previousAll.intersection(ambient);
        ignoredEquipmentExclude.addAll(rawWanted.difference(ambient));
        if (rawWanted.isNotEmpty && wanted.isEmpty) continue;
        if (!wanted.containsAll(previous)) {
          return _failure(
            state,
            'equipment_exclude_cannot_relax',
            'fields.equipment_exclude.value',
            previous.toList(),
            wanted.toList(),
            '保留已经明确排除的物品，只能追加排除。',
          );
        }
        if (wanted.difference(previous).isNotEmpty &&
            (sourceTurn != state.userTurns.last.turn ||
                sourceTurn <= (old?.turn ?? 0))) {
          return _failure(
            state,
            'equipment_exclude_quote_not_new',
            'fields.equipment_exclude.quote',
            '上次排除设置之后的本轮用户原话',
            quote,
            '引用用户本轮明确排除物品的原话。',
          );
        }
        effectiveValue = {...previousAll, ...wanted}.toList();
      }
      if (source == 'derived' &&
          name == 'scene' &&
          (old?.source == 'user' || old?.source == 'host')) {
        kept.add(name);
        continue;
      }
      if (source == 'derived' &&
          name == 'scene' &&
          (sourceTurn != state.userTurns.last.turn ||
              (old?.source == 'derived' &&
                  sourceTurn < old!.turn &&
                  !_same(old.value, value)))) {
        return _failure(
          state,
          'derived_quote_not_new',
          'fields.scene.quote',
          '上次场景设置之后的本轮用户原话',
          quote,
          '引用本轮新的用户消息来推断场景。',
        );
      }
      if (source == 'derived' &&
          name == 'minutes' &&
          (sourceTurn <= (derivedBaseline ?? old)!.turn ||
              sourceTurn != state.userTurns.last.turn)) {
        return _failure(
          state,
          'derived_quote_not_new',
          'fields.minutes.quote',
          '上次设置后且属于当前轮的用户消息',
          quote,
          '引用当前轮、且在上次时长设置之后的用户原话。',
        );
      }
      if ((old?.source == 'user' ||
              old?.source == 'host' ||
              old?.source == 'derived') &&
          (source == 'default' || source == 'preselect')) {
        kept.add(name);
        continue;
      }
      if (old?.source == 'host' &&
          source == 'user' &&
          sourceTurn <= old!.turn) {
        if (_same(old.value, value)) continue;
        return _failure(
          state,
          'quote_not_newer_than_host',
          'fields.$name.quote',
          '宿主设置之后的用户消息',
          quote,
          '引用宿主更新之后用户明确提供的新条件。',
        );
      }
      if ((old?.source == 'user' || old?.source == 'derived') &&
          source == 'user' &&
          sourceTurn < old!.turn &&
          !_same(old.value, value)) {
        return _failure(
          state,
          'stale_user_quote',
          'fields.$name.quote',
          '不早于当前条件来源的用户消息',
          quote,
          '引用较新的用户条件，保留已经更新的值。',
        );
      }
      if (source == 'preselect' &&
          !_isMemoryValue(name, value, memory, quote as String?)) {
        return _failure(
          state,
          'preselect_not_in_memory',
          'fields.$name.value',
          'user_memory 中可直接核对的编码习惯值',
          value,
          '只使用已保存且编码可直接核对的习惯值，或询问用户。',
        );
      }
      if (name == 'equipment') {
        final wanted = (value! as List<Object?>).cast<String>().toSet();
        if (source == 'default' && wanted.isNotEmpty) {
          return _failure(
            state,
            'default_equipment',
            'fields.equipment.value',
            <String>[],
            value,
            '默认器材只能使用空数组（徒手）。',
          );
        }
        final previous = old == null
            ? <String>{}
            : (old.value! as List<Object?>).cast<String>().toSet();
        final added = wanted.difference(previous);
        if (added.isNotEmpty &&
            (source != 'user' ||
                ({'user', 'host'}.contains(old?.source) &&
                    (sourceTurn <= (old?.turn ?? 0) ||
                        sourceTurn !=
                            (state.userTurns.lastOrNull?.turn ?? 0))))) {
          return _failure(
            state,
            'equipment_not_newly_confirmed',
            'fields.equipment.value',
            '新增器材须来自上次设置之后的新用户消息',
            added.toList(),
            '让用户提供新的器材信息，并引用该消息原话。',
          );
        }
      }
      if (name == 'limits' && old != null) {
        final oldLimits = {
          for (final code in (old.value! as List<Object?>).cast<String>())
            tags.canonicalLimitCode(code) ?? code,
        };
        final newLimits = (value! as List<Object?>).cast<String>().toSet();
        // Host protections that are not representable by the catalogue enum
        // stay separate and cannot be removed by a model-provided value.
        final opaque =
            (state.hostValues['limitsOpaque'] as List<Object?>? ?? const [])
                .cast<String>()
                .toSet();
        newLimits.addAll(opaque);
        final removed = oldLimits.difference(newLimits);
        if (removed.isNotEmpty) {
          return _failure(
            state,
            'limits_cannot_relax',
            'fields.limits.value',
            oldLimits.toList(),
            newLimits.toList(),
            '保留已有伤痛限制；需放宽时由宿主更新。',
          );
        }
        effectiveValue = newLimits.toList();
      }
      // A repeated value cannot move the equipment's last-set turn backwards.
      if (old != null &&
          _same(old.value, effectiveValue) &&
          old.source == source &&
          (name != 'equipment' || sourceTurn <= old.turn)) {
        continue;
      }
      next[name] = CoachParamValue(
        value: effectiveValue,
        source: source,
        quote: quote as String?,
        turn: sourceTurn,
        direction: source == 'derived' && name == 'minutes'
            ? direction as String
            : null,
        basedOn: source == 'derived' && name == 'minutes'
            ? derivedBaseline ?? old
            : null,
      );
      changed.add(name);
      if (old == null || !_same(old.value, effectiveValue)) {
        valueChanged.add(name);
      }
    }
    return ParamMutation._(
      state.copyWith(params: next),
      null,
      Set.unmodifiable(changed),
      Set.unmodifiable(valueChanged),
      kept: Set.unmodifiable(kept),
      ignoredEquipmentExclude: List.unmodifiable(ignoredEquipmentExclude),
      notes: List.unmodifiable(notes),
      feasibility: feasibility,
    );
  }

  /// Host changes are structural and are applied before the new user turn.
  /// Every explicitly supplied value is a host write, including repeats.
  /// An explicitly supplied avoid collection replaces current safety limits.
  ParamMutation applyHost(CoachSessionState state, CoachContext context) {
    final host = <String, Object?>{
      if (context.scene != null) 'scene': context.scene,
      if (context.equipment != null)
        'equipment': [
          for (final raw in context.equipment!) ?tags.equipmentCode(raw),
        ]..sort(),
      if (context.minutes != null) 'minutes': context.minutes,
      if (context.level != null) 'level': context.level,
      if (context.hasExplicitAvoid)
        'limits': [
          for (final raw in context.avoid) ?tags.canonicalLimitCode(raw),
        ]..sort(),
    };
    final next = Map<String, CoachParamValue>.of(state.params);
    final hostValues = Map<String, Object?>.of(state.hostValues);
    if (context.hasExplicitAvoid) {
      hostValues['limitsRaw'] = context.avoid.toList()..sort();
      hostValues['limitsOpaque'] = [
        for (final raw in context.avoid)
          if (tags.canonicalLimitCode(raw) case final code?)
            if (!tags.limitCodes.contains(code)) code,
      ]..sort();
    }
    final changed = <String>{};
    final valueChanged = <String>{};
    final turn = state.userTurns.isEmpty ? 0 : state.userTurns.last.turn;
    for (final entry in host.entries) {
      final name = entry.key;
      final value = entry.value;
      final old = state.params[name];
      if (name == 'scene' && !sceneCodes.contains(value)) {
        return _failure(
          state,
          'invalid_host_context',
          'scene',
          sceneCodes,
          value,
          '宿主提供有效场景编码。',
        );
      }
      if (name == 'minutes' && (value is! int || value < 1)) {
        return _failure(
          state,
          'invalid_host_context',
          'minutes',
          '正整数',
          value,
          '宿主提供正整数分钟数。',
        );
      }
      if (name == 'level' && (value is! int || value < 1 || value > 3)) {
        return _failure(
          state,
          'invalid_host_context',
          'level',
          [1, 2, 3],
          value,
          '宿主提供1–3的水平。',
        );
      }
      hostValues[name] = value;
      if (old == null ||
          old.source != 'host' ||
          !_same(old.value, value) ||
          old.turn != turn) {
        next[name] = CoachParamValue(value: value, source: 'host', turn: turn);
        if (old == null || old.source != 'host' || !_same(old.value, value)) {
          changed.add(name);
        }
        if (old == null || !_same(old.value, value)) valueChanged.add(name);
      }
    }
    return ParamMutation._(
      state.copyWith(params: next, hostValues: hostValues),
      null,
      Set.unmodifiable(changed),
      Set.unmodifiable(valueChanged),
    );
  }

  Object? _valueError(String name, Object? value, CoachSessionState state) {
    if (name == 'operation') {
      return {'edit', 'replace_all'}.contains(value)
          ? null
          : 'edit 或 replace_all';
    }
    if (name == 'dose') {
      if (value is! List) return '剂量约束数组';
      final seen = <String, int>{};
      for (final constraint in value) {
        if (constraint is! Map ||
            constraint.keys.any(
              (key) => !{'field', 'value', 'actionId', 'blockId'}.contains(key),
            ) ||
            !{
              'sets',
              'reps',
              'seconds',
              'rounds',
            }.contains(constraint['field']) ||
            constraint['value'] is! int ||
            (constraint['value'] as int) <= 0) {
          return '每项含 field、正整数 value，可选 actionId/blockId';
        }
        final id = constraint['actionId'];
        if (id != null &&
            (id is! String ||
                tags.catalog[id] == null ||
                !tags.profile.select.matches(tags.catalog[id]!))) {
          return '真实目录内的 actionId';
        }
        if (constraint['blockId'] != null &&
            (constraint['blockId'] is! String ||
                !RegExp(
                  r'^b[1-9][0-9]*$',
                ).hasMatch(constraint['blockId'] as String))) {
          return 'blockId 为 b1、b2 等稳定分块 ID';
        }
        if (constraint['field'] == 'rounds' && id != null) {
          return '轮数约束作用于块或全局，不含 actionId';
        }
        final key =
            '${constraint['field']}:${constraint['actionId']}:${constraint['blockId']}';
        if (seen.containsKey(key) && seen[key] != constraint['value']) {
          return '同一作用范围的同一剂量字段只能有一个明确值';
        }
        seen[key] = constraint['value'] as int;
      }
      return null;
    }
    if (name == 'scene') {
      return value is String && sceneCodes.contains(value) ? null : sceneCodes;
    }
    if (name == 'minutes') return value is int && value > 0 ? null : '正整数';
    if (name == 'level') {
      return value is int && value >= 1 && value <= 3 ? null : [1, 2, 3];
    }
    if (value is! List<Object?> || value.any((item) => item is! String)) {
      return '编码字符串数组';
    }
    if (name == 'equipment_exclude') {
      return value.every(
                (item) =>
                    RegExp(r'^equip\.[a-z0-9_]+$').hasMatch(item as String),
              ) &&
              value.toSet().length == value.length
          ? null
          : '不重复的 equip.* 编码数组';
    }
    final valid = switch (name) {
      'goal' => tags.goalCodes,
      'equipment' => equipmentCodes(state),
      'limits' => tags.limitCodes,
      _ => const <String>[],
    };
    return value.every(valid.contains) && value.toSet().length == value.length
        ? null
        : valid;
  }

  bool _isMemoryValue(
    String field,
    Object? value,
    List<MemoryEntry> memory,
    String? quote,
  ) {
    final kind = switch (field) {
      'scene' => MemoryKind.scene,
      'goal' => MemoryKind.goal,
      'equipment' => MemoryKind.equipment,
      'minutes' => MemoryKind.schedule,
      'level' => MemoryKind.level,
      'limits' => MemoryKind.injury,
      _ => MemoryKind.other,
    };
    final texts = {
      for (final entry in memory)
        if (entry.kind == kind) entry.text,
    };
    if (texts.contains(jsonEncode(value)) || texts.contains('$value')) {
      return true;
    }
    if (quote != null &&
        quote.runes.length <= 30 &&
        _normalize(quote).isNotEmpty) {
      // Literal source check only: the model maps memory text to the code.
      // This does not prove that the mapping is semantically correct.
      final needle = _normalize(quote);
      if (texts.any((text) => _normalize(text).contains(needle))) return true;
    }
    return value is List<Object?> &&
        value.isNotEmpty &&
        value.every((v) => texts.contains(v));
  }

  static final _strip = RegExp(r'[\s\p{P}]', unicode: true);
  static String _normalize(String text) =>
      text.replaceAll(_strip, '').toLowerCase();

  static bool _same(Object? a, Object? b) {
    if ((a is List && a.any((e) => e is Map)) || a is Map) {
      return jsonEncode(a) == jsonEncode(b);
    }
    if (a is List<Object?> && b is List<Object?>) {
      return a.length == b.length && a.toSet().containsAll(b);
    }
    return a == b;
  }

  static ParamMutation _failure(
    CoachSessionState state,
    String code,
    String field,
    Object? expected,
    Object? actual,
    String fix,
  ) => ParamMutation._(
    state,
    {
      'ok': false,
      'code': code,
      'field': field,
      'expected': expected,
      'actual': actual,
      'fix': fix,
    },
    const {},
    const {},
  );
}
