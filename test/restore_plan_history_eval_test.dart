import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';
import 'support_v2_plan_flow.dart';

// Scripted model responses exercise the real controller, agent and catalog.
// They are not a real-model or native-device evaluation.
var _seq = 0;
LlmResponse _tool(String name, Object arguments) => LlmResponse(
  content: '',
  toolCalls: [
    LlmToolCall(
      id: 'restore-tool-${_seq++}',
      name: name,
      arguments: jsonEncode(arguments),
    ),
  ],
  finishReason: 'tool_calls',
  model: 'fake',
);
void main() {
  const base = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final app = PoseHubAppTestCatalog.fromBytes(
    File('$base/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$base/catalog/catalog.json').readAsBytesSync(),
  );
  final catalog = app.toAiCatalog();
  final profile = loadProfile('smartfit');
  final duration = const PlanDuration();
  CoachConversationController controller(FakeLlmClient client) {
    final c = CoachConversationController(
      agent: CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
      ),
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<List<CoachConversationMessage>> history() async {
    final flow = ScriptedV2PlanFlow(catalog);
    final c = controller(FakeLlmClient(flow.initial()));
    final result = await c.send('在家有瑜伽垫，10分钟做髋部放松');
    expect(result!.plan, isNotNull, reason: '${result.issues} ${result.error}');
    return c.state.messages;
  }

  List<CoachConversationMessage> legacy(
    List<CoachConversationMessage> messages,
  ) => [
    for (final message in messages)
      CoachConversationMessage(
        id: message.id,
        at: message.at,
        isUser: message.isUser,
        text: message.text,
        plan: message.plan,
        question: message.question,
        questionAnswered: message.questionAnswered,
        answeredChoices: message.answeredChoices,
        answeredForm: message.answeredForm,
        actions: message.actions,
      ),
  ];

  test(
    'legacy card and snapshot restore explicit conditions into sourced v2 ledger',
    () async {
      final originalFlow = ScriptedV2PlanFlow(catalog);
      final original = controller(
        FakeLlmClient(originalFlow.initial(), latency: Duration.zero),
      );
      final delivered = await original.send('在家有瑜伽垫10分钟做髋部放松');
      expect(
        delivered!.plan,
        isNotNull,
        reason: '${delivered.issues} ${delivered.error}',
      );
      final card = delivered.plan!;
      final legacyMessages = legacy(original.state.messages);

      final fromCard = controller(FakeLlmClient([], latency: Duration.zero))
        ..restoreHistory(legacyMessages);
      final restored = fromCard.agent.sessionState.params;
      expect(restored['scene']!.value, 'home');
      expect(restored['scene']!.source, 'host');
      expect(restored['equipment']!.value, ['equip.mat']);
      expect(restored['equipment']!.source, 'host');
      expect(restored['minutes']!.value, 10);
      expect(restored['minutes']!.source, 'host');
      expect(restored['goal'], isNull, reason: '旧卡不包含可校验的新结构化目标');
      expect(fromCard.agent.sessionState.userTurns.map((turn) => turn.text), [
        '在家有瑜伽垫10分钟做髋部放松',
      ]);
      expect(fromCard.agent.sessionState.task, isNull);
      expect(fromCard.agent.sessionState.lastDeliveredPlanId, card.plan.id);
      expect(fromCard.agent.sessionState.lastDeliveredVersion, 1);

      final snapshot = CoachPlanState(
        planId: card.plan.id,
        context: const CoachContext(
          scene: 'home',
          equipment: {'mat', 'chair'},
          minutes: 10,
          avoid: {'wrist'},
          notes: ['保护手腕'],
        ),
      );
      final encoded = CoachPlanState.fromJson(
        jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, dynamic>,
      );
      final fromSnapshot = controller(FakeLlmClient([], latency: Duration.zero))
        ..restoreHistory(legacyMessages, planState: encoded);
      final saved = fromSnapshot.agent.sessionState.params;
      expect(saved['scene']!.source, 'host');
      expect(saved['equipment']!.source, 'host');
      expect(
        saved['equipment']!.value,
        containsAll(['equip.mat', 'equip.chair']),
      );
      expect(saved['minutes']!.value, 10);
      expect(saved['limits']!.source, 'host');
      expect(saved['limits']!.value, contains('limit.wrist'));
      expect(
        fromSnapshot.agent.planStateFor(card).context.notes,
        contains('保护手腕'),
      );
      expect(
        fromSnapshot.agent.sessionState.userTurns.map((turn) => turn.text),
        ['在家有瑜伽垫10分钟做髋部放松'],
      );
      expect(fromSnapshot.agent.sessionState.task, isNull);
    },
  );

  for (final sample in [('短一点', 5), ('缩短到 7 分钟', 7), ('换成徒手', 10)]) {
    test(
      'restored plan: ${sample.$1} is an adjustment without asking',
      () async {
        final previous = await history();
        final oldPlan = previous.lastWhere((m) => m.plan != null).plan!.plan;
        final flow = ScriptedV2PlanFlow(catalog)..planId = oldPlan.id;
        final client = FakeLlmClient(
          sample.$1 == '换成徒手'
              ? flow.changeToBodyweight()
              : flow.changeMinutes(
                  sample.$2,
                  sample.$1 == '短一点' ? '短一点' : '7 分钟',
                  direction: sample.$1 == '短一点' ? 'shorter' : null,
                ),
        );
        final c = controller(client)..restoreHistory(previous);
        final result = await c.send(sample.$1);
        expect(result!.question, isNull);
        expect(
          result.plan,
          isNotNull,
          reason: '${result.issues} ${result.error}',
        );
        final plan = result.plan!.plan;
        expect(plan.targetMinutes, sample.$2);
        expect(plan.scene, 'home');
        expect(plan.equipment, sample.$1 == '换成徒手' ? isEmpty : ['mat']);
        if (sample.$1 == '短一点') {
          expect(
            duration.estimateSeconds(plan, catalog),
            lessThan(duration.estimateSeconds(oldPlan, catalog)),
          );
        }
        final requestText = client.requests.first.messages
            .map((m) => m.content)
            .join('\n');
        expect(
          requestText,
          contains(catalog['s-kneel-hipflex']!.name.of('zh')),
          reason: 'model must see the previous plan, including actions',
        );
        expect(
          requestText,
          isNot(contains('workSeconds')),
          reason: 'the restored request contains a summary, not full plan JSON',
        );
        expect(
          jsonEncode(c.agent.sessionState.plans),
          contains('workSeconds'),
          reason: 'full plan doses remain in the persisted state',
        );
      },
    );
  }

  test(
    'legacy history without plan conditions infers them from the last card',
    () async {
      final previous = legacy(
        await history(),
      ).where((message) => message.plan != null).toList();
      final flow = ScriptedV2PlanFlow(catalog)
        ..planId = previous
            .lastWhere((message) => message.plan != null)
            .plan!
            .plan
            .id;
      final client = FakeLlmClient(
        flow.legacyEdit(minutes: 7, hasGoalQuote: false),
      );
      final c = controller(client)..restoreHistory(previous);
      final result = await c.send('缩短到 7 分钟');
      expect(result!.question, isNull);
      expect(
        result.plan,
        isNotNull,
        reason: '${result.issues} ${result.error}',
      );
      expect(result.plan!.plan.scene, 'home');
      expect(result.plan!.plan.equipment, ['mat']);
      expect(result.plan!.plan.targetMinutes, 7);
    },
  );

  test(
    'restored plan followed by a new focus may be clarified by the model',
    () async {
      final previous = await history();
      final client = FakeLlmClient([
        _tool(AgentTools.askUser, {'question': '肩膀有疼痛吗？', 'mode': 'text'}),
      ]);
      final c = controller(client)..restoreHistory(previous);
      final result = await c.send('我想针对肩膀拉伸');
      expect(result!.plan, isNull);
      expect(result.question, isNotNull);
      expect(result.question!.mode, AskUserMode.text);
      expect(result.question!.question, '肩膀有疼痛吗？');
      expect(client.requests, hasLength(1));
    },
  );

  test(
    'host-provided snapshot retains unused equipment and safety constraints',
    () async {
      final previous = legacy(await history());
      final plan = previous.lastWhere((m) => m.plan != null).plan!.plan;
      final snapshot = CoachPlanState(
        planId: plan.id,
        context: const CoachContext(
          scene: 'home',
          equipment: {'mat', 'chair'},
          minutes: 10,
          avoid: {'wrist'},
          notes: ['保护手腕'],
        ),
        focus: '髋部',
      );
      final restoredSnapshot = CoachPlanState.fromJson(
        jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, dynamic>,
      );
      expect(restoredSnapshot.toJson(), snapshot.toJson());
      final flow = ScriptedV2PlanFlow(catalog)..planId = plan.id;
      final client = FakeLlmClient(flow.legacyEdit(minutes: 7));
      final c = controller(client)
        ..restoreHistory(previous, planState: restoredSnapshot);
      final result = await c.send('缩短到 7 分钟');
      expect(result!.question, isNull);
      expect(
        result.plan,
        isNotNull,
        reason: '${result.issues} ${result.error}',
      );
      expect(
        c.agent.lastConfirmedForm?['equipment'],
        containsAll(['瑜伽垫', '椅子/凳子']),
      );
      final requestText = client.requests.first.messages
          .map((m) => m.content)
          .join('\n');
      expect(requestText, contains('wrist'));
      expect(requestText, contains('保护手腕'));
      expect(
        c.agent.planStateFor(result.plan!).context.notes,
        contains('保护手腕'),
      );
    },
  );

  for (final oldHistory in [false, true]) {
    test(
      'relative duration remains within 10% after restore; legacy=$oldHistory',
      () async {
        final flow = ScriptedV2PlanFlow(catalog);
        final original = controller(
          FakeLlmClient([
            ...flow.initial(),
            ...flow.changeMinutes(5, '短一点', direction: 'shorter'),
          ]),
        );
        expect((await original.send('在家有瑜伽垫，10分钟做髋部放松'))!.plan, isNotNull);
        final short = (await original.send('短一点'))!;
        expect(short.plan, isNotNull);
        final before = short.plan!.plan;
        expect(
          (duration.estimateSeconds(before, catalog) / 60 -
                      before.targetMinutes)
                  .abs() /
              before.targetMinutes,
          lessThanOrEqualTo(.10),
        );
        final messages = oldHistory
            ? legacy(original.state.messages)
            : original.state.messages;
        final client = FakeLlmClient(
          oldHistory
              ? flow.legacyEdit(bodyweight: true)
              : flow.changeToBodyweight(),
        );
        final c = controller(client)..restoreHistory(messages);
        final result = await c.send('换成徒手');
        expect(result!.question, isNull);
        expect(
          result.plan,
          isNotNull,
          reason: '${result.issues} ${result.error}',
        );
        expect(result.plan!.plan.targetMinutes, 5);
        expect(result.plan!.plan.equipment, isEmpty);
        expect(
          (duration.estimateSeconds(result.plan!.plan, catalog) / 60 - 5)
                  .abs() /
              5,
          lessThanOrEqualTo(.10),
        );
      },
    );
  }

  test(
    'snapshot of a different plan is never applied to the latest card',
    () async {
      final previous = legacy(await history());
      const mismatched = CoachPlanState(
        planId: 'other-plan',
        context: CoachContext(
          scene: 'office',
          equipment: {'chair'},
          minutes: 20,
        ),
        focus: '肩膀',
      );
      final flow = ScriptedV2PlanFlow(catalog)
        ..planId = previous
            .lastWhere((message) => message.plan != null)
            .plan!
            .plan
            .id;
      final c = controller(FakeLlmClient(flow.legacyEdit(minutes: 7)))
        ..restoreHistory(previous, planState: mismatched);
      final result = await c.send('缩短到 7 分钟');
      expect(result!.question, isNull);
      expect(
        result.plan,
        isNotNull,
        reason: '${result.issues} ${result.error}',
      );
      expect(result.plan!.plan.scene, 'home');
      expect(result.plan!.plan.equipment, ['mat']);
      expect(result.plan!.plan.targetMinutes, 7);
    },
  );

  test(
    'the last of multiple plan cards becomes the adjustment baseline',
    () async {
      final flow = ScriptedV2PlanFlow(catalog);
      final original = controller(
        FakeLlmClient([...flow.initial(), ...flow.changeMinutes(7, '7 分钟')]),
      );
      expect((await original.send('在家有瑜伽垫，10分钟做髋部放松'))!.plan, isNotNull);
      expect((await original.send('缩短到 7 分钟'))!.plan, isNotNull);
      final restored = original.state.messages;
      final client = FakeLlmClient(
        flow.changeMinutes(5, '短一点', direction: 'shorter'),
      );
      final c = controller(client)..restoreHistory(restored);
      final result = await c.send('短一点');
      expect(result!.question, isNull);
      expect(
        result.plan,
        isNotNull,
        reason: '${result.issues} ${result.error}',
      );
      expect(result.plan!.plan.targetMinutes, 5);
      final minutes = c.agent.sessionState.params['minutes']!;
      expect(minutes.source, 'derived');
      expect(minutes.basedOn!.value, 7, reason: '基于最近交付的计划，不是旧的 10 分钟');
      expect(minutes.basedOn!.quote, '7 分钟');
    },
  );
}
