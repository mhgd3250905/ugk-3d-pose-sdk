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

  test('different query sets, order, limit or language are never merged', () {
    for (final query in [
      (tags: <String>['purpose.stretch'], limit: 3, language: 'zh'),
      (tags: <String>[], limit: 4, language: 'zh'),
      (tags: <String>[], limit: 3, language: 'en'),
    ]) {
      final tools = handler();
      final first = search(tools, initial());
      final second = search(
        tools,
        first.state,
        tags: query.tags,
        limit: query.limit,
        language: query.language,
      );
      expect(_receipt(second)['ok'], isTrue);
      expect(_receipt(second)['cacheHit'], isFalse);
    }
    final tools = handler();
    final first = search(
      tools,
      initial(),
      tags: ['purpose.stretch', 'body.inner_thigh'],
    );
    final second = search(
      tools,
      first.state,
      tags: ['body.inner_thigh', 'purpose.stretch'],
    );
    expect(_receipt(second)['ok'], isTrue);
    expect(_receipt(second)['cacheHit'], isFalse);
    final third = search(tools, second.state, keywords: '蝴蝶');
    expect(_receipt(third)['ok'], isTrue);
    expect(_receipt(third)['cacheHit'], isFalse);
  });

  test('new task object, new user turn or new scope breaks reuse', () {
    for (final change in <CoachSessionState Function(CoachSessionState)>[
      (state) => state.copyWith(task: state.task!.copyWith()),
      (state) => state.appendUserTurn('同样要求'),
      (state) => state.copyWith(actionScopeIdentity: 'scope-v2'),
      (state) => state.copyWith(scopeAssessmentTurn: 2),
      (state) => state.copyWith(
        scopeDecisionRecords: [
          {'kind': 'substitute', 'adoptedId': 's-butterfly'},
        ],
      ),
    ]) {
      final tools = handler();
      final first = search(tools, initial());
      expect(_ids(first), isNotEmpty);
      final second = search(tools, change(first.state));
      expect(_receipt(second)['ok'], isTrue);
      expect(_receipt(second)['cacheHit'], isFalse);
    }
  });

  test(
    'admission and opaque safety metadata changes recheck current rules',
    () {
      final tools = handler();
      final first = search(tools, initial(), tags: ['pose.kneeling']);
      expect(_receipt(first)['ok'], isTrue);
      expect(_ids(first), isNotEmpty);
      final changed = first.state.copyWith(
        params: {
          ...first.state.params,
          'scene': CoachParamValue(value: 'office', source: 'user', turn: 1),
        },
      );
      final second = search(tools, changed, tags: ['pose.kneeling']);
      expect(_receipt(second)['ok'], isTrue);
      expect(_receipt(second)['cacheHit'], isFalse);
      expect(_ids(second), isEmpty);

      final third = search(
        tools,
        second.state.copyWith(
          hostValues: {
            'limitsOpaque': ['未知伤痛'],
          },
        ),
        tags: ['pose.kneeling'],
      );
      expect(_receipt(third)['ok'], isTrue);
      expect(_receipt(third)['cacheHit'], isFalse);
      expect(_receipt(third)['warnings'], isNotEmpty);
    },
  );

  test('every nonsearch tool boundary invalidates consecutive reuse', () {
    for (final tool in [
      AgentTools.read,
      AgentTools.getAction,
      AgentTools.check,
      AgentTools.checkPlan,
      AgentTools.setParams,
      AgentTools.showActions,
      'remember',
    ]) {
      final tools = handler();
      final first = search(tools, initial());
      tools.beginTool(tool);
      final second = search(tools, first.state);
      expect(_receipt(second)['cacheHit'], isFalse, reason: tool);
    }
  });

  test('get_action does not preserve a previous search cache', () {
    final tools = handler();
    final first = search(tools, initial());
    expect(_ids(first), isNotEmpty);
    final detail = tools.search(
      first.state,
      AgentTools.getAction,
      jsonEncode({
        'ids': [_ids(first).first],
      }),
      'zh',
    );
    expect(_receipt(detail)['ok'], isTrue);
    final second = search(tools, detail.state);
    expect(_receipt(second)['cacheHit'], isFalse);
  });

  test('removed seen IDs require a real search before they can return', () {
    final tools = handler();
    final first = search(tools, initial());
    expect(_ids(first), isNotEmpty);
    final second = search(tools, first.state.copyWith(seenActionIds: const {}));
    expect(_receipt(second)['cacheHit'], isFalse);
    expect(_receipt(second)['newCount'], _ids(second).length);
    expect(_receipt(second)['newCount'], greaterThan(0));
    expect(second.fresh, isTrue);
  });

  test(
    'a cache hit retains the current ledger instead of restoring old state',
    () {
      final tools = handler();
      final first = search(tools, initial());
      expect(_ids(first), isNotEmpty);
      final version = CoachPlanVersion(
        version: 1,
        plan: {'id': 'retained-plan', 'title': '已有计划'},
        estimateSec: 30,
        fitLog: const [],
      );
      final changed = first.state.copyWith(
        plans: {
          'retained-plan': [version],
        },
        picks: [_ids(first).last],
        emittedWarningCodes: {'current-warning'},
        savedRef: const CoachSavedPlanRef(
          externalId: 'host-plan',
          baseVersion: 7,
        ),
        completedContextLedger: {'current-proof': true},
      );
      final second = search(tools, changed);
      expect(_receipt(second)['cacheHit'], isTrue);
      expect(second.state.plans['retained-plan']!.single, same(version));
      expect(second.state.picks, changed.picks);
      expect(second.state.emittedWarningCodes, changed.emittedWarningCodes);
      expect(second.state.savedRef, changed.savedRef);
      expect(
        second.state.completedContextLedger,
        changed.completedContextLedger,
      );
    },
  );

  test(
    'invalid argument or failed search breaks successful-search continuity',
    () {
      for (final arguments in [
        '{',
        jsonEncode({
          'tags': [3],
        }),
        jsonEncode({
          'tags': ['not.a.tag'],
        }),
      ]) {
        final tools = handler();
        final first = search(tools, initial());
        final invalid = tools.search(
          first.state,
          AgentTools.searchActions,
          arguments,
          'zh',
        );
        expect(_receipt(invalid)['ok'], isFalse);
        expect(invalid.state.seenActionIds, first.state.seenActionIds);
        final second = search(tools, invalid.state);
        expect(_receipt(second)['cacheHit'], isFalse);
      }
    },
  );

  test('new HTTP handler never reuses a previous batch receipt', () {
    final first = search(handler(), initial());
    expect(_ids(first), isNotEmpty);
    final second = search(handler(), first.state);
    expect(_receipt(second)['cacheHit'], isFalse);
    expect(_receipt(second)['newCount'], 0);
  });

  test(
    'nonfinite host metadata disables only reuse and does not reject search',
    () {
      final tools = handler();
      final first = search(
        tools,
        initial().copyWith(hostValues: {'opaque': double.nan}),
      );
      expect(_receipt(first)['ok'], isTrue);
      expect(_ids(first), isNotEmpty);
      final second = search(tools, first.state);
      expect(_receipt(second)['ok'], isTrue);
      expect(_receipt(second)['cacheHit'], isFalse);
    },
  );

  test(
    'agent pairs every search receipt and a skill read ends reuse',
    () async {
      LlmToolCall call(String id, String name, Object args) =>
          LlmToolCall(id: id, name: name, arguments: jsonEncode(args));
      final query = {'tags': <String>[], 'limit': 3};
      final client = FakeLlmClient([
        LlmResponse(
          content: '',
          finishReason: 'tool_calls',
          toolCalls: [
            call('start', AgentTools.startTask, {'type': 'recommend'}),
            call('search-1', AgentTools.searchActions, query),
            call('search-2', AgentTools.searchActions, query),
            call('skill-read', AgentTools.read, {
              'path': 'action-library/SKILL.md',
            }),
            call('search-3', AgentTools.searchActions, query),
          ],
        ),
        LlmResponse(
          content: '',
          finishReason: 'tool_calls',
          toolCalls: [
            call('ask', AgentTools.askUser, {
              'question': '还要继续吗？',
              'mode': 'text',
            }),
          ],
        ),
      ], latency: Duration.zero);
      final agent = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
      );
      addTearDown(agent.dispose);
      final turn = await agent.send('在家推荐拉伸');
      expect(turn.question, isNotNull);
      expect(client.requests, hasLength(2));
      final tools = {
        for (final message in client.requests[1].messages)
          if (message.role == LlmRole.tool)
            message.toolCallId!: message.content,
      };
      expect(tools.keys.toSet(), {
        'start',
        'search-1',
        'search-2',
        'skill-read',
        'search-3',
      });
      Map<String, Object?> receipt(String id) =>
          Map<String, Object?>.from(jsonDecode(tools[id]!) as Map);
      expect(receipt('search-1')['items'], isNotEmpty);
      expect(receipt('search-1')['cacheHit'], isFalse);
      expect(receipt('search-2')['cacheHit'], isTrue);
      expect(receipt('search-2')['newCount'], 0);
      expect(receipt('search-3')['cacheHit'], isFalse);
      expect(agent.sessionState.seenActionIds, {
        for (final item in receipt('search-1')['items']! as List)
          (item as Map)['id'],
      });
    },
  );
}
