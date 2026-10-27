import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmResponse tool(String id, String name, Object args) => LlmResponse(
  content: '',
  toolCalls: [LlmToolCall(id: id, name: name, arguments: jsonEncode(args))],
  finishReason: 'tool_calls',
  model: 'fake',
);

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('hiplab');
  CoachAgent agent(FakeLlmClient client, {CoachProfile? custom}) {
    final instance = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: custom ?? profile,
      enableUserMemory: false,
      maxRequestRetries: 0,
    );
    addTearDown(instance.dispose);
    return instance;
  }

  bool hasCheck(LlmRequest request) =>
      request.tools.any((entry) => entry.name == AgentTools.checkPlan);
  Map<String, dynamic> feedback(LlmRequest request, String id) =>
      jsonDecode(
            request.messages.singleWhere((m) => m.toolCallId == id).content,
          )
          as Map<String, dynamic>;

  test(
    'check_plan is available for different messages without intent matching',
    () async {
      for (final prompt in [
        '在家有瑜伽垫十分钟做开胯计划',
        '先检查这个计划',
        'Please review my plan',
        '深蹲膝盖响正常吗',
      ]) {
        final client = FakeLlmClient([
          tool('ask', AgentTools.askUser, {
            'question': '请问还有什么要求？',
            'mode': 'text',
          }),
        ], latency: Duration.zero);
        expect((await agent(client).send(prompt)).status, TurnStatus.ok);
        expect(client.requests, hasLength(1));
        expect(hasCheck(client.requests.single), isTrue, reason: prompt);
      }
    },
  );

  test(
    'check_plan remains available after a read and rejects missing or extra fields',
    () async {
      final client = FakeLlmClient([
        tool('read', AgentTools.read, {'path': 'plan-training/SKILL.md'}),
        tool('missing', AgentTools.checkPlan, {}),
        tool('extra', AgentTools.checkPlan, {
          'plan_id': 'p',
          'equipment': ['mat'],
        }),
        tool('ask', AgentTools.askUser, {
          'question': '请问还有什么要求？',
          'mode': 'text',
        }),
      ], latency: Duration.zero);
      final result = await agent(client).send('在家有瑜伽垫十分钟排个计划');
      expect(result.status, TurnStatus.ok);
      expect(client.requests, hasLength(4));
      expect(client.requests.every(hasCheck), isTrue);
      expect(
        feedback(client.requests[2], 'missing')['code'],
        'invalid_arguments',
      );
      expect(
        feedback(client.requests[3], 'extra')['code'],
        'invalid_arguments',
      );
    },
  );

  test(
    'rejected unknown action stays rejected and check_plan remains available',
    () async {
      final client = FakeLlmClient([
        tool('bad', AgentTools.showActions, {
          'ids': ['invented-id'],
          'note': '请看动作。',
        }),
        tool('check', AgentTools.checkPlan, {'plan_id': 'missing'}),
        '目录里没有这个动作。',
      ], latency: Duration.zero);
      final result = await agent(client).send('展示动作');
      expect(result.status, TurnStatus.ok);
      expect(result.actions, isNull);
      expect(client.requests.every(hasCheck), isTrue);
      expect(result.records.first.issueCodes, contains('wrong_task_type'));
      expect(feedback(client.requests[2], 'check')['ok'], isFalse);
    },
  );

  test('App-specific skills retain the same check_plan availability', () async {
    final custom = CoachProfile.fromJson({
      ...profile.toJson(),
      'skills': [
        {
          'name': 'app-routine',
          'description': 'App-specific routine',
          'content': 'Use check_plan before delivery.',
        },
      ],
    });
    final client = FakeLlmClient([
      '无法提供，按 App 专属流程执行。',
    ], latency: Duration.zero);
    expect(
      (await agent(client, custom: custom).send('在家有瑜伽垫十分钟安排训练')).status,
      TurnStatus.ok,
    );
    expect(hasCheck(client.requests.single), isTrue);
  });
}
