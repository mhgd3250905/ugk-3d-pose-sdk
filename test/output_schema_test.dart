import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();
  const actions = {
    'type': 'object',
    'properties': {
      'ids': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'note': {'type': 'string', 'minLength': 1, 'description': '最多120字'},
    },
    'required': ['ids', 'note'],
    'additionalProperties': false,
  };
  const plan = {
    'type': 'object',
    'properties': {
      'plan_id': {'type': 'string'},
      'note': {'type': 'string', 'minLength': 1, 'description': '最多120字'},
    },
    'required': ['plan_id', 'note'],
    'additionalProperties': false,
  };

  for (final name in ['smartfit', 'hiplab', 'flarelab']) {
    test('$name agent output schemas expose only the required fields', () {
      final tools = AgentTools.build(loadProfile(name), catalog, memory: false);
      final actionTool = tools.singleWhere(
        (t) => t.name == AgentTools.showActions,
      );
      final planTool = tools.singleWhere((t) => t.name == AgentTools.showPlan);
      expect(actionTool.parameters, actions);
      expect(planTool.parameters, plan);
      final wire = jsonEncode([actionTool.toJson(), planTool.toJson()]);
      for (final drill in catalog.drills) {
        expect(wire, isNot(contains(drill.id)));
      }
    });

    test('$name legacy CoachTools schemas still match golden', () {
      final golden = jsonDecode(
        File('test/fixtures/golden/$name.tools.json').readAsStringSync(),
      );
      final built = CoachTools.build(loadProfile(name), catalog);
      expect(
        jsonDecode(jsonEncode([for (final tool in built) tool.toJson()])),
        golden,
      );
    });
  }

  test(
    'English output notes advertise word limits without rejecting long input at schema level',
    () {
      final tools = AgentTools.build(
        loadProfile('smartfit'),
        catalog,
        memory: false,
        language: 'en',
      );
      for (final name in [AgentTools.showActions, AgentTools.showPlan]) {
        final tool = tools.singleWhere((tool) => tool.name == name);
        final note = (tool.parameters['properties'] as Map)['note'] as Map;
        expect(note, {
          'type': 'string',
          'minLength': 1,
          'description': 'At most 2 sentences and 45 words',
        });
        expect(note.containsKey('maxLength'), isFalse);
      }
    },
  );

  test(
    'legacy CoachSession sends the old CoachTools schema and accepts its action payload',
    () async {
      final profile = loadProfile('hiplab');
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
    },
  );
}
