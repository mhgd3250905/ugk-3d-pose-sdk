import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmResponse call(String id, String name, Map<String, Object?> arguments) =>
    LlmResponse(
      content: '',
      finishReason: 'tool_calls',
      toolCalls: [
        LlmToolCall(id: id, name: name, arguments: jsonEncode(arguments)),
      ],
    );

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('hiplab');

  Future<({String result, CoachAgent agent})> probe(
    String name,
    Map<String, Object?> arguments,
  ) async {
    final client = FakeLlmClient([
      call('start', AgentTools.startTask, {'type': 'recommend'}),
      call('probe', name, arguments),
      '暂时不能给出结果。',
    ], latency: Duration.zero);
    final agent = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      enableUserMemory: false,
      maxRequestRetries: 0,
    );
    addTearDown(agent.dispose);
    await agent.send('推荐一些动作', context: const CoachContext(equipment: {}));
    expect(client.requests, hasLength(3));
    expect(agent.sessionState.task?.type, 'recommend');
    final lastRequest = client.requests.last;
    final start = lastRequest.messages.singleWhere(
      (m) => m.toolCallId == 'start',
    );
    expect((jsonDecode(start.content) as Map)['ok'], isTrue);
    final toolResult = lastRequest.messages.singleWhere(
      (m) => m.toolCallId == 'probe',
    );
    return (result: toolResult.content, agent: agent);
  }

  for (final path in [
    'action-library/compact.md',
    'action-library/details/s-figure4.md',
    'action-library/index/scene/home.md',
  ]) {
    test(
      'read cannot expose unfiltered action data after task start: $path',
      () async {
        final response = await probe(AgentTools.read, {'path': path});
        final original = response.agent.files(catalog).read(path);
        expect(
          original,
          isNotNull,
          reason: 'test must target a real data file',
        );
        expect(
          original,
          contains('s-figure4'),
          reason: 'fixture includes a mat action',
        );
        final message = jsonDecode(response.result) as Map<String, dynamic>;
        expect(message['ok'], isFalse);
        expect(message['code'], 'use_action_search');
        expect(
          response.result,
          isNot(contains(catalog['s-figure4']!.name.of('zh'))),
        );
        expect(response.agent.sessionState.seenActionIds, isEmpty);
      },
    );
  }

  for (final directory in [
    'action-library',
    'action-library/details',
    'action-library/index/scene',
  ]) {
    test(
      'removed ls is rejected without exposing action data: $directory',
      () async {
        final response = await probe('ls', {'dir': directory});
        expect(response.agent.files(catalog).ls(directory), isNotNull);
        final message = jsonDecode(response.result) as Map<String, dynamic>;
        expect(message['ok'], isFalse);
        expect(message['code'], 'unknown_tool');
        expect(response.result, isNot(contains('s-figure4')));
        expect(response.agent.sessionState.seenActionIds, isEmpty);
      },
    );
  }

  test('action-library skill remains readable during a task', () async {
    const path = 'action-library/SKILL.md';
    final response = await probe(AgentTools.read, {'path': path});
    final original = response.agent.files(catalog).read(path);
    expect(original, isNotNull);
    expect(response.result, original);
    expect(response.agent.sessionState.seenActionIds, isEmpty);
  });
}
