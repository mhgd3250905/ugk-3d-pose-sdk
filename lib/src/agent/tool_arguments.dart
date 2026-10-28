/// Unambiguous protocol/presentation repairs, never natural-language intent.
library;

import 'dart:convert';

import '../llm/llm_types.dart';

class NormalizedToolArguments {
  const NormalizedToolArguments(this.value, this.notes);
  final Map<String, Object?>? value;
  final List<String> notes;
}

NormalizedToolArguments normalizeToolArguments(
  String raw, {
  required Set<String> allowed,
  Set<String> lists = const {},
}) {
  Object? decoded;
  final notes = <String>[];
  try {
    decoded = jsonDecode(raw);
    if (decoded is String) {
      decoded = jsonDecode(decoded);
      notes.add('已解包字符串化的工具参数对象。');
    }
  } on FormatException {
    return const NormalizedToolArguments(null, []);
  }
  if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
    return const NormalizedToolArguments(null, []);
  }
  final args = <String, Object?>{};
  for (final entry in decoded.entries) {
    if (!allowed.contains(entry.key)) {
      notes.add('已忽略不生效的附加字段 ${entry.key}。');
      continue;
    }
    args[entry.key as String] = entry.value;
  }
  for (final field in lists) {
    Object? value = args[field];
    if (value is String) {
      try {
        value = jsonDecode(value);
      } on FormatException {
        // A single literal ID/tag has one unambiguous array representation.
        value = [value];
      }
      notes.add('已将 $field 规范化为数组。');
    }
    if (value == null) {
      value = <String>[];
      notes.add('已为缺省 $field 使用空数组。');
    }
    if (value is List && value.every((item) => item is String)) {
      final unique = value.toSet().toList();
      if (unique.length != value.length) notes.add('$field 已去重。');
      value = unique;
    }
    args[field] = value;
  }
  return NormalizedToolArguments(args, notes);
}

class NormalizedToolBatch {
  const NormalizedToolBatch(this.response, this.notes);
  final LlmResponse response;
  final Map<String, List<String>> notes;
}

/// Move only the presentation pause behind its dependent operations. Renaming
/// duplicate call IDs is reflected in the assistant message and every receipt.
NormalizedToolBatch normalizeToolBatch(LlmResponse original) {
  final reserved = original.toolCalls.map((call) => call.id).toSet();
  final used = <String>{};
  final notes = <String, List<String>>{};
  final calls = <LlmToolCall>[];
  for (final call in original.toolCalls) {
    var id = call.id;
    if (id.isEmpty || !used.add(id)) {
      var suffix = 2;
      do {
        id = '${call.id.isEmpty ? 'call' : call.id}__sdk${suffix++}';
      } while (reserved.contains(id) || !used.add(id));
      notes[id] = ['重复或空 tool_call_id 已映射为唯一 ID；原 ID：${call.id}。'];
    }
    calls.add(LlmToolCall(id: id, name: call.name, arguments: call.arguments));
  }
  final ordered = [
    ...calls.where(
      (call) => !{'ask_user', 'show_plan', 'show_actions'}.contains(call.name),
    ),
    ...calls.where((call) => call.name == 'ask_user'),
    ...calls.where((call) => {'show_plan', 'show_actions'}.contains(call.name)),
  ];
  if (calls.indexed.any((entry) => ordered[entry.$1].id != entry.$2.id)) {
    for (final call in ordered.where((call) => call.name == 'ask_user')) {
      (notes[call.id] ??= []).add('已先执行同批其他操作，再暂停询问。');
    }
  }
  if (notes.isEmpty) return NormalizedToolBatch(original, const {});
  return NormalizedToolBatch(
    LlmResponse(
      content: original.content,
      reasoning: original.reasoning,
      usage: original.usage,
      model: original.model,
      finishReason: original.finishReason,
      latency: original.latency,
      httpAttempts: original.httpAttempts,
      toolCalls: ordered,
    ),
    notes,
  );
}
