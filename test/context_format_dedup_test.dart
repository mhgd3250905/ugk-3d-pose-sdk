import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/context_compactor.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();
  const compactor = ContextCompactor();
  const firstFormat = {
    'body': ['body.abs'],
    'equipment': ['equip.mat'],
    'data': ['body_index', 'equipment_indices'],
  };
  const secondFormat = {
    'body': ['body.chest'],
    'equipment': ['equip.mat'],
    'data': ['body_index', 'equipment_indices'],
  };
  LlmToolCall search(String id) =>
      LlmToolCall(id: id, name: 'search_actions', arguments: '{"tags":[]}');
  LlmMessage result(String id, Map<String, Object?> format) => LlmMessage.tool(
    id,
    jsonEncode({
      'ok': true,
      'items': [
        {
          'id': 'action-$id',
          'name': '动作$id',
          'data': [
            0,
            [0],
          ],
        },
      ],
      'summary': '完整查询结果',
      'format': format,
    }),
  );
  Map<String, dynamic> body(List<LlmMessage> messages, String id) =>
      jsonDecode(
            messages.singleWhere((message) => message.toolCallId == id).content,
          )
          as Map<String, dynamic>;

  test(
    'same-batch identical dictionaries reference an earlier complete paired tool result',
    () {
      final calls = [search('first'), search('second'), search('different')];
      final history = [
        LlmMessage.assistant('', reasoning: '当前轮思考必须完整保留', toolCalls: calls),
        result('first', firstFormat),
        result('second', firstFormat),
        result('different', secondFormat),
      ];
      final before = jsonEncode(
        history.map((message) => message.toJson()).toList(),
      );
      final composed = compactor.compose(
        system: const LlmMessage.system('角色'),
        state: CoachSessionState(),
        catalog: catalog,
        history: history,
      );
      expect(body(composed, 'first')['format'], firstFormat);
      expect(body(composed, 'second')['format'], {'sameAsToolCall': 'first'});
      expect(body(composed, 'different')['format'], secondFormat);
      expect(
        body(composed, 'second')['items'],
        body(history, 'second')['items'],
      );
      expect(body(composed, 'second')['summary'], '完整查询结果');
      expect(
        composed
            .singleWhere((message) => message.role == LlmRole.assistant)
            .reasoning,
        '当前轮思考必须完整保留',
      );
      expect(
        jsonEncode(history.map((message) => message.toJson()).toList()),
        before,
      );
      final referenceIndex = composed.indexWhere(
        (message) => message.toolCallId == 'first',
      );
      final repeatedIndex = composed.indexWhere(
        (message) => message.toolCallId == 'second',
      );
      expect(referenceIndex, lessThan(repeatedIndex));
      final assistant = composed[referenceIndex - 1];
      expect(
        assistant.toolCalls.map((call) => call.id),
        containsAll(['first', 'second', 'different']),
      );
    },
  );

  test(
    'a dictionary archived in an earlier batch is never a reference target',
    () {
      final history = [
        LlmMessage.assistant('', toolCalls: [search('old')]),
        result('old', firstFormat),
        LlmMessage.assistant(
          '',
          toolCalls: [search('new-first'), search('new-second')],
        ),
        result('new-first', firstFormat),
        result('new-second', firstFormat),
      ];
      final composed = compactor.compose(
        system: const LlmMessage.system('角色'),
        state: CoachSessionState(),
        catalog: catalog,
        history: history,
      );
      expect(
        composed.singleWhere((message) => message.toolCallId == 'old').content,
        startsWith('[已归档]'),
      );
      expect(body(composed, 'new-first')['format'], firstFormat);
      expect(body(composed, 'new-second')['format'], {
        'sameAsToolCall': 'new-first',
      });
    },
  );
}
