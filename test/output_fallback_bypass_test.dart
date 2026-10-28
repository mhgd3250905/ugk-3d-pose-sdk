import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmResponse calls(String id, String name, Object arguments) => LlmResponse(
  content: '',
  toolCalls: [
    LlmToolCall(id: id, name: name, arguments: jsonEncode(arguments)),
  ],
  finishReason: 'tool_calls',
  model: 'fake',
);

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('hiplab');
  const context = CoachContext(scene: 'home', equipment: {'mat'}, minutes: 10);
  final plan = TrainingPlan(
    id: 'fallback-plan',
    source: 'ai',
    title: '髋部放松',
    summary: '放松髋部',
    goal: 'relax',
    scene: 'home',
    equipment: const ['mat'],
    level: 1,
    targetMinutes: 10,
    blocks: const [
      PlanBlock(
        id: 'main',
        name: '训练',
        type: BlockType.main,
        items: [
          PlanItem(
            exerciseId: 's-figure4',
            mode: DoseMode.time,
            sets: 1,
            workSeconds: 40,
            perSide: true,
            restSeconds: 10,
          ),
        ],
      ),
    ],
  );

  for (final started in [false, true]) {
    for (final showPlan in [false, true]) {
      final tool = showPlan ? AgentTools.showPlan : AgentTools.showActions;
      test(
        '${started ? 'incomplete task' : 'no task'}: $tool cannot fall back to a plan',
        () async {
          // A fallback preset cannot supply a missing user goal. Computable
          // task nodes no longer reject an otherwise valid delivery.
          expect(
            ToolGate(
              catalog: catalog,
              profile: profile,
            ).admitTemplate(plan, context),
            isNotNull,
          );
          final arguments = showPlan
              ? <String, Object>{'plan_id': 'missing', 'note': '开始训练'}
              : <String, Object>{
                  'ids': ['s-figure4'],
                  'note': '开始训练',
                };
          final client = FakeLlmClient([
            if (started)
              calls('start', AgentTools.startTask, {
                'type': showPlan ? 'plan' : 'recommend',
              }),
            calls('show1', tool, arguments),
            calls('show2', tool, arguments),
          ], latency: Duration.zero);
          var fallbackCalled = false;
          final agent = CoachAgent(
            client: client,
            catalog: () => catalog,
            profile: profile,
            maxResubmits: 1,
            maxRequestRetries: 0,
            enableUserMemory: false,
            fallback: (_) {
              fallbackCalled = true;
              return SessionFallbackReply('预设方案', plan: plan);
            },
          );
          addTearDown(agent.dispose);
          final result = await agent.send('你好', context: context);
          expect(client.requests, hasLength(started ? 3 : 2));
          expect(result.status, TurnStatus.error);
          expect(result.submissions, 2);
          expect(
            result.issues.map((issue) => issue.code),
            contains('missing_parameters'),
          );
          expect(result.plan, isNull);
          expect(result.actions, isNull);
          expect(fallbackCalled, isFalse);
        },
      );
    }
  }

  test('non-training text fallback remains available', () async {
    final client = FakeLlmClient([
      const LlmException(LlmErrorKind.network, 'offline'),
    ], latency: Duration.zero);
    final agent = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      maxRequestRetries: 0,
      enableUserMemory: false,
      fallback: (_) => const SessionFallbackReply('请稍后再试'),
    );
    addTearDown(agent.dispose);
    final result = await agent.send('你好');
    expect(result.status, TurnStatus.fallback);
    expect(result.text, '请稍后再试');
    expect(result.plan, isNull);
    expect(result.actions, isNull);
  });
}
