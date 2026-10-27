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
Map<String, Object?> userValue(Object value, String quote) => {
  'value': value,
  'source': 'user',
  'quote': quote,
};
Map<String, Object?> defaultValue(Object value) => {
  'value': value,
  'source': 'default',
};
LlmResponse setParams(Map<String, Object?> fields) =>
    tool(AgentTools.setParams, {'fields': fields});

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
        final chat = conversation([
          setParams({
            'scene': userValue('home', '在家'),
            'equipment': userValue(['equip.mat'], '瑜伽垫'),
            'minutes': userValue(10, '10 分钟'),
          }),
          tool(AgentTools.showPlan, plan()),
        ]);
        final result = await chat.send('在家，有瑜伽垫，10 分钟，排个髋部放松计划');
        expect(result!.plan, isNotNull);
        expect(result.question, isNull);
        expect(chat.agent.turnCount, 1);
        expect(chat.agent.sessionState.params['equipment']!.value, [
          'equip.mat',
        ]);
      });
      test(
        'model asks only for missing equipment and uses the grouped answer',
        () async {
          final chat = conversation([
            setParams({
              'scene': userValue('home', '在家'),
              'minutes': userValue(10, '10 分钟'),
            }),
            tool(AgentTools.askUser, form(['equipment'])),
            setParams({
              'equipment': userValue(['equip.mat'], '瑜伽垫'),
            }),
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
          setParams({
            'scene': userValue('home', '家里'),
            'equipment': userValue(['equip.mat'], '瑜伽垫'),
            'minutes': userValue(10, '10 分钟'),
          }),
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
          setParams({
            'scene': defaultValue('home'),
            'equipment': defaultValue(<String>[]),
            'minutes': defaultValue(12),
          }),
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

  test('model can request all missing parameters in one form', () async {
    for (final request in ['帮我做个训练组', '帮我推荐一套全身训练']) {
      final chat = conversation([
        tool(AgentTools.askUser, form(['scene', 'equipment', 'minutes'])),
      ]);
      final result = await chat.send(request);
      expect(result!.plan, isNull);
      expect(result.question!.fields, hasLength(3));
      expect(result.records, isNotEmpty);
    }
  });
  test(
    'model chooses its own question mode when parameters are missing',
    () async {
      final chat = conversation([
        tool(AgentTools.askUser, {
          'question': '准备多久？',
          'mode': 'choice',
          'options': ['5 分钟', '10 分钟'],
        }),
      ]);
      final result = await chat.send('帮我做个训练组');
      expect(result!.question!.mode, AskUserMode.choice);
      expect(chat.agent.questionsAsked, 1);
      expect(result.records, isNotEmpty);
    },
  );
  test(
    'skip defaults are enforced, rather than admitting undeclared gear or a different duration',
    () async {
      final chat = conversation([
        tool(AgentTools.askUser, form(['scene', 'equipment', 'minutes'])),
        setParams({
          'scene': defaultValue('home'),
          'equipment': defaultValue(<String>[]),
          'minutes': defaultValue(12),
        }),
        tool(AgentTools.showPlan, plan()),
        '无法提供该方案',
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
  test('model can ask a clarification during action search', () async {
    final chat = conversation([
      tool(AgentTools.askUser, {
        'question': '想放松哪个部位？',
        'mode': 'choice',
        'options': ['肩颈', '髋部'],
      }),
      '先告诉我需要哪个动作。',
    ]);
    final result = await chat.send(
      '帮我找个放松动作',
      context: const CoachContext(
        scene: 'home',
        equipment: {'mat'},
        minutes: 10,
      ),
    );
    expect(result!.question, isNotNull);
    expect(result.plan, isNull);
  });
  test(
    'final admission rejects equipment, scene, duration label and actual dose conflicts',
    () async {
      for (final text in ['在家徒手10分钟做计划', '在办公室有瑜伽垫10分钟做计划', '在家有瑜伽垫20分钟做计划']) {
        final chat = conversation([
          tool(AgentTools.showPlan, plan()),
          '无法提供合适方案',
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
      final chat = conversation([
        tool(AgentTools.showPlan, tooShort),
        '无法提供方案',
      ]);
      final result = await chat.send('在家有瑜伽垫10分钟做计划');
      expect(result!.plan, isNull);
    },
  );
  test(
    'known host conditions are recorded and model may answer without a form',
    () async {
      final chat = conversation([tool(AgentTools.showPlan, plan())]);
      final result = await chat.send(
        '帮我排个髋部放松训练计划',
        context: const CoachContext(
          scene: 'home',
          equipment: {'mat'},
          minutes: 10,
        ),
      );
      expect(chat.agent.sessionState.params['minutes']!.value, 10);
      expect(chat.agent.sessionState.params['equipment']!.value, ['equip.mat']);
      expect(result!.question, isNull);
      expect(
        result.plan,
        isNotNull,
        reason: '${result.issues}; ${result.error}',
      );
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
      final chat = conversation([
        tool(AgentTools.askUser, form(['scene', 'equipment', 'minutes'])),
      ]);
      final question = (await chat.send('在家10分钟做个训练组'))!.question!;
      final equipment = question.fields.firstWhere(
        (field) => field.key == 'equipment',
      );
      expect(equipment.options, isNot(contains('虚构器械')));
      expect(
        await chat.answerForm(chat.state.pendingQuestion!.id, {
          'scene': ['家里'],
          'equipment': ['虚构器械'],
          'minutes': ['10 分钟'],
        }),
        isNull,
      );
    },
  );
}
