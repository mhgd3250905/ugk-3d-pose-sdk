import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/output_gate.dart';
import 'package:ugk_coach/src/agent/terminal_tool_handler.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('smartfit');
  final gate = ToolGate(catalog: catalog, profile: profile);
  final nodes = NodeGates(profile, catalog, minPicks: profile.minActions);
  CoachParamValue param(Object value) =>
      CoachParamValue(value: value, source: 'user', turn: 1);
  CoachSessionState base() => CoachSessionState(
    task: CoachTaskState(
      type: 'recommend',
      reused: false,
      nodes: [
        for (final id in AgentTask.recommendNodes)
          CoachNodeState(
            id: id,
            status: id == 'actions'
                ? 'current'
                : id == 'output'
                ? 'pending'
                : 'done',
          ),
      ],
    ),
    params: {
      'scene': param('home'),
      'goal': param(['purpose.strength']),
      'equipment': param(<String>[]),
      'limits': param(<String>[]),
    },
  );
  final ids = profile
      .scope(catalog)
      .where((drill) => nodes.actionProblem(base(), drill.id) == null)
      .take(3)
      .map((drill) => drill.id)
      .toList();
  CoachSessionState ready() => base().copyWith(seenActionIds: ids.toSet());
  AgentOutputResult show(
    CoachSessionState state, {
    List<String>? selected,
    Object? note = '可以从这些动作开始。',
    String language = 'zh',
  }) => gate.checkAgentOutput(state, CoachTools.showActions, {
    'ids': selected ?? ids,
    'note': note,
  }, language: language);

  test(
    'show_actions atomically completes actions and output with real stamps',
    () {
      final original = ready();
      final before = jsonEncode(original.toJson());
      final result = show(original);
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(result.state.picks, ids);
      expect(result.card!.actions!.items.map((item) => item.id), ids);
      expect(
        result.state.task!.nodes.every((node) => node.status == 'done'),
        isTrue,
      );
      expect(result.changes.map((node) => '${node.id}:${node.status}'), [
        'actions:done',
        'output:current',
        'output:done',
      ]);
      expect(result.changes.first.stamp, '选了 3 个动作');
      expect(result.changes.last.stamp, '已交付');
      expect(jsonEncode(original.toJson()), before);
    },
  );

  test('invalid note types remain errors and cannot advance actions', () {
    for (final note in [null, 17, '', '   ', <String>[]]) {
      final original = ready();
      final before = jsonEncode(original.toJson());
      final result = show(original, note: note);
      expect(result.ok, isFalse);
      expect(result.error!['code'], 'invalid_note');
      expect(result.state, same(original));
      expect(result.changes, isEmpty);
      expect(jsonEncode(original.toJson()), before);
    }
  });

  test(
    'automatic selection preserves minPicks, uniqueness and seen checks',
    () {
      for (final selected in [
        ids.take(2).toList(),
        [ids[0], ids[0], ids[2]],
      ]) {
        final original = ready();
        final result = show(original, selected: selected);
        expect(result.error!['code'], 'invalid_picks');
        expect(result.state, same(original));
        expect(result.changes, isEmpty);
      }
      final unseen = ready().copyWith(seenActionIds: ids.take(2).toSet());
      final result = show(unseen);
      expect(result.error!['code'], 'unseen_actions');
      expect(result.state, same(unseen));
      expect(result.changes, isEmpty);
    },
  );

  test('safety failure never commits a partially completed actions node', () {
    final unsafe = profile
        .scope(catalog)
        .firstWhere((drill) => drill.cautions.contains('膝'));
    final selected = {...ids.take(2), unsafe.id}.toList();
    while (selected.length < 3) {
      selected.add(ids.firstWhere((id) => !selected.contains(id)));
    }
    final original = ready().copyWith(
      seenActionIds: selected.toSet(),
      params: {
        ...ready().params,
        'limits': param(['limit.knee']),
      },
    );
    final result = show(original, selected: selected);
    expect(result.error!['code'], 'incompatible_actions');
    expect(result.state, same(original));
    expect(result.changes, isEmpty);
    expect(original.task!.nodes[2].status, 'current');
  });

  test('recommendation output cannot skip understanding or parameters', () {
    final original = ready().copyWith(
      task: CoachTaskState(
        type: 'recommend',
        reused: false,
        nodes: [
          for (final id in AgentTask.recommendNodes)
            CoachNodeState(
              id: id,
              status: id == 'parameters'
                  ? 'current'
                  : id == 'understand'
                  ? 'done'
                  : 'pending',
            ),
        ],
      ),
    );
    final result = show(original);
    expect(result.error!['code'], 'nodes_incomplete');
    expect(result.state, same(original));
    expect(result.changes, isEmpty);
  });

  test(
    'overlong English note is shortened and explained in the tool receipt',
    () {
      final note = '${List.generate(46, (i) => 'word$i').join(' ')}.';
      final terminal = TerminalToolHandler(gate).show(
        ready(),
        CoachTools.showActions,
        jsonEncode({'ids': ids, 'note': note}),
        language: 'en',
      );
      expect(terminal.rejected, isFalse);
      expect(terminal.output!.noteTruncated, isTrue);
      expect(
        terminal.output!.card!.text,
        List.generate(45, (i) => 'word$i').join(' '),
      );
      expect(jsonDecode(terminal.response), {
        'ok': true,
        'shown': true,
        'noteTruncated': true,
        'note': '已截断',
      });
      expect(terminal.output!.changes.first.stamp, 'Selected 3 actions');
    },
  );

  test('locale-specific note budgets preserve words, Unicode and decimals', () {
    expect(normalizeOutputNote('😀' * 121).text, '😀' * 120);
    expect(normalizeOutputNote('😀' * 121).truncated, isTrue);
    expect(normalizeOutputNote('20.3 分钟。慢慢开始。忽略这一句。').text, '20.3 分钟。慢慢开始。');
    expect(
      normalizeOutputNote('First?! Second! Third.', language: 'en').text,
      'First?! Second!',
    );
    expect(normalizeOutputNote('“第一句。”“第二句。”第三句。').text, '“第一句。”“第二句。”');
    final exact = '${List.filled(45, 'word').join(' ')}.';
    expect(normalizeOutputNote(exact, language: 'en').text, exact);
    expect(normalizeOutputNote(exact, language: 'en').truncated, isFalse);
    expect(
      normalizeOutputNote(
        '  First sentence. Second sentence.  ',
        language: 'en',
      ).truncated,
      isFalse,
    );
    expect(
      normalizeOutputNote(
        'First sentence. Second sentence. Third sentence.',
        language: 'en',
      ).text,
      'First sentence. Second sentence.',
    );
  });

  test(
    'real agent can deliver recommendation after search without check(actions)',
    () async {
      LlmToolCall call(String id, String name, Object arguments) =>
          LlmToolCall(id: id, name: name, arguments: jsonEncode(arguments));
      LlmResponse calls(List<LlmToolCall> values) => LlmResponse(
        content: '',
        toolCalls: values,
        finishReason: 'tool_calls',
        model: 'fake',
      );
      final client = FakeLlmClient([
        calls([
          call('start', 'start_task', {'type': 'recommend'}),
          call('understand', 'check', {'node': 'understand'}),
          call('params', 'set_params', {
            'fields': {
              'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
              'goal': {
                'value': ['body.core'],
                'source': 'user',
                'quote': '核心',
              },
              'equipment': {
                'value': <String>[],
                'source': 'user',
                'quote': '徒手',
              },
            },
          }),
          call('parameters', 'check', {'node': 'parameters'}),
          call('search', 'search_actions', {
            'tags': ['body.core'],
            'limit': 3,
          }),
        ]),
        (LlmRequest request) {
          final result =
              jsonDecode(
                    request.messages
                        .singleWhere(
                          (message) => message.toolCallId == 'search',
                        )
                        .content,
                  )
                  as Map;
          final selected = (result['items'] as List)
              .map((row) => (row as Map)['id'])
              .toList();
          return calls([
            call('show', 'show_actions', {
              'ids': selected,
              'note': '先从这些动作开始。',
            }),
          ]);
        },
      ]);
      final agent = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
      );
      addTearDown(agent.dispose);
      final events = <AgentEvent>[];
      agent.events.listen(events.add);
      final result = await agent.send('在家徒手练核心');
      expect(
        result.status,
        TurnStatus.ok,
        reason: '${result.error}; ${result.issues}',
      );
      expect(result.actions!.items, hasLength(3));
      final completed = events
          .where((event) => event.node?.status == 'done')
          .map((event) => event.node!.id)
          .toList();
      expect(completed, ['understand', 'parameters', 'actions', 'output']);
      expect(client.requests, hasLength(2));
    },
  );
}
