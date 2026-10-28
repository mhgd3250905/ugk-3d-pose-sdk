// Scripted, deterministic multi-turn protocol evaluation. FakeLlmClient
// replaces network/model inference: these checks do not measure model quality.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

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

  List<Object> planFlow({
    required String prefix,
    required Map<String, Object?> fields,
    required List<String> main,
    List<String> warmup = const [],
    List<String> cooldown = const [],
  }) {
    final ids = [...warmup, ...main, ...cooldown];
    LlmToolCall call(String id, String name, Object args) =>
        LlmToolCall(id: '$prefix-$id', name: name, arguments: jsonEncode(args));
    LlmResponse batch(List<LlmToolCall> values) => LlmResponse(
      content: '',
      toolCalls: values,
      finishReason: 'tool_calls',
      model: 'fake',
    );
    Map<String, dynamic> feedback(LlmRequest req, String id) =>
        jsonDecode(
              req.messages
                  .singleWhere((m) => m.toolCallId == '$prefix-$id')
                  .content,
            )
            as Map<String, dynamic>;
    late String planId;
    return [
      batch([
        call('start', AgentTools.startTask, {'type': 'plan'}),
        call('understand', AgentTools.check, {'node': 'understand'}),
        call('params', AgentTools.setParams, {'fields': fields}),
        call('parameters', AgentTools.check, {'node': 'parameters'}),
        for (var i = 0; i < ids.length; i++)
          call('search$i', AgentTools.searchActions, {
            'tags': <String>[],
            'keywords': catalog[ids[i]]!.name.of('en'),
          }),
      ]),
      (LlmRequest request) {
        expect(feedback(request, 'params')['ok'], isTrue);
        expect(feedback(request, 'parameters')['ok'], isTrue);
        for (var i = 0; i < ids.length; i++) {
          final search = feedback(request, 'search$i');
          expect(search['ok'], isTrue, reason: '$search');
          expect(
            (search['items'] as List).map((e) => (e as Map)['id']),
            contains(ids[i]),
          );
        }
        return batch([
          call('actions', AgentTools.check, {'node': 'actions', 'picks': ids}),
          call('draft', AgentTools.draftPlan, {
            'title': '训练方案',
            'blocks': [
              if (warmup.isNotEmpty)
                {
                  'kind': 'warmup',
                  'items': [
                    for (final id in warmup) {'id': id},
                  ],
                },
              {
                'kind': 'main',
                'items': [
                  for (final id in main) {'id': id},
                ],
              },
              if (cooldown.isNotEmpty)
                {
                  'kind': 'cooldown',
                  'items': [
                    for (final id in cooldown) {'id': id},
                  ],
                },
            ],
          }),
        ]);
      },
      (LlmRequest request) {
        expect(feedback(request, 'actions')['ok'], isTrue);
        final draft = feedback(request, 'draft');
        expect(draft['ok'], isTrue, reason: '$draft');
        planId = draft['plan_id'] as String;
        return batch([
          call('planning', AgentTools.check, {'node': 'planning'}),
          call('review-plan', AgentTools.checkPlan, {'plan_id': planId}),
        ]);
      },
      (LlmRequest request) {
        final check = feedback(request, 'review-plan');
        expect(check['ok'], isTrue, reason: '$check');
        return batch([
          call('review', AgentTools.check, {'node': 'review'}),
        ]);
      },
      (LlmRequest request) {
        expect(feedback(request, 'review')['ok'], isTrue);
        return batch([
          call('show', AgentTools.showPlan, {
            'plan_id': planId,
            'note': '按你的条件安排训练。',
          }),
        ]);
      },
    ];
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
          ...planFlow(
            prefix: 'hip',
            fields: {
              'scene': _user('home', '在家'),
              'equipment': _user(['equip.mat'], '瑜伽垫'),
              'minutes': _user(10, '10分钟'),
              'goal': _user(['purpose.stretch'], '放松'),
            },
            warmup: ['n-pelvis-circle'],
            main: ['h-knee-hug', 'h-sumo-pry', 's-figure4', 's-kneel-hipflex'],
            cooldown: ['s-butterfly'],
          ),
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
        late String planId;
        const main = [
          'h-knee-hug',
          'h-sumo-pry',
          's-figure4',
          's-kneel-hipflex',
        ];
        final controller = chat(
          FakeLlmClient([
            ...planFlow(
              prefix: 'relative-initial',
              fields: {
                'scene': _user('home', '在家'),
                'equipment': _user(['equip.mat'], '瑜伽垫'),
                'minutes': _user(10, '10分钟'),
                'goal': _user(['purpose.stretch'], '放松'),
              },
              warmup: ['n-pelvis-circle'],
              main: main,
              cooldown: ['s-butterfly'],
            ),
            _setParams({
              'minutes': {
                'value': 5,
                'source': 'derived',
                'quote': '短一点',
                'direction': 'shorter',
              },
            }),
            (LlmRequest request) {
              final update = jsonDecode(request.messages.last.content) as Map;
              expect(update['ok'], isTrue, reason: '$update');
              return _tool(AgentTools.draftPlan, {
                'plan_id': planId,
                'operation': 'edit',
                'title': '髋部放松',
                'blocks': [
                  {
                    'kind': 'main',
                    'items': [
                      for (final item in main) {'id': item},
                    ],
                  },
                ],
              });
            },
            (LlmRequest request) {
              final draft = jsonDecode(request.messages.last.content) as Map;
              expect(draft['ok'], isTrue, reason: '$draft');
              return _tool(AgentTools.check, {'node': 'planning'});
            },
            (LlmRequest request) {
              final planning = jsonDecode(request.messages.last.content) as Map;
              expect(planning['ok'], isTrue, reason: '$planning');
              return _tool(AgentTools.checkPlan, {'plan_id': planId});
            },
            (LlmRequest request) {
              final checked = jsonDecode(request.messages.last.content) as Map;
              expect(checked['ok'], isTrue, reason: '$checked');
              return _tool(AgentTools.check, {'node': 'review'});
            },
            (LlmRequest request) {
              final reviewed = jsonDecode(request.messages.last.content) as Map;
              expect(reviewed['ok'], isTrue, reason: '$reviewed');
              return _tool(AgentTools.showPlan, {
                'plan_id': planId,
                'note': '按你的要求缩短训练。',
              });
            },
          ]),
        );
        final first = await controller.send(turn(id, 0));
        expect(first!.plan, isNotNull);
        planId = first.plan!.plan.id;
        final next = await controller.send(turn(id, 1));
        expect(next!.question, isNull);
        expect(next.plan, isNotNull);
        final minutes = controller.agent.sessionState.params['minutes']!;
        expect(
          (minutes.value, minutes.source, minutes.quote, minutes.direction),
          (5, 'derived', '短一点', 'shorter'),
        );
        expect(minutes.basedOn?.value, 10);
        expect(controller.agent.sessionState.params['goal']!.value, [
          'purpose.stretch',
        ]);
        expect(controller.agent.sessionState.params['scene']!.value, 'home');
        expect(controller.agent.sessionState.params['equipment']!.value, [
          'equip.mat',
        ]);
        expect(next.plan!.plan.id, planId);
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
        final controller = chat(
          FakeLlmClient(
            planFlow(
              prefix: 'core',
              fields: {
                'scene': _user('home', '在家'),
                'equipment': _user(<String>[], '徒手'),
                'minutes': _user(20, '20分钟'),
                'goal': _user(['body.core'], '核心'),
              },
              warmup: ['h-step-jack', 'n-pelvis-circle'],
              main: ['erectors-A', 'obliques-A', 'h-squat', 'h-good-morning'],
              cooldown: ['o-stand-sidebend', 'h-bilateral-upper-back-hug'],
            ),
          ),
        );
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
          inInclusiveRange(18, 22),
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
          ...planFlow(
            prefix: 'office',
            fields: {
              'goal': _user(['purpose.stretch'], '拉伸'),
            },
            warmup: ['o-stand-sidebend'],
            main: [
              'h-chair-lat',
              'h-wall-calf',
              'n-wide-fold',
              'o-seated-fig4',
            ],
            cooldown: ['o-seated-ham'],
          ),
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
        ...planFlow(
          prefix: 'default',
          fields: {
            'goal': _default(['purpose.strength']),
          },
          warmup: ['h-step-jack', 'n-pelvis-circle'],
          main: [
            'h-squat',
            'h-good-morning',
            'h-kneeling-pushup',
            'erectors-A',
          ],
          cooldown: ['o-stand-sidebend', 'h-bilateral-upper-back-hug'],
        ),
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
      expect(client.requests.length, greaterThan(3));
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
            LlmResponse(
              content: '',
              toolCalls: [
                LlmToolCall(
                  id: 'begin',
                  name: 'start_task',
                  arguments: '{"type":"plan"}',
                ),
              ],
            ),
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
