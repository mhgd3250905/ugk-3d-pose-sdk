import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

var _seq = 0;
LlmToolCall _call(String name, Object args) =>
    LlmToolCall(id: 'r${_seq++}', name: name, arguments: jsonEncode(args));

LlmResponse _tools(List<LlmToolCall> calls, [String text = '']) => LlmResponse(
  content: text,
  toolCalls: calls,
  finishReason: 'tool_calls',
  model: 'fake',
);

LlmResponse _read(String path) => _tools([
  _call('read', {'path': path}),
]);

FakeStep _hang() =>
    (_) => Completer<Object>().future;

/// 每个 assistant 的 tool_call 后面都有对应 tool 回复，每个 tool 回复都对应前面的调用。
void _expectProtocol(List<LlmMessage> msgs) {
  final pending = <String>{};
  for (final m in msgs) {
    if (m.role == LlmRole.assistant) {
      expect(pending, isEmpty, reason: '上一组 tool_call 未全部回复');
      pending.addAll(m.toolCalls.map((t) => t.id));
    } else if (m.role == LlmRole.tool) {
      expect(
        pending.remove(m.toolCallId),
        isTrue,
        reason: '孤立的 tool 回复 ${m.toolCallId}',
      );
    }
  }
  expect(pending, isEmpty);
}

