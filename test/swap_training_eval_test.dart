import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';
import 'support_v2_plan_flow.dart';

// Offline scripted tool calls exercise the real Agent and Pose-Hub catalog.
Set<String> mainIds(TrainingPlan plan) => {
  for (final block in plan.blocks)
    if (block.type == BlockType.main || block.type == BlockType.circuit)
      for (final item in block.items)
        if (item.segments.isEmpty)
          item.exerciseId
        else
          for (final segment in item.segments) segment.exerciseId,
};

void main() {
  const base = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$base/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$base/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();
  final profile = loadProfile('smartfit');

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

  for (final phrase in ['换一套', '换个别的', '再来一套']) {
    for (final restore in [false, true]) {
      test(
        '$phrase after ${restore ? 'restore' : 'live session'} replaces the plan',
        () async {
          final flow = ScriptedV2PlanFlow(catalog);
          final client = FakeLlmClient([
            ...flow.initial(),
            ...flow.changeActions(replaceAll: true, rejectSimilarFirst: true),
          ]);
          var c = controller(client);
          final original = await c.send('在家有瑜伽垫，10分钟做髋部放松');
          expect(
            original!.plan,
            isNotNull,
            reason: '${original.issues} ${original.error}',
          );
          final oldPlan = original.plan!.plan;
          if (restore) c = controller(client)..restoreHistory(c.state.messages);
          final result = await c.send(phrase);
          expect(result!.question, isNull);
          expect(
            result.plan,
            isNotNull,
            reason: '${result.issues} ${result.error}',
          );
          final plan = result.plan!.plan;
          expect(plan.id, oldPlan.id);
          expect(plan.scene, 'home');
          expect(plan.targetMinutes, 10);
          expect(plan.equipment, isEmpty);
          expect(
            c.agent.sessionState.params['equipment']!.value,
            contains('equip.mat'),
          );
          expect(
            (const PlanDuration().estimateSeconds(plan, catalog) / 60 - 10)
                    .abs() /
                10,
            lessThanOrEqualTo(.10),
          );
          final previous = mainIds(oldPlan);
          final next = mainIds(plan);
          expect(
            next.difference(previous).length / next.length,
            greaterThanOrEqualTo(.5),
          );
          expect(c.agent.lastConfirmedForm?['scene'], ['家里']);
          expect(c.agent.lastConfirmedForm?['equipment'], contains('瑜伽垫'));
          expect(
            c.agent.sessionState.plans[flow.planId]!.last.operation,
            'replace_all',
          );
        },
      );
    }
  }

  for (final restore in [false, true]) {
    test(
      'replace_all rejects 2/6 new main actions and accepts 3/6; restore=$restore',
      () async {
        final flow = ScriptedV2PlanFlow(catalog);
        final client = FakeLlmClient([
          ...flow.initial(mainActions: ScriptedV2PlanFlow.thresholdOld),
          ...flow.sixActionThreshold(),
        ]);
        var c = controller(client);
        final original = await c.send('在家有瑜伽垫，10分钟做髋部放松');
        expect(
          original!.plan,
          isNotNull,
          reason: '${original.issues} ${original.error}',
        );
        expect(mainIds(original.plan!.plan), hasLength(6));
        if (restore) c = controller(client)..restoreHistory(c.state.messages);
        final result = await c.send('换一套');
        expect(
          result!.plan,
          isNotNull,
          reason: '${result.issues} ${result.error}',
        );
        final newer = mainIds(result.plan!.plan);
        expect(newer, hasLength(6));
        expect(newer.difference(mainIds(original.plan!.plan)), hasLength(3));
        expect(
          c.agent.sessionState.plans[flow.planId]!.last.operation,
          'replace_all',
        );
      },
    );
  }

  test('whole replacement can also request a shorter plan', () async {
    final flow = ScriptedV2PlanFlow(catalog);
    final c = controller(
      FakeLlmClient([
        ...flow.initial(),
        ...flow.changeActions(replaceAll: true, shorter: true),
      ]),
    );
    expect((await c.send('在家有瑜伽垫，10分钟做髋部放松'))!.plan, isNotNull);
    final result = await c.send('换一套，再短一点');
    expect(result!.plan, isNotNull, reason: '${result.issues} ${result.error}');
    expect(result.plan!.plan.targetMinutes, 5);
    expect(
      (const PlanDuration().estimateSeconds(result.plan!.plan, catalog) / 60 -
                  5)
              .abs() /
          5,
      lessThanOrEqualTo(.10),
    );
    expect(c.agent.sessionState.params['minutes']!.source, 'derived');
    expect(c.agent.sessionState.params['minutes']!.quote, '短一点');
    expect(c.agent.sessionState.params['minutes']!.basedOn!.value, 10);
  });

  for (final phrase in ['换一个动作', '换个别的动作', '换掉第 2 个']) {
    for (final restore in [false, true]) {
      test(
        '$phrase is a single-action edit without a whole-plan requirement; restore=$restore',
        () async {
          final flow = ScriptedV2PlanFlow(catalog);
          final client = FakeLlmClient([
            ...flow.initial(),
            ...flow.changeActions(replaceAll: false),
          ]);
          var c = controller(client);
          final original = await c.send('在家有瑜伽垫，10分钟做髋部放松');
          expect(original!.plan, isNotNull, reason: '${original.issues}');
          if (restore) c = controller(client)..restoreHistory(c.state.messages);
          expect(
            c.agent.sessionState.picks,
            isNot(contains('n-pelvis-circle')),
          );
          final nodeEvents = <AgentEvent>[];
          final subscription = c.agent.events.listen(nodeEvents.add);
          final result = await c.send(phrase);
          await subscription.cancel();
          expect(
            result!.plan,
            isNotNull,
            reason: '${result.issues} ${result.error}',
          );
          expect(c.agent.sessionState.picks, contains('n-pelvis-circle'));
          final updates = nodeEvents.where(
            (event) =>
                event.kind == AgentEventKind.node &&
                event.node?.id == 'actions' &&
                event.node?.status == 'done',
          );
          expect(updates, hasLength(1));
          final before = mainIds(original.plan!.plan);
          final after = mainIds(result.plan!.plan);
          expect(before, hasLength(3));
          expect(after, hasLength(3));
          expect(after.intersection(before), hasLength(2));
          expect(after.difference(before), hasLength(1));
          expect(result.plan!.plan.targetMinutes, 10);
          expect(result.plan!.plan.scene, 'home');
          expect(
            c.agent.sessionState.plans[flow.planId]!.last.operation,
            'edit',
          );
        },
      );
    }
  }

  for (final phrase in ['难一点', '再短一点']) {
    for (final restore in [false, true]) {
      test('$phrase is a plan edit; restore=$restore', () async {
        final flow = ScriptedV2PlanFlow(catalog);
        final client = FakeLlmClient([
          ...flow.initial(),
          ...flow.changeActions(
            replaceAll: false,
            keepSame: true,
            shorter: phrase == '再短一点',
          ),
        ]);
        var c = controller(client);
        expect((await c.send('在家有瑜伽垫，10分钟做髋部放松'))!.plan, isNotNull);
        if (restore) c = controller(client)..restoreHistory(c.state.messages);
        final result = await c.send(phrase);
        expect(result!.question, isNull);
        expect(
          result.plan,
          isNotNull,
          reason: '${result.issues} ${result.error}',
        );
        expect(result.plan!.plan.scene, 'home');
        expect(result.plan!.plan.targetMinutes, phrase == '再短一点' ? 5 : 10);
        expect(c.agent.lastConfirmedForm?['equipment'], contains('瑜伽垫'));
        expect(c.agent.sessionState.plans[flow.planId]!.last.operation, 'edit');
        if (phrase == '再短一点') {
          expect(c.agent.sessionState.params['minutes']!.source, 'derived');
          expect(c.agent.sessionState.params['minutes']!.quote, '短一点');
        }
      });
    }
  }

  test('the model may ask about a different focus', () async {
    final flow = ScriptedV2PlanFlow(catalog);
    final client = FakeLlmClient([
      ...flow.initial(),
      LlmResponse(
        content: '',
        toolCalls: [
          LlmToolCall(
            id: 'question',
            name: AgentTools.askUser,
            arguments: jsonEncode({'question': '肩膀有疼痛吗？', 'mode': 'text'}),
          ),
        ],
        finishReason: 'tool_calls',
      ),
    ]);
    final c = controller(client);
    expect((await c.send('在家有瑜伽垫，10分钟做髋部放松'))!.plan, isNotNull);
    final result = await c.send('再来一套练肩膀');
    expect(result!.plan, isNull);
    expect(result.question?.mode, AskUserMode.text);
    expect(result.question!.question, '肩膀有疼痛吗？');
  });

  test('swap without any plan does not inherit previous conditions', () async {
    final c = controller(FakeLlmClient(['请先告诉我你想练什么。']));
    final result = await c.send('换一套');
    expect(result!.plan, isNull);
    expect(c.agent.lastConfirmedForm, isNull);
  });
}
