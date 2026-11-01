import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/structured_tool_handler.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

Map<String, Object?> _receipt(StructuredToolResult result) =>
    Map<String, Object?>.from(jsonDecode(result.response) as Map);

List<String> _ids(StructuredToolResult result) => [
  for (final item in _receipt(result)['items']! as List<Object?>)
    (item! as Map)['id']! as String,
];

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('smartfit');
  StructuredToolHandler handler() =>
      StructuredToolHandler(profile, catalog, newPlanId: () => 'cache-plan');
  CoachSessionState initial() => CoachSessionState(
    userTurns: const [CoachUserTurn(turn: 1, text: '在家推荐拉伸')],
    task: CoachTaskState(
      type: 'recommend',
      nodes: [
        for (final id in AgentTask.recommendNodes)
          CoachNodeState(id: id, status: id == 'actions' ? 'current' : 'done'),
      ],
      reused: false,
    ),
    params: {
      'scene': CoachParamValue(value: 'home', source: 'user', turn: 1),
      'limits': CoachParamValue(value: const [], source: 'default', turn: 1),
    },
  );
  StructuredToolResult search(
    StructuredToolHandler tools,
    CoachSessionState state, {
    List<String> tags = const [],
    String keywords = '',
    int limit = 3,
    String language = 'zh',
  }) => tools.search(
    state,
    AgentTools.searchActions,
    jsonEncode({'tags': tags, 'keywords': keywords, 'limit': limit}),
    language,
  );

  test('only consecutive exact searches reuse the real first receipt', () {
    final tools = handler();
    final first = search(tools, initial());
    expect(_receipt(first)['ok'], isTrue);
    expect(_ids(first), isNotEmpty);
    expect(_receipt(first)['cacheHit'], isFalse);
    expect(_receipt(first)['newCount'], _ids(first).length);
    expect(first.fresh, isTrue);

    final second = search(tools, first.state);
    expect(_receipt(second)['cacheHit'], isTrue);
    expect(_receipt(second)['newCount'], 0);
    expect(second.fresh, isFalse);
    expect(_ids(second), _ids(first));
    expect(second.state.seenActionIds, first.state.seenActionIds);
    expect(second.state.pendingSearchIds, first.state.pendingSearchIds);
    expect(second.state.consecutiveEmptySearches, 1);
    expect(second.state.task, same(first.state.task));
    for (final row in _receipt(second)['items']! as List<Object?>) {
      expect((row! as Map).keys.toSet(), {'id', 'doseMode', 'level'});
    }
    final third = search(tools, second.state);
    expect(_receipt(third)['cacheHit'], isTrue);
    expect(third.state.consecutiveEmptySearches, 2);
    expect(_receipt(third)['summary'], contains('candidates'));
    expect(_receipt(third)['summary'], contains('show_actions'));
  });
}
