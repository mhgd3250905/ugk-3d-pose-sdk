import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmToolCall tool(String id, String name, Object arguments) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(arguments));
LlmResponse calls(List<LlmToolCall> values) => LlmResponse(
  content: '',
  toolCalls: values,
  finishReason: 'tool_calls',
  model: 'fake',
);
Map<String, dynamic> feedback(LlmRequest request, String id) =>
    jsonDecode(request.messages.singleWhere((m) => m.toolCallId == id).content)
        as Map<String, dynamic>;

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('smartfit');

  FakeLlmClient model() => FakeLlmClient([
    calls([
      tool('start', AgentTools.startTask, {'type': 'recommend'}),
      tool('understand', AgentTools.check, {'node': 'understand'}),
      tool('params', AgentTools.setParams, {
        'fields': {
          'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
          'equipment': {'value': <String>[], 'source': 'user', 'quote': '徒手'},
          'goal': {
            'value': ['body.inner_thigh'],
            'source': 'user',
            'quote': '大腿内侧',
          },
        },
      }),
      tool('parameters', AgentTools.check, {'node': 'parameters'}),
      tool('squat', AgentTools.searchActions, {
        'tags': <String>[],
        'keywords': catalog['h-squat']!.name.of('zh'),
      }),
      tool('general', AgentTools.searchActions, {
        'tags': <String>[],
        'limit': 20,
      }),
    ]),
    (LlmRequest request) {
      final squash = feedback(request, 'squat');
      final general = feedback(request, 'general');
      expect(squash['ok'], isTrue);
      expect(general['ok'], isTrue);
      expect(
        (squash['items'] as List).map((row) => (row as Map)['id']),
        contains('h-squat'),
      );
      final other = (general['items'] as List)
          .map((row) => (row as Map)['id'] as String)
          .where((id) => id != 'h-squat')
          .take(2)
          .toList();
      expect(other, hasLength(2));
      return calls([
        tool('actions', AgentTools.check, {
          'node': 'actions',
          'picks': ['h-squat', ...other],
        }),
        tool('show', AgentTools.showActions, {
          'ids': ['h-squat'],
          'note': '先从这个动作开始。',
        }),
      ]);
    },
  ], latency: Duration.zero);

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

  test('control: a completed action task returns its card', () async {
    final agent = coach(model());
    final result = await agent.send('在家徒手推荐大腿内侧动作');
    expect(
      result.status,
      TurnStatus.ok,
      reason: '${result.error}; ${result.issues}',
    );
    expect(result.actions!.items.single.id, 'h-squat');
  });

  for (final operation in ['safety', 'cancel', 'reset']) {
    test(
      'output done listener $operation prevents stale card and history commit',
      () async {
        final agent = coach(model());
        final token = CancelToken();
        var fired = false;
        final sub = agent.events.listen((event) {
          if (fired ||
              event.kind != AgentEventKind.node ||
            event.node?.id != 'output' ||
            event.node?.status != 'done') {
            return;
        }
          fired = true;
          switch (operation) {
            case 'safety':
              agent.replaceSafetyAvoid({'膝'});
            case 'cancel':
              token.cancel();
            case 'reset':
              agent.reset();
          }
        });
        addTearDown(sub.cancel);
        final result = await agent.send('在家徒手推荐大腿内侧动作', cancel: token);
        expect(
          fired,
          isTrue,
          reason: 'the callback must run at the actual output-done event',
        );
        expect(result.actions, isNull);
        expect(result.plan, isNull);
        expect(result.status, isNot(TurnStatus.ok));
        expect(
          agent.history,
          isEmpty,
          reason: 'the invalidated card must not enter history',
        );
        if (operation == 'safety') {
          expect(
            agent.sessionState.params['limits']!.value,
            contains('limit.knee'),
          );
        } else {
          expect(agent.sessionState.task, isNull);
          expect(agent.sessionState.seenActionIds, isEmpty);
        }
      },
    );
  }
}
