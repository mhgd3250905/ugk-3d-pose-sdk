/// Structured parameter provenance and validation for a coaching session.
library;

import 'dart:convert';

import '../plan/coach_context.dart';
import 'action_tags.dart';
import 'session_state.dart';
import 'user_memory.dart';

class ParamMutation {
  const ParamMutation._(this.state, this.error, this.changedFields);

  final CoachSessionState state;
  final Map<String, Object?>? error;
  final Set<String> changedFields;
  bool get ok => error == null;

  Map<String, Object?> toJson() =>
      error ??
      {
        'ok': true,
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
    'minutes',
    'level',
    'limits',
  };
  static const scenes = {'home', 'office', 'gym', 'outdoor'};
  static const sources = {'user', 'preselect', 'default'};

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
        arguments.keys.any((key) => key != 'fields') ||
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
      return _failure(
        state,
        'invalid_fields',
        'fields',
        '至少一个字段',
        rawFields,
        '为至少一个参数提供值和来源。',
      );
    }
    final next = Map<String, CoachParamValue>.of(state.params);
    final changed = <String>{};
    for (final entry in rawFields.entries) {
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
          raw.keys.any(
            (key) => key != 'value' && key != 'source' && key != 'quote',
          ) ||
          !raw.containsKey('value') ||
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
      final value = raw['value'];
      Object? effectiveValue = value;
      final source = raw['source'];
      final old = state.params[name];
      if (source is! String || !sources.contains(source)) {
        return _failure(
          state,
          'invalid_source',
          'fields.$name.source',
          sources.toList(),
          source,
          '从 user、preselect、default 中选择来源。',
        );
      }
      final valueIssue = _valueError(name, value, state);
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
      final quote = raw['quote'];
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
      if (source == 'user') {
        if (quote is! String ||
            quote.runes.length > 30 ||
            _normalize(quote).isEmpty) {
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
      }
      if ((old?.source == 'user' || old?.source == 'host') &&
          (source == 'default' || source == 'preselect')) {
        return _failure(
          state,
          'source_conflict',
          'fields.$name.source',
          'user 或 host 的值不被默认或预选覆盖',
          source,
          '保留原值，或用用户新的原话提供修改。',
        );
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
      if (old?.source == 'user' &&
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
            (source != 'user' || sourceTurn <= (old?.turn ?? 0))) {
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
      );
      changed.add(name);
    }
    return ParamMutation._(
      state.copyWith(params: next),
      null,
      Set.unmodifiable(changed),
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
    final turn = state.userTurns.isEmpty ? 0 : state.userTurns.last.turn;
    for (final entry in host.entries) {
      final name = entry.key;
      final value = entry.value;
      final old = state.params[name];
      if (name == 'scene' && !scenes.contains(value)) {
        return _failure(
          state,
          'invalid_host_context',
          'scene',
          scenes.toList(),
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
      }
    }
    return ParamMutation._(
      state.copyWith(params: next, hostValues: hostValues),
      null,
      Set.unmodifiable(changed),
    );
  }

  Object? _valueError(String name, Object? value, CoachSessionState state) {
    if (name == 'scene') {
      return value is String && scenes.contains(value) ? null : scenes.toList();
    }
    if (name == 'minutes') return value is int && value > 0 ? null : '正整数';
    if (name == 'level') {
      return value is int && value >= 1 && value <= 3 ? null : [1, 2, 3];
    }
    if (value is! List<Object?> || value.any((item) => item is! String)) {
      return '编码字符串数组';
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
  ) => ParamMutation._(state, {
    'ok': false,
    'code': code,
    'field': field,
    'expected': expected,
    'actual': actual,
    'fix': fix,
  }, const {});
}
