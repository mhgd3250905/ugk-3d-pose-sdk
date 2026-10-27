import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmResponse tool(String name, Object args) => LlmResponse(
  content: '',
  toolCalls: [LlmToolCall(id: 'call', name: name, arguments: jsonEncode(args))],
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
    );
    addTearDown(instance.dispose);
    return instance;
  }

  bool hasCheck(LlmRequest request) =>
      request.tools.any((tool) => tool.name == AgentTools.checkPlan);

  test(
    'ordinary planning offers direct submission without optional self-check',
    () async {
      final client = FakeLlmClient([
        (LlmRequest request) {
          expect(hasCheck(request), isFalse);
          expect(
            request.tools.map((tool) => tool.name),
            contains(AgentTools.showPlan),
          );
          return tool(AgentTools.showPlan, planOf(okEnvelope()));
        },
      ]);
      final result = await agent(client).send(
        '在家有瑜伽垫十分钟做开胯计划',
        context: const CoachContext(
          scene: 'home',
          equipment: {'mat'},
          minutes: 10,
          level: 1,
        ),
      );
      expect(result.status, TurnStatus.ok);
      expect(result.plan, isNotNull);
      expect(result.steps, 1);
    },
  );

  test(
    'a rejected submission unlocks self-check while the final gate remains enforced',
    () async {
      final client = FakeLlmClient([
        (LlmRequest request) {
          expect(hasCheck(request), isFalse);
          return tool(AgentTools.showActions, {
            'items': [
              {'actionId': 'invented-id'},
            ],
          });
        },
        (LlmRequest request) {
          expect(hasCheck(request), isTrue);
          expect(request.messages.last.content, contains('unknown_exercise'));
          return tool(AgentTools.checkPlan, planOf(okEnvelope()));
        },
        (LlmRequest request) {
          expect(hasCheck(request), isTrue);
          final checked =
              jsonDecode(request.messages.last.content) as Map<String, dynamic>;
          expect(checked['ok'], isTrue);
          return tool(AgentTools.showPlan, planOf(okEnvelope()));
        },
      ]);
      final result = await agent(client).send(
        '在家有瑜伽垫十分钟做计划',
        context: const CoachContext(
          scene: 'home',
          equipment: {'mat'},
          minutes: 10,
          level: 1,
        ),
      );
      expect(result.status, TurnStatus.ok);
      expect(result.records.first.issueCodes, contains('unknown_exercise'));
      expect(result.steps, 3);
      expect(result.plan, isNotNull);
    },
  );

  test('an ordinary read does not unlock self-check', () async {
    final client = FakeLlmClient([
      tool(AgentTools.read, {'path': 'plan-training/SKILL.md'}),
      (LlmRequest request) {
        expect(hasCheck(request), isFalse);
        return '无法提供方案。';
      },
    ]);
    expect((await agent(client).send('在家有瑜伽垫十分钟排个计划')).status, TurnStatus.ok);
    expect(client.requests, hasLength(2));
  });

  test(
    'explicit plan checks and App-specific skills retain initial check_plan',
    () async {
      for (final prompt in ['先检查这个计划', 'Please review my plan', '校验一下这个计划']) {
        final client = FakeLlmClient([
          (LlmRequest request) {
            expect(hasCheck(request), isTrue);
            return '无法检查，请把计划发来。';
          },
        ]);
        expect(
          (await agent(client).send('在家有瑜伽垫十分钟，$prompt')).status,
          TurnStatus.ok,
        );
        expect(client.requests, hasLength(1));
      }
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
        (LlmRequest request) {
          expect(hasCheck(request), isTrue);
          return '无法提供，按 App 专属流程执行。';
        },
      ]);
      expect(
        (await agent(client, custom: custom).send('在家有瑜伽垫十分钟安排训练')).status,
        TurnStatus.ok,
      );
      expect(client.requests, hasLength(1));
    },
  );
}
