// Scripted, deterministic multi-turn protocol evaluation. FakeLlmClient
// replaces network/model inference: these checks do not measure model quality.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

Map<String, Object?> _item(
  String id,
  String mode, {
  int sets = 1,
  int? reps,
  int? seconds,
  bool perSide = false,
  int rest = 0,
}) => {
  'exerciseId': id,
  'mode': mode,
  'sets': sets,
  'reps': ?reps,
  'workSeconds': ?seconds,
  'perSide': perSide,
  'restSeconds': rest,
};

Map<String, Object?> _plan({
  required String scene,
  required int minutes,
  required String goal,
  required List<String> equipment,
  required List<Map<String, Object?>> items,
}) => {
  'schemaVersion': 1,
  'title': '训练方案',
  'summary': '按所选条件安排动作',
  'goal': goal,
  'scene': scene,
  'level': 1,
  'targetMinutes': minutes,
  'equipment': equipment,
  'blocks': [
    {'id': 'main', 'name': '训练', 'type': 'main', 'items': items},
  ],
};

Map<String, Object?> _hipPlan({bool short = false}) => _plan(
  scene: 'home',
  minutes: short ? 5 : 10,
  goal: 'relax',
  equipment: ['mat'],
  items: [
    _item('s-kneel-hipflex', 'time', seconds: short ? 60 : 120, perSide: true),
    _item(
      's-butterfly',
      'time',
      sets: short ? 1 : 3,
      seconds: 120,
      rest: short ? 0 : 30,
    ),
  ],
);

Map<String, Object?> _corePlan() => _plan(
  scene: 'home',
  minutes: 20,
  goal: 'core',
  equipment: [],
  items: [
    _item('erectors-A', 'time', sets: 4, seconds: 120, rest: 20),
    _item('obliques-A', 'reps', sets: 3, reps: 30, perSide: true, rest: 20),
  ],
);

Map<String, Object?> _officePlan() => _plan(
  scene: 'office',
  minutes: 10,
  goal: 'relax',
  equipment: ['chair', 'wall'],
  items: [
    _item('h-chair-lat', 'time', sets: 2, seconds: 120, rest: 30),
    _item('h-wall-calf', 'time', sets: 1, seconds: 120, perSide: true),
  ],
);

Map<String, Object?> _defaultPlan() => _plan(
  scene: 'home',
  minutes: 15,
  goal: 'fullbody',
  equipment: [],
  items: [
    _item('erectors-A', 'time', sets: 4, seconds: 120, rest: 20),
    _item('h-squat', 'reps', sets: 3, reps: 30, rest: 20),
  ],
);

