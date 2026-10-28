import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmToolCall tool(String id, String name, Object args) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(args));
LlmResponse calls(List<LlmToolCall> tools) => LlmResponse(
  content: '',
  toolCalls: tools,
  finishReason: 'tool_calls',
  model: 'fake',
);
Map<String, dynamic> response(LlmRequest request, String id) =>
    jsonDecode(request.messages.singleWhere((m) => m.toolCallId == id).content)
        as Map<String, dynamic>;
void protocol(List<LlmMessage> messages) {
  final pending = <String>{};
  for (final m in messages) {
    if (m.role == LlmRole.assistant) {
      expect(pending, isEmpty);
      for (final call in m.toolCalls) {
        expect(pending.add(call.id), isTrue, reason: 'duplicate tool ID');
      }
    } else if (m.role == LlmRole.tool) {
      expect(
        pending.remove(m.toolCallId),
        isTrue,
        reason: 'unexpected tool reply',
      );
    } else {
      expect(
        pending,
        isEmpty,
        reason: 'missing tool replies before next message',
      );
    }
  }
  expect(pending, isEmpty);
}

LlmToolCall start() =>
    tool('start', AgentTools.startTask, {'type': 'recommend'});
LlmToolCall understand() =>
    tool('understand', AgentTools.check, {'node': 'understand'});
LlmToolCall parameters({bool invalid = false}) =>
    tool('params', AgentTools.setParams, {
      'fields': {
        'scene': {
          'value': 'home',
          'source': 'user',
          'quote': invalid ? '不存在' : '在家',
        },
        'equipment': {'value': <String>[], 'source': 'user', 'quote': '徒手'},
        'goal': {
          'value': ['purpose.stretch'],
          'source': 'user',
          'quote': '拉伸',
        },
      },
    });
LlmToolCall checkParameters() =>
    tool('parameters', AgentTools.check, {'node': 'parameters'});
LlmToolCall search() =>
    tool('search', AgentTools.searchActions, {'tags': <String>[], 'limit': 20});
LlmToolCall read() =>
    tool('read', AgentTools.read, {'path': 'action-library/SKILL.md'});
