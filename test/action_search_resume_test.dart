import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmToolCall tool(String id, String name, Object arguments) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(arguments));
LlmResponse calls(List<LlmToolCall> tools) => LlmResponse(
  content: '',
  toolCalls: tools,
  finishReason: 'tool_calls',
  model: 'fake',
);
LlmResponse question() => calls([
  tool('question', AgentTools.askUser, {
    'question': '还有其他要求吗？',
    'mode': 'text',
  }),
]);

void expectProtocol(List<LlmMessage> messages) {
  final pending = <String>{};
  for (final message in messages) {
    if (message.role == LlmRole.assistant) {
      expect(pending, isEmpty, reason: 'previous batch is incomplete');
      pending.addAll(message.toolCalls.map((call) => call.id));
    } else if (message.role == LlmRole.tool) {
      expect(
        pending.remove(message.toolCallId),
        isTrue,
        reason: 'tool reply must match this assistant batch',
      );
    } else {
      expect(
        pending,
        isEmpty,
        reason: 'tool replies must precede next message',
      );
    }
  }
  expect(pending, isEmpty);
}

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('smartfit');
  CoachAgent agent(FakeLlmClient client, {bool memory = false}) {
    final coach = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      enableUserMemory: memory,
      maxRequestRetries: 0,
    );
    addTearDown(coach.dispose);
    return coach;
  }

  test(
    'search archive and read result remain visible after ask and user answer',
    () async {
      final client = FakeLlmClient([
        calls([
          tool('start', AgentTools.startTask, {'type': 'recommend'}),
          tool('search', AgentTools.searchActions, {
            'tags': <String>[],
            'limit': 3,
          }),
        ]),
        calls([
          tool('read', AgentTools.read, {'path': 'action-library/SKILL.md'}),
        ]),
        question(),
        '收到。',
      ], latency: Duration.zero);
      final coach = agent(client);
      final first = await coach.send(
        '推荐动作',
        context: const CoachContext(equipment: {}),
      );
      expect(first.question, isNotNull);
      expect(
        first.reads,
        isEmpty,
        reason: 'start_task already supplied the full skill',
      );
      final beforeQuestion = client.requests[2];
      final originalSearch = client.requests[1].messages
          .singleWhere((m) => m.toolCallId == 'search')
          .content;
      final data = jsonDecode(originalSearch) as Map<String, dynamic>;
      expect(data['ok'], isTrue);
      final ids = (data['items'] as List)
          .map((item) => (item as Map)['id'])
          .toSet();
      expect(ids, hasLength(3));
      expect(coach.sessionState.seenActionIds, ids);
      final searchResult = beforeQuestion.messages
          .singleWhere((m) => m.toolCallId == 'search')
          .content;
      expect(searchResult, '[已归档，候选见当前状态 candidates]');
      final current =
          jsonDecode(
                beforeQuestion.messages[1].content.substring('当前状态：'.length),
              )
              as Map<String, dynamic>;
      final candidates = (current['candidates'] as List).cast<List<Object?>>();
      for (final row in data['items'] as List) {
        final item = row as Map;
        final candidate = candidates.singleWhere(
          (value) => value.first == item['id'],
        );
        expect(candidate[1], item['name']);
      }
      await coach.send('没有其他要求');
      final resumed = client.requests[3];
      expect(
        resumed.messages.singleWhere((m) => m.toolCallId == 'search').content,
        searchResult,
      );
      final read = resumed.messages.singleWhere((m) => m.toolCallId == 'read');
      expect(read.content, '[已在 start_task 结果中]');
      final start =
          jsonDecode(
                resumed.messages
                    .singleWhere((m) => m.toolCallId == 'start')
                    .content,
              )
              as Map<String, dynamic>;
      expect(
        (start['skills'] as Map<String, dynamic>)['action-library'],
        SkillFiles.build(profile, catalog).read('action-library/SKILL.md'),
      );
      expect(resumed.messages.last.role, LlmRole.user);
      expectProtocol(resumed.messages);
    },
  );

  test(
    'cancellation before question commit retains no in-flight search history or seen ids',
    () async {
      final entered = Completer<void>();
      final release = Completer<Object>();
      final client = FakeLlmClient([
        calls([
          tool('start', AgentTools.startTask, {'type': 'recommend'}),
          tool('search', AgentTools.searchActions, {
            'tags': <String>[],
            'limit': 3,
          }),
        ]),
        (LlmRequest _) {
          entered.complete();
          return release.future;
        },
      ], latency: Duration.zero);
      final coach = agent(client);
      final cancel = CancelToken();
      final pending = coach.send('推荐动作', cancel: cancel);
      await entered.future;
      expect(coach.sessionState.seenActionIds, isNotEmpty);
      cancel.cancel();
      expect((await pending).status, TurnStatus.cancelled);
      expect(coach.history, isEmpty);
      expect(coach.sessionState.seenActionIds, isEmpty);
      release.complete(question());
      await Future<void>.delayed(Duration.zero);
      expect(coach.history, isEmpty);
      expect(coach.sessionState.seenActionIds, isEmpty);
    },
  );

  test(
    'memory privacy and reused tool IDs preserve the search batch',
    () async {
      const secret = 'private-memory-sentinel';
      final client = FakeLlmClient([
        calls([
          tool('shared', AgentTools.remember, {'kind': 'goal', 'text': secret}),
        ]),
        calls([
          tool('start', AgentTools.startTask, {'type': 'recommend'}),
          tool('shared', AgentTools.searchActions, {
            'tags': <String>[],
            'limit': 3,
          }),
        ]),
        question(),
        '收到。',
      ], latency: Duration.zero);
      final coach = agent(client, memory: true);
      expect((await coach.send('推荐动作')).question, isNotNull);
      final rawSearch = client.requests[2].messages
          .where((m) => m.toolCallId == 'shared')
          .map((m) => jsonDecode(m.content) as Map)
          .singleWhere((result) => result['items'] is List);
      expect(rawSearch['ok'], isTrue);
      final ids = (rawSearch['items'] as List)
          .map((item) => (item as Map)['id'] as String)
          .toList();
      expect(ids, hasLength(3));
      coach.enableUserMemory = false;
      await coach.send('谢谢');
      final resumed = client.requests.last;
      expect(
        jsonEncode([for (final m in resumed.messages) m.toJson()]),
        isNot(contains(secret)),
      );
      final searchResult = resumed.messages.singleWhere(
        (m) => m.toolCallId == 'shared',
      );
      expect(searchResult.content, '[已归档，候选见当前状态 candidates]');
      final current =
          jsonDecode(resumed.messages[1].content.substring('当前状态：'.length))
              as Map<String, dynamic>;
      final candidates = (current['candidates'] as List).cast<List<Object?>>();
      for (final id in ids) {
        expect(candidates.map((row) => row.first), contains(id));
      }
      expectProtocol(resumed.messages);
    },
  );
}
