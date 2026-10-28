import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmToolCall _call(String id, String name, Object args) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(args));

LlmResponse _read(String id, String path, {String? reasoning}) => LlmResponse(
  content: '',
  reasoning: reasoning,
  toolCalls: [
    _call(id, AgentTools.read, {'path': path}),
  ],
);

List<Map<String, Object?>> _assistants(LlmRequest request) => [
  for (final message in request.messages)
    if (message.role == LlmRole.assistant) message.toJson(),
];

String _wire(LlmRequest request) => jsonEncode({
  'messages': [for (final message in request.messages) message.toJson()],
  'tools': [for (final tool in request.tools) tool.toJson()],
});

void _expectProtocol(LlmRequest request) {
  final pending = <String>{};
  for (final message in request.messages) {
    final json = message.toJson();
    if (message.role == LlmRole.assistant) {
      expect(json, contains('reasoning_content'));
      expect(json['reasoning_content'], isA<String>());
      expect(pending, isEmpty);
      pending.addAll(message.toolCalls.map((tool) => tool.id));
    } else {
      expect(json, isNot(contains('reasoning_content')));
      if (message.role == LlmRole.tool) {
        expect(pending.remove(message.toolCallId), isTrue);
      }
    }
  }
  expect(pending, isEmpty);
}

class _CountingMemoryStore extends InMemoryUserMemoryStore {
  _CountingMemoryStore(super.initial);

  int saves = 0;

