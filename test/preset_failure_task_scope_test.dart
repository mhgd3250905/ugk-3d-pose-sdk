import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  test(
    'a failed action explanation cannot offer the previous plan preset',
    () async {
      final catalog = loadCatalog();
      final profile = loadProfile('hiplab');
      final planJson = planOf(okEnvelope())..remove('source');
      final oldPlan = const PlanCodec().decode(planJson);
      const warmup = ['n-pelvis-circle'];
      const main = [
        'h-knee-hug',
        'h-reverse-clam',
        'n-windshield',
        's-figure4',
      ];
      const cooldown = ['s-kneel-hipflex'];
      const ids = [...warmup, ...main, ...cooldown];
      LlmToolCall call(String id, String name, Object args) =>
          LlmToolCall(id: id, name: name, arguments: jsonEncode(args));
      LlmResponse calls(List<LlmToolCall> tools) => LlmResponse(
        content: '',
        toolCalls: tools,
        finishReason: 'tool_calls',
        model: 'fake',
      );
      Map<String, dynamic> feedback(LlmRequest request, String id) =>
          jsonDecode(
                request.messages.singleWhere((m) => m.toolCallId == id).content,
              )
          as Map<String, dynamic>;
      late String planId;
      final client = FakeLlmClient([
        calls([
          call('start', AgentTools.startTask, {'type': 'plan'}),
          call('understand', AgentTools.check, {'node': 'understand'}),
          call('params', AgentTools.setParams, {
            'fields': {
              'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
              'equipment': {
                'value': ['equip.mat'],
                'source': 'user',
                'quote': '瑜伽垫',
              },
              'minutes': {'value': 10, 'source': 'user', 'quote': '10分钟'},
              'goal': {
                'value': ['body.glute_max'],
                'source': 'user',
                'quote': '臀部',
              },
            },
          }),
          call('parameters', AgentTools.check, {'node': 'parameters'}),
          for (var i = 0; i < ids.length; i++)
            call('search$i', AgentTools.searchActions, {
              'tags': <String>[],
              'keywords': catalog[ids[i]]!.name.of('en'),
            }),
        ]),
        (LlmRequest request) {
          expect(feedback(request, 'parameters')['ok'], isTrue);
          for (var i = 0; i < ids.length; i++) {
            final search = feedback(request, 'search$i');
            expect(search['ok'], isTrue);
            expect(
              (search['items'] as List).map((e) => (e as Map)['id']),
              contains(ids[i]),
            );
          }
          return calls([
            call('actions', AgentTools.check, {
              'node': 'actions',
              'picks': ids,
            }),
            call('draft', AgentTools.draftPlan, {
              'title': '臀部训练',
              'blocks': [
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
          final drafted = feedback(request, 'draft');
          expect(drafted['ok'], isTrue, reason: '$drafted');
          planId = drafted['plan_id'] as String;
          return calls([
            call('planning', AgentTools.check, {'node': 'planning'}),
            call('check', AgentTools.checkPlan, {'plan_id': planId}),
          ]);
        },
        (LlmRequest request) {
          final checked = feedback(request, 'check');
          expect(checked['ok'], isTrue, reason: '$checked');
          return calls([
            call('review', AgentTools.check, {'node': 'review'}),
          ]);
        },
        (LlmRequest request) {
          expect(feedback(request, 'review')['ok'], isTrue);
          return calls([
            call('show', AgentTools.showPlan, {
              'plan_id': planId,
              'note': '按你的条件安排臀部训练。',
            }),
          ]);
        },
        const LlmException(
          LlmErrorKind.network,
          'planning network unavailable',
        ),
        const LlmException(LlmErrorKind.network, 'network unavailable'),
      ]);
      final conversation = CoachConversationController(
        agent: CoachAgent(
          client: client,
          catalog: () => catalog,
          profile: profile,
          enableUserMemory: false,
          maxRequestRetries: 0,
        ),
      );
      addTearDown(conversation.dispose);

      final first = await conversation.send('在家有瑜伽垫，10分钟安排一个臀部训练计划');
      expect(
        first!.plan,
        isNotNull,
        reason: 'the fixture is an admitted prior plan',
      );
      final failedPlanning = await conversation.send('重试');
      expect(failedPlanning!.status, TurnStatus.error);
      expect(
        conversation.canOfferPreset(oldPlan),
        isTrue,
        reason: 'the old preset is available for the failed old planning task',
      );

      final failed = await conversation.send('肩膀动作怎么做');
      expect(failed!.status, TurnStatus.error);
      expect(conversation.state.messages.last.isFailure, isTrue);
      expect(conversation.canOfferPreset(oldPlan), isFalse);
      expect(conversation.requestPreset(oldPlan), isNull);
      expect(conversation.state.messages.last.isFailure, isTrue);
    },
  );

  test(
    'a failed current planning turn can offer a verified matching preset',
    () async {
      final catalog = loadCatalog();
      final profile = loadProfile('hiplab');
      final plan = const PlanCodec().decode(planOf(okEnvelope()));
      final client = FakeLlmClient([
        const LlmException(LlmErrorKind.network, 'network unavailable'),
      ]);
      final conversation = CoachConversationController(
        agent: CoachAgent(
          client: client,
          catalog: () => catalog,
          profile: profile,
          enableUserMemory: false,
          maxRequestRetries: 0,
        ),
      );
      addTearDown(conversation.dispose);

      final failed = await conversation.send('在家有瑜伽垫，10分钟安排一个臀部训练计划');
      expect(failed!.status, TurnStatus.error);
      expect(failed.plan, isNull);
      expect(conversation.state.messages.last.isFailure, isTrue);
      expect(conversation.canOfferPreset(plan), isTrue);
      final accepted = conversation.requestPreset(plan);
      expect(accepted?.plan, isNotNull);
      expect(conversation.state.messages.last.plan, isNotNull);
    },
  );
}
