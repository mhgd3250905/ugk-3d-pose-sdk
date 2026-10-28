import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/structured_tool_handler.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$pack/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$pack/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();
  final profile = loadProfile('smartfit');
  final handler = StructuredToolHandler(
    profile,
    catalog,
    newPlanId: () => 'auto',
    files: SkillFiles.build(profile, catalog),
  );
  const groups = [
    ('warmup', ['n-squat-shift', 'forearms-A', 'n-pelvis-circle']),
    (
      'main',
      [
        'erectors-A',
        'rotator-cuff-A',
        'deltoids-A',
        'h-kneeling-pushup',
        'h-good-morning',
      ],
    ),
    ('cooldown', ['o-stand-sidebend', 'h-bilateral-upper-back-hug']),
  ];
  final ids = {for (final g in groups) ...g.$2};

  test(
    'nonterminal failed tool records its actual rejection before rollback',
    () async {
      final client = FakeLlmClient([
        LlmResponse(
          content: '',
          finishReason: 'tool_calls',
          toolCalls: const [
            LlmToolCall(
              id: 'early-search',
              name: 'search_actions',
              arguments: '{"tags":["invented.tag"]}',
            ),
          ],
        ),
        '你好。',
      ], latency: Duration.zero);
      final agent = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
      );
      addTearDown(agent.dispose);
      final result = await agent.send('你好');
      expect(result.records.first.outcome, CallOutcome.toolStep);
      expect(result.records.first.issueCodes, ['invalid_tags']);
    },
  );
  Map<String, Object?> params() => {
    'fields': {
      'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
      'goal': {
        'value': ['body.core'],
        'source': 'user',
        'quote': '核心',
      },
      'minutes': {'value': 20, 'source': 'user', 'quote': '20分钟'},
    },
  };
  Map<String, Object?> draft() => {
    'plan_id': 'auto',
    'title': '居家核心',
    'blocks': [
      for (final group in groups)
        {
          'kind': group.$1,
          if (group.$1 == 'main') 'rounds': 2,
          'items': [
            for (final id in group.$2) {'id': id},
          ],
        },
    ],
  };
  CoachSessionState started() => handler
      .task(
        CoachSessionState().appendUserTurn('在家徒手20分钟练核心'),
        'start_task',
        '{"type":"plan"}',
        'zh',
      )
      .state;
  CoachSessionState ready() => handler
      .setParams(started(), params(), 'zh', [])
      .state
      .copyWith(seenActionIds: ids);
  Map<String, dynamic> receipt(StructuredToolResult r) =>
      jsonDecode(r.response) as Map<String, dynamic>;

  test(
    'start and complete parameters auto advance once with genuine stamps',
    () {
      final state = started();
      expect(state.task!.nodes.first.status, 'done');
      expect(state.task!.nodes[1].status, 'current');
      final partial = handler.setParams(
        state,
        {
          'fields': {
            'scene': {'value': 'home', 'source': 'default'},
          },
        },
        'zh',
        [],
      );
      expect(receipt(partial)['ok'], isTrue);
      expect(partial.state.task!.nodes[1].status, 'current');
      final complete = handler.setParams(state, params(), 'zh', []);
      expect(complete.state.task!.nodes[1].status, 'done');
      expect(receipt(complete)['stamp'], contains('20 分钟（你说的）'));
      expect(complete.state.params['equipment']!.source, 'default');
      for (final node in ['understand', 'parameters']) {
        final again = handler.task(
          complete.state,
          'check',
          jsonEncode({'node': node}),
          'zh',
        );
        expect(receipt(again)['ok'], isTrue);
        expect(again.changes, isEmpty);
      }
    },
  );

  test(
    'draft automatically completes actions planning review and repeated checks are noops',
    () {
      final built = handler.draft(ready(), jsonEncode(draft()), 'zh');
      expect(receipt(built)['ok'], isTrue, reason: built.response);
      expect((receipt(built)['check'] as Map)['ok'], isTrue);
      expect(built.changes.where((n) => n.status == 'done').map((n) => n.id), [
        'actions',
        'planning',
        'review',
      ]);
      expect(built.state.task!.nodes.last.status, 'current');
      for (final node in ['actions', 'planning', 'review']) {
        final again = handler.task(
          built.state,
          'check',
          jsonEncode({'node': node}),
          'zh',
        );
        expect(receipt(again)['ok'], isTrue);
        expect(again.changes, isEmpty);
      }
      final again = handler.checkPlan(built.state, '{"plan_id":"auto"}');
      expect(receipt(again)['ok'], isTrue);
      expect(again.changes, isEmpty);
      final shown = ToolGate(catalog: catalog, profile: profile)
          .checkAgentOutput(built.state, 'show_plan', {
            'plan_id': 'auto',
            'note': '循序渐进。',
          }, language: 'zh');
      expect(shown.error, isNull);
      expect(shown.state.task!.nodes.last.status, 'done');
      final resumed = handler.task(
        shown.state.copyWith(
          lastDeliveredPlanId: 'auto',
          lastDeliveredVersion: 1,
          lastDeliveredTurn: 1,
        ),
        'start_task',
        '{"type":"plan","reuse":true}',
        'zh',
      );
      expect(resumed.state.activePlanId, 'auto');
      expect(resumed.state.seenActionIds, ids);
      expect(resumed.state.picks, built.state.picks);
      expect(resumed.state.task!.nodes[3].status, 'current');
    },
  );

  test('bad draft cannot commit temporary actions or bypass source gate', () {
    final state = ready();
    final bad = draft();
    (((bad['blocks'] as List).first as Map)['items'] as List)[0] = {
      'id': 'unsearched-action',
    };
    final rejected = handler.draft(state, jsonEncode(bad), 'zh');
    expect(receipt(rejected)['ok'], isFalse);
    expect(identical(rejected.state, state), isTrue);
    expect(rejected.changes, isEmpty);
    final unseen = handler.draft(
      state.copyWith(seenActionIds: {}),
      jsonEncode(draft()),
      'zh',
    );
    expect(receipt(unseen)['code'], 'unseen_actions');
  });

  test(
    'failed automatic review saves version and returns fix in the same receipt',
    () {
      final state = ready();
      final changed = state.copyWith(
        params: {
          ...state.params,
          'goal': CoachParamValue(
            value: ['body.inner_thigh'],
            source: 'user',
            turn: 1,
          ),
        },
      );
      final result = handler.draft(changed, jsonEncode(draft()), 'zh');
      expect(receipt(result)['code'], 'plan_check_failed');
      expect(receipt(result)['errors'], isNotEmpty);
      expect(receipt(result)['fix'], isNotEmpty);
      expect(result.state.plans['auto']!.last.check!['ok'], isFalse);
      expect(result.state.task!.nodes[3].status, 'current');
      expect(result.state.task!.nodes[4].status, 'pending');
    },
  );

  test(
    'real three-call plan flow emits every node without any check tool',
    () async {
      LlmToolCall call(String id, String name, Object args) =>
          LlmToolCall(id: id, name: name, arguments: jsonEncode(args));
      LlmResponse batch(List<LlmToolCall> calls) => LlmResponse(
        content: '',
        toolCalls: calls,
        finishReason: 'tool_calls',
        model: 'fake',
      );
      String? planId;
      final client = FakeLlmClient([
        batch([
          call('start', 'start_task', {'type': 'plan'}),
          call('params', 'set_params', params()),
          for (final id in ids)
            call('search-$id', 'search_actions', {
              'tags': <String>[],
              'keywords': catalog[id]!.name.of('en'),
            }),
        ]),
        (LlmRequest request) {
          final start =
              jsonDecode(
                    request.messages
                        .singleWhere((m) => m.toolCallId == 'start')
                        .content,
                  )
                  as Map;
          planId = start['plan_id'] as String;
          return batch([
            call('draft', 'draft_plan', draft()..['plan_id'] = planId),
          ]);
        },
        (LlmRequest request) {
          final result =
              jsonDecode(
                    request.messages
                        .singleWhere((m) => m.toolCallId == 'draft')
                        .content,
                  )
                  as Map;
          expect(result['ok'], isTrue, reason: '$result');
          return batch([
            call('show', 'show_plan', {'plan_id': planId, 'note': '循序渐进。'}),
          ]);
        },
      ], latency: Duration.zero);
      final agent = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
      );
      addTearDown(agent.dispose);
      final events = <AgentEvent>[];
      agent.events.listen(events.add);
      final result = await agent.send('在家徒手20分钟练核心');
      expect(
        result.plan,
        isNotNull,
        reason: '${result.error};${result.issues}',
      );
      expect(client.requests, hasLength(3));
      expect(
        events
            .where(
              (e) => e.kind == AgentEventKind.node && e.node?.status == 'done',
            )
            .map((e) => e.node!.id),
        ['understand', 'parameters', 'actions', 'planning', 'review', 'output'],
      );
    },
  );
}
