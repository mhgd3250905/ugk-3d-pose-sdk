import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/batch_handler.dart';
import 'package:ugk_coach/src/llm/llm_types.dart';

LlmToolCall _call(String id, String name, Object arguments) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(arguments));

void main() {
  final start = _call('start', 'start_task', {'type': 'plan'});
  final parameters = _call('params', 'set_params', {
    'fields': {
      'minutes': {'value': 5, 'source': 'user', 'quote': '5分钟'},
    },
  });
  final search = _call('search', 'search_actions', {
    'tags': ['purpose.stretch'],
    'limit': 20,
  });
  final draft = _call('draft', 'draft_plan', {
    'blocks': [
      {
        'kind': 'main',
        'items': [
          {'id': 's-butterfly'},
        ],
      },
    ],
  });
  List<String> ids(Iterable<LlmToolCall> values) =>
      values.map((call) => call.id).toList();

  test('typed chain is start, parameters, original searches, then draft', () {
    final original = [draft, search, parameters, start];
    final ordered = ToolBatch.orderedCalls(original);
    expect(ids(ordered), ['start', 'params', 'search', 'draft']);
    expect(ids(original), ['draft', 'search', 'params', 'start']);
    expect(
      {for (final call in ordered) call.id: call.arguments},
      {for (final call in original) call.id: call.arguments},
      reason: 'normalization cannot rewrite IDs, user quotes or query data',
    );
  });
}