LlmResponse _show(Map<String, Object?> plan) => LlmResponse(
  content: '',
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

var _scriptSequence = 0;
LlmResponse _tool(String name, Object arguments) => LlmResponse(
  content: '',
  toolCalls: [
    LlmToolCall(
      id: 'scripted-${_scriptSequence++}',
      name: name,
      arguments: jsonEncode(arguments),
    ),
  ],
  finishReason: 'tool_calls',
  model: 'fake',
);

LlmResponse _askText(String question) =>
    _tool(AgentTools.askUser, {'question': question, 'mode': 'text'});

LlmResponse _askForm() => _tool(AgentTools.askUser, {
  'question': '你准备在哪里、用什么器材、练多久？',
  'mode': 'form',
  'fields': [
    {
      'key': 'scene',
      'label': '场景',
      'options': ['家里', '办公室'],
      'multiple': false,
    },
    {
      'key': 'equipment',
      'label': '器械',
      'options': ['徒手', '瑜伽垫', '椅子/凳子', '墙'],
      'multiple': true,
    },
    {
      'key': 'minutes',
      'label': '时长',
      'options': ['5 分钟', '10 分钟', '15 分钟'],
      'multiple': false,
    },
  ],
});

Map<String, Object?> _user(Object value, String quote) => {
  'value': value,
  'source': 'user',
  'quote': quote,
};

Map<String, Object?> _default(Object value) => {
  'value': value,
  'source': 'default',
};

LlmResponse _setParams(Map<String, Object?> fields) =>
    _tool(AgentTools.setParams, {'fields': fields});

void main() {
  final fixture =
      jsonDecode(File('eval/cases/ask_user_r2.json').readAsStringSync())
          as Map<String, Object?>;
  final cases = <String, Map<String, Object?>>{
    for (final raw
        in (fixture['cases']! as List<Object?>).cast<Map<String, Object?>>())
      raw['id']! as String: raw,
  };
  Map<String, Object?> caseTurn(String id, int i) =>
      ((cases[id]!['turns']! as List<Object?>)[i]! as Map<String, Object?>);
  String turn(String id, int i) => caseTurn(id, i)['text']! as String;
  final base = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final app = PoseHubAppTestCatalog.fromBytes(
    File('$base/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$base/catalog/catalog.json').readAsBytesSync(),
  );
  final catalog = app.toAiCatalog();
  final profile = loadProfile('smartfit');

  CoachConversationController chat(
    FakeLlmClient client, {
    SessionFallback? fallback,
  }) {
    final controller = CoachConversationController(
      agent: CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
        fallback: fallback,
      ),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  group('r2 multi-turn offline scripted protocol; no real model calls', () {
    test('fixture identifies all six distinct cases', () {
      expect(fixture['mode'], 'offline-scripted-protocol');
      expect(cases.keys.toSet(), {
        'new_focus_previous_preselected',
        'adjust_shorter',
        'complete_home_core',
        'office_chair_wall',
        'accept_defaults',
        'safe_failure',
      });
    });

    test(
      'model asks about new focus and preserves known conditions across questions',
      () async {
        const id = 'new_focus_previous_preselected';
        final client = FakeLlmClient([
          _setParams({
            'scene': _user('home', '在家'),
            'equipment': _user(['equip.mat'], '瑜伽垫'),
            'minutes': _user(10, '10分钟'),
          }),
          _show(_hipPlan()),
          _askText('肩颈主要是僵硬，还是活动时有不适？'),
          _askText('有没有疼痛或其他运动限制？'),
          '明白，出现不适时请停下休息。',
        ]);
        final controller = chat(client);
        final initial = await controller.send(turn(id, 0));
        expect(initial!.plan, isNotNull);
        final before = client.requests.length;
        final next = await controller.send(turn(id, 1));
        final question = next!.question;
        expect(question, isNotNull);
        expect(question!.mode, AskUserMode.text);
        expect(question.question, '肩颈主要是僵硬，还是活动时有不适？');
        expect(client.requests.length, greaterThan(before));
        expect(next.plan, isNull);
        final second = await controller.answerText(
          controller.state.pendingQuestion!.id,
          '只是有点僵硬',
        );
        expect(second!.question?.question, '有没有疼痛或其他运动限制？');
        expect(controller.agent.sessionState.params['scene']!.value, 'home');
        expect(controller.agent.sessionState.params['equipment']!.value, [
          'equip.mat',
        ]);
        expect(controller.agent.sessionState.params['minutes']!.value, 10);
        final result = await controller.answerText(
          controller.state.pendingQuestion!.id,
          '没有疼痛，也没有运动限制',
        );
        expect(result!.question, isNull);
        expect(controller.state.pendingQuestion, isNull);
        final userHistory = controller.agent.sessionState.userTurns
            .map((t) => t.text)
            .toList();
        expect(
          userHistory,
          containsAll([turn(id, 0), turn(id, 1), '只是有点僵硬', '没有疼痛，也没有运动限制']),
        );
        expect(client.remaining, 0);
      },
    );

    test(
      'shorter adjustment does not ask and changes the actual target',
      () async {
        const id = 'adjust_shorter';
        final controller = chat(
          FakeLlmClient([_show(_hipPlan()), _show(_hipPlan(short: true))]),
        );
        final first = await controller.send(turn(id, 0));
        expect(first!.plan, isNotNull);
        final next = await controller.send(turn(id, 1));
        expect(next!.question, isNull);
        expect(next.plan, isNotNull);
        expect(
          next.plan!.plan.targetMinutes,
          lessThan(first.plan!.plan.targetMinutes),
        );
        final duration =
            const PlanDuration().estimateSeconds(next.plan!.plan, catalog) / 60;
        expect(
          duration,
          lessThan(
            const PlanDuration().estimateSeconds(first.plan!.plan, catalog) /
                60,
          ),
        );
      },
    );

    test(
      'complete home bodyweight twenty-minute core request goes straight to plan',
      () async {
        const id = 'complete_home_core';
        final controller = chat(FakeLlmClient([_show(_corePlan())]));
        final result = await controller.send(turn(id, 0));
        expect(result!.question, isNull);
        expect(
          result.plan,
          isNotNull,
          reason: 'issues: ${result.issues}; error: ${result.error}',
        );
        final plan = result.plan!.plan;
        expect(plan.scene, 'home');
        expect(plan.targetMinutes, 20);
        expect(plan.goal, 'core');
        expect(plan.equipment, isEmpty);
        expect(
          plan.items.every(
            (item) => catalog[item.exerciseId]!.equipment.isEmpty,
          ),
          isTrue,
        );
        expect(
          const PlanDuration().estimateSeconds(plan, catalog) / 60,
          inInclusiveRange(15, 25),
        );
      },
    );

    test(
      'model asks for office conditions before the chair and wall plan',
      () async {
        const id = 'office_chair_wall';
        final client = FakeLlmClient([
          _askForm(),
          _setParams({
            'scene': _user('office', '办公室'),
            'equipment': _user(['equip.chair', 'equip.wall'], '椅子/凳子、墙'),
            'minutes': _user(10, '10 分钟'),
          }),
          _show(_officePlan()),
        ]);
        final controller = chat(client);
        final first = await controller.send(turn(id, 0));
        expect(first!.question?.mode, AskUserMode.form);
        expect(client.requests, hasLength(1));
        final form = (caseTurn(id, 1)['answerForm']! as Map<String, Object?>)
            .map(
              (key, value) =>
                  MapEntry(key, (value! as List<Object?>).cast<String>()),
            );
        final result = await controller.answerForm(
          controller.state.pendingQuestion!.id,
          form,
        );
        expect(result!.question, isNull);
        expect(
          result.plan,
          isNotNull,
          reason: 'issues: ${result.issues}; error: ${result.error}',
        );
        final plan = result.plan!.plan;
        final used = {
          for (final item in plan.items) ...catalog[item.exerciseId]!.equipment,
        };
        expect(used.intersection({'chair', 'wall'}), isNotEmpty);
        expect(plan.equipment.toSet(), used);
        expect(plan.scene, 'office');
        expect(plan.targetMinutes, 10);
        expect(controller.agent.sessionState.params['equipment']!.value, [
          'equip.chair',
          'equip.wall',
        ]);
        expect(
          controller.agent.sessionState.params['equipment']!.source,
          'user',
        );
        expect(
          const PlanDuration().estimateSeconds(plan, catalog) / 60,
          inInclusiveRange(8, 12),
        );
      },
    );

    test('model records the user-requested defaults and continues', () async {
      const id = 'accept_defaults';
      final client = FakeLlmClient([
        _askForm(),
        _setParams({
          'scene': _default('home'),
          'equipment': _default(<String>[]),
          'minutes': _default(15),
          'level': _default(1),
        }),
        _show(_defaultPlan()),
      ]);
      final controller = chat(client);
      final first = await controller.send(turn(id, 0));
      expect(first!.question?.mode, AskUserMode.form);
      expect(client.requests, hasLength(1));
      final pending = controller.state.pendingQuestion!;
      final result = await controller.answerText(pending.id, turn(id, 1));
      expect(result!.question, isNull);
      expect(result.plan, isNotNull);
      expect(controller.state.pendingQuestion, isNull);
      expect(client.requests, hasLength(3));
      expect(controller.agent.sessionState.params['equipment']!.value, isEmpty);
      expect(
        controller.agent.sessionState.params['equipment']!.source,
        'default',
      );
      expect(controller.agent.sessionState.params['minutes']!.value, 15);
      expect(
        controller.agent.sessionState.params['minutes']!.source,
        'default',
      );
    });

    test(
      'model failure creates one failure message and never exposes internals',
      () async {
        const id = 'safe_failure';
        var fallbackCalls = 0;
        final controller = chat(
          FakeLlmClient([
            const LlmException(
              LlmErrorKind.network,
              'internal-secret-unsafe-detail',
            ),
          ]),
          fallback: (_) {
            fallbackCalls++;
            return const SessionFallbackReply('fallback');
          },
        );
        final result = await controller.send(turn(id, 0));
        expect(result!.status, TurnStatus.error);
        expect(result.plan, isNull);
        expect(
          fallbackCalls,
          0,
          reason: 'a failed planning request must not silently select a preset',
        );
        final assistant = controller.state.messages
            .where((message) => !message.isUser)
            .toList();
        expect(assistant, hasLength(1));
        expect(assistant.single.isFailure, isTrue);
        expect(assistant.single.plan, isNull);
        expect(
          assistant.single.text,
          isNot(contains('internal-secret-unsafe-detail')),
        );
        expect(assistant.single.text, isNot(contains('LlmException')));
      },
    );
  });
}