void main() {
  final catalog = loadCatalog();
  final hiplab = loadProfile('hiplab');
  late List<Duration> delays;

  setUp(() => delays = []);

  CoachAgent agent(
    FakeLlmClient c, {
    SessionFallback? fallback,
    UsageSink? usage,
    Duration requestTimeout = const Duration(seconds: 60),
    Duration turnTimeout = const Duration(seconds: 360),
    int contextBudgetTokens = 60000,
    int keepRecentSteps = 3,
    Future<void> Function(Duration)? sleep,
    UserMemoryStore? store,
  }) => CoachAgent(
    client: c,
    memoryStore: store,
    usage: usage,
    catalog: () => catalog,
    profile: hiplab,
    fallback: fallback ?? (_) => const SessionFallbackReply('模板回复'),
    requestTimeout: requestTimeout,
    turnTimeout: turnTimeout,
    contextBudgetTokens: contextBudgetTokens,
    keepRecentSteps: keepRecentSteps,
    random: () => 0.5, // 抖动系数 = 1.0
    sleep:
        sleep ??
        (d) async {
          delays.add(d);
        },
  );

  test('默认参数：maxSteps=100、重试 4 次、整轮 360s、慢提示 30s、预算 60k', () {
    final a = CoachAgent(
      client: FakeLlmClient(const []),
      catalog: () => catalog,
      profile: hiplab,
    );
    expect(a.maxSteps, 100);
    expect(a.maxRequestRetries, 4);
    expect(a.retryBaseDelay, const Duration(seconds: 1));
    expect(a.retryMaxDelay, const Duration(seconds: 15));
    expect(a.turnTimeout, const Duration(seconds: 360));
    expect(a.slowAfter, const Duration(seconds: 30));
    expect(a.requestTimeout, const Duration(seconds: 60));
    expect(a.contextBudgetTokens, 60000);
    expect(a.maxStallSteps, 3);
  });

  test('超时后只重试这一步并成功：之前的步骤和读过的文件保留，records 标 retry', () async {
    final c = FakeLlmClient([
      _read('action-library/SKILL.md'),
      _hang(),
      '可以看看。',
    ]);
    final a = agent(c, requestTimeout: const Duration(milliseconds: 40));
    final events = <AgentEvent>[];
    a.events.listen(events.add);
    final r = await a.send('展示臀部动作');
    expect(r.status, TurnStatus.ok);
    expect(c.requests.length, 3);
    expect(r.steps, 2);
    expect(r.reads, ['action-library/SKILL.md']);
    expect(r.records.map((x) => x.outcome), [
      CallOutcome.toolStep,
      CallOutcome.error,
      CallOutcome.passed,
    ]);
    expect(r.records.map((x) => x.retry), [0, 0, 1]);
    expect(r.records[1].errorKind, 'timeout');
    // 重试请求与超时那次相同：带着第 1 步的读取结果。
    expect(c.requests[2].messages.length, c.requests[1].messages.length);
    expect(c.requests[2].messages.last.role, LlmRole.tool);
    final retry = events.singleWhere((e) => e.kind == AgentEventKind.retrying);
    expect(
      (retry.attempt, retry.maxAttempts, retry.reason),
      (1, 4, RequestErrorClass.timeout),
    );
    expect(delays, [const Duration(seconds: 1)]);
  });

  test('429 / 503 尊重 Retry-After（封顶 15s）', () async {
    final c = FakeLlmClient([
      const LlmException(
        LlmErrorKind.rateLimited,
        'slow',
        statusCode: 429,
        retryAfter: Duration(seconds: 7),
      ),
      const LlmException(
        LlmErrorKind.http,
        'busy',
        statusCode: 503,
        retryAfter: Duration(seconds: 60),
      ),
      '好的，想练哪里？',
    ]);
    final r = await agent(c).send('练练');
    expect(r.status, TurnStatus.ok);
    expect(delays, [const Duration(seconds: 7), const Duration(seconds: 15)]);
  });

  test('401 不重试，直接回落并标注原因', () async {
    final c = FakeLlmClient([
      const LlmException(LlmErrorKind.auth, 'bad key', statusCode: 401),
      '不该到这',
    ]);
    final r = await agent(c).send('练练');
    expect(r.status, TurnStatus.fallback);
    expect(r.text, '模板回复');
    expect(c.requests.length, 1);
    expect(delays, isEmpty);
    expect(r.fallbackReason, FallbackReason.auth);
    final e = r.error as AgentRequestFailed;
    expect(
      (e.kind, e.errorClass),
      (AgentFailureKind.nonRetryable, RequestErrorClass.auth),
    );
  });

  test('重试用尽回落：退避 1/2/4/8s，records 与 sink 完整', () async {
    final sink = MemoryUsageSink();
    final c = FakeLlmClient([
      _read('action-library/SKILL.md'),
      for (var i = 0; i < 5; i++)
        const LlmException(LlmErrorKind.network, 'down'),
    ]);
    final r = await agent(c, usage: sink).send('练练');
    expect(r.status, TurnStatus.fallback);
    expect(r.fallbackReason, FallbackReason.offline);
    expect(delays, [
      for (final s in [1, 2, 4, 8]) Duration(seconds: s),
    ]);
    expect(r.records.length, 6);
    expect(r.records.skip(1).map((x) => x.retry), [0, 1, 2, 3, 4]);
    expect(
      r.records.skip(1).every((x) => x.outcome == CallOutcome.error),
      isTrue,
    );
    expect(sink.records.map((x) => x.id), r.records.map((x) => x.id));
    final e = r.error as AgentRequestFailed;
    expect((e.kind, e.attempts), (AgentFailureKind.retriesExhausted, 5));
  });

  for (final how in ['cancel', 'reset']) {
    test('退避中 $how：立即结束、不回写、不回落', () async {
      final sleeping = Completer<void>();
      var fellBack = false;
      final token = CancelToken();
      final c = FakeLlmClient([
        const LlmException(LlmErrorKind.network, 'down'),
        '不该到这',
      ]);
      final a = agent(
        c,
        fallback: (_) {
          fellBack = true;
          return const SessionFallbackReply('模板');
        },
        sleep: (_) {
          sleeping.complete();
          return Completer<void>().future; // 永不结束，只能被打断
        },
      );
      final events = <AgentEvent>[];
      a.events.listen(events.add);
      final f = a.send('练练', cancel: token);
      await sleeping.future;
      how == 'cancel' ? token.cancel() : a.reset();
      final r = await f.timeout(const Duration(seconds: 1));
      expect(r.status, TurnStatus.cancelled);
      expect(r.records.length, 1);
      expect(fellBack, isFalse);
      expect(a.history, isEmpty);
      expect(a.turnCount, 0);
      expect(c.requests.length, 1);
      expect(events.where((e) => e.kind == AgentEventKind.done), isEmpty);
    });
  }

  test('整轮时限触发回落', () async {
    final c = FakeLlmClient([_hang()]);
    final r = await agent(
      c,
      turnTimeout: const Duration(milliseconds: 60),
    ).send('练练');
    expect(r.status, TurnStatus.fallback);
    expect(r.fallbackReason, FallbackReason.timeout);
    expect((r.error as AgentRequestFailed).kind, AgentFailureKind.turnTimeout);
    expect(r.records.single.errorKind, 'timeout');
  });

  test('上下文超长：先强制压缩再重试成功，压缩后 tool_call_id 协议有效', () async {
    final c = FakeLlmClient([
      _read('action-library/SKILL.md'),
      _read('action-library/index/scene/home.md'),
      const LlmException(
        LlmErrorKind.http,
        "This model's maximum context length is 65536 tokens",
        statusCode: 400,
      ),
      '可以看看。',
    ]);
    final a = agent(c);
    final events = <AgentEvent>[];
    a.events.listen(events.add);
    final r = await a.send('展示臀部动作');
    expect(r.status, TurnStatus.ok);
    expect(delays, isEmpty);
    final last = c.requests.last.messages;
    final tools = last.where((m) => m.role == LlmRole.tool).toList();
    expect(tools.first.content, startsWith('已读 action-library/SKILL.md（'));
    expect(tools.last.content, isNot(startsWith('已读'))); // 最近一步完整保留
    _expectProtocol(last);
    expect(
      events.singleWhere((e) => e.kind == AgentEventKind.retrying).reason,
      RequestErrorClass.contextTooLong,
    );
  });

  test('超预算压缩较早的 read：协议有效，被压缩的文件可再读全文', () async {
    final c = FakeLlmClient([
      _read('action-library/SKILL.md'),
      _read('plan-training/SKILL.md'),
      _read('action-library/SKILL.md'),
      '可以看看。',
    ]);
    final r = await agent(
      c,
      contextBudgetTokens: 1,
      keepRecentSteps: 1,
    ).send('展示臀部动作');
    expect(r.status, TurnStatus.ok);
    final third = c.requests[2].messages
        .where((m) => m.role == LlmRole.tool)
        .toList();
    expect(third.first.content, startsWith('已读 action-library/SKILL.md（'));
    final fourth = c.requests[3].messages;
    _expectProtocol(fourth);
    final t4 = fourth.where((m) => m.role == LlmRole.tool).toList();
    expect(t4[1].content, startsWith('已读 plan-training/SKILL.md（'));
    expect(t4.last.content, isNot(contains('已读'))); // 再读给全文
    expect(t4.last.content.length, greaterThan(100));
  });

  test('相同工具调用空转：提示一次，再犯回落', () async {
    final c = FakeLlmClient([
      for (var i = 0; i < 6; i++) _read('action-library/SKILL.md'),
    ]);
    final r = await agent(c).send('展示臀部动作');
    expect(r.status, TurnStatus.fallback);
    expect(r.error, isA<AgentStalled>());
    expect(c.requests.length, 4);
    final hint = c.requests[3].messages.last;
    expect(hint.role, LlmRole.user);
    expect(hint.content, contains('完全相同'));
  });

  String wire(LlmRequest r) => jsonEncode({
    'messages': [for (final m in r.messages) m.toJson()],
    'tools': [for (final t in r.tools) t.toJson()],
  });

  // 第一步：读记忆技能 + remember（参数含私密标记）；第二步请求失败后重试。
  for (final when in ['backoff', 'inflight']) {
    test(
      '[P2] ${when == 'backoff' ? '退避期间' : '在途失败前'}关闭记忆：重试请求不含摘要、记忆技能、记忆工具与调用参数/结果',
      () async {
        const stored = 'stored-only-private-sentinel';
        const said = 'remember-arg-private-sentinel';
        final store = InMemoryUserMemoryStore([
          MemoryEntry(MemoryKind.goal, stored, at: DateTime.utc(2026)),
        ]);
        late CoachAgent a;
        final c = FakeLlmClient([
          _tools([
            _call('read', {'path': 'user-memory/SKILL.md'}),
            _call('remember', {'kind': 'injury', 'text': said}),
          ]),
          if (when == 'backoff')
            const LlmException(LlmErrorKind.network, 'down')
          else
            (_) async {
              a.enableUserMemory = false;
              throw const LlmException(LlmErrorKind.network, 'down');
            },
          '好的。',
        ]);
        a = agent(
          c,
          store: store,
          sleep: (_) async {
            if (when == 'backoff') a.enableUserMemory = false;
          },
        );
        final r = await a.send('我左膝疼');
        expect(r.status, TurnStatus.ok);
        expect(c.requests.length, 3);
        expect(wire(c.requests[1]), allOf(contains(stored), contains(said)));
        final retry = c.requests[2];
        final w = wire(retry);
        expect(w, isNot(contains(stored)));
        expect(w, isNot(contains(said)));
        expect(
          retry.messages.first.content,
          isNot(contains('user-memory/SKILL.md')),
        );
        expect(
          retry.tools.map((t) => t.name),
          isNot(anyOf(contains('remember'), contains('forget'))),
        );
        expect(w, contains('用户记忆已关闭'));
        _expectProtocol(retry.messages);
        await Future<void>.delayed(Duration.zero);
        // 关闭记忆只阻止后续操作；此前已成功的工具已持久化。
        expect(store.entries.map((e) => e.text), [stored, said]);
      },
    );
  }

  test(
    '[P2] retrying 同步监听器里 reset：旧轮无需放行退避即返回 cancelled，不发第二次请求、不回写',
    () async {
      final c = FakeLlmClient([
        const LlmException(LlmErrorKind.network, 'down'),
        '不该到这',
      ]);
      var fellBack = false;
      final a = agent(
        c,
        fallback: (_) {
          fellBack = true;
          return const SessionFallbackReply('模板');
        },
        sleep: (_) => Completer<void>().future, // 永不放行
      );
      a.events.listen((e) {
        if (e.kind == AgentEventKind.retrying) a.reset();
      });
      final r = await a.send('练练').timeout(const Duration(milliseconds: 150));
      expect(r.status, TurnStatus.cancelled);
      expect(c.requests.length, 1);
      expect(fellBack, isFalse);
      expect(a.history, isEmpty);
      expect(a.turnCount, 0);
    },
  );

  test('[P2] 不同目录的 read 探索不触发空转，正常交付', () async {
    final c = FakeLlmClient([
      _read(''),
      _read('action-library'),
      _read('action-library/index'),
      _read('action-library/index/scene'),
      '可以看看。',
    ]);
    final r = await agent(c).send('展示臀部动作');
    expect(r.status, TurnStatus.ok);
    expect(r.error, isNull);
    expect(c.requests.length, 5);
    for (final req in c.requests) {
      expect(req.messages.last.content, isNot(contains('系统提示')));
    }
  });

  test('[P2] 同一目录的不同路径反复 read 仍判为无新信息：提示一次，再犯回落', () async {
    final c = FakeLlmClient([
      for (var i = 0; i < 3; i++) ...[
        _read('action-library'),
        _read('./action-library/'),
      ],
    ]);
    final r = await agent(c).send('展示臀部动作');
    expect(r.status, TurnStatus.fallback);
    expect((r.error as AgentStalled).why, 'no_new_info');
    expect(c.requests.length, 5);
    expect(c.requests[4].messages.last.content, contains('没有获得新信息'));
  });

  test('[P3] 跨步骤复用 tool_call_id：压缩元数据按消息关联，不错配摘要与已读集合', () async {
    LlmResponse readAs(String id, String path) => _tools([
      LlmToolCall(id: id, name: 'read', arguments: jsonEncode({'path': path})),
    ]);
    final c = FakeLlmClient([
      readAs('call_0', 'action-library/SKILL.md'),
      readAs('call_0', 'plan-training/SKILL.md'),
      _read('action-library/SKILL.md'),
      '可以看看。',
    ]);
    final r = await agent(
      c,
      contextBudgetTokens: 1,
      keepRecentSteps: 1,
    ).send('展示臀部动作');
    expect(r.status, TurnStatus.ok);
    final third = c.requests[2].messages
        .where((m) => m.role == LlmRole.tool)
        .toList();
    expect(third.first.content, startsWith('已读 action-library/SKILL.md（'));
    expect(third[1].content, isNot(startsWith('已读'))); // 第二步完整保留
    final t4 = c.requests[3].messages
        .where((m) => m.role == LlmRole.tool)
        .toList();
    expect(t4[1].content, startsWith('已读 plan-training/SKILL.md（'));
    expect(t4.last.content, isNot(contains('已读'))); // 第一个文件被压缩后再读给全文
    expect(t4.last.content.length, greaterThan(100));
  });
}
