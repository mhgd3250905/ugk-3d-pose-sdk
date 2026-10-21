import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

var _seq = 0;
LlmToolCall _call(String name, Object args) => LlmToolCall(id: 'r${_seq++}', name: name, arguments: jsonEncode(args));

LlmResponse _tools(List<LlmToolCall> calls, [String text = '']) =>
    LlmResponse(content: text, toolCalls: calls, finishReason: 'tool_calls', model: 'fake');

LlmResponse _read(String path) => _tools([
  _call('read', {'path': path}),
]);

LlmResponse _showActions(List<String> ids) => _tools([
  _call('show_actions', {
    'items': [
      for (final id in ids) {'actionId': id},
    ],
  }),
], '可以看看。');

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
      expect(pending.remove(m.toolCallId), isTrue, reason: '孤立的 tool 回复 ${m.toolCallId}');
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
    Duration turnTimeout = const Duration(seconds: 180),
    int contextBudgetTokens = 60000,
    int keepRecentSteps = 3,
    Future<void> Function(Duration)? sleep,
  }) => CoachAgent(
    client: c,
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

  test('默认参数：maxSteps=100、重试 4 次、退避 1s 起封顶 15s、整轮 180s、预算 60k', () {
    final a = CoachAgent(client: FakeLlmClient(const []), catalog: () => catalog, profile: hiplab);
    expect(a.maxSteps, 100);
    expect(a.maxRequestRetries, 4);
    expect(a.retryBaseDelay, const Duration(seconds: 1));
    expect(a.retryMaxDelay, const Duration(seconds: 15));
    expect(a.turnTimeout, const Duration(seconds: 180));
    expect(a.requestTimeout, const Duration(seconds: 60));
    expect(a.contextBudgetTokens, 60000);
    expect(a.maxStallSteps, 3);
  });

  test('超时后只重试这一步并成功：之前的步骤和读过的文件保留，records 标 retry', () async {
    final c = FakeLlmClient([
      _read('action-library/SKILL.md'),
      _hang(),
      _showActions(['s-figure4']),
    ]);
    final a = agent(c, requestTimeout: const Duration(milliseconds: 40));
    final events = <AgentEvent>[];
    a.events.listen(events.add);
    final r = await a.send('练臀');
    expect(r.status, TurnStatus.ok);
    expect(c.requests.length, 3);
    expect(r.steps, 2);
    expect(r.reads, ['action-library/SKILL.md']);
    expect(r.records.map((x) => x.outcome), [CallOutcome.toolStep, CallOutcome.error, CallOutcome.passed]);
    expect(r.records.map((x) => x.retry), [0, 0, 1]);
    expect(r.records[1].errorKind, 'timeout');
    // 重试请求与超时那次相同：带着第 1 步的读取结果。
    expect(c.requests[2].messages.length, c.requests[1].messages.length);
    expect(c.requests[2].messages.last.role, LlmRole.tool);
    final retry = events.singleWhere((e) => e.kind == AgentEventKind.retrying);
    expect((retry.attempt, retry.maxAttempts, retry.reason), (1, 4, RequestErrorClass.timeout));
    expect(delays, [const Duration(seconds: 1)]);
  });

  test('429 / 503 尊重 Retry-After（封顶 15s）', () async {
    final c = FakeLlmClient([
      const LlmException(LlmErrorKind.rateLimited, 'slow', statusCode: 429, retryAfter: Duration(seconds: 7)),
      const LlmException(LlmErrorKind.http, 'busy', statusCode: 503, retryAfter: Duration(seconds: 60)),
      '好的，想练哪里？',
    ]);
    final r = await agent(c).send('练练');
    expect(r.status, TurnStatus.ok);
    expect(delays, [const Duration(seconds: 7), const Duration(seconds: 15)]);
  });

  test('401 不重试，直接回落并标注原因', () async {
    final c = FakeLlmClient([const LlmException(LlmErrorKind.auth, 'bad key', statusCode: 401), '不该到这']);
    final r = await agent(c).send('练练');
    expect(r.status, TurnStatus.fallback);
    expect(r.text, '模板回复');
    expect(c.requests.length, 1);
    expect(delays, isEmpty);
    expect(r.fallbackReason, FallbackReason.auth);
    final e = r.error as AgentRequestFailed;
    expect((e.kind, e.errorClass), (AgentFailureKind.nonRetryable, RequestErrorClass.auth));
  });

  test('重试用尽回落：退避 1/2/4/8s，records 与 sink 完整', () async {
    final sink = MemoryUsageSink();
    final c = FakeLlmClient([
      _read('action-library/SKILL.md'),
      for (var i = 0; i < 5; i++) const LlmException(LlmErrorKind.network, 'down'),
    ]);
    final r = await agent(c, usage: sink).send('练练');
    expect(r.status, TurnStatus.fallback);
    expect(r.fallbackReason, FallbackReason.offline);
    expect(delays, [
      for (final s in [1, 2, 4, 8]) Duration(seconds: s),
    ]);
    expect(r.records.length, 6);
    expect(r.records.skip(1).map((x) => x.retry), [0, 1, 2, 3, 4]);
    expect(r.records.skip(1).every((x) => x.outcome == CallOutcome.error), isTrue);
    expect(sink.records.map((x) => x.id), r.records.map((x) => x.id));
    final e = r.error as AgentRequestFailed;
    expect((e.kind, e.attempts), (AgentFailureKind.retriesExhausted, 5));
  });

  for (final how in ['cancel', 'reset']) {
    test('退避中 $how：立即结束、不回写、不回落', () async {
      final sleeping = Completer<void>();
      var fellBack = false;
      final token = CancelToken();
      final c = FakeLlmClient([const LlmException(LlmErrorKind.network, 'down'), '不该到这']);
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
    final r = await agent(c, turnTimeout: const Duration(milliseconds: 60)).send('练练');
    expect(r.status, TurnStatus.fallback);
    expect(r.fallbackReason, FallbackReason.timeout);
    expect((r.error as AgentRequestFailed).kind, AgentFailureKind.turnTimeout);
    expect(r.records.single.errorKind, 'timeout');
  });

  test('上下文超长：先强制压缩再重试成功，压缩后 tool_call_id 协议有效', () async {
    final c = FakeLlmClient([
      _read('action-library/SKILL.md'),
      _read('action-library/index/scene/home.md'),
      const LlmException(LlmErrorKind.http, "This model's maximum context length is 65536 tokens", statusCode: 400),
      _showActions(['s-figure4']),
    ]);
    final a = agent(c);
    final events = <AgentEvent>[];
    a.events.listen(events.add);
    final r = await a.send('练臀');
    expect(r.status, TurnStatus.ok);
    expect(delays, isEmpty);
    final last = c.requests.last.messages;
    final tools = last.where((m) => m.role == LlmRole.tool).toList();
    expect(tools.first.content, startsWith('已读 action-library/SKILL.md（'));
    expect(tools.last.content, isNot(startsWith('已读'))); // 最近一步完整保留
    _expectProtocol(last);
    expect(events.singleWhere((e) => e.kind == AgentEventKind.retrying).reason, RequestErrorClass.contextTooLong);
  });

  test('超预算压缩较早的 read：协议有效，被压缩的文件可再读全文', () async {
    final c = FakeLlmClient([
      _read('action-library/SKILL.md'),
      _read('plan-training/SKILL.md'),
      _read('action-library/SKILL.md'),
      _showActions(['s-figure4']),
    ]);
    final r = await agent(c, contextBudgetTokens: 1, keepRecentSteps: 1).send('练臀');
    expect(r.status, TurnStatus.ok);
    final third = c.requests[2].messages.where((m) => m.role == LlmRole.tool).toList();
    expect(third.first.content, startsWith('已读 action-library/SKILL.md（'));
    final fourth = c.requests[3].messages;
    _expectProtocol(fourth);
    final t4 = fourth.where((m) => m.role == LlmRole.tool).toList();
    expect(t4[1].content, startsWith('已读 plan-training/SKILL.md（'));
    expect(t4.last.content, isNot(contains('已读'))); // 再读给全文
    expect(t4.last.content.length, greaterThan(100));
  });

  test('相同工具调用空转：提示一次，再犯回落', () async {
    final c = FakeLlmClient([for (var i = 0; i < 6; i++) _read('action-library/SKILL.md')]);
    final r = await agent(c).send('练臀');
    expect(r.status, TurnStatus.fallback);
    expect(r.error, isA<AgentStalled>());
    expect(c.requests.length, 4);
    final hint = c.requests[3].messages.last;
    expect(hint.role, LlmRole.user);
    expect(hint.content, contains('完全相同'));
  });
}
