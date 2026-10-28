import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmToolCall call(String id, String name, Object arguments) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(arguments));

LlmResponse calls(List<LlmToolCall> tools) => LlmResponse(
  content: '',
  toolCalls: tools,
  finishReason: 'tool_calls',
  model: 'fake',
);

LlmResponse ask() => calls([
  call('ask', 'ask_user', {'question': '在哪里训练？', 'mode': 'text'}),
]);

Map<String, Object?> user(Object value, String quote) => {
  'value': value,
  'source': 'user',
  'quote': quote,
};

Map<String, dynamic> result(FakeLlmClient client, String id) =>
    jsonDecode(
          client.requests
              .expand((request) => request.messages)
              .firstWhere((message) => message.toolCallId == id)
              .content,
        )
        as Map<String, dynamic>;

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
    'real loop emits completed nodes in order with sourced parameters',
    () async {
      final client = FakeLlmClient([
        calls([
          call('start', 'start_task', {'type': 'plan'}),
          call('understand', 'check', {'node': 'understand'}),
          call('params', 'set_params', {
            'fields': {
              'scene': user('home', '在家'),
              'goal': user(['body.core'], '核心'),
              'minutes': user(20, '20 分钟'),
            },
          }),
          call('parameters', 'check', {'node': 'parameters'}),
        ]),
        ask(),
      ], latency: Duration.zero);
      final coach = agent(client);
      final events = <AgentEvent>[];
      coach.events.listen(events.add);
      await coach.send('在家练核心 20 分钟');

      expect(result(client, 'start')['ok'], isTrue);
      expect(result(client, 'understand')['ok'], isTrue);
      expect(result(client, 'params')['ok'], isTrue);
      expect(result(client, 'parameters')['ok'], isTrue);
      final done = events
          .where(
            (event) =>
                event.kind == AgentEventKind.node &&
                event.node?.status == 'done',
          )
          .map((event) => event.node!)
          .toList();
      expect(done.map((node) => node.id), ['understand', 'parameters']);
      expect(done.last.stamp, contains('20 分钟（你说的）'));
      expect(
        coach.sessionState.task!.nodes
            .singleWhere((n) => n.status == 'current')
            .id,
        'actions',
      );
    },
  );

  test(
    'skipping a node and model-supplied stamps or planId are rejected',
    () async {
      final client = FakeLlmClient([
        calls([
          call('start', 'start_task', {'type': 'plan'}),
          call('skip', 'check', {'node': 'parameters'}),
          call('skipped-understand', 'check', {'node': 'understand'}),
        ]),
        calls([
          call('stamp', 'check', {'node': 'understand', 'stamp': '伪造'}),
        ]),
        calls([
          call('planId', 'check', {'node': 'understand', 'planId': 'p'}),
        ]),
        calls([
          call('right', 'check', {'node': 'understand'}),
        ]),
        ask(),
      ], latency: Duration.zero);
      final coach = agent(client);
      final events = <AgentEvent>[];
      coach.events.listen(events.add);
      await coach.send('安排计划');
      expect(result(client, 'skip')['code'], 'missing_parameters');
      expect(result(client, 'skip')['expected'], ['scene', 'goal', 'minutes']);
      expect(
        result(client, 'skipped-understand')['code'],
        'skipped_after_error',
      );
      expect(result(client, 'stamp')['code'], 'invalid_arguments');
      expect(result(client, 'planId')['code'], 'invalid_arguments');
      expect(result(client, 'right')['ok'], isTrue);
      for (final id in ['stamp', 'planId']) {
        expect(
          client.requests.last.messages
              .singleWhere((message) => message.toolCallId == id)
              .content,
          '[已归档，见当前状态]',
        );
      }
      expect(coach.sessionState.task!.nodes.first.stamp, isNot('伪造'));
      expect(
        events.where(
          (event) =>
              event.kind == AgentEventKind.node &&
              event.node?.id == 'understand' &&
              event.node?.status == 'done',
        ),
        hasLength(1),
      );
    },
  );

  for (final type in ['recommend', 'plan']) {
    test('$type cannot deliver its card before nodes are complete', () async {
      final show = type == 'plan' ? 'show_plan' : 'show_actions';
      final client = FakeLlmClient([
        calls([
          call('start', 'start_task', {'type': type}),
        ]),
        calls([call('early', show, {})]),
        ask(),
      ], latency: Duration.zero);
      final coach = agent(client);
      final reply = await coach.send('请帮我训练');
      expect(result(client, 'early')['ok'], isFalse);
      expect(coach.sessionState.task!.nodes.first.status, 'done');
      expect(coach.sessionState.task!.nodes[1].status, 'current');
      expect(reply.actions, isNull);
      expect(reply.plan, isNull);
    });
  }

  test('ask_user pauses and answer resumes the same node', () async {
    final client = FakeLlmClient([
      calls([
        call('start', 'start_task', {'type': 'plan'}),
        call('understand', 'check', {'node': 'understand'}),
        call('goal', 'set_params', {
          'fields': {
            'goal': user(['body.core'], '核心'),
          },
        }),
      ]),
      ask(),
      calls([
        call('params', 'set_params', {
          'fields': {'scene': user('home', '在家'), 'minutes': user(20, '20 分钟')},
        }),
        call('parameters', 'check', {'node': 'parameters'}),
      ]),
      calls([
        call('ask2', 'ask_user', {'question': '还有其他条件吗？', 'mode': 'text'}),
      ]),
    ], latency: Duration.zero);
    final coach = agent(client);
    final first = await coach.send('帮我练核心');
    expect(first.question, isNotNull);
    expect(
      coach.sessionState.task!.nodes
          .singleWhere((n) => n.status == 'current')
          .id,
      'parameters',
    );
    final second = await coach.send('在家，20 分钟');
    expect(second.question, isNotNull);
    expect(result(client, 'params')['ok'], isTrue);
    expect(result(client, 'parameters')['ok'], isTrue);
    expect(
      coach.sessionState.task!.nodes
          .singleWhere((n) => n.status == 'current')
          .id,
      'actions',
    );
    expect(coach.sessionState.params['goal']!.value, ['body.core']);
  });

  test(
    'plain question and answer does not create a task or node events',
    () async {
      final client = FakeLlmClient(['可以适当起身活动。'], latency: Duration.zero);
      final coach = agent(client);
      final events = <AgentEvent>[];
      coach.events.listen(events.add);
      await coach.send('久坐后需要活动吗？');
      expect(coach.sessionState.task, isNull);
      expect(
        events.where((event) => event.kind == AgentEventKind.node),
        isEmpty,
      );
    },
  );
}
