import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

Map<String, Object?> _item(
  String id,
  int seconds, {
  int sets = 1,
  int rest = 0,
  bool perSide = false,
}) => {
  'exerciseId': id,
  'mode': 'time',
  'sets': sets,
  'workSeconds': seconds,
  'perSide': perSide,
  'restSeconds': rest,
};

Map<String, Object?> _plan(int minutes, List<Map<String, Object?>> items) => {
  'schemaVersion': 1,
  'title': '髋部放松',
  'summary': '按所选条件安排动作',
  'goal': 'relax',
  'scene': 'home',
  'level': 1,
  'targetMinutes': minutes,
  'equipment': ['mat'],
  'blocks': [
    {'id': 'main', 'name': '训练', 'type': 'main', 'items': items},
  ],
};

Map<String, Object?> _original() => _plan(10, [
  _item('s-kneel-hipflex', 120, perSide: true),
  _item('s-butterfly', 120, sets: 3, rest: 30),
]);

Map<String, Object?> _sevenMinutes() => _plan(7, [
  _item('s-kneel-hipflex', 90, perSide: true),
  _item('s-butterfly', 100, sets: 2, rest: 25),
]);

LlmResponse _show(Map<String, Object?> plan, {String text = ''}) => LlmResponse(
  content: text,
  toolCalls: [
    LlmToolCall(
      id: 'scripted-show',
      name: AgentTools.showPlan,
      arguments: jsonEncode(plan),
    ),
  ],
  finishReason: 'tool_calls',
  model: 'fake',
);

