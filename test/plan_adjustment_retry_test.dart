import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';
import 'support_v2_plan_flow.dart';

// Scripted model tool calls run through a real Agent and local catalog.
void main() {
  const base = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$base/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$base/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();
  final profile = loadProfile('smartfit');
  const duration = PlanDuration();

  CoachConversationController chat(FakeLlmClient client) {
    final controller = CoachConversationController(
      agent: CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
      ),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  for (final sample in [
    ('短一些', 5, 'shorter'),
    ('长一些', 15, 'longer'),
    ('加长一点', 15, 'longer'),
  ]) {
    test(
      'relative wording ${sample.$1} retains the user quote and changes actual duration',
      () async {
        final flow = ScriptedV2PlanFlow(catalog);
        final controller = chat(
          FakeLlmClient([
            ...flow.initial(),
            ...flow.changeMinutes(sample.$2, sample.$1, direction: sample.$3),
          ]),
        );
        final original = await controller.send('在家有瑜伽垫10分钟做髋部放松');
        expect(original!.plan, isNotNull, reason: '${original.issues}');
        final result = await controller.send(sample.$1);
        expect(
          result!.plan,
          isNotNull,
          reason: '${result.issues} ${result.error}',
        );
        final actual = duration.estimateSeconds(result.plan!.plan, catalog);
        final previous = duration.estimateSeconds(original.plan!.plan, catalog);
        expect(
          actual,
          sample.$3 == 'shorter' ? lessThan(previous) : greaterThan(previous),
        );
        expect(result.plan!.plan.targetMinutes, sample.$2);
        expect(
          (actual / 60 - sample.$2).abs() / sample.$2,
          lessThanOrEqualTo(.10),
        );
        final param = controller.agent.sessionState.params['minutes']!;
        expect(param.source, 'derived');
        expect(param.quote, sample.$1);
        expect(param.basedOn!.source, 'user');
        expect(param.basedOn!.value, 10);
        expect(param.basedOn!.quote, '10分钟');
        expect(controller.agent.sessionState.userTurns.last.text, sample.$1);
      },
    );
  }

  for (final badMinutes in [15]) {
    test(
      'opposite proposed shorter duration $badMinutes is normalized without losing its source',
      () async {
        final flow = ScriptedV2PlanFlow(catalog);
        final correction = flow.changeMinutes(5, '短一点', direction: 'shorter');
        final client = FakeLlmClient([
          ...flow.initial(),
          LlmResponse(
            content: '',
            toolCalls: [
              LlmToolCall(
                id: 'invalid-duration',
                name: AgentTools.setParams,
                arguments: jsonEncode({
                  'fields': {
                    'minutes': {
                      'value': badMinutes,
                      'source': 'derived',
                      'quote': '短一点',
                      'direction': 'shorter',
                    },
                  },
                }),
              ),
            ],
            finishReason: 'tool_calls',
          ),
          (LlmRequest request) {
            final result =
                jsonDecode(
                      request.messages
                          .singleWhere(
                            (message) =>
                                message.toolCallId == 'invalid-duration',
                          )
                          .content,
                    )
                    as Map<String, dynamic>;
            expect(result['ok'], isTrue, reason: '$result');
            expect(result['notes'], isNotEmpty);
            return correction.first as LlmResponse;
          },
          ...correction.skip(1),
        ]);
        final controller = chat(client);
        final first = await controller.send('在家有瑜伽垫10分钟做髋部放松');
        expect(first!.plan, isNotNull, reason: '${first.issues}');
        final result = await controller.send('短一点');
        expect(
          result!.plan,
          isNotNull,
          reason: '${result.issues} ${result.error}',
        );
        expect(result.plan!.plan.targetMinutes, 5);
        final minutes = controller.agent.sessionState.params['minutes']!;
        expect(minutes.source, 'derived');
        expect(minutes.quote, '短一点');
        expect(minutes.direction, 'shorter');
        expect(
          controller.agent.sessionState.params['minutes']!.basedOn!.value,
          10,
        );
      },
    );
  }

  test(
    'relative duration rounds proposed 7 to 5 without changing the user quote',
    () async {
      final flow = ScriptedV2PlanFlow(catalog);
      final controller = chat(
        FakeLlmClient([
          ...flow.initial(),
          ...flow.changeMinutes(7, '短一点', direction: 'shorter'),
        ]),
      );
      expect((await controller.send('在家有瑜伽垫10分钟做髋部放松'))!.plan, isNotNull);
      final result = await controller.send('短一点');
      expect(
        result!.plan,
        isNotNull,
        reason: '${result.issues} ${result.error}',
      );
      expect(result.plan!.plan.targetMinutes, 5);
      final minutes = controller.agent.sessionState.params['minutes']!;
      expect(minutes.value, 5);
      expect(minutes.source, 'derived');
      expect(minutes.quote, '短一点');
      expect(minutes.basedOn!.value, 10);
      expect(minutes.basedOn!.quote, '10分钟');
    },
  );

  test('delivered plan summary is also the assistant history', () async {
    final flow = ScriptedV2PlanFlow(catalog);
    final client = FakeLlmClient(flow.initial(modelContent: '这是一套99分钟徒手方案'));
    final controller = chat(client);
    final result = await controller.send('在家有瑜伽垫10分钟做髋部放松');
    expect(result!.plan, isNotNull, reason: '${result.issues} ${result.error}');
    final assistant = controller.agent.history.lastWhere(
      (m) => m.role == LlmRole.assistant,
    );
    expect(assistant.content, result.text);
    expect(assistant.content, isNot(contains('99分钟')));
    expect(assistant.content, '量力而行。');
  });

  test('failed explicit adjustment retries the new duration', () async {
    final flow = ScriptedV2PlanFlow(catalog);
    final client = FakeLlmClient([
      ...flow.initial(),
      const LlmException(LlmErrorKind.network, 'offline'),
      ...flow.changeMinutes(7, '7分钟'),
    ]);
    final controller = chat(client);
    expect((await controller.send('在家有瑜伽垫10分钟做髋部放松'))!.plan, isNotNull);
    final failed = await controller.send('缩短到7分钟');
    expect(failed!.status, TurnStatus.error);
    final result = await controller.send('重试');
    expect(result!.question, isNull);
    expect(result.plan, isNotNull, reason: '${result.issues} ${result.error}');
    expect(result.plan!.plan.targetMinutes, 7);
    expect(controller.agent.sessionState.plans[flow.planId]!.last.version, 2);
    expect(controller.agent.sessionState.params['minutes']!.source, 'user');
    expect(controller.agent.sessionState.params['minutes']!.quote, '7分钟');
    expect(
      (duration.estimateSeconds(result.plan!.plan, catalog) / 60 - 7).abs() / 7,
      lessThanOrEqualTo(.10),
    );
    expect(
      client.requests.any(
        (request) => request.messages.any((m) => m.content.contains('缩短到7分钟')),
      ),
      isTrue,
    );
  });

  test('a later equipment edit keeps the latest relative duration', () async {
    final flow = ScriptedV2PlanFlow(catalog);
    final controller = chat(
      FakeLlmClient([
        ...flow.initial(),
        ...flow.changeMinutes(5, '短一点', direction: 'shorter'),
        ...flow.changeToBodyweight(),
      ]),
    );
    expect((await controller.send('在家有瑜伽垫10分钟做髋部放松'))!.plan, isNotNull);
    expect((await controller.send('短一点'))!.plan, isNotNull);
    final result = await controller.send('换成徒手');
    expect(result!.plan, isNotNull, reason: '${result.issues} ${result.error}');
    expect(result.plan!.plan.targetMinutes, 5);
    expect(result.plan!.plan.equipment, isEmpty);
    expect(
      (duration.estimateSeconds(result.plan!.plan, catalog) / 60 - 5).abs() / 5,
      lessThanOrEqualTo(.10),
    );
    expect(controller.agent.sessionState.params['minutes']!.source, 'derived');
    expect(controller.agent.sessionState.params['minutes']!.quote, '短一点');
  });
}
