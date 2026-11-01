import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_search.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/structured_tool_handler.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmToolCall _call(String id, String name, Object arguments) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(arguments));

LlmResponse _calls(List<LlmToolCall> tools) =>
    LlmResponse(content: '', toolCalls: tools, finishReason: 'tool_calls');

Map<String, Object?> _receipt(LlmRequest request, String id) =>
    Map<String, Object?>.from(
      jsonDecode(request.messages.lastWhere((m) => m.toolCallId == id).content)
          as Map,
    );

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('smartfit');

  test(
    'batch queries keep successful searches and expose required replacements',
    () {
      final schema = AgentTools.build(
        profile,
        catalog,
        memory: false,
        scopeEnabled: true,
      ).singleWhere((tool) => tool.name == AgentTools.searchActions).parameters;
      expect(schema['anyOf'], [
        {
          'required': ['tags'],
        },
        {
          'required': ['queries'],
        },
      ]);
      final properties = schema['properties']! as Map;
      final queriesSchema = properties['queries']! as Map;
      final querySchema = queriesSchema['items']! as Map;
      expect(queriesSchema['minItems'], 1);
      expect(querySchema['required'], ['tags']);
      expect((querySchema['properties']! as Map)['tags'], properties['tags']);
      var state = CoachSessionState().appendUserTurn('在家推荐拉伸');
      final search = ActionSearch(
        profile,
        catalog,
        minPicks: profile.minActions,
      );
      final first = search.search(state, tags: ['purpose.stretch'], limit: 1);
      final last = search.search(
        first.state,
        tags: ['purpose.mobility'],
        limit: 2,
      );
      expect(first.items, isNotEmpty);
      expect(last.items, isNotEmpty);
      final expected = <String>{
        for (final row in [...first.items, ...last.items]) row['id']! as String,
      };
      final nodes = NodeGates(profile, catalog, minPicks: profile.minActions);
      final required = catalog.ids.firstWhere(
        (id) =>
            !expected.contains(id) && nodes.actionProblem(state, id) == null,
      );
      state = state.copyWith(hostValues: {'adopted': required});
      final handler = StructuredToolHandler(
        profile,
        catalog,
        newPlanId: () => 'unused',
        requiredActionIds: (current) => {
          current.hostValues['adopted']! as String,
        },
      );
      final result = handler.search(
        state,
        AgentTools.searchActions,
        jsonEncode({
          'queries': [
            {
              'tags': ['purpose.stretch'],
              'limit': 1,
            },
            {
              'tags': ['unknown.tag'],
            },
            {
              'tags': ['purpose.mobility'],
              'limit': 2,
            },
          ],
        }),
        'zh',
      );
      final receipt = jsonDecode(result.response) as Map;
      final queries = (receipt['queries'] as List).cast<Map<String, Object?>>();
      expect(receipt['ok'], isTrue);
      expect(receipt['partial'], isTrue);
      expect(queries.map((query) => query['ok']), [true, false, true]);
      expect(queries[1]['code'], 'invalid_tags');
      expect(
        (receipt['items'] as List).cast<Map<String, Object?>>().map(
          (item) => item['id'],
        ),
        expected.toList(),
      );
      expect(result.state.seenActionIds, expected);
      expect(result.state.pendingSearchIds, expected);
      expect(receipt['requiredActionIds'], [required]);
      expect(receipt['requiredActionsNotice'], contains('必须采用'));
      expect(result.state.seenActionIds, isNot(contains(required)));
      expect(result.state.plans, isEmpty);
    },
  );

  test(
    'parallel search tools keep valid results after one query fails',
    () async {
      late List<String> returned;
      final client = FakeLlmClient([
        _calls([
          _call('start', AgentTools.startTask, {'type': 'recommend'}),
          _call('params', AgentTools.setParams, {
            'fields': {
              'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
              'goal': {
                'value': ['purpose.stretch'],
                'source': 'user',
                'quote': '拉伸',
              },
            },
          }),
          _call('invalid-query', AgentTools.searchActions, {
            'tags': ['unknown.tag'],
          }),
          _call('valid-query', AgentTools.searchActions, {
            'tags': ['purpose.stretch'],
            'limit': 3,
          }),
        ]),
        (LlmRequest request) {
          expect(_receipt(request, 'invalid-query')['code'], 'invalid_tags');
          final good = _receipt(request, 'valid-query');
          expect(good['ok'], isTrue);
          returned = [
            for (final row in good['items']! as List)
              (row as Map)['id']! as String,
          ];
          expect(returned, isNotEmpty);
          return _calls([
            _call('show', AgentTools.showActions, {
              'ids': returned,
              'note': '量力而行。',
            }),
          ]);
        },
      ], latency: Duration.zero);
      final agent = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
      );
      addTearDown(agent.dispose);
      final result = await agent.send('在家推荐拉伸');
      expect(
        result.status,
        TurnStatus.ok,
        reason: '${result.issues} ${result.error}',
      );
      expect(result.actions, isNotNull);
      expect(result.actions!.items, isNotEmpty);
      expect(result.actions!.items.map((item) => item.id), returned);
      expect(agent.sessionState.seenActionIds, returned.toSet());
      expect(client.requests, hasLength(2));
      expect(result.records.first.issueCodes, contains('invalid_tags'));
    },
  );
}
