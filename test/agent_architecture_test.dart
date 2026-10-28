import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmResponse _calls(List<(String, String, Object)> calls) => LlmResponse(
  content: '',
  toolCalls: [
    for (final (id, name, args) in calls)
      LlmToolCall(id: id, name: name, arguments: jsonEncode(args)),
  ],
  model: 'fake',
  finishReason: 'tool_calls',
);

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('smartfit');
  CoachAgent create(FakeLlmClient client) {
    final agent = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      enableUserMemory: false,
      maxRequestRetries: 0,
    );
    addTearDown(agent.dispose);
    return agent;
  }

  test('agent owns no natural-language intent inference or question cap', () {
    for (final file in Directory(
      'lib/src/agent',
    ).listSync().whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final text = file.readAsStringSync();
      for (final forbidden in [
        'TrainingParameters',
        'trainingFocus(',
        'trainingGoal(',
        'hasTrainingRedFlag(',
        'maxQuestionsPerTask',
        'hasPlanWords',
        'explicitlyCreatesPlan',
        'asksFocusTraining',
        'changesCurrent',
      ]) {
        expect(text, isNot(contains(forbidden)), reason: file.path);
      }
      if (file.path.endsWith('coach_agent.dart') ||
          file.path.endsWith('coach_conversation_controller.dart') ||
          file.path.endsWith('training_confirmation.dart')) {
        expect(text, isNot(contains('RegExp(')), reason: file.path);
      }
    }
  });

  test(
    'the model can ask more than one round while retaining its node',
    () async {
      final client = FakeLlmClient([
        _calls([
          ('start', AgentTools.startTask, {'type': 'plan'}),
          ('understand', AgentTools.check, {'node': 'understand'}),
          ('ask0', AgentTools.askUser, {'question': '条件 0？', 'mode': 'text'}),
        ]),
        for (var i = 1; i < 8; i++)
          _calls([
            (
              'ask$i',
              AgentTools.askUser,
              {'question': '条件 $i？', 'mode': 'text'},
            ),
          ]),
      ]);
      final agent = create(client);
      for (var i = 0; i < 8; i++) {
        final result = await agent.send('回答 $i');
        expect(result.status, TurnStatus.ok);
        expect(result.question?.question, '条件 $i？');
        expect(agent.questionsAsked, i + 1);
        expect(agent.sessionState.task?.nodes[1].status, 'current');
      }
    },
  );

  test(
    'an unfinished plan cannot be delivered as prose or refusal prose',
    () async {
      for (final prose in ['这是完整计划：做三组深蹲。', '无法生成这份计划。']) {
        final agent = create(
          FakeLlmClient([
            _calls([
              ('start', AgentTools.startTask, {'type': 'plan'}),
              ('understand', AgentTools.check, {'node': 'understand'}),
            ]),
            prose,
          ]),
        );
        final result = await agent.send('安排计划');
        expect(result.status, TurnStatus.error);
        expect(result.plan, isNull);
        expect(result.text, isEmpty);
        expect(result.issues.map((e) => e.code), contains('missing_plan'));
      }
    },
  );

  test('in-scope question prose needs no task in either language', () async {
    for (final message in ['深蹲膝盖响正常吗', 'Can I stretch at my desk?']) {
      final agent = create(FakeLlmClient(['先观察有无疼痛、肿胀或卡住。']));
      final result = await agent.send(message);
      expect(result.status, TurnStatus.ok);
      expect(result.plan, isNull);
      expect(agent.sessionState.task, isNull);
    }
  });
}
