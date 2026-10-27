import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmResponse _call(String id, String name, Object args) => LlmResponse(
  content: '',
  toolCalls: [LlmToolCall(id: id, name: name, arguments: jsonEncode(args))],
  finishReason: 'tool_calls',
  model: 'fake',
);

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('hiplab');
  const expected = {
    'type': 'object',
    'properties': {
      'plan_id': {'type': 'string'},
    },
    'required': ['plan_id'],
    'additionalProperties': false,
  };

  for (final id in ['smartfit', 'hiplab', 'flarelab']) {
    test('$id exposes check_plan using only plan_id', () {
      final tools = AgentTools.build(loadProfile(id), catalog, memory: false);
      expect(
        tools.singleWhere((t) => t.name == AgentTools.checkPlan).parameters,
        expected,
      );
    });
  }

  test(
    'agent offers check_plan in successive requests and rejects model equipment',
    () async {
      final client = FakeLlmClient([
        _call('read', 'read', {'path': 'plan-training/SKILL.md'}),
        _call('bad', 'check_plan', {
          'plan_id': 'missing',
          'equipment': ['mat'],
        }),
        '暂时无法核对该计划。',
      ], latency: Duration.zero);
      final coach = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
      );
      addTearDown(coach.dispose);
      await coach.send('检查计划');
      expect(client.requests, hasLength(3));
      for (final request in client.requests) {
        expect(
          request.tools
              .singleWhere((tool) => tool.name == AgentTools.checkPlan)
              .parameters,
          expected,
        );
      }
      final message = client.requests.last.messages.singleWhere(
        (m) => m.toolCallId == 'bad',
      );
      final response = jsonDecode(message.content) as Map<String, dynamic>;
      expect(response['ok'], isFalse);
      expect(response['code'], 'invalid_arguments');
    },
  );

  test('legacy CoachSession retains its original CoachTools payload', () async {
    final action = profile.scope(catalog).first;
    final client = FakeLlmClient([
      LlmResponse(
        content: '看看这个动作。',
        toolCalls: [
          LlmToolCall(
            id: 'legacy',
            name: 'show_actions',
            arguments: jsonEncode({
              'items': [
                {'actionId': action.id},
              ],
            }),
          ),
        ],
        finishReason: 'tool_calls',
        model: 'fake',
      ),
    ], latency: Duration.zero);
    final session = CoachSession(
      client: client,
      catalog: () => catalog,
      profile: profile,
    );
    final reply = await session.send('看看动作');
    expect(reply.status, TurnStatus.ok);
    expect(reply.actions, isNotNull);
    expect(
      client.requests.single.tools.map((t) => t.toJson()),
      CoachTools.build(profile, catalog).map((t) => t.toJson()),
    );
    expect(client.requests.single.tools.map((t) => t.name), [
      'show_actions',
      'show_plan',
    ]);
  });
}