void main() {
  const base = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$base/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$base/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();

  CoachConversationController chat(FakeLlmClient client) {
    final controller = CoachConversationController(
      agent: CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: loadProfile('smartfit'),
        enableUserMemory: false,
        maxRequestRetries: 0,
        maxResubmits: 0,
      ),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  group('adjustment retry and relative duration', () {
    for (final phrase in ['短一些', '长一些', '加长一点']) {
      test(
        'relative wording $phrase changes actual duration in the requested direction',
        () async {
          final shorter = phrase == '短一些';
          final changed = shorter
              ? _plan(5, [
                  _item('s-kneel-hipflex', 60, perSide: true),
                  _item('s-butterfly', 60),
                ])
              : _plan(15, [
                  _item('s-kneel-hipflex', 120, perSide: true, sets: 4),
                  _item('s-butterfly', 120),
                ]);
          final controller = chat(
            FakeLlmClient([_show(_original()), _show(changed)]),
          );
          final original = await controller.send('在家有瑜伽垫10分钟做髋部放松');
          expect(original!.plan, isNotNull);
          final result = await controller.send(phrase);
          expect(result!.question, isNull);
          expect(
            result.plan,
            isNotNull,
            reason: '${result.issues} ${result.error}',
          );
          final actual = const PlanDuration().estimateSeconds(
            result.plan!.plan,
            catalog,
          );
          final previous = const PlanDuration().estimateSeconds(
            original.plan!.plan,
            catalog,
          );
          expect(actual, shorter ? lessThan(previous) : greaterThan(previous));
        },
      );
    }

    test('delivered plan summary is also the assistant history', () async {
      final client = FakeLlmClient([_show(_original(), text: '这是一套99分钟徒手方案')]);
      final agent = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: loadProfile('smartfit'),
        enableUserMemory: false,
        maxRequestRetries: 0,
      );
      final result = await agent.send('在家有瑜伽垫10分钟做髋部放松');
      expect(
        result.plan,
        isNotNull,
        reason: '${result.issues} ${result.error}',
      );
      final assistant = agent.history.lastWhere(
        (m) => m.role == LlmRole.assistant,
      );
      expect(assistant.content, result.text);
      expect(assistant.content, isNot(contains('99分钟')));
      expect(assistant.toolCalls, isNotEmpty);
    });

    test('failed explicit adjustment retries the new duration', () async {
      final client = FakeLlmClient([
        _show(_original()),
        const LlmException(LlmErrorKind.network, 'offline'),
        _show(_sevenMinutes()),
      ]);
      final controller = chat(client);
      expect((await controller.send('在家有瑜伽垫10分钟做髋部放松'))!.plan, isNotNull);
      final failed = await controller.send('缩短到7分钟');
      expect(failed!.status, TurnStatus.error);
      final result = await controller.send('重试');
      expect(result!.question, isNull);
      expect(
        result.plan,
        isNotNull,
        reason: '${result.issues} ${result.error}',
      );
      expect(result.plan!.plan.targetMinutes, 7);
      expect(client.requests.last.messages.last.content, contains('缩短到7分钟'));
    });

    test(
      'relative shorter accepts a directionally correct plan without 25% gate',
      () async {
        final short = _plan(5, [
          _item('s-kneel-hipflex', 60, perSide: true),
          _item('s-butterfly', 60),
        ]);
        final controller = chat(
          FakeLlmClient([_show(_original()), _show(short)]),
        );
        final first = await controller.send('在家有瑜伽垫10分钟做髋部放松');
        expect(first!.plan, isNotNull);
        final result = await controller.send('短一点');
        expect(
          result!.plan,
          isNotNull,
          reason: '${result.issues} ${result.error}',
        );
        final actual = const PlanDuration().estimateSeconds(
          result.plan!.plan,
          catalog,
        );
        final previous = const PlanDuration().estimateSeconds(
          first.plan!.plan,
          catalog,
        );
        expect(actual, lessThan(previous));
        expect(((actual / 60 - 5).abs() / 5), greaterThan(.25));
      },
    );

    test(
      'relative shorter rejects a longer actual plan despite a smaller label',
      () async {
        final tooLong = _plan(5, [
          _item('s-kneel-hipflex', 120, perSide: true, sets: 5),
          _item('s-butterfly', 120),
        ]);
        final controller = chat(
          FakeLlmClient([_show(_original()), _show(tooLong)]),
        );
        expect((await controller.send('在家有瑜伽垫10分钟做髋部放松'))!.plan, isNotNull);
        final result = await controller.send('短一点');
        expect(result!.plan, isNull);
        expect(result.status, TurnStatus.error);
      },
    );

    test(
      'a later edit keeps the latest relative duration, not old chat values',
      () async {
        final short = _plan(5, [
          _item('s-kneel-hipflex', 60, perSide: true),
          _item('s-butterfly', 60),
        ]);
        final bodyweight = _plan(5, [
          {
            'exerciseId': 'n-pelvis-circle',
            'mode': 'reps',
            'sets': 1,
            'reps': 4,
            'perSide': false,
            'restSeconds': 0,
          },
        ])..['equipment'] = <String>[];
        final client = FakeLlmClient([
          _show(_original()),
          _show(short),
          _show(bodyweight),
          _show(bodyweight),
        ]);
        final controller = chat(client);
        expect((await controller.send('在家有瑜伽垫10分钟做髋部放松'))!.plan, isNotNull);
        expect((await controller.send('短一点'))!.plan, isNotNull);
        final result = await controller.send('换成徒手');
        expect(
          result!.plan,
          isNotNull,
          reason: '${result.issues} ${result.error}',
        );
        expect(result.plan!.plan.targetMinutes, 5);
        expect(result.plan!.plan.equipment, isEmpty);
        final actual =
            const PlanDuration().estimateSeconds(result.plan!.plan, catalog) /
            60;
        expect((actual - 5).abs() / 5, greaterThan(.25));
        final prompt = client.requests.last.messages.first.content;
        expect(prompt, contains('"minutes":5'));
        expect(prompt, contains('"equipment":[]'));
        // Explicitly stating a duration reinstates the absolute 25% gate.
        final explicit = await controller.send('改到5分钟');
        expect(explicit!.plan, isNull);
        expect(explicit.status, TurnStatus.error);
      },
    );
  });
}
