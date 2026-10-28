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
  final actions = {
    'items': [
      {'actionId': 's-figure4'},
    ],
  };

  const v2Ids = ['h-sumo-pry', 'n-squat-shift', 's-butterfly'];
  List<Map<String, Object?>> setup(String type, {bool parameters = true}) => [
    _tool('start-$type', 'start_task', {'type': type}),
    _tool('understand-$type', 'check', {'node': 'understand'}),
    if (parameters)
      _tool('params-$type', 'set_params', {
        'fields': {
          'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
          'equipment': {'value': <String>[], 'source': 'user', 'quote': '徒手'},
          'goal': {
            'value': ['body.inner_thigh'],
            'source': 'user',
            'quote': '大腿内侧',
          },
          if (type == 'plan')
            'minutes': {'value': 5, 'source': 'user', 'quote': '5分钟'},
        },
      }),
    _tool('parameters-$type', 'check', {'node': 'parameters'}),
    for (var i = 0; i < v2Ids.length; i++)
      _tool('search-$type-$i', 'search_actions', {
        'tags': <String>[],
        'keywords': catalog[v2Ids[i]]!.name.of('zh'),
      }),
  ];
  List<Map<String, Object?>> actionsAndDraft() => [
    _tool('select', 'check', {'node': 'actions', 'picks': v2Ids}),
    _tool('draft', 'draft_plan', {
      'title': '拉伸计划',
      'blocks': [
        {
          'kind': 'main',
          'items': [
            for (final id in v2Ids) {'id': id},
          ],
        },
      ],
    }),
  ];
  Map<String, dynamic> toolResult(Map<dynamic, dynamic> body, String id) {
    final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
    final message = messages.singleWhere((m) => m['tool_call_id'] == id);
    return jsonDecode(message['content'] as String) as Map<String, dynamic>;
  }

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
      const LlmMessage.assistant('visible').toJson()['reasoning_content'],
      '',
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

  test('thinking 请求附带 tools 时，跨用户消息保留纯问答的推理', () async {
    var step = 0;
    final client = OpenAiCompatibleClient(
      config: LlmConfig.ugkWorker.copyWith(
        maxRetries: 0,
        extraBody: {
          'thinking': {'type': 'enabled'},
        },
      ),
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        expect(body['tools'], isNotEmpty);
        expect(body['thinking'], {'type': 'enabled'});
        final assistants = (body['messages'] as List)
            .cast<Map<String, Object?>>()
            .where((message) => message['role'] == 'assistant');
        if (step++ == 0) {
          expect(assistants, isEmpty);
          return _response(_message('可以先轻柔活动。', 'plain-turn-reasoning'));
        }
        expect(assistants, hasLength(1));
        expect(assistants.single['content'], '可以先轻柔活动。');
        expect(assistants.single['reasoning_content'], 'plain-turn-reasoning');
        expect(assistants.single.containsKey('tool_calls'), isFalse);
        return _response(_message('按舒适范围活动。', 'next-turn-reasoning'));
      }),
    );
    final agent = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      enableUserMemory: false,
      maxRequestRetries: 0,
    );
    addTearDown(client.close);
    addTearDown(agent.dispose);
    final first = await agent.send('久坐之后可以轻柔活动吗？');
    expect(first.status, TurnStatus.ok);
    expect(first.text, '可以先轻柔活动。');
    final second = await agent.send('需要注意什么？');
    expect(second.status, TurnStatus.ok);
    expect(second.text, '按舒适范围活动。');
    expect(agent.sessionState.task, isNull);
    expect(step, 2);
  });

  test('HTTP 请求体：Agent 保留进行中及交付后可见历史的原始推理', () async {
    final expected = <List<String>>[
      [],
      ['read-reasoning'],
      ['read-reasoning', 'remember-reasoning'],
      ['read-reasoning', 'remember-reasoning', 'setup-reasoning'],
      [
        'read-reasoning',
        'remember-reasoning',
        'setup-reasoning',
        'draft-reasoning',
      ],
      [
        'read-reasoning',
        'remember-reasoning',
        'setup-reasoning',
        'draft-reasoning',
        'check-reasoning',
      ],
      ['plan-reasoning'],
      ['plan-reasoning', 'plain-reasoning'],
      ['plan-reasoning', 'plain-reasoning', 'recommend-reasoning'],
      ['plan-reasoning', 'plain-reasoning', 'actions-reasoning'],
    ];
    var step = 0;
    late String planId;
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
        final reply = switch (step++) {
          0 => _message('', 'read-reasoning', [
            _tool('r1', 'read', {'path': 'action-library/SKILL.md'}),
            _tool('r2', 'read', {'path': 'user-memory/SKILL.md'}),
          ]),
          1 => _message('', 'remember-reasoning', [
            _tool('m1', 'remember', {'kind': 'level', 'text': '新手'}),
          ]),
          2 => _message('', 'setup-reasoning', setup('plan')),
          3 => _message('', 'draft-reasoning', actionsAndDraft()),
          4 => () {
            final result = toolResult(body, 'draft');
            expect(result['ok'], isTrue, reason: '$result');
            planId = result['plan_id'] as String;
            return _message('', 'check-reasoning', [
              _tool('planning', 'check', {'node': 'planning'}),
              _tool('check-plan', 'check_plan', {'plan_id': planId}),
            ]);
          }(),
          5 => () {
            expect(toolResult(body, 'planning')['ok'], isTrue);
            expect(
              (body['messages'] as List)
                  .cast<Map<String, Object?>>()
                  .singleWhere(
                    (message) => message['tool_call_id'] == 'draft',
                  )['content'],
              '[已归档，见当前状态]',
            );
            final checked = toolResult(body, 'check-plan');
            expect(checked['ok'], isTrue, reason: '$checked');
            return _message('正文应被忽略', 'plan-reasoning', [
              _tool('review', 'check', {'node': 'review'}),
              _tool('show-plan', 'show_plan', {
                'plan_id': planId,
                'note': '先舒缓地活动。',
              }),
            ]);
          }(),
          6 => _message('可以先了解动作。', 'plain-reasoning'),
          7 => _message(
            '',
            'recommend-reasoning',
            setup('recommend', parameters: false),
          ),
          8 => _message('正文应被忽略', 'actions-reasoning', [
            _tool('select-actions', 'check', {
              'node': 'actions',
              'picks': v2Ids,
            }),
            _tool('show-actions', 'show_actions', {
              'ids': v2Ids,
              'note': '可以看看这些动作。',
            }),
          ]),
          _ => _message('好的。', 'last-reasoning'),
        };
        return _response(reply);
      }),
    );
    final store = InMemoryUserMemoryStore();
    final agent = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      memoryStore: store,
      maxRequestRetries: 0,
    );
    addTearDown(client.close);
    addTearDown(agent.dispose);
    final result = await agent.send('新手，在家徒手，5分钟训练大腿内侧');
    expect(
      result.status,
      TurnStatus.ok,
      reason: '${result.error}; ${result.issues}',
    );
    expect(result.steps, 6);
    expect(result.plan, isNotNull);
    expect(result.text, '先舒缓地活动。');
    expect(result.text, isNot(contains('reasoning')));
    expect(result.records.map((r) => r.outcome), [
      CallOutcome.toolStep,
      CallOutcome.toolStep,
      CallOutcome.toolStep,
      CallOutcome.toolStep,
      CallOutcome.toolStep,
      CallOutcome.passed,
    ]);
    expect((await agent.memory()).single.text, '新手');
    expect((await agent.send('明白了')).status, TurnStatus.ok);
    expect((await agent.send('看看动作')).actions, isNotNull);
    expect((await agent.send('谢谢')).status, TurnStatus.ok);
    expect(step, 10);
  });

  for (final useAgent in [true, false]) {
    test(
      'HTTP 请求体：${useAgent ? 'Agent' : 'Session'} 门禁重交回传被拒和最终历史的推理',
      () async {
        if (useAgent) {
          final replies = [
            _message('', 'setup-reasoning', setup('recommend')),
            _message('原始内容', 'rejected-reasoning', [
              _tool('select', 'check', {'node': 'actions', 'picks': v2Ids}),
              _tool('bad', 'show_actions', {
                'ids': ['unknown-action'],
                'note': '先看看。',
              }),
            ]),
            _message('原始正文', 'accepted-reasoning', [
              _tool('ok', 'show_actions', {'ids': v2Ids, 'note': '动作演示。'}),
            ]),
            _message('好的', 'next-reasoning'),
          ];
          final expected = [
            <String>[],
            ['setup-reasoning'],
            ['setup-reasoning', 'rejected-reasoning'],
            ['accepted-reasoning'],
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
              );
              if (step == 2) {
                expect(toolResult(body, 'bad')['code'], 'invalid_picks');
              }
              return _response(replies[step++]);
            }),
          );
          final agent = CoachAgent(
            client: client,
            catalog: () => catalog,
            profile: profile,
            maxRequestRetries: 0,
            enableUserMemory: false,
          );
          addTearDown(client.close);
          addTearDown(agent.dispose);
          final result = await agent.send('在家徒手推荐大腿内侧动作');
          expect(result.status, TurnStatus.ok, reason: '${result.error}');
          expect(result.submissions, 2);
          expect(result.text, '动作演示。');
          expect(result.actions, isNotNull);
          expect((await agent.send('谢谢')).status, TurnStatus.ok);
          expect(step, 4);
          return;
        }
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

  test('记忆从未开启：进行中及交付后保留的历史推理完整回传', () async {
    final expected = <List<String>>[
      [],
      ['library-reasoning'],
      ['library-reasoning', 'setup-reasoning'],
      ['library-reasoning', 'setup-reasoning', 'draft-reasoning'],
      [
        'library-reasoning',
        'setup-reasoning',
        'draft-reasoning',
        'checking-reasoning',
      ],
      ['final-reasoning'],
    ];
    var step = 0;
    late String planId;
    final client = OpenAiCompatibleClient(
      config: LlmConfig.ugkWorker.copyWith(maxRetries: 0),
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        final assistants = (body['messages'] as List)
            .cast<Map<String, dynamic>>()
            .where((m) => m['role'] == 'assistant');
        expect(assistants.map((m) => m['reasoning_content']), expected[step]);
        expect(request.body, isNot(contains('user-memory')));
        final reply = switch (step++) {
          0 => _message('', 'library-reasoning', [
            _tool('read', 'read', {'path': 'action-library/SKILL.md'}),
          ]),
          1 => _message('', 'setup-reasoning', setup('plan')),
          2 => _message('', 'draft-reasoning', actionsAndDraft()),
          3 => () {
            final draft = toolResult(body, 'draft');
            expect(draft['ok'], isTrue, reason: '$draft');
            planId = draft['plan_id'] as String;
            return _message('', 'checking-reasoning', [
              _tool('planning', 'check', {'node': 'planning'}),
              _tool('check-plan', 'check_plan', {'plan_id': planId}),
            ]);
          }(),
          4 => () {
            final checked = toolResult(body, 'check-plan');
            expect(checked['ok'], isTrue, reason: '$checked');
            return _message('', 'final-reasoning', [
              _tool('review', 'check', {'node': 'review'}),
              _tool('plan', 'show_plan', {'plan_id': planId, 'note': '轻柔开始。'}),
            ]);
          }(),
          _ => _message('好。', null),
        };
        return _response(reply);
      }),
    );
    final agent = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      enableUserMemory: false,
      maxRequestRetries: 0,
    );
    addTearDown(client.close);
    addTearDown(agent.dispose);
    final delivered = await agent.send('在家徒手，5分钟训练大腿内侧');
    expect(delivered.plan, isNotNull, reason: '${delivered.error}');
    expect((await agent.send('谢谢')).status, TurnStatus.ok);
    expect(step, 6);
  });

  for (final useAgent in [true, false]) {
    for (final mode in <String, Map<String, Object?>>{
      'missing': {},
      'null': {'reasoning_content': null},
      'empty': {'reasoning_content': ''},
    }.entries) {
      test(
        'HTTP 请求体：${useAgent ? 'Agent' : 'Session'} ${mode.key} 推理在工具步及最终历史保留显式空字段',
        () async {
          Map<String, Object?> message(
            String content, [
            List<Map<String, Object?>> calls = const [],
          ]) => _message(content, null, calls)..addAll(mode.value);
          final replies = [
            message('', [
              if (useAgent) ...[
                _tool('read-empty', 'read', {
                  'path': 'action-library/SKILL.md',
                }),
                ...setup('recommend'),
              ] else
                _tool('rejected-empty', 'show_actions', {
                  'items': [
                    {'actionId': 'unknown-action'},
                  ],
                }),
            ]),
            message('动作演示', [
              if (useAgent) ...[
                _tool('select-empty', 'check', {
                  'node': 'actions',
                  'picks': v2Ids,
                }),
                _tool('show-empty', 'show_actions', {
                  'ids': v2Ids,
                  'note': '动作演示。',
                }),
              ] else
                _tool('show-empty', 'show_actions', actions),
            ]),
            message('好。'),
            message('继续。'),
          ];
          final expected = <List<String>>[
            [],
            [''],
            [''],
            ['', ''],
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
              );
              for (final m in assistants) {
                expect(m.containsKey('reasoning_content'), isTrue);
              }
              return _response(replies[step++]);
            }),
          );
          final agent = CoachAgent(
            client: client,
            catalog: () => catalog,
            profile: profile,
            enableUserMemory: false,
            maxRequestRetries: 0,
          );
          final session = CoachSession(
            client: client,
            catalog: () => catalog,
            profile: profile,
          );
          addTearDown(client.close);
          addTearDown(agent.dispose);
          Future<CoachTurnResult> send(String input) =>
              useAgent ? agent.send(input) : session.send(input);
          expect(
            (await send(useAgent ? '在家徒手推荐大腿内侧动作' : '看动作')).actions,
            isNotNull,
          );
          expect((await send('谢谢')).status, TurnStatus.ok);
          expect((await send('再说一句')).status, TurnStatus.ok);
          expect(step, 4);
        },
      );
    }

    test(
      'HTTP 请求体：${useAgent ? 'Agent' : 'Session'} 预设回落后历史也保留空推理协议字段',
      () async {
        var step = 0;
        final client = OpenAiCompatibleClient(
          config: LlmConfig.ugkWorker.copyWith(maxRetries: 0),
          httpClient: MockClient((request) async {
            if (step++ == 0) return http.Response('upstream unavailable', 503);
            final body = jsonDecode(request.body) as Map;
            final assistants = (body['messages'] as List)
                .cast<Map<String, dynamic>>()
                .where((m) => m['role'] == 'assistant');
            expect(assistants.single['reasoning_content'], '');
            expect(assistants.single['content'], '先用预设方案。');
            return _response(_message('好。', null));
          }),
        );
        const fallbackReply = SessionFallbackReply('先用预设方案。');
        final agent = CoachAgent(
          client: client,
          catalog: () => catalog,
          profile: profile,
          fallback: (_) => fallbackReply,
          maxRequestRetries: 0,
        );
        final session = CoachSession(
          client: client,
          catalog: () => catalog,
          profile: profile,
          fallback: (_) => fallbackReply,
        );
        addTearDown(client.close);
        addTearDown(agent.dispose);
        Future<CoachTurnResult> send(String input) =>
            useAgent ? agent.send(input) : session.send(input);
        expect((await send('看动作')).status, TurnStatus.fallback);
        expect((await send('再来')).status, TurnStatus.ok);
        expect(step, 2);
      },
    );
  }

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