  @override
  Future<void> save(List<MemoryEntry> entries) async {
    saves++;
    await super.save(entries);
  }
}

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('hiplab');

  CoachAgent agent(
    FakeLlmClient client, {
    bool memory = false,
    UserMemoryStore? store,
    Duration requestTimeout = const Duration(seconds: 60),
    Future<void> Function(Duration)? sleep,
  }) {
    final result = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      enableUserMemory: memory,
      memoryStore: store,
      requestTimeout: requestTimeout,
      random: () => 0.5,
      sleep: sleep ?? (_) async {},
    );
    addTearDown(result.dispose);
    return result;
  }

  test('assistant 序列化始终带 reasoning_content，未返回推理时为空串', () {
    final tool = _call('read_0', AgentTools.read, {
      'path': 'action-library/SKILL.md',
    });
    final messages = [
      const LlmMessage.assistant('answer'),
      LlmMessage.assistant('', toolCalls: [tool]),
      const LlmMessage(LlmRole.assistant, 'generic answer'),
      const LlmMessage.assistant('answer', reasoning: 'reasoning marker'),
    ];
    expect(messages.map((message) => message.toJson()['reasoning_content']), [
      '',
      '',
      '',
      'reasoning marker',
    ]);
    for (final message in const [
      LlmMessage.system('s'),
      LlmMessage.user('u'),
      LlmMessage.tool('read_0', 't'),
    ]) {
      expect(message.toJson(), isNot(contains('reasoning_content')));
    }
  });

  test('兼容旧 compressContext 的可见文本计数，压缩 read 仍保留 assistant 及推理', () {
    final largeReasoning = List.filled(
      10000,
      'private reasoning marker ',
    ).join();
    final oldAssistant = LlmMessage.assistant(
      '',
      toolCalls: [
        _call('old_read', AgentTools.read, {'path': 'old.md'}),
      ],
      reasoning: largeReasoning,
    );
    final recentAssistant = LlmMessage.assistant(
      '',
      toolCalls: [
        _call('recent_read', AgentTools.read, {'path': 'recent.md'}),
      ],
      reasoning: 'recent reasoning marker',
    );
    final oldResult = LlmMessage.tool(
      'old_read',
      List.filled(200, 'file text ').join(),
    );
    const recentResult = LlmMessage.tool('recent_read', 'recent file text');
    final messages = [oldAssistant, oldResult, recentAssistant, recentResult];
    final compressible =
        LinkedHashMap<LlmMessage, CompressibleResult>.identity()
          ..[oldResult] = const CompressibleResult(
            'old_read',
            'old result omitted',
            path: 'old.md',
          );
    final withoutReasoning = LlmMessage.assistant(
      '',
      toolCalls: oldAssistant.toolCalls,
    );
    expect(
      estimateMessageTokens(oldAssistant),
      estimateMessageTokens(withoutReasoning),
    );
    final visibleBudget = messages.fold<int>(
      0,
      (total, message) => total + estimateMessageTokens(message),
    );
    expect(
      compressContext(
        messages,
        fixedTokens: 0,
        budget: visibleBudget,
        keepRecent: 1,
        compressible: compressible,
      ),
      isEmpty,
    );
    expect(messages[1], same(oldResult));

    expect(
      compressContext(
        messages,
        fixedTokens: 0,
        budget: 1,
        keepRecent: 1,
        compressible: compressible,
      ),
      {'old.md'},
    );
    expect(messages[0], same(oldAssistant));
    expect(messages[0].toJson()['reasoning_content'], largeReasoning);
    expect(messages[1].content, 'old result omitted');
    expect(messages[1].toolCallId, 'old_read');
    expect(messages[2], same(recentAssistant));
    expect(
      messages[2].toJson()['reasoning_content'],
      'recent reasoning marker',
    );
    expect(messages[3], same(recentResult));
    _expectProtocol(LlmRequest(messages: messages));
  });

  for (final failure in ['timeout', 'network']) {
    test('$failure 单步重试保留历史和工具 assistant 的推理', () async {
      final client = FakeLlmClient([
        const LlmResponse(
          content: 'previous answer',
          reasoning: 'history reasoning marker',
        ),
        _read(
          'read_0',
          'action-library/SKILL.md',
          reasoning: 'tool reasoning marker',
        ),
        if (failure == 'timeout')
          (_) => Completer<Object>().future
        else
          const LlmException(LlmErrorKind.network, 'network down'),
        const LlmResponse(
          content: 'final answer',
          reasoning: 'final reasoning marker',
        ),
      ], latency: Duration.zero);
      final coach = agent(
        client,
        requestTimeout: const Duration(milliseconds: 50),
      );
      expect((await coach.send('first turn')).status, TurnStatus.ok);
      final result = await coach.send('second turn');
      expect(result.status, TurnStatus.ok);
      expect(result.steps, 2);
      expect(result.records.map((record) => record.retry), [0, 0, 1]);
      expect(client.requests, hasLength(4));
      expect(_wire(client.requests[3]), _wire(client.requests[2]));
      expect(
        _assistants(
          client.requests[3],
        ).map((message) => message['reasoning_content']),
        ['history reasoning marker', 'tool reasoning marker'],
      );
      expect(result.text, 'final answer');
      expect(
        coach.history
            .where((message) => message.role == LlmRole.assistant)
            .map((message) => message.reasoning),
        ['history reasoning marker', 'final reasoning marker'],
      );
      for (final request in client.requests) {
        _expectProtocol(request);
      }
    });
  }

  test('重试前关闭记忆会脱敏历史及工具推理，并保留空 reasoning_content 字段', () async {
    const stored = 'stored-private-marker';
    const remembered = 'remember-argument-marker';
    final store = InMemoryUserMemoryStore([
      MemoryEntry(MemoryKind.goal, stored, at: DateTime.utc(2026)),
    ]);
    final client = FakeLlmClient([
      const LlmResponse(
        content: 'previous answer',
        reasoning: 'private history reasoning marker',
      ),
      LlmResponse(
        content: '',
        reasoning: 'private tool reasoning marker',
        toolCalls: [
          _call('memory_read', AgentTools.read, {
            'path': 'user-memory/SKILL.md',
          }),
          _call('remember_0', AgentTools.remember, {
            'kind': 'injury',
            'text': remembered,
          }),
          _call('list_0', AgentTools.read, {'path': 'action-library'}),
        ],
      ),
      const LlmException(LlmErrorKind.network, 'network down'),
      'final answer',
    ], latency: Duration.zero);
    late CoachAgent coach;
    coach = agent(
      client,
      memory: true,
      store: store,
      sleep: (_) async {
        coach.enableUserMemory = false;
      },
    );
    expect((await coach.send('first turn')).status, TurnStatus.ok);
    expect((await coach.send('second turn')).status, TurnStatus.ok);
    final failedWire = _wire(client.requests[2]);
    expect(
      failedWire,
      allOf(
        contains(stored),
        contains(remembered),
        contains('private history reasoning marker'),
      ),
    );
    final retry = client.requests[3];
    final retryWire = _wire(retry);
    for (final secret in [
      stored,
      remembered,
      'private history reasoning marker',
      'private tool reasoning marker',
    ]) {
      expect(retryWire, isNot(contains(secret)));
    }
    expect(_assistants(retry), isNotEmpty);
    expect(
      _assistants(retry).map((message) => message['reasoning_content']),
      everyElement(''),
    );
    expect(retryWire, contains('previous answer'));
    expect(retryWire, contains('用户记忆已关闭'));
    expect(
      retry.tools.map((tool) => tool.name),
      isNot(anyOf(contains(AgentTools.remember), contains(AgentTools.forget))),
    );
    _expectProtocol(retry);
    await Future<void>.delayed(Duration.zero);
    // remember 已在关闭开关前返回成功并持久化；关闭记忆只阻止后续请求携带私密内容。
    expect(store.entries.map((entry) => entry.text), [stored, remembered]);
  });

  test('模型请求期间清空记忆：迟到 remember 不复活私密内容，本轮后续按关闭记忆处理', () async {
    const stored = 'cleared-private-memory-marker';
    const privateReasoning = 'cleared-private-reasoning-marker';
    final store = _CountingMemoryStore([
      MemoryEntry(MemoryKind.goal, stored, at: DateTime.utc(2026)),
    ]);
    final requested = Completer<void>();
    final response = Completer<Object>();
    final client = FakeLlmClient([
      (_) {
        requested.complete();
        return response.future;
      },
      'answer after clear',
      'next turn answer',
    ], latency: Duration.zero);
    addTearDown(() {
      if (!response.isCompleted) response.complete('unused late response');
    });
    final coach = agent(client, memory: true, store: store);
    final pending = coach.send('first turn');
    await requested.future;
    expect(_wire(client.requests.single), contains(stored));
    await coach.clearMemory();
    expect(store.saves, 1);
    expect(store.entries, isEmpty);

    response.complete(
      LlmResponse(
        content: '',
        reasoning: privateReasoning,
        toolCalls: [
          _call('stale_remember', AgentTools.remember, {
            'kind': 'goal',
            'text': stored,
          }),
          _call('safe_list', AgentTools.read, {'path': 'action-library'}),
        ],
      ),
    );
    expect((await pending).status, TurnStatus.ok);
    expect(client.requests, hasLength(2));
    final afterClear = client.requests[1];
    expect(afterClear.messages.first.content, isNot(contains('user-memory')));
    expect(
      afterClear.tools.map((tool) => tool.name),
      isNot(contains(AgentTools.remember)),
    );
    final afterClearWire = _wire(afterClear);
    expect(afterClearWire, isNot(contains(stored)));
    expect(afterClearWire, isNot(contains(privateReasoning)));
    expect(_assistants(afterClear).single['reasoning_content'], '');
    expect(
      afterClear.messages
          .where((message) => message.role == LlmRole.assistant)
          .single
          .toolCalls
          .map((tool) => tool.name),
      [AgentTools.read],
    );
    _expectProtocol(afterClear);
    expect(store.saves, 1, reason: '清空前在途响应的 remember 不应发起任何保存。');
    expect(await coach.memory(), isEmpty);
    expect(store.entries, isEmpty);

    expect((await coach.send('next turn')).status, TurnStatus.ok);
    final nextTurn = client.requests[2];
    expect(
      nextTurn.tools.map((tool) => tool.name),
      contains(AgentTools.remember),
    );
    expect(_wire(nextTurn), isNot(contains(stored)));
    expect(_wire(nextTurn), isNot(contains(privateReasoning)));
    expect(store.entries, isEmpty);
    expect(store.saves, 1);
    _expectProtocol(nextTurn);
  });

  for (final operation in ['cancel', 'reset']) {
    test('工具步骤后 $operation：旧轮及迟到响应的推理不进入新轮', () async {
      final waiting = Completer<void>();
      final lateResponse = Completer<Object>();
      final token = CancelToken();
      final client = FakeLlmClient([
        _read(
          'old_read',
          'action-library/SKILL.md',
          reasoning: 'old tool reasoning marker',
        ),
        (_) {
          waiting.complete();
          return lateResponse.future;
        },
        const LlmResponse(
          content: 'new answer',
          reasoning: 'new reasoning marker',
        ),
        'next answer',
      ], latency: Duration.zero);
      addTearDown(() {
        if (!lateResponse.isCompleted) {
          lateResponse.complete('unused late response');
        }
      });
      final coach = agent(client);
      final oldTurn = coach.send('old turn', cancel: token);
      await waiting.future;
      operation == 'cancel' ? token.cancel() : coach.reset();
      final cancelled = await oldTurn.timeout(const Duration(seconds: 1));
      expect(cancelled.status, TurnStatus.cancelled);
      expect(cancelled.records.map((record) => record.outcome), [
        CallOutcome.toolStep,
        CallOutcome.cancelled,
      ]);
      expect(coach.history, isEmpty);
      expect((await coach.send('new turn')).status, TurnStatus.ok);
      expect(
        _wire(client.requests[2]),
        isNot(contains('old tool reasoning marker')),
      );
      lateResponse.complete(
        const LlmResponse(
          content: 'late answer',
          reasoning: 'late old reasoning marker',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect((await coach.send('next turn')).status, TurnStatus.ok);
      final nextWire = _wire(client.requests[3]);
      expect(nextWire, contains('new reasoning marker'));
      expect(nextWire, isNot(contains('old tool reasoning marker')));
      expect(nextWire, isNot(contains('late old reasoning marker')));
      expect(
        coach.history.map((message) => message.reasoning),
        isNot(contains('late old reasoning marker')),
      );
      _expectProtocol(client.requests[3]);
    });
  }

  test('清空期间迟到的最终文字保留正文，历史推理脱敏后不带入下一轮', () async {
    const stored = 'late-final-stored-private-marker';
    const privateReasoning = 'late-final-private-reasoning-marker';
    const answer = 'visible final answer';
    final store = _CountingMemoryStore([
      MemoryEntry(MemoryKind.goal, stored, at: DateTime.utc(2026)),
    ]);
    final requested = Completer<void>();
    final response = Completer<Object>();
    final client = FakeLlmClient([
      (_) {
        requested.complete();
        return response.future;
      },
      'next turn answer',
    ], latency: Duration.zero);
    addTearDown(() {
      if (!response.isCompleted) response.complete('unused late response');
    });
    final coach = agent(client, memory: true, store: store);
    final pending = coach.send('first turn');
    await requested.future;
    expect(_wire(client.requests.single), contains(stored));
    await coach.clearMemory();
    response.complete(
      const LlmResponse(
        content: answer,
        reasoning: '$privateReasoning: $stored',
      ),
    );

    final result = await pending;
    expect(result.status, TurnStatus.ok);
    expect(result.text, answer);
    final history = coach.history.singleWhere(
      (message) => message.role == LlmRole.assistant,
    );
    expect(history.content, answer);
    expect(history.reasoning, '');
    expect(history.toJson()['reasoning_content'], '');
    expect(await coach.memory(), isEmpty);

    expect((await coach.send('next turn')).status, TurnStatus.ok);
    final nextTurn = client.requests[1];
    expect(_wire(nextTurn), contains(answer));
    expect(_wire(nextTurn), isNot(contains(stored)));
    expect(_wire(nextTurn), isNot(contains(privateReasoning)));
    expect(
      _assistants(nextTurn).map((message) => message['reasoning_content']),
      everyElement(''),
    );
    expect(store.entries, isEmpty);
    expect(store.saves, 1);
    _expectProtocol(nextTurn);
  });
}
