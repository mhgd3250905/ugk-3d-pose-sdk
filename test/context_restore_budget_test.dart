import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/src/agent/plan_checker.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

const warmup = ['h-step-jack', 'forearms-A', 'n-pelvis-circle'];
const mainActions = [
  'erectors-A',
  'rotator-cuff-A',
  'deltoids-A',
  'h-kneeling-pushup',
  'h-good-morning',
];
const cooldown = ['o-stand-sidebend', 'h-bilateral-upper-back-hug'];
const r3 = [...warmup, ...mainActions, ...cooldown];

void main() {
  const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$pack/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$pack/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();
  final profile = loadProfile('smartfit');
  final gates = NodeGates(profile, catalog, minPicks: profile.minActions);
  CoachParamValue param(Object value) =>
      CoachParamValue(value: value, source: 'user', turn: 1);
  CoachSessionState r3State({
    List<String> goalCodes = const ['body.core'],
    List<String> selected = r3,
  }) {
    var state = CoachSessionState(
      userTurns: [const CoachUserTurn(turn: 1, text: '居家徒手20分钟核心')],
      params: {
        'scene': param('home'),
        'goal': param(goalCodes),
        'minutes': param(20),
        'equipment': param(<String>[]),
        'level': param(1),
        'limits': param(<String>[]),
      },
    );
    state = AgentTask.start(
      state,
      'plan',
    ).state.copyWith(seenActionIds: selected.toSet());
    state = gates.check(state, 'understand').state;
    state = gates.check(state, 'parameters').state;
    final actions = gates.check(state, 'actions', picks: selected);
    expect(actions.ok, isTrue, reason: '${actions.error}');
    return actions.state;
  }

  Map<String, Object?> r3Draft(List<String> mains) => {
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
          for (final id in mains) {'id': id},
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

  test(
    'original R3 structure with single core code passes hierarchical focus',
    () {
      final draft = PlanBuilder(
        profile,
        catalog,
        minPicks: profile.minActions,
      ).draft(r3State(), r3Draft(mainActions), newPlanId: 'r3');
      expect(draft.ok, isTrue, reason: '${draft.error}');
      final planning = gates.check(draft.state, 'planning');
      expect(planning.ok, isTrue, reason: '${planning.error}');
      final checked = PlanChecker(
        profile,
        catalog,
        minPicks: profile.minActions,
      ).check(planning.state, 'r3');
      expect(checked.ok, isTrue, reason: '${checked.errors}');
      expect((checked.rules['focus_body'] as Map)['ok'], isTrue);
    },
  );
  ({CoachSessionState state, TrainingPlan plan}) sample10() {
    final draft = PlanBuilder(
      profile,
      catalog,
      minPicks: profile.minActions,
    ).draft(r3State(), r3Draft(mainActions), newPlanId: 'r3-core');
    expect(draft.ok, isTrue, reason: '${draft.error}');
    final planning = gates.check(draft.state, 'planning');
    expect(planning.ok, isTrue, reason: '${planning.error}');
    final checked = PlanChecker(
      profile,
      catalog,
      minPicks: profile.minActions,
    ).check(planning.state, 'r3-core');
    expect(
      checked.ok,
      isTrue,
      reason: '${checked.error}; ${checked.errors}; ${checked.rules}',
    );
    expect((checked.rules['focus_body'] as Map)['ok'], isTrue);
    final plan = PlanCodec().decode(checked.state.plans['r3-core']!.last.plan);
    expect(plan.exerciseIds, hasLength(10));
    return (state: checked.state, plan: plan);
  }

  ({CoachSessionState state, TrainingPlan plan}) sample15() {
    const main15 = [
      ...mainActions,
      'obliques-A',
      'chest-A',
      'h-squat',
      'adductors-A',
      'hamstrings-A',
    ];
    const selected = [...warmup, ...main15, ...cooldown];
    expect(selected.toSet(), hasLength(15));
    final draft = PlanBuilder(profile, catalog, minPicks: profile.minActions)
        .draft(
          r3State(
            goalCodes: [
              'body.core',
              'body.abs',
              'body.obliques',
              'body.erectors',
            ],
            selected: selected,
          ),
          r3Draft(main15),
          newPlanId: 'segmented',
        );
    expect(draft.ok, isTrue, reason: '${draft.error}');
    final raw =
        jsonDecode(jsonEncode(draft.state.plans['segmented']!.last.plan))
            as Map<String, dynamic>;
    final blocks = raw['blocks'] as List;
    final mainItems = (blocks[1] as Map)['items'] as List;
    final first = mainItems[0] as Map<String, dynamic>;
    // Preserve two catalogue exercises as separate segments of one item.
    final second = mainItems.removeAt(4) as Map<String, dynamic>;
    first['segments'] = [
      {
        'id': 'segment-1',
        'exerciseId': first['exerciseId'],
        'mode': first['mode'],
        if (first['mode'] == 'time') 'workSeconds': first['workSeconds'],
        if (first['mode'] == 'reps') 'reps': first['reps'],
      },
      {
        'id': 'segment-2',
        'exerciseId': second['exerciseId'],
        'mode': second['mode'],
        if (second['mode'] == 'time') 'workSeconds': second['workSeconds'],
        if (second['mode'] == 'reps') 'reps': second['reps'],
      },
    ];
    final strict = const PlanCodec().decodeStrict(raw);
    expect(strict.ok, isTrue, reason: '${strict.issues}');
    expect(strict.plan!.exerciseIds, hasLength(15));
    expect(
      strict.plan!.items.where((item) => item.segments.length == 2),
      hasLength(1),
    );
    final previous = draft.state.plans['segmented']!.last;
    final next = draft.state.copyWith(
      plans: {
        ...draft.state.plans,
        'segmented': [
          CoachPlanVersion(
            version: previous.version,
            plan: raw,
            estimateSec: const PlanDuration().estimateSeconds(
              strict.plan!,
              catalog,
            ),
            fitLog: previous.fitLog,
          ),
        ],
      },
    );
    final planning = gates.check(next, 'planning');
    expect(planning.ok, isTrue, reason: '${planning.error}');
    final checked = PlanChecker(
      profile,
      catalog,
      minPicks: profile.minActions,
    ).check(planning.state, 'segmented');
    expect(
      checked.ok,
      isTrue,
      reason: '${checked.error}; ${checked.errors}; ${checked.rules}',
    );
    return (state: checked.state, plan: strict.plan!);
  }

  test('R3 scenario 10 actions pass with the single core goal', () {
    sample10();
  });
  test('15-action segmented sample passes the actual check_plan', () {
    sample15();
  });
  for (final segmented in [false, true]) {
    test(
      'restored ${segmented ? '15-action segmented' : 'R3 10-action'} plan first request stays within 12 KB',
      () async {
        final sample = segmented ? sample15() : sample10();
        const context = CoachContext(
          scene: 'home',
          equipment: {},
          minutes: 20,
          goal: 'core',
        );
        final admitted = ToolGate(
          catalog: catalog,
          profile: profile,
        ).admitTemplate(sample.plan, context);
        expect(
          admitted,
          isNotNull,
          reason: 'sample must pass normal card admission',
        );
        final seedClient = FakeLlmClient([
          LlmResponse(
            content: '',
            toolCalls: [
              LlmToolCall(
                id: 'review-seed',
                name: AgentTools.check,
                arguments: jsonEncode({'node': 'review'}),
              ),
              LlmToolCall(
                id: 'show-seed',
                name: AgentTools.showPlan,
                arguments: jsonEncode({
                  'plan_id': sample.plan.id,
                  'note': '量力而行。',
                }),
              ),
            ],
            finishReason: 'tool_calls',
          ),
        ], latency: Duration.zero);
        final seedAgent = CoachAgent(
          client: seedClient,
          catalog: () => catalog,
          profile: profile,
          enableUserMemory: false,
          maxRequestRetries: 0,
        );
        seedAgent.restorePlan(
          admitted!,
          planState: CoachPlanState(
            planId: sample.plan.id,
            context: context,
            sessionState: sample.state,
          ),
        );
        final seed = CoachConversationController(agent: seedAgent);
        addTearDown(seed.dispose);
        final delivered = await seed.send('请输出这个计划');
        expect(
          delivered!.plan,
          isNotNull,
          reason: '${delivered.issues}; ${delivered.error}',
        );
        final snapshot = CoachPlanState.fromJson(
          jsonDecode(
                jsonEncode(seedAgent.planStateFor(delivered.plan!).toJson()),
              )
              as Map<String, dynamic>,
        );
        final messages = [
          CoachConversationMessage(
            id: 'original',
            at: DateTime.utc(2026),
            isUser: true,
            text: '在家徒手20分钟练核心',
          ),
          ...seed.state.messages,
        ];
        final client = FakeLlmClient(['收到。'], latency: Duration.zero);
        final fresh = CoachAgent(
          client: client,
          catalog: () => catalog,
          profile: profile,
          enableUserMemory: false,
          maxRequestRetries: 0,
        );
        final restored = CoachConversationController(agent: fresh);
        addTearDown(restored.dispose);
        restored.restoreHistory(messages, planState: snapshot);
        final result = await restored.send('继续');
        expect(result, isNotNull);
        final request = client.requests.single;
        final serializer = OpenAiCompatibleClient(
          config: LlmConfig.ugkWorker.copyWith(
            extraBody: {
              'thinking': {'type': 'enabled'},
            },
          ),
        );
        final payload = jsonEncode(serializer.buildBody(request));
        final bytes = utf8.encode(payload).length;
        final system = request.messages
            .where((m) => m.role == LlmRole.system)
            .fold<int>(
              0,
              (n, m) => n + utf8.encode(jsonEncode(m.toJson())).length,
            );
        final userAssistant = request.messages
            .where((m) => m.role != LlmRole.system)
            .fold<int>(
              0,
              (n, m) => n + utf8.encode(jsonEncode(m.toJson())).length,
            );
        final tools = utf8
            .encode(jsonEncode([for (final t in request.tools) t.toJson()]))
            .length;
        for (final message in request.messages) {
          print(
            'COMPONENT role=${message.role.name} bytes=${utf8.encode(jsonEncode(message.toJson())).length} prefix=${message.content.substring(0, message.content.length < 35 ? message.content.length : 35)}',
          );
        }
        // Components are diagnostic measurements; whole body includes transport fields.
        print(
          'RESTORE ${segmented ? 15 : 10}: bytes=$bytes system=$system history=$userAssistant tools=$tools',
        );
        expect(
          bytes,
          lessThanOrEqualTo(12 * 1024),
          reason: 'restore payload=$bytes bytes',
        );
        expect(
          request.messages.any((m) => m.content.contains('在家徒手20分钟练核心')),
          isTrue,
        );
        expect(
          request.messages.any((m) => m.content.contains('量力而行。')),
          isTrue,
        );
      },
    );
  }
  test(
    'R3 stress replay keeps every serialized Worker request within 40 KB',
    () async {
      LlmToolCall call(String id, String name, Object args) =>
          LlmToolCall(id: id, name: name, arguments: jsonEncode(args));
      LlmResponse batch(List<LlmToolCall> calls) => LlmResponse(
        content: '',
        toolCalls: calls,
        finishReason: 'tool_calls',
        model: 'fake',
      );
      void protocol(LlmRequest request) {
        final pending = <String>{};
        for (final message in request.messages) {
          if (message.role == LlmRole.assistant) {
            expect(pending, isEmpty, reason: 'previous tool batch incomplete');
            for (final tool in message.toolCalls) {
              expect(pending.add(tool.id), isTrue);
            }
          } else if (message.role == LlmRole.tool) {
            expect(pending.remove(message.toolCallId), isTrue);
          } else {
            expect(pending, isEmpty);
          }
        }
        expect(pending, isEmpty);
      }

      LlmToolCall searchFor(String id, String callId) =>
          call(callId, AgentTools.searchActions, {
            'tags': <String>[],
            'keywords': catalog[id]!.name.of('en'),
            'limit': 20,
          });
      String? planId;
      final client = FakeLlmClient([
        batch([
          call('r3-start', AgentTools.startTask, {'type': 'plan'}),
          call('r3-understand', AgentTools.check, {'node': 'understand'}),
          call('r3-params', AgentTools.setParams, {
            'fields': {
              'scene': {'value': 'home', 'source': 'user', 'quote': '在家'},
              'equipment': {
                'value': <String>[],
                'source': 'user',
                'quote': '徒手',
              },
              'minutes': {'value': 20, 'source': 'user', 'quote': '20 分钟'},
              'goal': {
                'value': ['body.core'],
                'source': 'user',
                'quote': '核心',
              },
            },
          }),
          call('r3-parameters', AgentTools.check, {'node': 'parameters'}),
        ]),
        (LlmRequest request) {
          protocol(request);
          final start =
              jsonDecode(
                    request.messages
                        .singleWhere((m) => m.toolCallId == 'r3-start')
                        .content,
                  )
                  as Map;
          planId = start['plan_id'] as String?;
          expect(planId, isNotEmpty);
          final skills = start['skills'] as Map;
          expect(
            skills.keys,
            containsAll(['ask', 'action-library', 'plan-training']),
          );
          return batch([
            for (var i = 0; i < 3; i++) searchFor(r3[i], 'r3-search-$i'),
          ]);
        },
        batch([for (var i = 3; i < 7; i++) searchFor(r3[i], 'r3-search-$i')]),
        batch([
          for (var i = 7; i < 10; i++) searchFor(r3[i], 'r3-search-$i'),
          call('r3-search-general', AgentTools.searchActions, {
            'tags': <String>[],
            'limit': 20,
          }),
          call('r3-question', AgentTools.askUser, {
            'question': '还有伤痛或器材限制吗？',
            'mode': 'text',
          }),
        ]),
        batch([
          for (var i = 0; i < 4; i++) searchFor(r3[i], 'r3-second-search-$i'),
        ]),
        batch([
          for (var i = 0; i < r3.length; i++)
            call('r3-detail-$i', AgentTools.getAction, {
              'ids': [r3[i]],
            }),
        ]),
        (LlmRequest request) {
          protocol(request);
          for (var i = 0; i < r3.length; i++) {
            final detail =
                jsonDecode(
                      request.messages
                          .singleWhere((m) => m.toolCallId == 'r3-detail-$i')
                          .content,
                    )
                    as Map;
            expect(detail['ok'], isTrue, reason: 'detail $i: $detail');
          }
          return batch([
            call('r3-actions', AgentTools.check, {
              'node': 'actions',
              'picks': r3,
            }),
            call('r3-draft', AgentTools.draftPlan, {
              'plan_id': planId,
              ...r3Draft(mainActions),
            }),
            call('r3-planning', AgentTools.check, {'node': 'planning'}),
            call('r3-check', AgentTools.checkPlan, {'plan_id': planId}),
            call('r3-review', AgentTools.check, {'node': 'review'}),
            call('r3-show', AgentTools.showPlan, {
              'plan_id': planId,
              'note': '量力而行。',
            }),
          ]);
        },
        '不客气。',
      ], latency: Duration.zero);
      final agent = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
      );
      addTearDown(agent.dispose);
      const firstUser = '在家徒手 20 分钟练核心';
      const reply = '初学者，在家徒手，没有垫子或其他器材，20分钟练核心。目前没有伤病、疼痛或其他运动限制。';
      final first = await agent.send(firstUser);
      expect(
        first.question,
        isNotNull,
        reason: '${first.issues}; ${first.error}',
      );
      final second = await agent.send(reply);
      expect(
        second.plan,
        isNotNull,
        reason: '${second.issues}; ${second.error}',
      );
      expect(second.plan!.plan.exerciseIds, hasLength(10));
      final finalReply = await agent.send('谢谢');
      expect(finalReply.text, '不客气。');
      final serializer = OpenAiCompatibleClient(
        config: LlmConfig.ugkWorker.copyWith(
          extraBody: {
            'thinking': {'type': 'enabled'},
          },
        ),
      );
      addTearDown(serializer.close);
      for (var i = 0; i < client.requests.length; i++) {
        final request = client.requests[i];
        protocol(request);
        final size = utf8
            .encode(jsonEncode(serializer.buildBody(request)))
            .length;
        print('STRESS request=$i bytes=$size');
        expect(
          size,
          lessThanOrEqualTo(40 * 1024),
          reason: 'R3 replay request $i: $size bytes',
        );
      }
      final finalRequest = client.requests.last;
      expect(
        finalRequest.messages.any((m) => m.content.contains(firstUser)),
        isTrue,
      );
      expect(
        finalRequest.messages.any((m) => m.content.contains(reply)),
        isTrue,
      );
      expect(
        finalRequest.messages.any((m) => m.content.contains('量力而行。')),
        isTrue,
      );
    },
  );
}
