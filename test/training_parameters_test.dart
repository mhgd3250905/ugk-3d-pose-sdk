import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_tags.dart';
import 'package:ugk_coach/src/agent/session_params.dart';
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

  List<Object> planFlow({
    required Map<String, Object?> fields,
    bool bodyweight = false,
    bool oversized = false,
    bool undersized = false,
  }) {
    final warmup = ['n-pelvis-circle'];
    final main = bodyweight
        ? ['n-pelvis-circle', 'n-squat-shift', 'h-squat', 'h-sumo-pry']
        : ['h-knee-hug', 'h-sumo-pry', 's-figure4', 's-kneel-hipflex'];
    final cooldown = [bodyweight ? 'h-sumo-pry' : 's-butterfly'];
    final ids = {...warmup, ...main, ...cooldown}.toList();
    LlmToolCall call(String id, String name, Object args) =>
        LlmToolCall(id: 'flow-$id', name: name, arguments: jsonEncode(args));
    LlmResponse batch(List<LlmToolCall> calls) => LlmResponse(
      content: '',
      toolCalls: calls,
      finishReason: 'tool_calls',
      model: 'fake',
    );
    Map<String, dynamic> feedback(LlmRequest request, String id) =>
        jsonDecode(
              request.messages
                  .singleWhere((m) => m.toolCallId == 'flow-$id')
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
          expect(search['ok'], isTrue);
          expect(
            (search['items'] as List).map((e) => (e as Map)['id']),
            contains(ids[i]),
          );
        }
        return batch([
          call('actions', AgentTools.check, {'node': 'actions', 'picks': ids}),
          call('draft', AgentTools.draftPlan, {
            'title': '髋部训练',
            'blocks': [
              if (!undersized)
                {
                  'kind': 'warmup',
                  'items': [
                    for (final id in warmup) {'id': id},
                  ],
                },
              {
                'kind': 'main',
                'items': [
                  for (final id in undersized ? main.take(1) : main)
                    {
                      'id': id,
                      if (oversized && id == main.first) 'sets': 999,
                      if (undersized) 'sets': 1,
                      if (undersized) 'seconds': 10,
                    },
                ],
              },
              if (!undersized)
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
        if (oversized) {
          expect((draft['fitLog'] as List).join(' '), contains('夹到'));
        }
        planId = draft['plan_id'] as String;
        return batch([
          call('planning', AgentTools.check, {'node': 'planning'}),
          call('check', AgentTools.checkPlan, {'plan_id': planId}),
        ]);
      },
      (LlmRequest request) {
        final checked = feedback(request, 'check');
        if (undersized) {
          expect(checked['ok'], isFalse);
          expect(checked['code'], 'plan_check_failed');
          return '无法提供合适方案。';
        }
        expect(checked['ok'], isTrue, reason: '$checked');
        return batch([
          call('review', AgentTools.check, {'node': 'review'}),
        ]);
      },
      if (!undersized)
        (LlmRequest request) {
          expect(feedback(request, 'review')['ok'], isTrue);
          return batch([
            call('show', AgentTools.showPlan, {
              'plan_id': planId,
              'note': '按你的条件安排髋部训练。',
            }),
          ]);
        },
    ];
  }

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
          ...planFlow(
            fields: {
              'goal': userValue(['purpose.stretch'], '放松'),
            },
            oversized: true,
          ),
        ]);
        final result = await chat.send('在家，有瑜伽垫，10 分钟，排个髋部放松计划');
        expect(result!.plan, isNotNull);
        final plan = result.plan!.plan;
        expect(
          const PlanDuration().estimateSeconds(plan, catalog),
          inInclusiveRange(540, 660),
        );
        final item = plan.items.firstWhere((i) => i.exerciseId == 'h-knee-hug');
        final range = catalog['h-knee-hug']!.doseRange.sets!;
        expect(item.sets, inInclusiveRange(range.min, range.max));
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
            ...planFlow(
              fields: {
                'goal': userValue(['purpose.stretch'], '放松'),
              },
            ),
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
          ...planFlow(
            fields: {
              'goal': userValue(['purpose.stretch'], '放松'),
            },
          ),
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
        final chat = conversation([
          tool(AgentTools.askUser, form(['scene', 'equipment', 'minutes'])),
          setParams({
            'scene': defaultValue('home'),
            'equipment': defaultValue(<String>[]),
            'minutes': defaultValue(12),
          }),
          ...planFlow(
            fields: {
              'goal': defaultValue(['purpose.mobility']),
            },
            bodyweight: true,
          ),
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
      var filtered = false;
      final chat = conversation([
        tool(AgentTools.askUser, form(['scene', 'equipment', 'minutes'])),
        setParams({
          'scene': defaultValue('home'),
          'equipment': defaultValue(<String>[]),
          'minutes': defaultValue(12),
        }),
        tool(AgentTools.searchActions, {
          'tags': <String>[],
          'keywords': catalog['s-figure4']!.name.of('en'),
        }),
        (LlmRequest request) {
          final search = jsonDecode(request.messages.last.content) as Map;
          expect(search['ok'], isTrue);
          expect(
            (search['items'] as List).map((item) => (item as Map)['id']),
            isNot(contains('s-figure4')),
          );
          expect(
            (search['filter'] as Map)['hiddenEquipmentCount'],
            greaterThan(0),
          );
          filtered = true;
          return '没有符合当前条件的这个动作。';
        },
      ]);
      await chat.send('帮我做个训练组');
      final result = await chat.skipQuestion(chat.state.pendingQuestion!.id);
      expect(result!.plan, isNull);
      expect(result.question, isNull);
      expect(filtered, isTrue, reason: '${result.error} ${result.issues}');
      expect(chat.agent.sessionState.params['equipment']!.value, isEmpty);
      expect(chat.agent.sessionState.params['minutes']!.value, 12);
    },
  );

  test(
    'structured negative equipment and latest correction preserve provenance',
    () {
      final params = SessionParams(ActionTags(profile, catalog));
      final initial = params.set(
        CoachSessionState().appendUserTurn('在家，没什么器械，十五分钟'),
        {
          'fields': {
            'scene': userValue('home', '在家'),
            'equipment': userValue(<String>[], '没什么器械'),
            'minutes': userValue(15, '十五分钟'),
          },
        },
      );
      expect(initial.ok, isTrue, reason: '${initial.error}');
      expect(initial.state.params['minutes']!.value, 15);
      expect(initial.state.params['equipment']!.value, isEmpty);
      final mat = params.set(
        CoachSessionState().appendUserTurn('在家，没有哑铃，只有瑜伽垫，10分钟'),
        {
          'fields': {
            'equipment': userValue(['equip.mat'], '只有瑜伽垫'),
          },
        },
      );
      expect(mat.ok, isTrue, reason: '${mat.error}');
      expect(mat.state.params['equipment']!.value, ['equip.mat']);
      final unknown = CoachSessionState().appendUserTurn('不用椅子');
      expect(unknown.params.containsKey('equipment'), isFalse);
      final host = params
          .applyHost(
            CoachSessionState(),
            const CoachContext(
              scene: 'home',
              equipment: {'mat', 'chair'},
              minutes: 10,
            ),
          )
          .state;
      final removed = params.set(host.appendUserTurn('不用椅子'), {
        'fields': {
          'equipment': userValue(['equip.mat'], '不用椅子'),
        },
      });
      expect(removed.ok, isTrue, reason: '${removed.error}');
      expect(removed.state.params['equipment']!.value, ['equip.mat']);
      final changed = params.set(
        removed.state.appendUserTurn('改为办公室，徒手，5 分钟'),
        {
          'fields': {
            'scene': userValue('office', '改为办公室'),
            'equipment': userValue(<String>[], '徒手'),
            'minutes': userValue(5, '5 分钟'),
          },
        },
      );
      expect(changed.ok, isTrue, reason: '${changed.error}');
      expect(changed.state.params['scene']!.value, 'office');
      expect(changed.state.params['equipment']!.value, isEmpty);
      expect(changed.state.params['minutes']!.value, 5);
      for (final field in ['scene', 'equipment', 'minutes']) {
        expect(changed.state.params[field]!.source, 'user');
        expect(changed.state.params[field]!.turn, 2);
      }
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
    'search enforces equipment and scene before a card can be delivered',
    () async {
      for (final example in [
        (
          text: '在家徒手10分钟做计划',
          scene: 'home',
          sceneQuote: '在家',
          equipment: <String>[],
          equipmentQuote: '徒手',
          forbidden: 's-figure4',
        ),
        (
          text: '在办公室有瑜伽垫10分钟做计划',
          scene: 'office',
          sceneQuote: '办公室',
          equipment: ['equip.mat'],
          equipmentQuote: '瑜伽垫',
          forbidden: 's-figure4',
        ),
      ]) {
        var filtered = false;
        final chat = conversation([
          setParams({
            'scene': userValue(example.scene, example.sceneQuote),
            'equipment': userValue(example.equipment, example.equipmentQuote),
            'minutes': userValue(10, '10分钟'),
          }),
          tool(AgentTools.searchActions, {
            'tags': <String>[],
            'keywords': catalog[example.forbidden]!.name.of('en'),
          }),
          (LlmRequest request) {
            final search = jsonDecode(request.messages.last.content) as Map;
            expect(search['ok'], isTrue);
            expect(
              (search['items'] as List).map((item) => (item as Map)['id']),
              isNot(contains(example.forbidden)),
              reason: example.text,
            );
            filtered = true;
            return '没有符合当前条件的这个动作。';
          },
        ]);
        final result = await chat.send(example.text);
        expect(result!.plan, isNull, reason: example.text);
        expect(filtered, isTrue, reason: '${result.error} ${result.issues}');
      }
    },
  );
  test(
    'short draft is resized but rejected when required structure is missing',
    () async {
      final chat = conversation([
        tool(AgentTools.askUser, {'question': '想练什么？', 'mode': 'text'}),
        ...planFlow(
          fields: {
            'scene': userValue('home', '在家'),
            'equipment': userValue(['equip.mat'], '瑜伽垫'),
            'minutes': userValue(10, '10分钟'),
            'goal': userValue(['purpose.stretch'], '拉伸'),
          },
          undersized: true,
        ),
      ]);
      final first = await chat.send('在家有瑜伽垫10分钟做计划');
      expect(first!.question, isNotNull);
      final result = await chat.answerText(
        chat.state.pendingQuestion!.id,
        '拉伸',
      );
      expect(result!.plan, isNull);
      final versions = chat.agent.sessionState.plans.values.single;
      expect(versions.single.estimateSec, inInclusiveRange(540, 660));
      expect(versions.single.check?['ok'], isFalse);
    },
  );
  test(
    'known host conditions are recorded and model may answer without a form',
    () async {
      final chat = conversation([
        ...planFlow(
          fields: {
            'goal': userValue(['purpose.stretch'], '放松'),
          },
        ),
      ]);
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
