import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

LlmToolCall call(String id, String name, Object args) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(args));
LlmResponse calls(List<LlmToolCall> values) => LlmResponse(
  content: '',
  toolCalls: values,
  finishReason: 'tool_calls',
  model: 'fake',
);
Map<String, dynamic> feedback(LlmRequest request, String id) =>
    jsonDecode(request.messages.singleWhere((m) => m.toolCallId == id).content)
        as Map<String, dynamic>;

void main() {
  const root = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$root/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$root/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();
  final profile = loadProfile('smartfit');
  const warmup = ['n-squat-shift', 'forearms-A', 'n-pelvis-circle'];
  const main = [
    'erectors-A',
    'rotator-cuff-A',
    'deltoids-A',
    'h-kneeling-pushup',
    'h-good-morning',
  ];
  const cooldown = ['o-stand-sidebend', 'h-bilateral-upper-back-hug'];
  final ids = [...warmup, ...main, ...cooldown];

  CoachAgent agent(FakeLlmClient client) {
    final coach = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      enableUserMemory: false,
      maxRequestRetries: 0,
    );
    addTearDown(coach.dispose);
    return coach;
  }

  LlmResponse setup() => calls([
    call('start', AgentTools.startTask, {'type': 'plan'}),
    call('understand', AgentTools.check, {'node': 'understand'}),
    call('params', AgentTools.setParams, {
      'fields': {
        'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
        'equipment': {'value': <String>[], 'source': 'user', 'quote': '徒手'},
        'goal': {
          'value': ['body.core'],
          'source': 'user',
          'quote': '核心',
        },
        'minutes': {'value': 20, 'source': 'user', 'quote': '20分钟'},
      },
    }),
    call('parameters', AgentTools.check, {'node': 'parameters'}),
    for (var i = 0; i < ids.length; i++)
      call('search$i', AgentTools.searchActions, {
        'tags': <String>[],
        'keywords': catalog[ids[i]]!.name.of('en'),
      }),
  ]);

  void ensureSearched(LlmRequest request) {
    for (var i = 0; i < ids.length; i++) {
      final result = feedback(request, 'search$i');
      expect(result['ok'], isTrue, reason: '$i: $result');
      expect(
        (result['items'] as List).map((e) => (e as Map)['id']),
        contains(ids[i]),
      );
    }
  }

  Map<String, Object?> draft() => {
    'title': '居家核心',
    'blocks': [
      {
        'kind': 'warmup',
        'items': [
          for (final id in warmup) {'id': id},
        ],
      },
      {
        'kind': 'main',
        'rounds': 2,
        'items': [
          for (final id in main) {'id': id},
        ],
      },
      {
        'kind': 'cooldown',
        'items': [
          for (final id in cooldown) {'id': id},
        ],
      },
    ],
  };
  LlmResponse ask() => calls([
    call('ask', AgentTools.askUser, {'question': '还有其他要求吗？', 'mode': 'text'}),
  ]);

  test(
    'real loop drafts a version and completes planning from structured goal',
    () async {
      final client = FakeLlmClient([
        setup(),
        (LlmRequest request) {
          ensureSearched(request);
          return calls([
            call('actions', AgentTools.check, {
              'node': 'actions',
              'picks': ids,
            }),
            call('draft', AgentTools.draftPlan, draft()),
          ]);
        },
        (LlmRequest request) {
          final result = feedback(request, 'draft');
          expect(result['ok'], isTrue, reason: '$result');
          expect(result['version'], 1);
          expect(result['legacyGoal'], 'core');
          expect((result['check'] as Map)['ok'], isTrue);
          expect(result['estimateMinutes'], inInclusiveRange(18, 22));
          expect(result.containsKey('plan'), isFalse);
          expect(result.containsKey('blocks'), isFalse);
          return calls([
            call('planning', AgentTools.check, {'node': 'planning'}),
          ]);
        },
        ask(),
      ], latency: Duration.zero);
      final coach = agent(client);
      final events = <AgentEvent>[];
      final sub = coach.events.listen(events.add);
      addTearDown(sub.cancel);
      final result = await coach.send('在家徒手 20分钟练核心');
      expect(
        result.question,
        isNotNull,
        reason: '${result.error}; ${result.issues}',
      );
      final state = coach.sessionState;
      final id = state.activePlanId!;
      final version = state.plans[id]!.single;
      expect(version.version, 1);
      expect(version.plan['goal'], 'core');
      expect(version.plan['equipment'], isEmpty);
      expect(version.check!['ok'], isTrue);
      expect(
        state.task!.nodes.singleWhere((n) => n.id == 'planning').status,
        'done',
      );
      expect(
        state.task!.nodes.singleWhere((n) => n.status == 'current').id,
        'output',
      );
      final done = events
          .where(
            (e) => e.kind == AgentEventKind.node && e.node?.status == 'done',
          )
          .map((e) => e.node!.id);
      expect(done, [
        'understand',
        'parameters',
        'actions',
        'planning',
        'review',
      ]);
    },
  );

  test(
    'duration_unfit saves version and its plan_id can repair it on the next model call',
    () async {
      late String planId;
      final client = FakeLlmClient([
        setup(),
        (LlmRequest request) {
          ensureSearched(request);
          return calls([
            call('actions', AgentTools.check, {
              'node': 'actions',
              'picks': ids,
            }),
            call('short', AgentTools.draftPlan, {
              'title': '太短的方案',
              'blocks': [
                {
                  'kind': 'warmup',
                  'items': [
                    for (final id in warmup) {'id': id},
                  ],
                },
              ],
            }),
          ]);
        },
        (LlmRequest request) {
          final short = feedback(request, 'short');
          expect(short['ok'], isFalse, reason: '$short');
          expect(short['code'], 'duration_unfit');
          expect(short['version'], 1);
          expect(short.containsKey('plan'), isFalse);
          planId = short['plan_id'] as String;
          expect(short['fix'], contains('增加'));
          return calls([
            call('repair', AgentTools.draftPlan, {
              ...draft(),
              'plan_id': planId,
            }),
          ]);
        },
        (LlmRequest request) {
          final repaired = feedback(request, 'repair');
          expect(repaired['ok'], isTrue, reason: '$repaired');
          expect(repaired['plan_id'], planId);
          expect(repaired['version'], 2);
          expect(repaired['legacyGoal'], 'core');
          expect((repaired['check'] as Map)['ok'], isTrue);
          expect(repaired.containsKey('plan'), isFalse);
          return calls([
            call('planning', AgentTools.check, {'node': 'planning'}),
          ]);
        },
        ask(),
      ], latency: Duration.zero);
      final coach = agent(client);
      final result = await coach.send('在家徒手 20分钟练核心');
      expect(
        result.question,
        isNotNull,
        reason: '${result.error}; ${result.issues}',
      );
      expect(coach.sessionState.activePlanId, planId);
      final versions = coach.sessionState.plans[planId]!;
      expect(versions.map((v) => v.version), [1, 2]);
      expect(versions.first.check, isNull);
      expect(versions.last.check!['ok'], isTrue);
      expect(
        coach.sessionState.task!.nodes
            .singleWhere((n) => n.id == 'planning')
            .status,
        'done',
      );
    },
  );

  test(
    'invalid arguments and model legacy_goal never save a version',
    () async {
      final client = FakeLlmClient([
        setup(),
        (LlmRequest request) {
          ensureSearched(request);
          return calls([
            call('actions', AgentTools.check, {
              'node': 'actions',
              'picks': ids,
            }),
            call('bad', AgentTools.draftPlan, {
              'title': '',
              'blocks': <Object>[],
            }),
          ]);
        },
        (LlmRequest request) {
          expect(feedback(request, 'bad')['ok'], isFalse);
          return calls([
            call('goal_injection', AgentTools.draftPlan, {
              ...draft(),
              'legacy_goal': 'strength',
            }),
          ]);
        },
        (LlmRequest request) {
          final denied = feedback(request, 'goal_injection');
          expect(denied['ok'], isFalse);
          expect(denied['code'], 'invalid_draft');
          expect(denied.containsKey('plan_id'), isFalse);
          return ask();
        },
      ], latency: Duration.zero);
      final coach = agent(client);
      final result = await coach.send('在家徒手 20分钟练核心');
      expect(
        result.question,
        isNotNull,
        reason: '${result.error}; ${result.issues}',
      );
      final reserved = coach.sessionState.activePlanId;
      expect(reserved, isNotNull);
      expect(coach.sessionState.plans.keys, [reserved]);
      expect(coach.sessionState.plans[reserved], isEmpty);
      expect(
        coach.sessionState.task!.nodes
            .singleWhere((n) => n.status == 'current')
            .id,
        'planning',
      );
    },
  );
}
