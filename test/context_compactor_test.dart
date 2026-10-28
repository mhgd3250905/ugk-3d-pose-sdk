import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/context_compactor.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmToolCall _call(String id, String name, Map<String, Object?> args) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(args));

List<LlmMessage> _batch(LlmToolCall call, String response) => [
  LlmMessage.assistant('', toolCalls: [call]),
  LlmMessage.tool(call.id, response),
];

void main() {
  const compactor = ContextCompactor();
  const system = LlmMessage.system('角色和技能索引');
  final catalog = loadCatalog();
  final firstId = catalog.drills.first.id;
  final state = CoachSessionState(
    task: CoachTaskState(
      type: 'plan',
      reused: false,
      nodes: const [
        CoachNodeState(
          id: 'actions',
          status: 'done',
          stamp: '已选动作',
          doneAtTurn: 1,
        ),
        CoachNodeState(id: 'planning', status: 'current', stamp: '原有记录'),
        CoachNodeState(id: 'review', status: 'pending'),
      ],
    ),
    params: {
      'minutes': CoachParamValue(
        value: 15,
        source: 'derived',
        quote: '短一点',
        turn: 2,
        direction: 'shorter',
        basedOn: CoachParamValue(value: 20, source: 'host', turn: 1),
      ),
    },
    picks: [firstId],
    activePlanId: 'plan-a',
    plans: {
      'plan-a': [
        CoachPlanVersion(
          version: 2,
          plan: {
            'title': '计划',
            'targetMinutes': 15,
            'blocks': ['完整计划不应注入'],
          },
          estimateSec: 900,
          fitLog: const [],
          check: {'ok': true},
        ),
      ],
    },
  );

  test('state contains source, picks and a summary without plan body', () {
    final result = compactor.compose(
      system: system,
      state: state,
      catalog: catalog,
      history: const [],
    );
    expect(result.first, same(system));
    final content = result[1].content;
    expect(content, contains('短一点'));
    expect(content, contains('basedOn'));
    expect(content, contains(firstId));
    expect(content, contains(catalog[firstId]!.name.of()));
    expect(content, contains('plan-a'));
    expect(content, isNot(contains('完整计划不应注入')));
    expect(
      utf8
          .encode(
            jsonEncode(result.map((message) => message.toJson()).toList()),
          )
          .length,
      lessThan(10240),
    );
  });

  test('compact task and picks restore every field and derived provenance', () {
    final withUnknownPick = state.copyWith(picks: [firstId, 'not-in-catalog']);
    final result = compactor.compose(
      system: system,
      state: withUnknownPick,
      catalog: catalog,
      history: const [],
    );
    const prefix = '当前状态：';
    final content = result[1].content;
    expect(content, startsWith(prefix));
    final summary =
        jsonDecode(content.substring(prefix.length)) as Map<String, dynamic>;
    expect(summary['format'], contains('nodes=[id,status,stamp,doneAtTurn]'));
    expect(summary['format'], contains('picks=[id,name]'));
    final task = summary['task'] as List<dynamic>;
    final nodes = task[2] as List<dynamic>;
    final decodedTask = {
      'type': task[0],
      'reused': task[1],
      'nodes': [
        for (final row in nodes.cast<List<dynamic>>())
          {
            'id': row[0],
            'status': row[1],
            'stamp': row[2],
            'doneAtTurn': row[3],
          },
      ],
    };
    expect(decodedTask, withUnknownPick.task!.toJson());
    final picks = (summary['picks'] as List<dynamic>).cast<List<dynamic>>();
    expect(picks, [
      [firstId, catalog[firstId]!.name.of()],
      ['not-in-catalog', null],
    ]);
    expect(
      (summary['params'] as Map)['minutes'],
      withUnknownPick.params['minutes']!.toJson(),
    );
    expect(
      ((summary['params'] as Map)['minutes'] as Map)['basedOn'],
      withUnknownPick.params['minutes']!.basedOn!.toJson(),
    );
    expect(summary['plan'], {
      'plan_id': 'plan-a',
      'version': 2,
      'title': '计划',
      'targetMinutes': 15,
      'estimateSec': 900,
      'checkOk': true,
    });
  });

  test(
    'node archival follows successful check and retains skills and pairs',
    () {
      final history = <LlmMessage>[
        ..._batch(
          _call('same', AgentTools.startTask, {'type': 'plan'}),
          '{"ok":true,"skills":"技能正文"}',
        ),
        ..._batch(
          _call('same', AgentTools.searchActions, {'tags': []}),
          '{"ok":true,"items":[1]}',
        ),
        ..._batch(
          _call('check', AgentTools.check, {'node': 'actions'}),
          '{"ok":true}',
        ),
        ..._batch(
          _call('same', AgentTools.searchActions, {
            'tags': ['body.core'],
          }),
          '{"ok":true,"items":[{"id":"action-2","name":"动作二","data":[2]}]}',
        ),
        ..._batch(
          _call('draft', AgentTools.draftPlan, {'plan_id': 'plan-a'}),
          '{"ok":true,"plan":"未完成"}',
        ),
      ];
      final result = compactor.compose(
        system: system,
        state: state,
        catalog: catalog,
        history: history,
      );
      final tools = result
          .where((message) => message.role == LlmRole.tool)
          .toList();
      expect(tools.map((message) => message.toolCallId), [
        'same',
        'same',
        'check',
        'same',
        'draft',
      ]);
      expect(tools[0].content, contains('技能正文'));
      expect(tools[1].content, ContextCompactor.archived);
      expect(tools[3].content, '[已归档] 返回：action-2 动作二');
      expect(tools[4].content, contains('未完成'));
      expect(history[3].content, contains('[1]'));
    },
  );

  test('action batches are full once then compact before node completion', () {
    final active = state.copyWith(
      task: CoachTaskState(
        type: 'plan',
        reused: false,
        nodes: const [CoachNodeState(id: 'actions', status: 'current')],
      ),
    );
    final batch = [
      LlmMessage.assistant(
        '',
        reasoning: 'protocol reasoning',
        toolCalls: [
          _call('search', AgentTools.searchActions, {'tags': []}),
          _call('details', AgentTools.getAction, {
            'ids': ['a'],
          }),
        ],
      ),
      const LlmMessage.tool(
        'search',
        '{"ok":true,"items":[{"id":"a","name":"动作甲","data":[1,2,3]}]}',
      ),
      const LlmMessage.tool(
        'details',
        '{"ok":true,"items":[{"id":"a","cues":["完整要领"],"cautions":[]}]}',
      ),
    ];
    List<LlmMessage> compose(List<LlmMessage> history) => compactor.compose(
      system: system,
      state: active,
      catalog: catalog,
      history: history,
    );
    final first = compose(batch);
    expect(
      first.singleWhere((m) => m.toolCallId == 'search').content,
      contains('data'),
    );
    expect(
      first.singleWhere((m) => m.toolCallId == 'details').content,
      contains('完整要领'),
    );
    final next = compose([
      ...batch,
      ..._batch(
        _call('again', AgentTools.getAction, {
          'ids': ['a'],
        }),
        '{"ok":true,"items":[{"id":"a","cues":["再次查看要领"]}]}',
      ),
    ]);
    expect(
      next.singleWhere((m) => m.toolCallId == 'search').content,
      '[已归档] 返回：a 动作甲',
    );
    expect(
      next.singleWhere((m) => m.toolCallId == 'details').content,
      '[已归档] 已查看要领：a',
    );
    expect(
      next.singleWhere((m) => m.toolCallId == 'again').content,
      contains('再次查看要领'),
    );
    expect(
      next.where((m) => m.role == LlmRole.assistant).first.reasoning,
      'protocol reasoning',
    );
    expect(batch.last.content, contains('完整要领'));
  });

  test(
    'completed task summary only contains stamp, plan metadata and names',
    () {
      final done = state.copyWith(
        task: CoachTaskState(
          type: 'plan',
          reused: false,
          nodes: const [
            CoachNodeState(
              id: 'parameters',
              status: 'done',
              stamp: '15 分钟（按你说的短一点调整，原 20 分钟）',
            ),
            CoachNodeState(id: 'output', status: 'done'),
          ],
        ),
      );
      final before = jsonEncode(done.toJson());
      final result = compactor.compose(
        system: system,
        state: done,
        catalog: catalog,
        history: const [],
      );
      final summary =
          jsonDecode(result[1].content.substring('当前状态：'.length)) as Map;
      expect(summary.keys.toSet(), {'parameters', 'plan', 'actions'});
      expect(summary['parameters'], contains('原 20 分钟'));
      expect((summary['plan'] as Map).keys.toSet(), {
        'plan_id',
        'version',
        'title',
        'estimateSec',
      });
      expect(result[1].content, isNot(contains('basedOn')));
      expect(result[1].content, isNot(contains('picks')));
      expect(jsonEncode(done.toJson()), before);
      expect(
        CoachSessionState.fromJson(
          jsonDecode(before) as Map<String, dynamic>,
        ).params['minutes']!.basedOn!.source,
        'host',
      );
    },
  );

  test(
    'only provable same target failure is replaced and task epochs stay separate',
    () {
      final history = <LlmMessage>[
        ..._batch(
          _call('x', AgentTools.checkPlan, {'plan_id': 'plan-a'}),
          '{"ok":false,"code":"bad"}',
        ),
        ..._batch(
          _call('x', AgentTools.checkPlan, {'plan_id': 'plan-b'}),
          '{"ok":true}',
        ),
        ..._batch(
          _call('x', AgentTools.checkPlan, {'plan_id': 'plan-a'}),
          '{"ok":true}',
        ),
        ..._batch(
          _call('x', AgentTools.draftPlan, {'plan_id': 'plan-a'}),
          '{"ok":false,"code":"bad"}',
        ),
        ..._batch(
          _call('x', AgentTools.startTask, {'type': 'plan'}),
          '{"ok":true,"skills":"保留"}',
        ),
        ..._batch(
          _call('x', AgentTools.draftPlan, {'plan_id': 'plan-a'}),
          '{"ok":true}',
        ),
      ];
      final indexes = compactor.supersededFailures(history);
      expect(indexes, {1});
      final result = compactor.compose(
        system: system,
        state: state,
        catalog: catalog,
        history: history,
        supersededFailureMessageIndexes: indexes,
      );
      final tools = result
          .where((message) => message.role == LlmRole.tool)
          .toList();
      expect(tools[0].content, ContextCompactor.archived);
      expect(tools[3].content, contains('bad'));
      expect(tools[4].content, contains('保留'));
    },
  );

  test(
    'finished history retains visible text while current batch remains paired',
    () {
      final history = <LlmMessage>[
        const LlmMessage.user('用户原文'),
        ..._batch(
          _call('old', AgentTools.startTask, {'type': 'plan'}),
          '{"ok":true,"skills":"旧技能"}',
        ),
        LlmMessage.assistant(
          '有什么限制吗？',
          toolCalls: [
            _call('ask', AgentTools.askUser, {
              'question': '有什么限制吗？',
              'mode': 'text',
            }),
          ],
          reasoning: '内部推理',
        ),
        const LlmMessage.tool('ask', '{"ok":true,"asked":true}'),
        LlmMessage.assistant(
          '未展示的中间内容',
          toolCalls: [
            _call('search-intermediate', AgentTools.searchActions, {
              'tags': [],
            }),
          ],
        ),
        const LlmMessage.tool('search-intermediate', '{"ok":true}'),
        LlmMessage.assistant(
          '未展示的失败提问',
          toolCalls: [
            _call('bad-ask', AgentTools.askUser, {
              'question': '问题',
              'mode': 'text',
            }),
          ],
        ),
        const LlmMessage.tool('bad-ask', '{"ok":false}'),
        const LlmMessage.assistant('可见回复'),
      ];
      final turn = _batch(
        _call('new', AgentTools.searchActions, {'tags': []}),
        '{"ok":true}',
      );
      final result = compactor.compose(
        system: system,
        state: state,
        catalog: catalog,
        history: history,
        turnMessages: turn,
        previousTaskFinished: true,
      );
      expect(
        result.map((message) => message.content),
        containsAll(['用户原文', '有什么限制吗？', '可见回复']),
      );
      final question = result.singleWhere(
        (message) => message.content == '有什么限制吗？',
      );
      expect(question.toolCalls, isEmpty);
      expect(question.reasoning, '内部推理');
      expect(result.any((message) => message.toolCallId == 'ask'), isFalse);
      expect(result.any((message) => message.content == '未展示的中间内容'), isFalse);
      expect(result.any((message) => message.content == '未展示的失败提问'), isFalse);
      expect(result.any((message) => message.content.contains('旧技能')), isFalse);
      expect(result.last.toolCallId, 'new');
      expect(result[result.length - 2].toolCalls.single.id, 'new');
    },
  );
}
