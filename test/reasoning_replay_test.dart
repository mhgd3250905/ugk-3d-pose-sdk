import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

Map<String, Object?> _tool(String id, String name, Object arguments) => {
  'id': id,
  'type': 'function',
  'function': {'name': name, 'arguments': jsonEncode(arguments)},
};

Map<String, Object?> _message(
  String content,
  String? reasoning, [
  List<Map<String, Object?>> calls = const [],
]) => {
  'role': 'assistant',
  'content': content.isEmpty && calls.isNotEmpty ? null : content,
  'reasoning_content': ?reasoning,
  if (calls.isNotEmpty) 'tool_calls': calls,
};

http.Response _response(Map<String, Object?> message) => http.Response.bytes(
  utf8.encode(
    jsonEncode({
      'model': 'deepseek-wire-test',
      'choices': [
        {
          'message': message,
          'finish_reason': message.containsKey('tool_calls')
              ? 'tool_calls'
              : 'stop',
        },
      ],
      'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
    }),
  ),
  200,
);

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('hiplab');
  final plan = planOf(okEnvelope())..remove('source');
  final actions = {
    'items': [
      {'actionId': 's-figure4'},
    ],
  };

  test('LlmMessage 序列化仅 assistant 回传 reasoning，正文与 toString 不混入推理', () {
    const reasoning = 'transport-only-reasoning';
    const msg = LlmMessage.assistant('visible', reasoning: reasoning);
    expect(msg.toJson(), {
      'role': 'assistant',
      'content': 'visible',
      'reasoning_content': reasoning,
    });
    expect(msg.content, 'visible');
    expect(msg.toString(), isNot(contains(reasoning)));
    expect(
      const LlmMessage.assistant(
        'visible',
      ).toJson().containsKey('reasoning_content'),
      isFalse,
    );
    expect(
      const LlmMessage.assistant(
        'visible',
        reasoning: '',
      ).toJson()['reasoning_content'],
      '',
    );
    for (final role in [LlmRole.system, LlmRole.user, LlmRole.tool]) {
      expect(
        LlmMessage(
          role,
          'x',
          reasoning: reasoning,
        ).toJson().containsKey('reasoning_content'),
        isFalse,
      );
    }
  });

  test(
    'HTTP 请求体：Agent read / remember / check_plan / show_plan 与跨轮纯文字、show_actions 保留推理',
    () async {
      final replies = [
        _message('', 'read-reasoning', [
          _tool('r1', 'read', {'path': 'action-library/SKILL.md'}),
          _tool('r2', 'read', {'path': 'user-memory/SKILL.md'}),
        ]),
        _message('', 'remember-reasoning', [
          _tool('m1', 'remember', {'kind': 'level', 'text': '新手'}),
          _tool('r3', 'read', {
            'path': 'action-library/index/muscle/glute-max.md',
          }),
        ]),
        _message('', 'check-reasoning', [_tool('p1', 'check_plan', plan)]),
        _message('排好了。', 'plan-reasoning', [_tool('p2', 'show_plan', plan)]),
        _message('可以先了解动作。', 'plain-reasoning'),
        _message('这个动作可以看看。', 'actions-reasoning', [
          _tool('a1', 'show_actions', actions),
        ]),
        _message('好的。', 'last-reasoning'),
      ];
      final expected = <List<String>>[
        [],
        ['read-reasoning'],
        ['read-reasoning', 'remember-reasoning'],
        ['read-reasoning', 'remember-reasoning', 'check-reasoning'],
        ['plan-reasoning'],
        ['plan-reasoning', 'plain-reasoning'],
        ['plan-reasoning', 'plain-reasoning', 'actions-reasoning'],
      ];
      var step = 0;
      final client = OpenAiCompatibleClient(
        config: LlmConfig.ugkWorker.copyWith(maxRetries: 0),
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          final assistants = (body['messages'] as List)
              .cast<Map<String, dynamic>>()
              .where((m) => m['role'] == 'assistant');
          expect(
            assistants.map((m) => m['reasoning_content']),
            expected[step],
            reason: 'request ${step + 1}',
          );
          expect(body['tools'], isNotEmpty);
          return _response(replies[step++]);
        }),
      );
      final store = InMemoryUserMemoryStore();
      final agent = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        memoryStore: store,
      );
      addTearDown(client.close);
      addTearDown(agent.dispose);
      final result = await agent.send('新手，睡前开胯 10 分钟');
      expect(result.status, TurnStatus.ok);
      expect(result.steps, 4);
      expect(result.plan, isNotNull);
      expect(result.text, '排好了。');
      expect(result.text, isNot(contains('reasoning')));
      expect(result.records.map((r) => r.outcome), [
        CallOutcome.toolStep,
        CallOutcome.toolStep,
        CallOutcome.toolStep,
        CallOutcome.passed,
      ]);
      expect((await agent.memory()).single.text, '新手');
      expect((await agent.send('明白了')).status, TurnStatus.ok);
      expect((await agent.send('看看动作')).actions, isNotNull);
      expect((await agent.send('谢谢')).status, TurnStatus.ok);
      expect(step, 7);
    },
  );

  for (final useAgent in [true, false]) {
    test(
      'HTTP 请求体：${useAgent ? 'Agent' : 'Session'} 门禁重交回传被拒和最终历史的推理',
      () async {
        final replies = [
          _message('原始内容', 'rejected-reasoning', [
            _tool('bad', 'show_actions', {
              'items': [
                {'actionId': 'unknown-action'},
              ],
            }),
          ]),
          _message('动作演示', 'accepted-reasoning', [
            _tool('ok', 'show_actions', actions),
          ]),
          _message('好的', 'next-reasoning'),
        ];
        var step = 0;
        final client = OpenAiCompatibleClient(
          config: LlmConfig.ugkWorker.copyWith(maxRetries: 0),
          httpClient: MockClient((request) async {
            final body = jsonDecode(request.body) as Map;
            final assistants = (body['messages'] as List)
                .cast<Map<String, dynamic>>()
                .where((m) => m['role'] == 'assistant');
            expect(
              assistants.map((m) => m['reasoning_content']),
              [
                <String>[],
                ['rejected-reasoning'],
                ['accepted-reasoning'],
              ][step],
            );
            return _response(replies[step++]);
          }),
        );
        addTearDown(client.close);
        final agent = CoachAgent(
          client: client,
          catalog: () => catalog,
          profile: profile,
        );
        final session = CoachSession(
          client: client,
          catalog: () => catalog,
          profile: profile,
        );
        addTearDown(agent.dispose);
        final result = await (useAgent
            ? agent.send('动作演示')
            : session.send('动作演示'));
        expect(result.status, TurnStatus.ok);
        expect(result.submissions, 2);
        expect(result.text, '动作演示');
        expect(
          (await (useAgent ? agent.send('谢谢') : session.send('谢谢'))).status,
          TurnStatus.ok,
        );
        expect(step, 3);
      },
    );
  }

  test('记忆从未开启：读库、自检、最终历史的 reasoning_content 完整回传', () async {
    final replies = [
      _message('', 'library-reasoning', [
        _tool('read', 'read', {'path': 'action-library/SKILL.md'}),
      ]),
      _message('', 'checking-reasoning', [_tool('check', 'check_plan', plan)]),
      _message('排好了。', 'final-reasoning', [_tool('plan', 'show_plan', plan)]),
      _message('好。', null),
    ];
    final expected = <List<String>>[
      [],
      ['library-reasoning'],
      ['library-reasoning', 'checking-reasoning'],
      ['final-reasoning'],
    ];
    var step = 0;
    final client = OpenAiCompatibleClient(
      config: LlmConfig.ugkWorker.copyWith(maxRetries: 0),
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        final assistants = (body['messages'] as List)
            .cast<Map<String, dynamic>>()
            .where((m) => m['role'] == 'assistant');
        expect(assistants.map((m) => m['reasoning_content']), expected[step]);
        expect(request.body, isNot(contains('user-memory')));
        return _response(replies[step++]);
      }),
    );
    final agent = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      enableUserMemory: false,
    );
    addTearDown(client.close);
    addTearDown(agent.dispose);
    expect((await agent.send('睡前开胯 10 分钟')).plan, isNotNull);
    expect((await agent.send('谢谢')).status, TurnStatus.ok);
    expect(step, 4);
  });

  test('运行时关闭记忆：当前中间步、记忆工具及先前最终历史推理不回传记忆原文', () async {
    const sentinel = 'stored-only-private-reasoning-sentinel';
    final store = InMemoryUserMemoryStore([
      MemoryEntry(MemoryKind.goal, sentinel, at: DateTime.utc(2026)),
    ]);
    late CoachAgent agent;
    var step = 0;
    final client = OpenAiCompatibleClient(
      config: LlmConfig.ugkWorker.copyWith(maxRetries: 0),
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        final messages = (body['messages'] as List)
            .cast<Map<String, dynamic>>();
        if (step >= 2) {
          expect(request.body, isNot(contains(sentinel)));
          for (final message in messages.where(
            (m) => m['role'] == 'assistant',
          )) {
            expect(
              message['reasoning_content'],
              message['content'] == '继续。' ? 'safe-final' : '',
            );
          }
          final ids = {
            for (final m in messages)
              for (final t in m['tool_calls'] as List? ?? const [])
                (t as Map)['id'],
          };
          for (final m in messages.where((m) => m['role'] == 'tool')) {
            expect(ids, contains(m['tool_call_id']));
          }
        }
        switch (step++) {
          case 0:
            return _response(_message('知道了。', sentinel));
          case 1:
            agent.enableUserMemory = false;
            return _response(
              _message('', sentinel, [
                _tool('read-memory', 'read', {'path': 'user-memory/SKILL.md'}),
                _tool('forget-memory', 'forget', {
                  'kind': 'goal',
                  'text': sentinel,
                }),
                _tool('read-library', 'read', {
                  'path': 'action-library/SKILL.md',
                }),
              ]),
            );
          case 2:
            return _response(
              _message('', 'safe-after-disable', [
                _tool('late-memory', 'remember', {
                  'kind': 'goal',
                  'text': sentinel,
                }),
              ]),
            );
          default:
            return _response(_message('继续。', 'safe-final'));
        }
      }),
    );
    addTearDown(client.close);
    agent = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      memoryStore: store,
    );
    addTearDown(agent.dispose);
    expect((await agent.send('你好')).status, TurnStatus.ok);
    expect((await agent.send('看看动作库')).status, TurnStatus.ok);
    expect((await agent.send('下一轮')).status, TurnStatus.ok);
    expect(step, 5);
    expect((await agent.memory()).single.text, sentinel);
  });

  test('有推理的历史计入会话字符上限', () async {
    final client = FakeLlmClient([
      LlmResponse(content: '好', reasoning: 'hidden' * 20),
    ]);
    final agent = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      maxHistoryChars: 100,
    );
    addTearDown(agent.dispose);
    expect((await agent.send('你好')).status, TurnStatus.ok);
    expect(agent.historyChars, greaterThan(100));
    expect((await agent.send('再来')).status, TurnStatus.limitReached);
    expect(client.requests, hasLength(1));
  });
}
