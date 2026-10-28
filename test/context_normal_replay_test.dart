import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmToolCall _call(String id, String name, Object args) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(args));

LlmResponse _batch(List<LlmToolCall> calls) => LlmResponse(
  content: '',
  toolCalls: calls,
  finishReason: 'tool_calls',
  model: 'fake',
);

Map<String, Object?> _result(LlmRequest request, String id) {
  final value = jsonDecode(
    request.messages.singleWhere((m) => m.toolCallId == id).content,
  );
  return (value as Map).cast<String, Object?>();
}

void _protocol(LlmRequest request) {
  final pending = <String>{};
  for (final message in request.messages) {
    if (message.role == LlmRole.assistant) {
      expect(pending, isEmpty, reason: 'previous tool batch incomplete');
      for (final call in message.toolCalls) {
        expect(pending.add(call.id), isTrue);
      }
    } else if (message.role == LlmRole.tool) {
      expect(pending.remove(message.toolCallId), isTrue);
      if (message.content.startsWith('{')) {
        final data = jsonDecode(message.content) as Map;
        expect(
          data['ok'],
          isNot(false),
          reason: '${message.toolCallId}: $data',
        );
      }
    } else {
      expect(pending, isEmpty);
    }
  }
  expect(pending, isEmpty);
}

void main() {
  test(
    'normal R3 uses three tagged searches and five bounded model calls',
    () async {
      const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
      final catalog = PoseHubAppTestCatalog.fromBytes(
        File('$pack/catalog.json').readAsBytesSync(),
        semanticCatalogBytes: File(
          '$pack/catalog/catalog.json',
        ).readAsBytesSync(),
      ).toAiCatalog();
      final profile = loadProfile('smartfit');
      final observed = <String, Map<String, Object?>>{};
      final returned = <String, List<String>>{};
      String? planId;

      void collect(LlmRequest request, String callId) {
        final data = _result(request, callId);
        expect(data['ok'], isTrue, reason: '$callId: $data');
        final ids = <String>[];
        for (final row in data['items'] as List) {
          final item = (row as Map).cast<String, Object?>();
          final id = item['id'] as String;
          ids.add(id);
          // Repeated search rows may contain only an ID. The model already saw
          // the original row during an earlier call in this same task.
          observed[id] = {...?observed[id], ...item};
        }
        returned[callId] = ids;
      }

      LlmToolCall search(String id, String tag) =>
          _call(id, AgentTools.searchActions, {
            'tags': [tag],
            'limit': 20,
          });

      final client = FakeLlmClient([
        _batch([
          _call('start', AgentTools.startTask, {'type': 'plan'}),
          _call('understand', AgentTools.check, {'node': 'understand'}),
          _call('params', AgentTools.setParams, {
            'fields': {
              'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
              'equipment': {
                'value': <String>[],
                'source': 'user',
                'quote': '徒手',
              },
              'minutes': {'value': 20, 'source': 'user', 'quote': '20 分钟'},
              'goal': {
                'value': ['body.core'],
                'source': 'user',
                'quote': '核心',
              },
            },
          }),
        ]),
        (LlmRequest request) {
          _protocol(request);
          planId = _result(request, 'start')['plan_id'] as String;
          return _batch([
            _call('parameters', AgentTools.check, {'node': 'parameters'}),
            search('core', 'body.core'),
          ]);
        },
        (LlmRequest request) {
          _protocol(request);
          collect(request, 'core');
          return _batch([search('mobility', 'purpose.mobility')]);
        },
        (LlmRequest request) {
          _protocol(request);
          collect(request, 'mobility');
          return _batch([search('stretch', 'purpose.stretch')]);
        },
        (LlmRequest request) {
          _protocol(request);
          collect(request, 'stretch');
          // Select solely from rows supplied by the three real search tools.
          // Alternate catalogue muscle groups to avoid a run of four identical
          // primary muscles; dose fitting and all plan gates remain real.
          final queues = <String, List<String>>{};
          for (final id in returned['core']!) {
            final row = observed[id]!;
            final primaryBody = (row['data'] as List).first;
            (queues['$primaryBody'] ??= []).add(id);
          }
          final mains = <String>[];
          while (mains.length < 5 && queues.values.any((q) => q.isNotEmpty)) {
            for (final queue in queues.values) {
              if (queue.isNotEmpty && mains.length < 5) {
                mains.add(queue.removeAt(0));
              }
            }
          }
          final warmup = returned['mobility']!
              .where((id) => !mains.contains(id))
              .take(3)
              .toList();
          final cooldown = returned['stretch']!
              .where((id) => !mains.contains(id) && !warmup.contains(id))
              .take(2)
              .toList();
          expect(mains, hasLength(5));
          expect(warmup, hasLength(3));
          expect(cooldown, hasLength(2));
          final picks = [...warmup, ...mains, ...cooldown];
          expect(picks.toSet(), hasLength(10));
          expect(observed.keys, containsAll(picks));
          return _batch([
            _call('actions', AgentTools.check, {
              'node': 'actions',
              'picks': picks,
            }),
            _call('draft', AgentTools.draftPlan, {
              'plan_id': planId,
              'title': '居家徒手核心',
              'blocks': [
                {
                  'kind': 'warmup',
                  'items': [
                    for (final id in warmup) {'id': id},
                  ],
                },
                {
                  'kind': 'main',
                  'rounds': 2,
                  'items': [
                    for (final id in mains) {'id': id},
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
            _call('planning', AgentTools.check, {'node': 'planning'}),
            _call('review-plan', AgentTools.checkPlan, {'plan_id': planId}),
            _call('review', AgentTools.check, {'node': 'review'}),
            _call('show', AgentTools.showPlan, {
              'plan_id': planId,
              'note': '循序渐进，动作保持平稳。',
            }),
          ]);
        },
      ], latency: Duration.zero);
      final agent = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
      );
      addTearDown(agent.dispose);
      final events = <AgentEvent>[];
      final subscription = agent.events.listen(events.add);
      addTearDown(subscription.cancel);
      final result = await agent.send('在家徒手 20 分钟练核心');
      expect(
        result.plan,
        isNotNull,
        reason: '${result.error}; ${result.issues}',
      );
      expect(result.plan!.plan.exerciseIds, hasLength(10));
      expect(client.requests, hasLength(5));
      expect(client.remaining, 0);
      expect(agent.sessionState.params['goal']!.value, ['body.core']);
      expect(
        agent.sessionState.task!.nodes.every((node) => node.status == 'done'),
        isTrue,
      );
      expect(agent.sessionState.plans[planId]!.last.check!['ok'], isTrue);
      expect(
        events
            .where((event) => event.node?.status == 'done')
            .map((event) => event.node!.id),
        ['understand', 'parameters', 'actions', 'planning', 'review', 'output'],
      );
      final target = 20 * 60;
      final estimate = agent.sessionState.plans[planId]!.last.estimateSec;
      expect(estimate, inInclusiveRange(target * 0.9, target * 1.1));
      final serializer = OpenAiCompatibleClient(
        config: LlmConfig.ugkWorker.copyWith(
          extraBody: {
            'thinking': {'type': 'enabled'},
          },
        ),
      );
      addTearDown(serializer.close);
      for (var i = 0; i < client.requests.length; i++) {
        final request = client.requests[i];
        _protocol(request);
        expect(
          request.messages
              .expand((m) => m.toolCalls)
              .any((call) => call.name == AgentTools.getAction),
          isFalse,
        );
        final bytes = utf8
            .encode(jsonEncode(serializer.buildBody(request)))
            .length;
        print('NORMAL R3 request ${i + 1}: $bytes B');
        expect(
          bytes,
          lessThanOrEqualTo(40 * 1024),
          reason: 'request ${i + 1}: $bytes B',
        );
      }
    },
  );
}
