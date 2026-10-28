import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_tags.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/session_params.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void _expectSceneCueGuidance(String text) {
  expect(text, contains('derived'));
  expect(text, contains('quote'));
  expect(text, contains('地点/情境'));
  for (final cue in ['坐了很久', '在工位上', '刚起床']) {
    expect(text, contains(cue));
  }
  expect(text, contains('不能引用整句'));
  expect(text, contains('动作/部位'));
  expect(text, contains('user/host/preselect'));
  expect(text, contains('ask_user'));
  expect(text, contains('preselect'));
  expect(text, contains('沿用上次'));
}

void main() {
  final profile = loadProfile('smartfit');
  final catalog = loadCatalog();

  test(
    'scene cue and memory provenance guidance appear in the first request',
    () async {
      final client = FakeLlmClient([const LlmResponse(content: '你想在哪里练？')]);
      final agent = CoachAgent(
        client: client,
        catalog: loadCatalog,
        profile: profile,
      );
      addTearDown(agent.dispose);

      await agent.send('拉伸一下臀部');

      final first = client.requests.single;
      expect(first.messages.first.role, LlmRole.system);
      _expectSceneCueGuidance(first.messages.first.content);
      final setParams = first.tools.singleWhere(
        (tool) => tool.name == AgentTools.setParams,
      );
      _expectSceneCueGuidance(
        jsonEncode({
          'description': setParams.description,
          'parameters': setParams.parameters,
        }),
      );
      expect(
        first.messages.where((message) => message.role == LlmRole.tool),
        isEmpty,
      );
    },
  );

  test('ask skill uses the same scene cue and habit provenance guidance', () {
    final files = SkillFiles.build(profile, catalog);
    _expectSceneCueGuidance(files.read('ask/SKILL.md')!);
  });

  for (final language in ['zh', 'en']) {
    test(
      'habit and inferred scenes have distinct $language parameter stamps',
      () {
        final params = SessionParams(ActionTags(profile, catalog));
        final initial = CoachSessionState().appendUserTurn('刚起床，想拉伸一下');
        final remembered = params.set(
          initial,
          {
            'fields': {
              'scene': {'value': 'home', 'source': 'preselect'},
            },
          },
          memory: [
            MemoryEntry(
              MemoryKind.scene,
              'home',
              at: DateTime.utc(2026, 10, 28),
            ),
          ],
        );
        final inferred = params.set(initial, {
          'fields': {
            'scene': {'value': 'home', 'source': 'derived', 'quote': '刚起床'},
          },
        });
        expect(remembered.ok, isTrue, reason: '${remembered.error}');
        expect(inferred.ok, isTrue, reason: '${inferred.error}');

        String stamp(CoachSessionState state) {
          final ready = AgentTask.start(
            state.copyWith(
              params: {
                ...state.params,
                'goal': CoachParamValue(
                  value: ['purpose.stretch'],
                  source: 'default',
                  turn: 1,
                ),
              },
            ),
            'recommend',
          ).state;
          final result = NodeGates(
            profile,
            catalog,
            minPicks: 3,
          ).check(ready, 'parameters', language: language);
          expect(result.ok, isTrue, reason: '${result.error}');
          return result.state.task!.nodes
              .singleWhere((node) => node.id == 'parameters')
              .stamp!;
        }

        final rememberedStamp = stamp(remembered.state);
        final inferredStamp = stamp(inferred.state);
        expect(
          rememberedStamp,
          contains(language == 'en' ? 'previous habit' : '沿用上次'),
        );
        expect(inferredStamp, contains(language == 'en' ? 'inferred' : '推测'));
        expect(
          rememberedStamp,
          isNot(contains(language == 'en' ? 'inferred' : '推测')),
        );
        expect(
          inferredStamp,
          isNot(contains(language == 'en' ? 'previous habit' : '沿用上次')),
        );
        expect(remembered.state.params['scene']!.source, 'preselect');
        expect(inferred.state.params['scene']!.source, 'derived');
        expect(inferred.state.params['scene']!.quote, '刚起床');
      },
    );
  }
}
