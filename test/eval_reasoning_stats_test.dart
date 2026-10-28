import 'dart:convert';

import 'package:test/test.dart';

import '../tool/eval_reasoning_stats.dart';

void main() {
  test('counts UTF-8 replay per message and total, preserving input', () {
    final body = <String, Object?>{
      'messages': [
        {'role': 'system', 'content': 'role'},
        {'role': 'assistant', 'reasoning_content': '先核对🙂'},
        {'role': 'tool', 'content': 'ok'},
        {'role': 'assistant', 'reasoning_content': 'abc\n"'},
        {'role': 'assistant', 'reasoning_content': ''},
      ],
    };
    final before = jsonEncode(body);
    final result = reasoningReplayStats(body);
    final messages = result['messages'] as List;
    expect(result['totalUtf8Bytes'], 18);
    expect(result['messagesWithField'], 3);
    expect((messages[0] as Map)['utf8Bytes'], isNull);
    expect((messages[1] as Map)['utf8Bytes'], 13);
    expect((messages[3] as Map)['utf8Bytes'], 5);
    expect((messages[3] as Map)['jsonValueBytes'], 9);
    expect((messages[4] as Map)['utf8Bytes'], 0);
    expect(jsonEncode(result), isNot(contains('先核对')));
    expect(jsonEncode(body), before);
  });

  test('missing and nonstring reasoning remain distinguishable from empty', () {
    final result = reasoningReplayStats({
      'messages': [
        {'role': 'assistant', 'reasoning_content': null},
        {'role': 'assistant', 'reasoning_content': 17},
        {'role': 'user'},
      ],
    });
    expect(result['totalUtf8Bytes'], 0);
    expect(result['messagesWithField'], 2);
    for (final row in result['messages'] as List) {
      expect((row as Map)['utf8Bytes'], isNull);
    }
    expect(reasoningReplayStats({})['messages'], isEmpty);
  });
}
