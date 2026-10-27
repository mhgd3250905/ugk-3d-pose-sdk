import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/training_confirmation.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmResponse _tool(String name, Map<String, Object?> args) => LlmResponse(
  content: '',
  toolCalls: [LlmToolCall(id: 'test', name: name, arguments: jsonEncode(args))],
);

LlmResponse _set(Map<String, Object?> fields) =>
    _tool(AgentTools.setParams, {'fields': fields});

Map<String, Object?> _user(Object value, String quote) => {
  'value': value,
  'source': 'user',
  'quote': quote,
};

LlmResponse _ask([String question = '准备在哪儿练？']) => _tool(AgentTools.askUser, {
  'question': question,
  'mode': 'form',
  'fields': [
    {
      'key': 'scene',
      'label': '场景',
      'options': ['家里', '办公室'],
    },
    {
      'key': 'equipment',
      'label': '器械',
      'options': ['徒手', '瑜伽垫'],
      'multiple': true,
    },
    {
      'key': 'minutes',
      'label': '时长',
      'options': ['5 分钟', '10 分钟'],
    },
  ],
});

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

  test('new focus retains host conditions and safety restrictions', () async {
    final client = FakeLlmClient([
      '已记录条件。',
      _set({
        'goal': _user(['body.inner_thigh'], '大腿内侧'),
      }),
      '好的。',
    ]);
    final a = agent(client);
    await a.send(
      '想训练',
      context: const CoachContext(
        scene: 'home',
        equipment: {'mat'},
        minutes: 10,
        avoid: {'knee'},
        level: 2,
        notes: ['screening-kept'],
      ),
    );
    await a.send('练练大腿内侧');
    final params = a.sessionState.params;
    expect(params['scene']!.value, 'home');
    expect(params['equipment']!.value, ['equip.mat']);
    expect(params['minutes']!.value, 10);
    expect(params['level']!.value, 2);
    expect(params['limits']!.value, contains('limit.knee'));
    expect(params['goal']!.value, ['body.inner_thigh']);
    expect(params['goal']!.source, 'user');
  });

  test('editing current duration retains the other user conditions', () async {
    final client = FakeLlmClient([
      _set({
        'scene': _user('home', '在家'),
        'equipment': _user(<String>[], '徒手'),
        'minutes': _user(10, '10分钟'),
      }),
      '记录好了。',
      _set({'minutes': _user(15, '15分钟')}),
      '时间已更新。',
    ]);
    final a = agent(client);
    await a.send('在家徒手10分钟做一个训练计划');
    await a.send('把这个计划改成15分钟');
    expect(a.sessionState.params['scene']!.value, 'home');
    expect(a.sessionState.params['equipment']!.value, isEmpty);
    expect(a.sessionState.params['minutes']!.value, 15);
  });

  test(
    'a new objective retains known conditions and can be explained',
    () async {
      final a = agent(
        FakeLlmClient([
          _set({'scene': _user('home', '在家'), 'minutes': _user(10, '10分钟')}),
          '记录好了。',
          _set({
            'goal': _user(['purpose.stretch'], '拉伸'),
          }),
          '记下新目标。',
          '拉伸可以轻柔进行。',
        ]),
      );
      await a.send('在家10分钟训练全身');
      await a.send('我想拉伸');
      expect(a.sessionState.params['scene']!.value, 'home');
      expect(a.sessionState.params['minutes']!.value, 10);
      expect(a.sessionState.params['goal']!.value, ['purpose.stretch']);
      final explanation = await a.send('拉伸是什么');
      expect(explanation.question, isNull);
      expect(explanation.plan, isNull);
      expect(explanation.text, contains('轻柔'));
    },
  );

  test(
    'model may ask about a routine without local confirmation injection',
    () async {
      final a = agent(FakeLlmClient([_ask()]));
      final result = await a.send('排十分钟居家开胯');
      expect(result.question!.mode, AskUserMode.form);
      expect(result.question!.isConfirmation, isFalse);
      expect(a.pendingConfirmation, same(result.question));
    },
  );

  test(
    'unrelated chat retains a pending model question until parameter progress',
    () async {
      final a = agent(
        FakeLlmClient([
          _ask(),
          '你好。',
          _set({'minutes': _user(10, '10分钟')}),
          '记下时间。',
        ]),
      );
      final first = await a.send('想练肩颈');
      final chat = await a.send('你好');
      expect(chat.question, isNull);
      expect(chat.plan, isNull);
      expect(a.pendingConfirmation, same(first.question));
      await a.send('10分钟');
      expect(a.sessionState.params['minutes']!.value, 10);
      expect(a.pendingConfirmation, isNull);
    },
  );

  test('dismissing a question invalidates stale structured replies', () async {
    final a = agent(FakeLlmClient([_ask()]));
    expect((await a.send('想练肩颈')).question, isNotNull);
    a.dismissConfirmation();
    expect(a.pendingConfirmation, isNull);
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
  });

  test('changing body focus retains known context across turns', () async {
    final a = agent(
      FakeLlmClient([
        _set({'scene': _user('home', '在家'), 'minutes': _user(10, '10分钟')}),
        '已记录。',
        _ask('肩颈有不适吗？'),
        '可以轻柔活动肩颈。',
      ]),
    );
    await a.send('在家10分钟训练全身');
    final next = await a.send('把这套换成肩颈');
    expect(next.question!.question, '肩颈有不适吗？');
    expect(a.sessionState.params['scene']!.value, 'home');
    expect(a.sessionState.params['minutes']!.value, 10);
    final explain = await a.send('肩颈动作怎么做');
    expect(explain.question, isNull);
    expect(explain.plan, isNull);
  });

  test(
    'new model question replaces pending question without a round limit',
    () async {
      final a = agent(
        FakeLlmClient([
          _ask('第一个问题？'),
          _ask('第二个问题？'),
          _ask('第三个问题？'),
          _ask('第四个问题？'),
        ]),
      );
      final first = (await a.send('帮我做个训练组')).question!;
      final second = (await a.send('再做一套新训练组')).question!;
      expect(second.question, '第二个问题？');
      expect(second, isNot(same(first)));
      expect(a.pendingConfirmation, same(second));
      expect((await a.send('在家')).question!.question, '第三个问题？');
      final fourth = (await a.send('十分钟')).question!;
      expect(fourth.question, '第四个问题？');
      expect(a.pendingConfirmation, same(fourth));
    },
  );

  for (final enabled in [false, true]) {
    test(
      'memory is visible only when enabled and does not set conditions: $enabled',
      () async {
        final store = InMemoryUserMemoryStore([
          MemoryEntry(MemoryKind.scene, '在家', at: DateTime.utc(2026)),
          MemoryEntry(MemoryKind.equipment, '有瑜伽垫', at: DateTime.utc(2026)),
          MemoryEntry(MemoryKind.schedule, '10分钟', at: DateTime.utc(2026)),
        ]);
        final client = FakeLlmClient([_ask()]);
        final a = agent(client, memoryStore: store, memory: enabled);
        await a.send('帮我练练髋部');
        final system = client.requests.single.messages.first.content;
        expect(system.contains('有瑜伽垫'), enabled);
        expect(a.sessionState.params.containsKey('equipment'), isFalse);
      },
    );
  }

  test(
    'reported equipment enters ledger only from current user quotation',
    () async {
      for (final sample in [
        ('在家有哑铃', 'home', '哑铃', 'equip.dumbbell'),
        ('在办公室有弹力带', 'office', '弹力带', 'equip.band'),
      ]) {
        final a = CoachAgent(
          client: FakeLlmClient([
            _set({
              'scene': _user(sample.$2, sample.$1),
              'equipment': _user([sample.$4], sample.$3),
            }),
            '记录好了。',
          ]),
          catalog: () => catalog,
          profile: loadProfile('smartfit'),
          enableUserMemory: false,
        );
        addTearDown(a.dispose);
        await a.send(sample.$1);
        expect(a.sessionState.params['scene']!.value, sample.$2);
        expect(a.sessionState.params['equipment']!.value, [sample.$4]);
        expect(a.sessionState.params['equipment']!.source, 'user');
      }
    },
  );

  test(
    'explicit equipment answer is recorded, without assumed scene equipment',
    () async {
      final a = agent(
        FakeLlmClient([
          _ask(),
          _set({
            'equipment': _user(['equip.mat'], '瑜伽垫'),
          }),
          '记下瑜伽垫。',
        ]),
      );
      final question = (await a.send('在办公室训练')).question!;
      final equipment = question.fields.firstWhere((f) => f.key == 'equipment');
      expect(equipment.options, contains('瑜伽垫'));
      expect(a.sessionState.params.containsKey('equipment'), isFalse);
      await a.send('我有瑜伽垫');
      expect(a.sessionState.params['equipment']!.value, ['equip.mat']);
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
          expect(system, contains('减少实际估时'));
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
    final a = agent(FakeLlmClient(['建议先就医。', '请先咨询医生。', _ask()]));
    expect((await a.send('腿麻，想做训练计划')).question, isNull);
    final blocked = await a.send('那给我排个训练计划');
    expect(blocked.question, isNull);
    expect(blocked.plan, isNull);
    final corrected = await a.send('刚才说错了，没有腿麻，请给我做训练计划');
    expect(corrected.question?.mode, AskUserMode.form);
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
