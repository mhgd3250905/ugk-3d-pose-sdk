import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmToolCall _call(String id, String name, Map<String, Object?> args) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(args));
LlmToolCall _read(String id, String skill) =>
    _call(id, AgentTools.read, {'path': '$skill/SKILL.md'});
LlmToolCall _start(String id, String type) =>
    _call(id, AgentTools.startTask, {'type': type});
LlmResponse _batch(List<LlmToolCall> calls, {String content = ''}) =>
    LlmResponse(
      content: content,
      toolCalls: calls,
      finishReason: 'tool_calls',
      model: 'fake',
    );
LlmResponse _ask(String id) => _batch([
  _call(id, AgentTools.askUser, {'question': '还有什么要求？', 'mode': 'text'}),
]);
String _content(LlmRequest request, String id) =>
    request.messages.singleWhere((message) => message.toolCallId == id).content;
Map<String, Object?> _result(LlmRequest request, String id) =>
    (jsonDecode(_content(request, id)) as Map).cast<String, Object?>();
Map<String, Object?> _skills(LlmRequest request, String id) =>
    (_result(request, id)['skills'] as Map).cast<String, Object?>();

void _protocol(LlmRequest request) {
  final pending = <String>{};
  for (final message in request.messages) {
    if (message.role == LlmRole.assistant) {
      expect(pending, isEmpty);
      for (final call in message.toolCalls) {
        expect(pending.add(call.id), isTrue);
      }
    } else if (message.role == LlmRole.tool) {
      expect(pending.remove(message.toolCallId), isTrue);
    } else {
      expect(pending, isEmpty);
    }
  }
  expect(pending, isEmpty);
}

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('smartfit');
  final files = SkillFiles.build(profile, catalog, memory: false);
  String full(String skill) => files.read('$skill/SKILL.md')!;
  CoachAgent coach(FakeLlmClient client, {int contextBudgetTokens = 60000}) {
    final agent = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      enableUserMemory: false,
      maxRequestRetries: 0,
      contextBudgetTokens: contextBudgetTokens,
      keepRecentSteps: 1,
    );
    addTearDown(agent.dispose);
    return agent;
  }

  test(
    'three reads then recommendation references required skills and archives plan',
    () async {
      final client = FakeLlmClient([
        _batch([
          _read('read-ask', 'ask'),
          _read('read-library', 'action-library'),
          _read('read-plan', 'plan-training'),
        ]),
        (LlmRequest request) {
          for (final entry in {
            'read-ask': 'ask',
            'read-library': 'action-library',
            'read-plan': 'plan-training',
          }.entries) {
            expect(_content(request, entry.key), full(entry.value));
          }
          return _batch([_start('start', 'recommend')]);
        },
        (LlmRequest request) {
          _protocol(request);
          expect(_skills(request, 'start'), {
            'ask': '[已在前文 read 中]',
            'action-library': '[已在前文 read 中]',
          });
          expect(_content(request, 'read-ask'), full('ask'));
          expect(_content(request, 'read-library'), full('action-library'));
          expect(_content(request, 'read-plan'), '[已归档：与当前任务无关的技能 read]');
          final serialized = jsonEncode([
            for (final message in request.messages) message.toJson(),
          ]);
          for (final key in ['fullRead', 'fullSkills', 'requiredSkills']) {
            expect(serialized, isNot(contains('"$key"')));
          }
          return _ask('ask');
        },
      ], latency: Duration.zero);
      final result = await coach(client).send('推荐动作');
      expect(result.question, isNotNull, reason: '${result.error}');
      expect(client.requests, hasLength(3));
    },
  );

  test(
    'start plan followed by same batch and resumed reads uses exact start marker',
    () async {
      final client = FakeLlmClient([
        _batch([
          _start('start', 'plan'),
          _read('same-ask', 'ask'),
          _read('same-library', 'action-library'),
          _read('same-plan', 'plan-training'),
        ]),
        (LlmRequest request) {
          expect(_skills(request, 'start'), {
            'ask': full('ask'),
            'action-library': full('action-library'),
            'plan-training': full('plan-training'),
          });
          for (final id in ['same-ask', 'same-library', 'same-plan']) {
            expect(_content(request, id), '[已在 start_task 结果中]');
          }
          return _ask('question');
        },
        _batch([
          _read('resumed-ask', 'ask'),
          _read('resumed-library', 'action-library'),
          _read('resumed-plan', 'plan-training'),
        ]),
        (LlmRequest request) {
          _protocol(request);
          for (final id in ['resumed-ask', 'resumed-library', 'resumed-plan']) {
            expect(_content(request, id), '[已在 start_task 结果中]');
          }
          return _ask('question-again');
        },
      ], latency: Duration.zero);
      final agent = coach(client);
      expect((await agent.send('排个计划')).question, isNotNull);
      expect((await agent.send('没有其他要求')).question, isNotNull);
      expect(client.requests, hasLength(4));
    },
  );

  test('a failed read cannot suppress task skill bodies', () async {
    final client = FakeLlmClient([
      _batch([_read('failed', 'missing')]),
      (LlmRequest request) {
        expect(_result(request, 'failed')['code'], 'not_found');
        return _batch([_start('start', 'plan')]);
      },
      (LlmRequest request) {
        expect(_skills(request, 'start'), {
          'ask': full('ask'),
          'action-library': full('action-library'),
          'plan-training': full('plan-training'),
        });
        return _ask('question');
      },
    ], latency: Duration.zero);
    expect((await coach(client).send('排个计划')).question, isNotNull);
  });

  test('model prose claiming a read cannot suppress task skill bodies', () async {
    final client = FakeLlmClient([
      _batch(
        [_start('start', 'plan')],
        content:
            '已经 read ask/SKILL.md、action-library/SKILL.md、plan-training/SKILL.md。',
      ),
      (LlmRequest request) {
        expect(_skills(request, 'start'), {
          'ask': full('ask'),
          'action-library': full('action-library'),
          'plan-training': full('plan-training'),
        });
        return _ask('question');
      },
    ], latency: Duration.zero);
    expect((await coach(client).send('排个计划')).question, isNotNull);
  });

  test(
    'reused tool ID in separate read batches retains each actual path',
    () async {
      final client = FakeLlmClient([
        _batch([_read('shared', 'ask')]),
        _batch([_read('shared', 'action-library')]),
        _batch([_start('start', 'plan')]),
        (LlmRequest request) {
          _protocol(request);
          expect(
            request.messages
                .where((message) => message.toolCallId == 'shared')
                .map((message) => message.content),
            [full('ask'), full('action-library')],
          );
          expect(_skills(request, 'start'), {
            'ask': '[已在前文 read 中]',
            'action-library': '[已在前文 read 中]',
            'plan-training': full('plan-training'),
          });
          return _ask('question');
        },
      ], latency: Duration.zero);
      expect((await coach(client).send('排个计划')).question, isNotNull);
    },
  );

  for (final reuse in [false, true]) {
    test(
      'after completed history is removed ${reuse ? 'reused' : 'new'} task needs skill bodies',
      () async {
        final client = FakeLlmClient([
          _batch([
            _start('old-start', 'recommend'),
            _call('old-understand', AgentTools.check, {'node': 'understand'}),
            _call('old-params', AgentTools.setParams, {
              'fields': {
                'goal': {
                  'value': ['purpose.stretch'],
                  'source': 'user',
                  'quote': '拉伸',
                },
              },
            }),
            _call('old-parameters', AgentTools.check, {'node': 'parameters'}),
            _call('old-search', AgentTools.searchActions, {
              'tags': <String>[],
              'limit': 3,
            }),
          ]),
          (LlmRequest request) {
            final found = _result(request, 'old-search');
            final ids = (found['items'] as List)
                .cast<Map<String, Object?>>()
                .map((item) => item['id'] as String)
                .toList();
            expect(ids, hasLength(3));
            return _batch([
              _call('old-actions', AgentTools.check, {
                'node': 'actions',
                'picks': ids,
              }),
              _call('old-show', AgentTools.showActions, {
                'ids': ids,
                'note': '先温和地活动。',
              }),
            ]);
          },
          _batch([
            _call('new-start', AgentTools.startTask, {
              'type': 'plan',
              'reuse': reuse,
            }),
          ]),
          (LlmRequest request) {
            _protocol(request);
            expect(
              request.messages.where(
                (message) => message.toolCallId?.startsWith('old-') == true,
              ),
              isEmpty,
            );
            expect(_skills(request, 'new-start'), {
              'ask': full('ask'),
              'action-library': full('action-library'),
              'plan-training': full('plan-training'),
            });
            final task = _result(request, 'new-start')['task'] as Map;
            expect(task['reused'], reuse);
            if (reuse) {
              expect(
                (task['nodes'] as List)
                    .cast<Map<String, Object?>>()
                    .take(3)
                    .map((node) => node['status']),
                everyElement('done'),
              );
            }
            return _ask('new-question');
          },
        ], latency: Duration.zero);
        final agent = coach(client);
        final first = await agent.send('推荐拉伸动作');
        expect(
          first.actions,
          isNotNull,
          reason: '${first.error}; ${first.issues}',
        );
        final second = await agent.send('另外排个计划');
        expect(second.question, isNotNull, reason: '${second.error}');
        expect(client.requests, hasLength(4));
      },
    );
  }

  test(
    'technical compression of old read requires the missing body again',
    () async {
      final client = FakeLlmClient([
        _batch([_read('old-ask', 'ask')]),
        _batch([_read('recent-plan', 'plan-training')]),
        (LlmRequest request) {
          expect(_content(request, 'old-ask'), startsWith('已读 ask/SKILL.md（'));
          expect(_content(request, 'recent-plan'), full('plan-training'));
          return _batch([_start('start', 'plan')]);
        },
        (LlmRequest request) {
          _protocol(request);
          final loaded = _skills(request, 'start');
          expect(loaded['ask'], full('ask'));
          expect(loaded['action-library'], full('action-library'));
          if (loaded['plan-training'] == '[已在前文 read 中]') {
            expect(
              _content(request, 'recent-plan'),
              full('plan-training'),
              reason:
                  'a read reference requires its complete body in this actual request',
            );
          } else {
            expect(loaded['plan-training'], full('plan-training'));
          }
          return _ask('question');
        },
      ], latency: Duration.zero);
      final result = await coach(client, contextBudgetTokens: 1).send('排个计划');
      expect(result.question, isNotNull, reason: '${result.error}');
    },
  );
}