LlmToolCall ask([String id = 'ask']) =>
    tool(id, AgentTools.askUser, {'question': '还有其他要求吗？', 'mode': 'text'});

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('smartfit');
  CoachAgent coach(FakeLlmClient client) {
    final agent = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      enableUserMemory: false,
      maxRequestRetries: 0,
    );
    addTearDown(agent.dispose);
    return agent;
  }

  const input = '在家徒手拉伸，进阶';

  test('six tools execute in order with one matched result each', () async {
    final client = FakeLlmClient([
      calls([
        start(),
        understand(),
        parameters(),
        checkParameters(),
        search(),
        read(),
      ]),
      (LlmRequest request) {
        protocol(request.messages);
        for (final id in [
          'start',
          'understand',
          'params',
          'parameters',
          'search',
        ]) {
          expect(response(request, id)['ok'], isTrue, reason: id);
        }
        expect(
          request.messages.singleWhere((m) => m.toolCallId == 'read').content,
          contains('action-library'),
        );
        return calls([ask()]);
      },
    ], latency: Duration.zero);
    final agent = coach(client);
    final events = <AgentEvent>[];
    final subscription = agent.events.listen(events.add);
    final result = await agent.send(input);
    await subscription.cancel();
    expect(
      result.question,
      isNotNull,
      reason: '${result.issues} ${result.error}',
    );
    expect(agent.sessionState.params['scene']!.value, 'home');
    expect(agent.sessionState.seenActionIds, isNotEmpty);
    final nodes = agent.sessionState.task!.nodes;
    expect(nodes[0].status, 'done');
    expect(nodes[1].status, 'done');
    expect(nodes[2].status, 'current');
    expect(
      events.where(
        (e) => e.node?.id == 'understand' && e.node?.status == 'done',
      ),
      hasLength(1),
    );
    expect(
      events.where(
        (e) => e.node?.id == 'parameters' && e.node?.status == 'done',
      ),
      hasLength(1),
    );
  });

  test('failure in third call skips calls four through six', () async {
    final client = FakeLlmClient([
      calls([
        start(),
        understand(),
        parameters(invalid: true),
        checkParameters(),
        search(),
        read(),
      ]),
      (LlmRequest request) {
        protocol(request.messages);
        expect(response(request, 'start')['ok'], isTrue);
        expect(response(request, 'understand')['ok'], isTrue);
        expect(response(request, 'params')['ok'], isFalse);
        for (final id in ['parameters', 'search', 'read']) {
          final skipped = response(request, id);
          expect(skipped['ok'], isFalse);
          expect(skipped['code'], 'skipped_after_error');
          expect(skipped['actual'], contains('3'));
        }
        return calls([ask()]);
      },
    ], latency: Duration.zero);
    final agent = coach(client);
    final result = await agent.send(input);
    expect(
      result.question,
      isNotNull,
      reason: '${result.issues} ${result.error}',
    );
    expect(agent.sessionState.params['scene'], isNull);
    expect(agent.sessionState.seenActionIds, isEmpty);
    expect(agent.sessionState.task!.nodes[1].status, 'current');
    expect(result.reads, isNot(contains('action-library/SKILL.md')));
  });

  for (final missing in [
    ('read', {'path': 'missing/SKILL.md'}, 'not_found'),
    ('ls', {'dir': 'missing'}, 'unknown_tool'),
    ('not_a_tool', <String, Object>{}, 'unknown_tool'),
  ]) {
    test('${missing.$1} failure stops subsequent calls', () async {
      late CoachAgent agent;
      final client = FakeLlmClient([
        calls([start(), tool('failure', missing.$1, missing.$2), parameters()]),
        (LlmRequest request) {
          protocol(request.messages);
          expect(response(request, 'start')['ok'], isTrue);
          expect(response(request, 'failure')['code'], missing.$3);
          expect(response(request, 'params')['code'], 'skipped_after_error');
          expect(agent.sessionState.params['scene'], isNull);
          return calls([ask()]);
        },
      ], latency: Duration.zero);
      agent = coach(client);
      final result = await agent.send(input);
      expect(
        result.question,
        isNotNull,
        reason: '${result.issues} ${result.error}',
      );
      expect(agent.sessionState.params['scene'], isNull);
    });
  }

  test(
    'ask last pauses and resumes with complete paired search history',
    () async {
      final client = FakeLlmClient([
        calls([
          start(),
          understand(),
          parameters(),
          checkParameters(),
          search(),
          ask(),
        ]),
        (LlmRequest request) {
          protocol(request.messages);
          for (final id in [
            'start',
            'understand',
            'params',
            'parameters',
            'search',
            'ask',
          ]) {
            expect(
              request.messages.where((m) => m.toolCallId == id),
              hasLength(1),
            );
          }
          expect(response(request, 'search')['items'], isNotEmpty);
          return calls([ask('ask-again')]);
        },
      ], latency: Duration.zero);
      final agent = coach(client);
      final first = await agent.send(input);
      expect(
        first.question,
        isNotNull,
        reason: '${first.issues} ${first.error}',
      );
      expect(agent.sessionState.task!.nodes[2].status, 'current');
      final second = await agent.send('没有其他要求');
      expect(
        second.question,
        isNotNull,
        reason: '${second.issues} ${second.error}',
      );
      expect(agent.sessionState.task!.nodes[2].status, 'current');
    },
  );

  test(
    'ask not last rejects itself, preserves prefix and skips suffix',
    () async {
      late CoachAgent agent;
      final client = FakeLlmClient([
        calls([start(), ask(), parameters()]),
        (LlmRequest request) {
          protocol(request.messages);
          for (final id in ['start', 'ask', 'params']) {
            expect(
              request.messages.where((m) => m.toolCallId == id),
              hasLength(1),
            );
          }
          expect(agent.sessionState.task, isNotNull);
          expect(response(request, 'ask')['ok'], isFalse);
          expect(response(request, 'params')['code'], 'skipped_after_error');
          expect(agent.sessionState.params['scene'], isNull);
          return calls([ask('repair')]);
        },
      ], latency: Duration.zero);
      agent = coach(client);
      final result = await agent.send(input);
      expect(
        result.question,
        isNotNull,
        reason: '${result.issues} ${result.error}',
      );
      expect(agent.sessionState.task, isNotNull);
      expect(agent.sessionState.params['scene'], isNull);
    },
  );

  test(
    'ask not last keeps prior memory write and skips subsequent write',
    () async {
      final store = InMemoryUserMemoryStore();
      final client = FakeLlmClient([
        calls([
          tool('memory-before', AgentTools.remember, {
            'kind': 'goal',
            'text': '想劈叉',
          }),
          ask(),
          tool('memory-after', AgentTools.remember, {
            'kind': 'goal',
            'text': '想拉伸',
          }),
        ]),
        (LlmRequest request) {
          protocol(request.messages);
          expect(store.entries.map((e) => e.text), ['想劈叉']);
          expect(response(request, 'ask')['ok'], isFalse);
          expect(
            response(request, 'memory-after')['code'],
            'skipped_after_error',
          );
          return calls([ask('repair-memory')]);
        },
      ], latency: Duration.zero);
      final agent = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        memoryStore: store,
        enableUserMemory: true,
        maxRequestRetries: 0,
      );
      addTearDown(agent.dispose);
      final events = <AgentEvent>[];
      final subscription = agent.events.listen(events.add);
      final result = await agent.send('我想劈叉和拉伸');
      await subscription.cancel();
      expect(
        result.question,
        isNotNull,
        reason: '${result.issues} ${result.error}',
      );
      expect(store.entries.map((e) => e.text), ['想劈叉']);
      expect(
        events.where((event) => event.kind == AgentEventKind.memory),
        hasLength(1),
      );
    },
  );

  test('cancel in a synchronous node event prevents later calls', () async {
    final token = CancelToken();
    final client = FakeLlmClient([
      calls([
        start(),
        understand(),
        parameters(),
        checkParameters(),
        search(),
        read(),
      ]),
    ], latency: Duration.zero);
    final agent = coach(client);
    final subscription = agent.events.listen((event) {
      if (event.node?.id == 'understand' && event.node?.status == 'done') {
        token.cancel();
      }
    });
    final result = await agent.send(input, cancel: token);
    await subscription.cancel();
    expect(result.status, TurnStatus.cancelled);
    expect(agent.sessionState.params['scene'], isNull);
    expect(agent.sessionState.seenActionIds, isEmpty);
    expect(result.reads, isNot(contains('action-library/SKILL.md')));
  });
  test(
    'successful show stops later calls and leaves paired history for next turn',
    () async {
      final client = FakeLlmClient([
        calls([
          start(),
          understand(),
          parameters(),
          checkParameters(),
          search(),
        ]),
        (LlmRequest request) {
          final found = response(request, 'search');
          final ids = (found['items'] as List)
              .map((row) => (row as Map)['id'] as String)
              .take(profile.minActions)
              .toList();
          expect(ids, hasLength(profile.minActions));
          return calls([
            tool('actions', AgentTools.check, {
              'node': 'actions',
              'picks': ids,
            }),
            tool('show', AgentTools.showActions, {'ids': ids, 'note': '量力而行。'}),
            tool('after-show', AgentTools.setParams, {
              'fields': {
                'level': {'value': 2, 'source': 'user', 'quote': '进阶'},
              },
            }),
          ]);
        },
        (LlmRequest request) {
          protocol(request.messages);
          return calls([ask('after-card')]);
        },
      ], latency: Duration.zero);
      final agent = coach(client);
      final result = await agent.send(input);
      expect(
        result.actions,
        isNotNull,
        reason: '${result.issues} ${result.error}',
      );
      expect(agent.sessionState.params['level']!.source, 'default');
      expect(agent.sessionState.params['level']!.value, 1);
      final next = await agent.send('谢谢');
      expect(next.question, isNotNull, reason: '${next.issues} ${next.error}');
    },
  );

  test(
    'host safety change during a batch is used by subsequent searches',
    () async {
      late CoachAgent agent;
      final client = FakeLlmClient([
        calls([
          start(),
          understand(),
          parameters(),
          checkParameters(),
          search(),
          read(),
        ]),
        (LlmRequest request) {
          protocol(request.messages);
          final result = response(request, 'search');
          expect(result['ok'], isTrue, reason: '$result');
          final gate = NodeGates(
            profile,
            catalog,
            minPicks: profile.minActions,
          );
          for (final row in result['items'] as List) {
            final id = (row as Map)['id'] as String;
            expect(
              gate.actionProblem(agent.sessionState, id),
              isNull,
              reason: id,
            );
          }
          return calls([ask()]);
        },
      ], latency: Duration.zero);
      agent = coach(client);
      var changed = false;
      final subscription = agent.events.listen((event) {
        if (!changed &&
            event.node?.id == 'understand' &&
            event.node?.status == 'done') {
          changed = true;
          agent.replaceSafetyAvoid({'膝'});
        }
      });
      final result = await agent.send(input);
      await subscription.cancel();
      expect(changed, isTrue);
      expect(
        result.question,
        isNotNull,
        reason: '${result.issues} ${result.error}',
      );
      expect(agent.sessionState.params['limits']!.source, 'host');
      expect(
        agent.sessionState.params['limits']!.value,
        contains('limit.knee'),
      );
    },
  );
  test(
    'reserved ID supports a real six-tool planning batch through delivery',
    () async {
      const base = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
      final realCatalog = PoseHubAppTestCatalog.fromBytes(
        File('$base/catalog.json').readAsBytesSync(),
        semanticCatalogBytes: File(
          '$base/catalog/catalog.json',
        ).readAsBytesSync(),
      ).toAiCatalog();
      const ids = [
        's-kneel-hipflex',
        'n-thomas-test',
        's-butterfly',
        'h-bilateral-upper-back-hug',
      ];
      String? planId;
      final client = FakeLlmClient([
        calls([
          tool('plan-start', AgentTools.startTask, {'type': 'plan'}),
          tool('plan-understand', AgentTools.check, {'node': 'understand'}),
          tool('plan-params', AgentTools.setParams, {
            'fields': {
              'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
              'equipment': {
                'value': ['equip.mat'],
                'source': 'user',
                'quote': '瑜伽垫',
              },
              'minutes': {'value': 10, 'source': 'user', 'quote': '10分钟'},
              'goal': {
                'value': ['body.hip_flexors', 'purpose.stretch'],
                'source': 'user',
                'quote': '髋部放松',
              },
            },
          }),
          tool('plan-parameters', AgentTools.check, {'node': 'parameters'}),
        ]),
        (LlmRequest request) {
          protocol(request.messages);
          for (final id in [
            'plan-start',
            'plan-understand',
            'plan-params',
            'plan-parameters',
          ]) {
            expect(response(request, id)['ok'], isTrue, reason: id);
          }
          planId = response(request, 'plan-start')['plan_id'] as String?;
          expect(planId, isNotEmpty);
          return calls([
            for (var i = 0; i < ids.length; i++)
              tool('plan-search-$i', AgentTools.searchActions, {
                'tags': <String>[],
                'keywords': realCatalog[ids[i]]!.name.of('en'),
              }),
          ]);
        },
        (LlmRequest request) {
          protocol(request.messages);
          for (var i = 0; i < ids.length; i++) {
            final found = response(request, 'plan-search-$i');
            expect(found['ok'], isTrue, reason: '$found');
            expect(
              (found['items'] as List).map((row) => (row as Map)['id']),
              contains(ids[i]),
            );
          }
          return calls([
            tool('batch-actions', AgentTools.check, {
              'node': 'actions',
              'picks': ids,
            }),
            tool('batch-draft', AgentTools.draftPlan, {
              'plan_id': planId,
              'title': '髋部放松',
              'blocks': [
                {
                  'kind': 'main',
                  'items': [
                    for (final id in ids.take(3)) {'id': id},
                  ],
                },
                {
                  'kind': 'cooldown',
                  'items': [
                    {'id': ids.last},
                  ],
                },
              ],
            }),
            tool('batch-planning', AgentTools.check, {'node': 'planning'}),
            tool('batch-check', AgentTools.checkPlan, {'plan_id': planId}),
            tool('batch-review', AgentTools.check, {'node': 'review'}),
            tool('batch-show', AgentTools.showPlan, {
              'plan_id': planId,
              'note': '量力而行。',
            }),
          ]);
        },
        (LlmRequest request) {
          protocol(request.messages);
          return calls([ask('post-plan')]);
        },
      ], latency: Duration.zero);
      final agent = CoachAgent(
        client: client,
        catalog: () => realCatalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
      );
      addTearDown(agent.dispose);
      final events = <AgentEvent>[];
      final subscription = agent.events.listen(events.add);
      final result = await agent.send('在家有瑜伽垫10分钟做髋部放松');
      await subscription.cancel();
      expect(
        result.plan,
        isNotNull,
        reason: '${result.issues}; ${result.error}',
      );
      expect(result.plan!.plan.id, planId);
      expect(result.plan!.plan.targetMinutes, 10);
      expect(client.requests, hasLength(3));
      final planVersion = agent.sessionState.plans[planId]!.last;
      expect(planVersion.version, 1);
      expect(planVersion.check?['ok'], isTrue);
      final doneNodes = events
          .where(
            (event) =>
                event.kind == AgentEventKind.node &&
                event.node?.status == 'done',
          )
          .map((event) => event.node!.id)
          .toList();
      expect(doneNodes, [
        'understand',
        'parameters',
        'actions',
        'planning',
        'review',
        'output',
      ]);
      final next = await agent.send('谢谢');
      expect(next.question, isNotNull, reason: '${next.issues}; ${next.error}');
    },
  );
  test(
    'duplicate call ID preserves the successful prefix and replies by position',
    () async {
      late CoachAgent agent;
      final client = FakeLlmClient([
        calls([
          tool('same', AgentTools.startTask, {'type': 'recommend'}),
          tool('same', AgentTools.setParams, {
            'fields': {
              'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
            },
          }),
          tool('last', AgentTools.searchActions, {
            'tags': <String>[],
            'limit': 3,
          }),
        ]),
        (LlmRequest request) {
          final index = request.messages.lastIndexWhere(
            (m) =>
                m.role == LlmRole.assistant &&
                m.toolCalls.any((t) => t.id == 'same'),
          );
          expect(index, greaterThanOrEqualTo(0));
          expect(request.messages[index].toolCalls.map((t) => t.id), [
            'same',
            'same',
            'last',
          ]);
          final feedback = request.messages.skip(index + 1).take(3).toList();
          expect(feedback.map((m) => m.role), [
            LlmRole.tool,
            LlmRole.tool,
            LlmRole.tool,
          ]);
          expect(feedback.map((m) => m.toolCallId), ['same', 'same', 'last']);
          final values = [
            for (final m in feedback)
              jsonDecode(m.content) as Map<String, dynamic>,
          ];
          expect(values[0]['ok'], isTrue);
          expect(values[1]['code'], 'duplicate_tool_call_id');
          expect(values[2]['code'], 'skipped_after_error');
          expect(values[2]['actual'], contains('2'));
          expect(agent.sessionState.task, isNotNull);
          expect(agent.sessionState.params['scene'], isNull);
          expect(agent.sessionState.seenActionIds, isEmpty);
          return calls([ask('repair-duplicate')]);
        },
      ], latency: Duration.zero);
      agent = coach(client);
      final result = await agent.send(input);
      expect(
        result.question,
        isNotNull,
        reason: '${result.issues}; ${result.error}',
      );
      expect(agent.sessionState.task, isNotNull);
      expect(agent.sessionState.params['scene'], isNull);
    },
  );
}
