import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_tags.dart';
import 'package:ugk_coach/src/agent/session_params.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmToolCall _set(String id, Map<String, Object?> fields) => LlmToolCall(
  id: id,
  name: AgentTools.setParams,
  arguments: jsonEncode({'fields': fields}),
);

LlmResponse _tools(List<LlmToolCall> calls) => LlmResponse(
  content: '',
  toolCalls: calls,
  finishReason: 'tool_calls',
  model: 'fake',
);

Map<String, Object?> _user(Object? value, String quote) => {
  'value': value,
  'source': 'user',
  'quote': quote,
};

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('smartfit');

  CoachAgent agent(FakeLlmClient client) {
    final coach = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      enableUserMemory: false,
      maxRequestRetries: 0,
    );
    addTearDown(coach.dispose);
    return coach;
  }

  test(
    'tool schema exposes only enumerated structured model sources and values',
    () {
      final tool = AgentTools.build(
        profile,
        catalog,
        memory: false,
      ).singleWhere((entry) => entry.name == AgentTools.setParams);
      final root = tool.parameters['properties']! as Map<String, Object?>;
      final fields =
          (root['fields']! as Map<String, Object?>)['properties']!
              as Map<String, Object?>;
      final goal =
          (fields['goal']! as Map<String, Object?>)['properties']!
              as Map<String, Object?>;
      final values =
          (goal['value']! as Map<String, Object?>)['items']!
              as Map<String, Object?>;
      final sources =
          (goal['source']! as Map<String, Object?>)['enum']! as List<String>;
      expect(sources, containsAll(['user', 'preselect', 'default']));
      expect(sources, isNot(contains('host')));
      expect(values['enum'], contains('body.core'));
      expect(values['enum'], contains('body.inner_thigh'));
      expect(values['enum'], contains('purpose.stretch'));
      expect(values['enum'], equals(ActionTags(profile, catalog).goalCodes));
    },
  );

  test(
    'agent exposes host time before model call and does not force a local question',
    () async {
      final client = FakeLlmClient(['我会按你提供的条件安排。'], latency: Duration.zero);
      final coach = agent(client);
      final result = await coach.send(
        '请帮我安排训练计划',
        context: const CoachContext(minutes: 20),
      );
      expect(result.question, isNull);
      expect(client.requests, hasLength(1));
      final system = client.requests.single.messages.first.content;
      expect(
        system,
        contains('"minutes":{"value":20,"source":"host","turn":0}'),
      );
      expect(coach.sessionState.params['minutes']!.value, 20);
    },
  );

  test(
    'real loop commits one set_params and rejects an invented expansion',
    () async {
      final client = FakeLlmClient([
        _tools([
          _set('mat', {
            'equipment': _user(['equip.mat'], '瑜伽垫'),
          }),
          _set('more', {
            'equipment': _user([
              'equip.mat',
              'equip.wall',
              'equip.block',
            ], '瑜伽垫'),
          }),
        ]),
        '已记录你说的条件。',
      ], latency: Duration.zero);
      final coach = agent(client);
      await coach.send('我有瑜伽垫');
      expect(coach.sessionState.params['equipment']!.value, ['equip.mat']);
      final replies = client.requests.last.messages
          .where((message) => message.role == LlmRole.tool)
          .toList();
      final mat =
          jsonDecode(
                replies
                    .singleWhere((message) => message.toolCallId == 'mat')
                    .content,
              )
              as Map<String, dynamic>;
      final more =
          jsonDecode(
                replies
                    .singleWhere((message) => message.toolCallId == 'more')
                    .content,
              )
              as Map<String, dynamic>;
      expect(mat['ok'], isTrue);
      expect(more['code'], 'equipment_not_newly_confirmed');
      expect(more['field'], 'fields.equipment.value');
    },
  );

  test(
    'replaceSafetyAvoid is host authority and cannot be removed by model',
    () async {
      final client = FakeLlmClient([
        _tools([
          _set('unsafe-clear', {'limits': _user(<String>[], '没有伤痛')}),
        ]),
        '好的。',
      ], latency: Duration.zero);
      final coach = agent(client)..replaceSafetyAvoid({'膝'});
      expect(coach.sessionState.params['limits']!.value, ['limit.knee']);
      await coach.send('现在没有伤痛');
      final response = client.requests.last.messages.singleWhere(
        (message) => message.toolCallId == 'unsafe-clear',
      );
      expect(
        (jsonDecode(response.content) as Map)['code'],
        'limits_cannot_relax',
      );
      coach.replaceSafetyAvoid({});
      expect(coach.sessionState.params['limits']!.source, 'host');
      expect(coach.sessionState.params['limits']!.value, isEmpty);
      final saved = CoachSessionState.fromJson(coach.sessionState.toJson());
      expect(saved.params['limits']!.value, isEmpty);
    },
  );

  test(
    'cancel retains explicit host updates and discards user and tool state',
    () async {
      final pendingModel = Completer<Object>();
      final client = FakeLlmClient([
        (LlmRequest _) => pendingModel.future,
      ], latency: Duration.zero);
      final coach = agent(client);
      final cancel = CancelToken();
      final pending = coach.send(
        '取消的输入',
        context: const CoachContext(minutes: 20, avoid: {'膝'}),
        cancel: cancel,
      );
      await Future<void>.delayed(Duration.zero);
      coach.replaceSafetyAvoid({'肩'});
      cancel.cancel();
      expect((await pending).status, TurnStatus.cancelled);
      expect(coach.sessionState.userTurns, isEmpty);
      expect(coach.sessionState.params['minutes']!.value, 20);
      expect(coach.sessionState.params['limits']!.value, ['limit.shoulder']);
      pendingModel.complete('迟到内容');
      await Future<void>.delayed(Duration.zero);
      expect(coach.sessionState.params['limits']!.value, ['limit.shoulder']);
    },
  );
  test('schema includes only already recorded opaque host equipment', () {
    final tags = ActionTags(profile, catalog);
    final state = SessionParams(tags)
        .applyHost(CoachSessionState(), const CoachContext(equipment: {'特殊器材'}))
        .state;
    final opaque = (state.params['equipment']!.value! as List<Object?>).single;
    final tool = AgentTools.build(
      profile,
      catalog,
      memory: false,
      sessionState: state,
    ).singleWhere((entry) => entry.name == AgentTools.setParams);
    final root = tool.parameters['properties']! as Map<String, Object?>;
    final fields =
        (root['fields']! as Map<String, Object?>)['properties']!
            as Map<String, Object?>;
    final equipment =
        (fields['equipment']! as Map<String, Object?>)['properties']!
            as Map<String, Object?>;
    final codes =
        ((equipment['value']! as Map<String, Object?>)['items']!
                as Map<String, Object?>)['enum']!
            as List<String>;
    expect(codes, contains(opaque));
    expect(codes, equals(SessionParams(tags).equipmentCodes(state)));
    expect(codes, isNot(contains(tags.equipmentCode('另一种器材'))));
  });

  test(
    'new safety protection while model is in flight reaches the gate',
    () async {
      final pendingModel = Completer<Object>();
      final client = FakeLlmClient([
        (LlmRequest _) => pendingModel.future,
        '先保护膝盖，不勉强训练。',
      ], latency: Duration.zero);
      final coach = agent(client);
      final pending = coach.send('推荐几个动作');
      await Future<void>.delayed(Duration.zero);
      coach.replaceSafetyAvoid({'knee'});
      pendingModel.complete(
        _tools([
          LlmToolCall(
            id: 'unsafe-squat',
            name: AgentTools.showActions,
            arguments: jsonEncode({
              'items': [
                {'actionId': 'h-squat'},
              ],
            }),
          ),
        ]),
      );
      final result = await pending;
      expect(result.actions, isNull);
      final feedback = client.requests.last.messages.singleWhere(
        (message) => message.toolCallId == 'unsafe-squat',
      );
      expect(feedback.content, contains('avoid'));
      expect(coach.sessionState.params['limits']!.value, ['limit.knee']);
    },
  );

  test('same-turn model parameters reach the subsequent plan gate', () async {
    final plan = {
      'schemaVersion': 1,
      'title': '髋部放松',
      'summary': '温和放松',
      'goal': 'relax',
      'scene': 'home',
      'level': 1,
      'targetMinutes': 10,
      'equipment': ['mat'],
      'blocks': [
        {
          'id': 'main',
          'name': '训练',
          'type': 'main',
          'items': [
            {
              'exerciseId': 's-kneel-hipflex',
              'mode': 'time',
              'sets': 1,
              'workSeconds': 120,
              'perSide': true,
              'restSeconds': 0,
            },
            {
              'exerciseId': 's-butterfly',
              'mode': 'time',
              'sets': 3,
              'workSeconds': 120,
              'perSide': false,
              'restSeconds': 30,
            },
          ],
        },
      ],
    };
    final client = FakeLlmClient([
      _tools([
        _set('mat', {
          'equipment': _user(['equip.mat'], 'a mat'),
        }),
      ]),
      LlmResponse(
        content: '已按你的条件安排。',
        toolCalls: [
          LlmToolCall(
            id: 'plan',
            name: AgentTools.showPlan,
            arguments: jsonEncode(plan),
          ),
        ],
        finishReason: 'tool_calls',
        model: 'fake',
      ),
    ], latency: Duration.zero);
    final coach = agent(client);
    final result = await coach.send(
      '请排个训练计划，I have a mat',
      context: const CoachContext(scene: 'home', equipment: {}, minutes: 10),
    );
    expect(result.plan, isNotNull, reason: '${result.issues}; ${result.error}');
    expect(result.plan!.plan.equipment, ['mat']);
    expect(coach.sessionState.params['equipment']!.value, ['equip.mat']);
  });

  test('invalid set_params does not dismiss an active question', () async {
    final client = FakeLlmClient([
      _tools([
        LlmToolCall(
          id: 'ask',
          name: AgentTools.askUser,
          arguments: jsonEncode({'question': '要练多久？', 'mode': 'text'}),
        ),
      ]),
      _tools([
        _set('bad', {'minutes': _user(10, '从未说过')}),
      ]),
      '我还在等你的回答。',
    ], latency: Duration.zero);
    final coach = agent(client);
    final first = await coach.send('我想训练');
    final question = first.question;
    expect(coach.pendingConfirmation, same(question));
    await coach.send('谢谢');
    expect(coach.pendingConfirmation, same(question));
    expect(coach.sessionState.params.containsKey('minutes'), isFalse);
  });

  test('successful set_params dismisses an active question', () async {
    final client = FakeLlmClient([
      _tools([
        LlmToolCall(
          id: 'ask',
          name: AgentTools.askUser,
          arguments: jsonEncode({'question': '要练多久？', 'mode': 'text'}),
        ),
      ]),
      _tools([
        _set('minutes', {'minutes': _user(10, '10分钟')}),
      ]),
      '已记录。',
    ], latency: Duration.zero);
    final coach = agent(client);
    expect((await coach.send('我想训练')).question, isNotNull);
    expect(coach.pendingConfirmation, isNotNull);
    await coach.send('10分钟');
    expect(coach.pendingConfirmation, isNull);
    expect(coach.sessionState.params['minutes']!.value, 10);
  });

  test('form question survives a plain text reply', () async {
    final client = FakeLlmClient([
      _tools([
        LlmToolCall(
          id: 'form',
          name: AgentTools.askUser,
          arguments: jsonEncode({
            'question': '你准备在哪里、用什么器材、练多久？',
            'mode': 'form',
            'fields': [
              {
                'key': 'scene',
                'label': '场景',
                'options': ['家里', '办公室'],
              },
              {
                'key': 'minutes',
                'label': '时长',
                'options': ['5 分钟', '10 分钟'],
              },
            ],
          }),
        ),
      ]),
      '你好！',
    ], latency: Duration.zero);
    final coach = agent(client);
    final question = (await coach.send('安排一个训练计划')).question;
    expect(question, isNotNull);
    await coach.send('谢谢');
    expect(coach.pendingConfirmation, same(question));
  });

  test('explicit dismissal survives an in-flight cancelled reply', () async {
    final entered = Completer<void>();
    final release = Completer<Object>();
    final client = FakeLlmClient([
      _tools([
        LlmToolCall(
          id: 'ask',
          name: AgentTools.askUser,
          arguments: jsonEncode({'question': '练多久？', 'mode': 'text'}),
        ),
      ]),
      (LlmRequest _) {
        entered.complete();
        return release.future;
      },
    ], latency: Duration.zero);
    final coach = agent(client);
    expect((await coach.send('训练')).question, isNotNull);
    final token = CancelToken();
    final pending = coach.send('十分钟', cancel: token);
    await entered.future;
    token.cancel();
    coach.dismissConfirmation();
    expect((await pending).status, TurnStatus.cancelled);
    release.complete('迟到结果');
    await Future<void>.delayed(Duration.zero);
    expect(coach.pendingConfirmation, isNull);
  });

  test(
    'an accepted input remains traceable after an uncaught failure',
    () async {
      var reads = 0;
      final coach = CoachAgent(
        client: FakeLlmClient([], latency: Duration.zero),
        catalog: () {
          if (++reads == 2) throw StateError('catalog unavailable');
          return catalog;
        },
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
      );
      addTearDown(coach.dispose);
      await expectLater(coach.send('  原始用户输入  '), throwsStateError);
      expect(coach.sessionState.userTurns.single.text, '  原始用户输入  ');
      expect(coach.sessionState.params, isEmpty);
    },
  );
}
