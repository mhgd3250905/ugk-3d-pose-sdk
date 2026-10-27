import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/training_confirmation.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmResponse _tool(String name, Map<String, Object?> args) => LlmResponse(
  content: '',
  toolCalls: [LlmToolCall(id: 'test', name: name, arguments: jsonEncode(args))],
);

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('hiplab');
  CoachAgent agent(
    FakeLlmClient client, {
    SessionFallback? fallback,
    UserMemoryStore? memoryStore,
    bool memory = false,
  }) {
    final a = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      fallback: fallback,
      enableUserMemory: memory,
      memoryStore: memoryStore,
      maxRequestRetries: 0,
    );
    addTearDown(a.dispose);
    return a;
  }

  AskUserField field(AskUserQuestion q, String key) =>
      q.fields.firstWhere((f) => f.key == key);

  test(
    'new focus resets old host fields but displays them as previous',
    () async {
      final client = FakeLlmClient(['无法提供', '无法提供']);
      final a = agent(client);
      await a.send('在家徒手10分钟做一个训练计划');
      final result = await a.send(
        '练练大腿内侧',
        context: const CoachContext(
          scene: 'home',
          equipment: {'mat'},
          minutes: 10,
          avoid: {'knee'},
          level: 2,
          goal: 'core',
          notes: ['screening-kept'],
        ),
      );
      final q = result.question!;
      expect(q.isConfirmation, isTrue);
      expect(q.focus, '大腿内侧');
      expect(q.fields.map((f) => f.key), ['scene', 'equipment', 'minutes']);
      expect(field(q, 'scene').previousSelections, ['家里']);
      expect(field(q, 'equipment').previousSelections, ['瑜伽垫']);
      expect(field(q, 'minutes').previousSelections, ['10 分钟']);
      expect(a.lastConfirmedForm, isNull);
      await a.send(
        '确认',
        context: const CoachContext(
          avoid: {'knee'},
          level: 2,
          goal: 'core',
          notes: ['screening-kept'],
        ),
        confirmedForm: {
          'scene': ['家里'],
          'equipment': ['徒手'],
          'minutes': ['5 分钟'],
        },
      );
      final prompt = client.requests.last.messages.first.content;
      expect(prompt, contains('"avoid":["knee"]'));
      expect(prompt, contains('"level":2'));
      expect(prompt, contains('"goal":"core"'));
      expect(prompt, contains('screening-kept'));
      expect(a.lastConfirmedForm!['minutes'], ['5 分钟']);
    },
  );

  test('editing the current plan retains its original conditions', () async {
    final client = FakeLlmClient(['无法提供', '无法提供']);
    final a = agent(client);
    await a.send('在家徒手10分钟做一个训练计划');
    await a.send('把这个计划改成15分钟');
    final prompt = client.requests.last.messages.first.content;
    expect(prompt, contains('"scene":"home"'));
    expect(prompt, contains('"equipment":[]'));
    expect(prompt, contains('"minutes":15'));
  });

  test('a new objective resets conditions without the word plan', () async {
    final client = FakeLlmClient(['无法提供', '减脂指减少体脂。']);
    final a = agent(client);
    await a.send('在家徒手10分钟训练全身');
    final next = await a.send('我想减脂');
    expect(next.question?.isConfirmation, isTrue);
    expect(next.question?.focus, '减脂');
    expect(next.question?.fields.map((field) => field.key), [
      'scene',
      'equipment',
      'minutes',
    ]);
    final explanation = await a.send('减脂是什么');
    expect(explanation.question, isNull);
    expect(explanation.plan, isNull);
    expect(explanation.text, contains('减少体脂'));
  });

  test(
    'routine verb plus opening hips is a new plan without the word plan',
    () async {
      final a = agent(FakeLlmClient([]));
      final result = await a.send('排十分钟居家开胯');
      expect(result.question?.isConfirmation, isTrue);
      expect(result.question?.focus, '髋');
      expect(field(result.question!, 'scene').preselected, ['家里']);
      expect(field(result.question!, 'minutes').preselected, ['10 分钟']);
    },
  );

  test('unrelated chat does not consume a pending confirmation', () async {
    final a = agent(FakeLlmClient(['你好。', '无法提供该方案。']));
    final first = await a.send('想练肩颈');
    expect(first.question?.isConfirmation, isTrue);
    final chat = await a.send('你好');
    expect(chat.question, isNull);
    expect(chat.plan, isNull);
    final confirmed = await a.send(
      '确认',
      confirmedForm: {
        'scene': ['家里'],
        'equipment': ['徒手'],
        'minutes': ['10 分钟'],
      },
    );
    expect(confirmed.status, TurnStatus.ok);
    expect(a.lastConfirmedForm?['scene'], ['家里']);
    expect(a.lastConfirmedForm?['minutes'], ['10 分钟']);
  });

  test(
    'dismissing a confirmation invalidates stale structured replies',
    () async {
      final a = agent(FakeLlmClient([]));
      expect((await a.send('想练肩颈')).question, isNotNull);
      a.dismissConfirmation();
      expect(a.pendingConfirmation, isNull);
      expect(a.questionsAsked, 0);
      final stale = await a.send(
        '确认',
        confirmedForm: {
          'scene': ['家里'],
          'equipment': ['徒手'],
          'minutes': ['10 分钟'],
        },
      );
      expect(stale.status, TurnStatus.error);
      expect(stale.plan, isNull);
    },
  );

  test(
    'changing to another body region starts a new task, not a plan edit',
    () async {
      final a = agent(FakeLlmClient(['无法提供', '可以轻柔活动肩颈。']));
      await a.send('在家徒手10分钟训练全身');
      final next = await a.send('把这套换成肩颈');
      expect(next.question?.isConfirmation, isTrue);
      expect(next.question?.focus, '肩颈');
      final explain = await a.send('肩颈动作怎么做');
      expect(explain.question, isNull);
      expect(explain.plan, isNull);
    },
  );

  test(
    'a new plan can replace a pending question and gets its own budget',
    () async {
      final a = agent(FakeLlmClient([]));
      expect((await a.send('帮我做个训练组')).question, isNotNull);
      final result = await a.send('再做一套新训练组');
      expect(result.question?.fields.map((f) => f.key), [
        'scene',
        'equipment',
        'minutes',
      ]);
      expect(a.questionsAsked, 1);
    },
  );

  for (final enabled in [false, true]) {
    test('memory values are suggestions only when enabled=$enabled', () async {
      final store = InMemoryUserMemoryStore([
        MemoryEntry(MemoryKind.scene, '在家', at: DateTime.utc(2026)),
        MemoryEntry(MemoryKind.equipment, '有瑜伽垫', at: DateTime.utc(2026)),
        MemoryEntry(MemoryKind.schedule, '10分钟', at: DateTime.utc(2026)),
      ]);
      final a = agent(FakeLlmClient([]), memoryStore: store, memory: enabled);
      final q = (await a.send('帮我练练髋部')).question!;
      expect(q.fields.length, 3);
      expect(field(q, 'scene').previousSelections, enabled ? ['家里'] : isEmpty);
      expect(
        field(q, 'equipment').previousSelections,
        enabled ? ['瑜伽垫'] : isEmpty,
      );
      expect(
        field(q, 'minutes').previousSelections,
        enabled ? ['10 分钟'] : isEmpty,
      );
    });
  }

  test('scene equipment follows actual eligible catalog actions', () async {
    final smart = loadProfile('smartfit');
    for (final sample in [
      ('在家有哑铃做肩部训练', '家里', catalog.taxonomy.equipmentLabel('dumbbell')),
      ('在办公室有弹力带做肩部训练', '办公室', catalog.taxonomy.equipmentLabel('band')),
    ]) {
      final a = CoachAgent(
        client: FakeLlmClient([]),
        catalog: () => catalog,
        profile: smart,
        enableUserMemory: false,
      );
      addTearDown(a.dispose);
      final q = (await a.send(sample.$1)).question!;
      final equipment = field(q, 'equipment');
      expect(equipment.optionsByScene[sample.$2], contains(sample.$3));
      expect(equipment.preselected, contains(sample.$3));
      expect(q.defaultSelections['equipment'], contains(sample.$3));
    }
  });

  test(
    'explicit scene equipment stays selectable and defaults validate',
    () async {
      final a = CoachAgent(
        client: FakeLlmClient([]),
        catalog: () => catalog,
        profile: loadProfile('smartfit'),
        enableUserMemory: false,
      );
      addTearDown(a.dispose);
      final q = (await a.send('在办公室有瑜伽垫做肩部训练')).question!;
      final equipment = field(q, 'equipment');
      expect(equipment.optionsByScene['办公室'], contains('瑜伽垫'));
      expect(equipment.preselected, ['瑜伽垫']);
      expect(
        confirmedTrainingContext(
          q,
          q.defaultSelections,
          const CoachContext(),
          catalog,
        ),
        isNotNull,
      );
    },
  );

  test(
    'generic non-training plans and chat do not open confirmation',
    () async {
      final a = agent(FakeLlmClient(['可以聊聊旅行。', '你好。']));
      for (final text in ['帮我做旅行计划', '聊聊你今天的计划']) {
        final result = await a.send(text);
        expect(result.question, isNull);
        expect(result.plan, isNull);
      }
    },
  );

  test('a mismatched preset does not match merely because one action does', () {
    final plan = const EnvelopeParser()
        .parse(jsonEncode(okEnvelope()))
        .reply!
        .plan!;
    expect(presetMatchesFocus(plan, catalog, '大腿内侧'), isFalse);
  });

  test('common preset focuses use trusted catalog muscle groups', () {
    for (final sample in [
      ('肩颈', 'h-band-pull-apart'),
      ('小腿', 'h-calf-raise'),
      ('小腿', 'h-tib-raise'),
      ('腰部', 'erectors-A'),
    ]) {
      final envelope = okEnvelope();
      itemOf(envelope, 0, 0)['exerciseId'] = sample.$2;
      planOf(envelope)['blocks'] = [blocksOf(envelope).first];
      final plan = const EnvelopeParser()
          .parse(jsonEncode(envelope))
          .reply!
          .plan!;
      expect(
        presetMatchesFocus(plan, catalog, sample.$1),
        isTrue,
        reason: sample.$2,
      );
      expect(presetMatchesFocus(plan, catalog, '未知重点'), isFalse);
    }
  });

  test(
    'failed planning preserves confirmation and offers only a matching preset',
    () async {
      final client = FakeLlmClient([
        const LlmException(LlmErrorKind.network, 'offline'),
      ]);
      final a = agent(client);
      final failed = await a.send('在家有瑜伽垫5分钟训练大腿内侧');
      expect(failed.status, TurnStatus.error);
      expect(a.lastConfirmedForm!['minutes'], ['5 分钟']);

      final wrong = const EnvelopeParser()
          .parse(jsonEncode(okEnvelope()))
          .reply!
          .plan!;
      expect(a.canOfferPreset(wrong), isFalse);
      expect(a.requestPreset(wrong), isNull);

      final envelope = okEnvelope();
      final data = planOf(envelope);
      data['targetMinutes'] = 5;
      data['blocks'] = [
        {
          'id': 'main',
          'name': '主训练',
          'type': 'main',
          'rounds': 1,
          'restBetweenRoundsSeconds': 0,
          'items': [
            {
              'exerciseId': 's-butterfly',
              'mode': 'time',
              'sets': 6,
              'workSeconds': 45,
              'perSide': false,
              'restSeconds': 10,
            },
          ],
        },
      ];
      final matching = const EnvelopeParser()
          .parse(jsonEncode(envelope))
          .reply!
          .plan!;
      expect(a.canOfferPreset(matching), isTrue);
      final selected = a.requestPreset(matching);
      expect(selected?.plan, isNotNull);
      expect(selected?.text, contains('5分钟'));
    },
  );

  test(
    'a shorter edit preserves scene and gear without locking old duration',
    () async {
      final first = planOf(okEnvelope())..remove('source');
      final shorter = planOf(okEnvelope())
        ..remove('source')
        ..['targetMinutes'] = 5;
      final blocks = shorter['blocks']! as List;
      blocks.removeAt(0);
      final mainItems = ((blocks.first as Map)['items']! as List);
      mainItems.removeRange(2, mainItems.length);
      final client = FakeLlmClient([
        _tool(AgentTools.showPlan, first),
        (LlmRequest request) {
          final system = request.messages.first.content;
          expect(system, contains('目标时长必须小于10分钟'));
          expect(system, contains('偏差不超过25%'));
          expect(system, isNot(contains('"minutes":10')));
          expect(system, contains('"scene":"home"'));
          return _tool(AgentTools.showPlan, shorter);
        },
      ]);
      final a = agent(client);
      final original = await a.send('在家有瑜伽垫10分钟做开髋训练计划');
      expect(original.plan, isNotNull);
      final result = await a.send('短一点');
      expect(result.question, isNull);
      expect(result.plan?.plan.targetMinutes, 5);
      expect(result.plan?.plan.scene, 'home');
      expect(a.lastConfirmedForm?['minutes'], ['5 分钟']);
    },
  );

  test('a longer edit requires a larger target without asking again', () async {
    final first = planOf(okEnvelope())..remove('source');
    final longer = planOf(okEnvelope())
      ..remove('source')
      ..['targetMinutes'] = 15;
    final blocks = longer['blocks']! as List;
    final items = ((blocks[1] as Map)['items']! as List);
    (items[1] as Map)['sets'] = 4;
    (items[3] as Map)['sets'] = 3;
    final client = FakeLlmClient([
      _tool(AgentTools.showPlan, first),
      (LlmRequest request) {
        final system = request.messages.first.content;
        expect(system, contains('目标时长必须大于10分钟'));
        expect(system, isNot(contains('"minutes":10')));
        return _tool(AgentTools.showPlan, longer);
      },
    ]);
    final a = agent(client);
    expect((await a.send('在家有瑜伽垫10分钟做开髋训练计划')).plan, isNotNull);
    final result = await a.send('长一点');
    expect(result.question, isNull);
    expect(result.plan?.plan.targetMinutes, 15);
  });

  test('explicit plan with an explanation request remains planning', () async {
    final a = agent(
      FakeLlmClient([
        _tool(AgentTools.showPlan, planOf(okEnvelope())..remove('source')),
      ]),
    );
    final result = await a.send('在家有瑜伽垫10分钟给我做个髋部训练计划，并说明怎么练');
    expect(result.question, isNull);
    expect(result.plan, isNotNull);
  });

  test('model plan must include the reliable requested focus', () async {
    final data = planOf(okEnvelope())..remove('source');
    final blocks = data['blocks']! as List;
    final items = ((blocks[1] as Map)['items']! as List);
    items.removeWhere((item) => (item as Map)['exerciseId'] == 's-butterfly');
    final a = agent(
      FakeLlmClient([_tool(AgentTools.showPlan, data), '无法提供合适方案。']),
    );
    final result = await a.send('在家有瑜伽垫10分钟做大腿内侧训练计划');
    expect(result.plan, isNull);
    expect(result.records.first.issueCodes, contains('focus_conflict'));
  });

  test(
    'plan summary describes only performed segments, not the parent',
    () async {
      final data = planOf(okEnvelope())
        ..remove('source')
        ..['targetMinutes'] = 5
        ..['equipment'] = <String>[]
        ..['blocks'] = [
          {
            'id': 'b',
            'name': '主训练',
            'type': 'main',
            'rounds': 1,
            'restBetweenRoundsSeconds': 0,
            'items': [
              {
                'exerciseId': 'n-windshield',
                'mode': 'reps',
                'sets': 6,
                'reps': 8,
                'perSide': false,
                'restSeconds': 10,
                'segments': [
                  {
                    'id': 'work',
                    'exerciseId': 'h-squat',
                    'mode': 'reps',
                    'reps': 12,
                  },
                ],
              },
            ],
          },
        ];
      final a = agent(FakeLlmClient([_tool(AgentTools.showPlan, data)]));
      final result = await a.send('在家有瑜伽垫5分钟做训练计划');
      expect(result.plan, isNotNull);
      expect(result.text, contains('器械：徒手'));
      expect(result.text, isNot(contains('瑜伽垫')));
    },
  );

  test('red flags are not suppressed and explicit denial is not a flag', () {
    expect(hasTrainingRedFlag('肩颈刺痛、手麻木'), isTrue);
    expect(hasTrainingRedFlag('没有刺痛、没有麻木'), isFalse);
  });

  test('red flags never open a plan confirmation', () async {
    final a = agent(FakeLlmClient(['建议就医检查。']));
    final result = await a.send('肩颈刺痛，给我做训练计划');
    expect(result.question, isNull);
    expect(result.plan, isNull);
    expect(result.text, contains('就医'));
  });

  test('red flags reject action cards while allowing safety advice', () async {
    final a = agent(
      FakeLlmClient([
        _tool(AgentTools.showActions, {
          'items': [
            {'actionId': 's-figure4'},
          ],
        }),
        '建议先咨询医生。',
      ]),
    );
    final result = await a.send('腿麻，推荐动作');
    expect(result.actions, isNull);
    expect(result.question, isNull);
    expect(result.text, contains('医生'));
    expect(result.records.first.issueCodes, contains('safety_no_actions'));
  });

  test('retry retains safety exclusions when the host omits them', () async {
    final data = planOf(okEnvelope())
      ..remove('source')
      ..['targetMinutes'] = 5
      ..['equipment'] = <String>[]
      ..['blocks'] = [
        {
          'id': 'b',
          'name': '主训练',
          'type': 'main',
          'rounds': 1,
          'restBetweenRoundsSeconds': 0,
          'items': [
            {
              'exerciseId': 'h-sumo-pry',
              'mode': 'time',
              'sets': 6,
              'workSeconds': 45,
              'perSide': false,
              'restSeconds': 10,
            },
          ],
        },
      ];
    final client = FakeLlmClient([
      const LlmException(LlmErrorKind.network, 'offline'),
      _tool(AgentTools.showPlan, data),
      '无法提供安全方案。',
    ]);
    final a = agent(client);
    expect(
      (await a.send(
        '在家徒手5分钟训练大腿内侧',
        context: const CoachContext(avoid: {'膝'}),
      )).status,
      TurnStatus.error,
    );
    final retry = await a.send('重试');
    expect(retry.plan, isNull);
    expect(retry.records.first.issueCodes, contains(IssueCodes.avoid));
  });

  test('red flags persist across tasks until an explicit correction', () async {
    final a = agent(FakeLlmClient(['建议先就医。', '请先咨询医生。']));
    expect((await a.send('腿麻，想做训练计划')).question, isNull);
    final blocked = await a.send('那给我排个训练计划');
    expect(blocked.question, isNull);
    expect(blocked.plan, isNull);
    final corrected = await a.send('刚才说错了，没有腿麻，请给我做训练计划');
    expect(corrected.question?.isConfirmation, isTrue);
  });

  test('unadmitted fallback plan is an error, never successful text', () async {
    final envelope = okEnvelope();
    planOf(envelope)['scene'] = 'gym';
    final invalid = const EnvelopeParser()
        .parse(jsonEncode(envelope))
        .reply!
        .plan!;
    final a = agent(
      FakeLlmClient([const LlmException(LlmErrorKind.network, 'offline')]),
      fallback: (_) => SessionFallbackReply('方案已生成', plan: invalid),
    );
    final result = await a.send('你好');
    expect(result.status, TurnStatus.error);
    expect(result.plan, isNull);
    expect(result.text, isEmpty);
  });

  test('a text-only fallback remains available outside planning', () async {
    final a = agent(
      FakeLlmClient([const LlmException(LlmErrorKind.network, 'offline')]),
      fallback: (_) => const SessionFallbackReply('请稍后再试'),
    );
    final result = await a.send('你好');
    expect(result.status, TurnStatus.fallback);
    expect(result.text, '请稍后再试');
  });
}
