/// Measures protocol reasoning replay without storing or exposing its text.
library;

import 'dart:convert';

Map<String, Object?> reasoningReplayStats(Map<String, Object?> body) {
  final raw = body['messages'];
  final messages = raw is List ? raw : const <Object?>[];
  final records = <Map<String, Object?>>[];
  var total = 0;
  var present = 0;
  for (var index = 0; index < messages.length; index++) {
    final rawMessage = messages[index];
    if (rawMessage is! Map) continue;
    final reasoning = rawMessage['reasoning_content'];
    final hasField = rawMessage.containsKey('reasoning_content');
    if (hasField) present++;
    final bytes = reasoning is String ? utf8.encode(reasoning).length : null;
    total += bytes ?? 0;
    records.add({
      'messageIndex': index,
      'role': rawMessage['role'],
      'fieldPresent': hasField,
      'utf8Bytes': bytes,
      'jsonValueBytes': reasoning is String
          ? utf8.encode(jsonEncode(reasoning)).length
          : null,
    });
  }
  return {
    'totalUtf8Bytes': total,
    'messagesWithField': present,
    'messages': records,
    'measurement':
        'UTF-8 bytes of reasoning_content strings in actual request; excludes JSON quotes and escaping',
  };
}
