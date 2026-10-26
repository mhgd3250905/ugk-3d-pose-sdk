import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/training_parameters.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

var _sequence = 0;
LlmResponse tool(String name, Object args) => LlmResponse(
  content: '',
  toolCalls: [
    LlmToolCall(
      id: 'parameters-${_sequence++}',
      name: name,
      arguments: jsonEncode(args),
    ),
  ],
);
Map<String, Object?> form(Iterable<String> keys) => {
  'question': '补充一下训练条件，也可以直接出方案。',
  'mode': 'form',
  'fields': [
    for (final key in keys)
      switch (key) {
        'scene' => {
          'key': key,
          'label': '场景',
          'options': ['办公室', '家里', '健身房'],
          'multiple': false,
        },
        'equipment' => {
          'key': key,
          'label': '器械',
          'options': ['徒手', '瑜伽垫'],
          'multiple': true,
        },
        _ => {
          'key': key,
          'label': '时长',
          'options': ['5 分钟', '10 分钟', '15 分钟', '20+ 分钟'],
          'multiple': false,
        },
      },
  ],
  'skipLabel': '直接出方案',
};
Map<String, Object?> plan() => planOf(okEnvelope())..remove('source');

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('hiplab');
  CoachConversationController conversation(List<Object> replies) {
    final value = CoachConversationController(
      agent: CoachAgent(
        client: FakeLlmClient(replies),
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
      ),
    );
    addTearDown(value.dispose);
    return value;
  }

  TrainingParameters infer(
    String text, [
    CoachContext context = const CoachContext(),
  ]) => TrainingParameters.infer([text], context, catalog, profile);

  group(
    'deterministic multi-turn protocol evaluation (network modelCalls=0)',
    () {
      test('all parameters supplied: no clarification, correct plan', () async {
        final chat = conversation([tool(AgentTools.showPlan, plan())]);
        final result = await chat.send('在家，有瑜伽垫，10 分钟，排个髋部放松计划');
        expect(result!.plan, isNotNull);
        expect(result.question, isNull);
        expect(chat.agent.turnCount, 1);
      });
      test(
        'one missing: asks only equipment and uses grouped answer',
        () async {
          final chat = conversation([
            tool(AgentTools.askUser, form(['equipment'])),
            tool(AgentTools.showPlan, plan()),
          ]);
          final first = await chat.send('在家，10 分钟，排个髋部放松计划');
          expect(first!.question!.fields.map((f) => f.key), ['equipment']);
          final id = chat.state.pendingQuestion!.id;
          final result = await chat.answerForm(id, {
            'equipment': ['瑜伽垫'],
          });
          expect(result!.plan, isNotNull);
          expect(chat.agent.turnCount, 2);
          expect(chat.agent.questionsAsked, 0);
          expect(
            await chat.answerForm(id, {
              'equipment': ['瑜伽垫'],
            }),
            isNull,
          );
        },
      );
      test('three missing: all groups in one round, no follow-up', () async {
        final chat = conversation([
          tool(AgentTools.askUser, form(['scene', 'equipment', 'minutes'])),
          tool(AgentTools.showPlan, plan()),
        ]);
        final first = await chat.send('帮我排个髋部放松训练组');
        expect(first!.question!.fields, hasLength(3));
        final result = await chat.answerForm(chat.state.pendingQuestion!.id, {
          'scene': ['家里'],
          'equipment': ['瑜伽垫'],
          'minutes': ['10 分钟'],
        });
        expect(result!.plan, isNotNull);
        expect(chat.agent.turnCount, 2);
        expect(chat.state.pendingQuestion, isNull);
      });
      test('skip: produces default bodyweight plan on next turn', () async {
        final bodyweight = plan()..['equipment'] = <String>[];
        bodyweight['targetMinutes'] = 12;
        bodyweight['blocks'] = [
          {
            'type': 'main',
            'items': [
              {
                'exerciseId': 'h-squat',
                'mode': 'reps',
                'sets': 3,
                'reps': 12,
                'perSide': false,
                'restSeconds': 30,
              },
              {
                'exerciseId': 'n-pelvis-circle',
                'mode': 'time',
                'sets': 4,
                'workSeconds': 120,
                'perSide': false,
                'restSeconds': 20,
              },
            ],
          },
        ];
        final chat = conversation([
          tool(AgentTools.askUser, form(['scene', 'equipment', 'minutes'])),
          tool(AgentTools.showPlan, bodyweight),
        ]);
        await chat.send('帮我排个训练组');
        final result = await chat.skipQuestion(chat.state.pendingQuestion!.id);
        expect(result!.plan, isNotNull);
        expect(result.plan!.plan.targetMinutes, 12);
        expect(
          result.plan!.plan.items.every(
            (item) => catalog[item.exerciseId]!.equipment.isEmpty,
          ),
          isTrue,
        );
        expect(chat.agent.turnCount, 2);
      });
    },
  );

  test(
    'missing three but premature show_plan is repaired into one complete form',
    () async {
      for (final request in ['帮我做个训练组', '帮我推荐一套全身训练']) {
        final chat = conversation([
          tool(AgentTools.showPlan, plan()),
          tool(AgentTools.askUser, form(['scene', 'equipment', 'minutes'])),
        ]);
        final result = await chat.send(request);
        expect(result!.plan, isNull);
        expect(result.question!.fields, hasLength(3));
        expect(result.records.first.outcome, CallOutcome.rejected);
      }
    },
  );
  test(
    'legacy one-field ask cannot consume the only round when three training parameters are missing',
    () async {
      final chat = conversation([
        tool(AgentTools.askUser, {
          'question': '准备多久？',
          'mode': 'choice',
          'options': ['5 分钟', '10 分钟'],
        }),
        tool(AgentTools.askUser, form(['scene', 'equipment', 'minutes'])),
      ]);
      final result = await chat.send('帮我做个训练组');
      expect(result!.question!.mode, AskUserMode.form);
      expect(chat.agent.questionsAsked, 1);
      expect(result.records.first.outcome, CallOutcome.rejected);
    },
  );
  test(
    'skip defaults are enforced, rather than admitting undeclared gear or a different duration',
    () async {
      final chat = conversation([
        tool(AgentTools.askUser, form(['scene', 'equipment', 'minutes'])),
        tool(AgentTools.showPlan, plan()),
        '按默认重新安排',
      ]);
      await chat.send('帮我做个训练组');
      final result = await chat.skipQuestion(chat.state.pendingQuestion!.id);
      expect(result!.plan, isNull);
      expect(result.question, isNull);
    },
  );

  test(
    'negative equipment and latest explicit correction do not grant gear',
    () {
      expect(infer('在家，没什么器械，十五分钟').missing, isEmpty);
      expect(infer('在家，没什么器械，十五分钟').context.minutes, 15);
      expect(infer('在家，没有哑铃，只有瑜伽垫，10分钟').context.equipment, {'mat'});
      expect(infer('不用椅子').context.equipment, isNull);
      expect(infer('不用椅子').missing, contains('equipment'));
      expect(
        infer(
          '不用椅子',
          const CoachContext(equipment: {'mat', 'chair'}),
        ).context.equipment,
        {'mat'},
      );
      expect(infer('我在家，不去健身房，徒手10分钟排个计划').context.scene, 'home');
      final changed = infer(
        '改为办公室，徒手，5 分钟',
        const CoachContext(scene: 'home', equipment: {'mat'}, minutes: 10),
      );
      expect(changed.context.scene, 'office');
      expect(changed.context.equipment, isEmpty);
      expect(changed.context.minutes, 5);
    },
  );
  test(
    'known training parameters do not suppress clarification for ordinary action search',
    () async {
      final chat = conversation([
        tool(AgentTools.askUser, {
          'question': '想放松哪个部位？',
          'mode': 'choice',
          'options': ['肩颈', '髋部'],
        }),
      ]);
      final result = await chat.send(
        '帮我找个放松动作',
        context: const CoachContext(
          scene: 'home',
          equipment: {'mat'},
          minutes: 10,
        ),
      );
      expect(result!.question!.mode, AskUserMode.choice);
    },
  );
  test(
    'final admission rejects equipment, scene, duration label and actual dose conflicts',
    () async {
      for (final text in ['在家徒手10分钟', '在办公室有瑜伽垫10分钟', '在家有瑜伽垫20分钟']) {
        final chat = conversation([
          tool(AgentTools.showPlan, plan()),
          '没有合适方案',
        ]);
        final result = await chat.send(text);
        expect(result!.plan, isNull, reason: text);
      }
      final tooShort = plan();
      tooShort['blocks'] = [
        {
          'type': 'main',
          'items': [
            {
              'exerciseId': 'h-knee-hug',
              'mode': 'time',
              'sets': 1,
              'workSeconds': 10,
              'perSide': false,
              'restSeconds': 0,
            },
          ],
        },
      ];
      final chat = conversation([tool(AgentTools.showPlan, tooShort), '重新安排']);
      final result = await chat.send('在家有瑜伽垫10分钟');
      expect(result!.plan, isNull);
    },
  );
  test(
    'known parameters cannot be asked again; action instruction needs no form',
    () async {
      final chat = conversation([
        tool(AgentTools.askUser, form(['equipment'])),
        tool(AgentTools.showPlan, plan()),
      ]);
      final result = await chat.send('在家有瑜伽垫10分钟排个计划');
      expect(result!.question, isNull);
      expect(result.plan, isNotNull);
      final instruction = conversation(['保持骨盆稳定，轻柔活动。']);
      expect((await instruction.send('四字拉伸怎么做'))!.question, isNull);
    },
  );
  test(
    'malformed grouped fields, incompatible modes and unknown equipment are rejected',
    () async {
      final bad = [
        {
          ...form(['scene']),
          'fields': [],
        },
        {
          ...form(['scene']),
          'options': ['A', 'B'],
        },
        form(['scene', 'scene']),
        {
          ...form(['scene']),
          'skipLabel': '别的文案',
        },
      ];
      for (final value in bad) {
        expect(AskUserGate.check(jsonEncode(value)).ok, isFalse);
      }
      final unknown = form(['equipment']);
      ((unknown['fields'] as List).single as Map)['options'] = ['徒手', '虚构器械'];
      final chat = conversation([
        tool(AgentTools.askUser, unknown),
        tool(AgentTools.askUser, form(['equipment'])),
      ]);
      expect(
        (await chat.send('在家10分钟做个训练组'))!.question!.fields.single.options,
        ['徒手', '瑜伽垫'],
      );
    },
  );
}
