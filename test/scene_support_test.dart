import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_tags.dart';
import 'package:ugk_coach/src/agent/session_params.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmToolCall tool(String id, String name, Object arguments) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(arguments));
LlmResponse calls(List<LlmToolCall> values) => LlmResponse(
  content: '',
  toolCalls: values,
  finishReason: 'tool_calls',
  model: 'fake',
);
Map<String, Object?> userValue(Object value, String quote) => {
  'value': value,
  'source': 'user',
  'quote': quote,
};

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('smartfit');

  List<String> schemaScenes(CoachProfile profile) {
    final tool = AgentTools.build(
      profile,
      catalog,
      memory: false,
    ).singleWhere((tool) => tool.name == AgentTools.setParams);
    final properties = tool.parameters['properties']! as Map;
    final fields = (properties['fields'] as Map)['properties'] as Map;
    final scene = (fields['scene'] as Map)['properties'] as Map;
    return ((scene['value'] as Map)['enum'] as List).cast<String>();
  }

  test('scene enums are scoped to supported profile and catalogue scenes', () {
    expect(schemaScenes(profile), ['gym', 'home', 'office']);
    expect(schemaScenes(loadProfile('hiplab')), ['home', 'office']);
    expect(schemaScenes(loadProfile('flarelab')), ['gym', 'home']);
    for (final id in ['smartfit', 'hiplab', 'flarelab']) {
      final p = loadProfile(id);
      expect(schemaScenes(p), SessionParams(ActionTags(p, catalog)).sceneCodes);
      expect(schemaScenes(p), isNot(contains('outdoor')));
    }
  });

  test('invalid outdoor is rejected atomically for model and host', () {
    final params = SessionParams(ActionTags(profile, catalog));
    final state = CoachSessionState().appendUserTurn('我想在公园练核心');
    final result = params.set(state, {
      'fields': {
        'scene': userValue('outdoor', '公园'),
        'goal': userValue(['body.core'], '核心'),
      },
    });
    expect(result.error!['code'], 'invalid_value');
    expect(result.state.params, isEmpty);
    expect(state.params, isEmpty);
    final host = params.applyHost(state, const CoachContext(scene: 'outdoor'));
    expect(host.error!['code'], 'invalid_host_context');
    expect(host.state.params, isEmpty);
  });

  test(
    'new profile and catalogue scenes become available without a hardcoded enum',
    () {
      final rawCatalog =
          jsonDecode(jsonEncode(catalog.raw)) as Map<String, dynamic>;
      final drills = rawCatalog['drills'] as List<dynamic>;
      (drills.first as Map<String, dynamic>)['scenes'] = ['outdoor'];
      final nextCatalog = Catalog.fromJson(rawCatalog);
      final rawProfile =
          jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>;
      (rawProfile['scenes'] as Map<String, dynamic>)['outdoor'] = {
        'label': '户外',
        'acceptDrillScenes': ['outdoor'],
      };
      final nextProfile = CoachProfile.fromJson(rawProfile);
      final params = SessionParams(ActionTags(nextProfile, nextCatalog));
      expect(params.sceneCodes, contains('outdoor'));
      final tool = AgentTools.build(
        nextProfile,
        nextCatalog,
        memory: false,
      ).singleWhere((item) => item.name == AgentTools.setParams);
      final fields =
          ((tool.parameters['properties'] as Map)['fields']
                  as Map)['properties']
              as Map;
      final scene =
          ((fields['scene'] as Map)['properties'] as Map)['value'] as Map;
      expect(scene['enum'], contains('outdoor'));
    },
  );

  test(
    'model asks about unsupported outdoor and records the actual home answer',
    () async {
      final client = FakeLlmClient([
        calls([
          tool('start', AgentTools.startTask, {'type': 'recommend'}),
          tool('understand', AgentTools.check, {'node': 'understand'}),
          tool('goal', AgentTools.setParams, {
            'fields': {
              'goal': userValue(['body.core'], '核心'),
            },
          }),
        ]),
        calls([
          tool('ask', AgentTools.askUser, {
            'question': '目前不能提供户外动作，愿意改为居家徒手吗？',
            'mode': 'choice',
            'options': ['居家徒手', '只在户外'],
          }),
        ]),
        calls([
          tool('answer', AgentTools.setParams, {
            'fields': {
              'scene': userValue('home', '居家徒手'),
              'equipment': userValue(<String>[], '居家徒手'),
            },
          }),
          tool('parameters', AgentTools.check, {'node': 'parameters'}),
        ]),
        '好的。',
      ], latency: Duration.zero);
      final coach = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
      );
      addTearDown(coach.dispose);
      final first = await coach.send('我想在公园练核心');
      expect(first.question!.question, contains('不能提供户外'));
      expect(first.question!.options, contains('居家徒手'));
      expect(coach.sessionState.params.containsKey('scene'), isFalse);
      await coach.send('居家徒手');
      final scene = coach.sessionState.params['scene']!;
      final equipment = coach.sessionState.params['equipment']!;
      expect(
        (scene.value, scene.source, scene.quote),
        ('home', 'user', '居家徒手'),
      );
      expect(equipment.value, isEmpty);
      expect((equipment.source, equipment.quote), ('user', '居家徒手'));
      final parameters = coach.sessionState.task!.nodes.singleWhere(
        (n) => n.id == 'parameters',
      );
      expect(parameters.status, 'updated');
      expect(parameters.stamp, contains('居家（你说的）'));
      expect(parameters.stamp, contains('徒手（可用'));
      expect(parameters.stamp, contains('墙'));
      expect(parameters.stamp, contains('（你说的）'));
    },
  );

  test(
    'when user insists on outdoor, model ends without a card or new scene',
    () async {
      final client = FakeLlmClient([
        calls([
          tool('ask', AgentTools.askUser, {
            'question': '目前不能提供户外动作，愿意改为居家徒手吗？',
            'mode': 'choice',
            'options': ['居家徒手', '只在户外'],
          }),
        ]),
        '抱歉，目前无法提供户外动作。',
      ], latency: Duration.zero);
      final coach = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
      );
      addTearDown(coach.dispose);
      expect((await coach.send('我想在公园练核心')).question, isNotNull);
      final second = await coach.send('只在户外');
      expect(second.actions, isNull);
      expect(second.plan, isNull);
      expect(second.text, contains('无法提供户外'));
      expect(coach.sessionState.params.containsKey('scene'), isFalse);
    },
  );
}
