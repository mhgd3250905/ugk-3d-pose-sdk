import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('hiplab');
  final gate = ToolGate(catalog: catalog, profile: profile);
  CoachParamValue param(Object value) =>
      CoachParamValue(value: value, source: 'user', turn: 1);
  CoachSessionState state({
    String type = 'plan',
    bool complete = true,
    bool checked = true,
  }) {
    final nodeNames = type == 'plan'
        ? AgentTask.planNodes
        : AgentTask.recommendNodes;
    final plan = planOf(okEnvelope())..['id'] = 'p';
    return CoachSessionState(
      task: CoachTaskState(
        type: type,
        reused: false,
        nodes: [
          for (var i = 0; i < nodeNames.length; i++)
            CoachNodeState(
              id: nodeNames[i],
              status: i == nodeNames.length - 1
                  ? 'current'
                  : (complete || i != 1 ? 'done' : 'pending'),
            ),
        ],
      ),
      params: {
        'scene': param('home'),
        'equipment': param(['equip.mat']),
        'minutes': param(10),
        'limits': param(<String>[]),
        'goal': param(['purpose.stretch']),
      },
      picks: ['s-figure4', 'h-squat'],
      seenActionIds: catalog.ids.toSet(),
      activePlanId: 'p',
      plans: {
        'p': [
          CoachPlanVersion(
            version: 1,
            plan: plan,
            estimateSec: 600,
            fitLog: const [],
            check: checked ? {'ok': true} : null,
          ),
        ],
      },
    );
  }

  AgentOutputResult showPlan(
    CoachSessionState source, {
    String id = 'p',
    String note = '这是适合你的安排。',
  }) => gate.checkAgentOutput(source, CoachTools.showPlan, {
    'plan_id': id,
    'note': note,
  });
  AgentOutputResult showActions(
    CoachSessionState source, {
    List<String> ids = const ['s-figure4', 'h-squat'],
    String note = '可以从这些动作开始。',
  }) => gate.checkAgentOutput(source, CoachTools.showActions, {
    'ids': ids,
    'note': note,
  });

  test(
    'plan output creates an existing card and returns an uncommitted completed node',
    () {
      final original = state();
      final result = showPlan(original);
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(result.card!.plan, isA<ValidatedPlan>());
      expect(result.card!.text, '这是适合你的安排。');
      expect(result.card!.plan!.plan.targetMinutes, 10);
      expect(original.task!.nodes.last.status, 'current');
      expect(result.state.task!.nodes.last.status, 'done');
      expect(result.changes.map((n) => '${n.id}:${n.status}'), [
        'actions:done',
        'output:done',
      ]);
    },
  );

  test('recommendation output creates renderable cards from selected ids', () {
    final result = showActions(state(type: 'recommend'));
    expect(result.ok, isTrue, reason: '${result.error}');
    expect(result.card!.actions, isA<ValidatedActions>());
    expect(result.card!.actions!.items.map((a) => a.id), [
      's-figure4',
      'h-squat',
    ]);
    expect(result.state.task!.nodes.last.status, 'done');
  });

  test(
    'incomplete or malformed internal nodes are deterministically rebuilt',
    () {
      final incomplete = state(complete: false);
      expect(showPlan(incomplete).ok, isTrue);
      expect(incomplete.task!.nodes.last.status, 'current');
      // An unfinished recommendation is a separate task and cannot lend its
      // pool or old active-plan reference to an unrelated output request.
      expect(showPlan(state(type: 'recommend')).error!['code'], 'missing_plan');
      final malformed = state().copyWith(
        task: CoachTaskState(
          type: 'plan',
          reused: false,
          nodes: [const CoachNodeState(id: 'output', status: 'current')],
        ),
      );
      expect(showPlan(malformed).ok, isTrue);
    },
  );
  test('latest current version is bound and checked automatically', () {
    expect(showPlan(state(checked: false)).ok, isTrue);
    expect(showPlan(state(), id: 'old').ok, isTrue);
    expect(showPlan(state(), id: 'old').notices, contains('已使用当前计划的最新版本。'));
    final original = state();
    final v1 = original.plans['p']!.single;
    final v2 = CoachPlanVersion(
      version: 2,
      plan: v1.plan,
      estimateSec: v1.estimateSec,
      fitLog: const [],
    );
    final newer = original.copyWith(
      plans: {
        'p': [v1, v2],
      },
    );
    expect(showPlan(newer).ok, isTrue);
    expect(newer.plans['p']!.first.check!['ok'], isTrue);
  });

  test(
    'seen actions synchronize picks and still enforce current equipment and limits',
    () {
      final base = state(type: 'recommend');
      expect(showActions(base, ids: ['n-windshield']).ok, isTrue);
      final noMat = base.copyWith(
        params: {
          ...base.params,
          'equipment': param(<String>[]),
          'equipment_exclude': param(['equip.mat']),
        },
      );
      expect(showActions(noMat).error!['code'], 'incompatible_actions');
      final knee = base.copyWith(
        params: {
          ...base.params,
          'limits': param(['limit.knee']),
        },
      );
      expect(showActions(knee).error!['code'], 'incompatible_actions');
    },
  );

  test(
    'notes are shortened without numeric or gear parsing; empty is a presentation no-op',
    () {
      final base = state();
      expect(showPlan(base, note: '').ok, isTrue);
      final long = showPlan(base, note: '😀' * 121);
      expect(long.ok, isTrue);
      expect(long.card!.text, '😀' * 120);
      expect(long.noteTruncated, isTrue);
      final threeSentences = showPlan(base, note: '一。二！三？');
      expect(threeSentences.ok, isTrue);
      expect(threeSentences.card!.text, '一。二！');
      expect(threeSentences.noteTruncated, isTrue);
      final result = showPlan(base, note: '20.3 分钟 block 哑铃。');
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(result.card!.text, '20.3 分钟 block 哑铃。');
      final twoSentences = showPlan(base, note: '20.3 分钟。准备开始。');
      expect(twoSentences.ok, isTrue, reason: '${twoSentences.error}');
      expect(twoSentences.card!.text, '20.3 分钟。准备开始。');
    },
  );

  test(
    'changed safety rejects while derived card conditions are synchronized',
    () {
      final base = state();
      final noMat = base.copyWith(
        params: {
          ...base.params,
          'equipment': param(<String>[]),
          'equipment_exclude': param(['equip.mat']),
        },
      );
      expect(showPlan(noMat).error!['code'], 'incompatible_actions');
      final duration = base.copyWith(
        params: {...base.params, 'minutes': param(20)},
      );
      final changed = showPlan(duration);
      expect(changed.ok, isTrue, reason: '${changed.error}');
      expect(changed.card!.plan!.plan.targetMinutes, 20);
      final seconds = const PlanDuration().estimateSeconds(
        changed.card!.plan!.plan,
        catalog,
      );
      expect((seconds - 1200).abs() / 1200, lessThanOrEqualTo(.1));
    },
  );

  for (final minutes in [5, 7, 15, 20]) {
    test(
      'old selected actions are refitted, not relabelled, for $minutes minutes',
      () {
        final old = state();
        final before = const PlanCodec().decode(old.plans['p']!.last.plan);
        final changed = showPlan(
          old.copyWith(params: {...old.params, 'minutes': param(minutes)}),
        );
        expect(
          changed.ok,
          isTrue,
          reason: '${changed.error} ${changed.feasibility}',
        );
        expect(changed.needsUserChoice, isFalse);
        final delivered = changed.card!.plan!.plan;
        final seconds = const PlanDuration().estimateSeconds(
          delivered,
          catalog,
        );
        expect(delivered.targetMinutes, minutes);
        expect(delivered.exerciseIds, before.exerciseIds);
        expect(delivered.items.length, before.items.length);
        expect(
          (seconds - minutes * 60).abs() / (minutes * 60),
          lessThanOrEqualTo(.1),
        );
        expect(changed.state.plans['p']!.last.estimateSec, seconds);
        expect(changed.state.plans['p']!.last.fitLog, isNotEmpty);
        expect(old.plans['p']!.last.plan['targetMinutes'], 10);
      },
    );
  }

  CoachSessionState impossible() {
    final old = state();
    return old.copyWith(
      params: {
        ...old.params,
        'minutes': param(3),
        'dose': param([
          {'field': 'sets', 'value': 1},
          {'field': 'reps', 'value': 8},
          {'field': 'seconds', 'value': 40},
          {'field': 'rounds', 'value': 1},
        ]),
      },
    );
  }

  test('infeasible refit is a normal choice with original card preserved', () {
    final source = impossible();
    final changed = showPlan(source);
    expect(changed.ok, isTrue);
    expect(changed.needsUserChoice, isTrue);
    expect(changed.feasibility!['status'], 'infeasible');
    expect(changed.card, isNull);
    expect(changed.state.plans['p']!.last.plan, source.plans['p']!.last.plan);
    expect(changed.state.params['minutes']!.value, 3);
    expect(
      changed.state.task!.nodes.singleWhere((n) => n.id == 'planning').status,
      'current',
    );
    expect(changed.state.task!.nodes.last.status, 'pending');
  });

  test(
    'stale segmented card is re-timed without flattening or an extra question',
    () {
      final old = state();
      final plan = {
        ...old.plans['p']!.last.plan,
        'equipment': <String>[],
        'blocks': [
          {
            'id': 'b1',
            'name': '分段训练',
            'type': 'main',
            'rounds': 1,
            'restBetweenRoundsSeconds': 0,
            'items': [
              {
                'exerciseId': 'n-windshield',
                'mode': 'reps',
                'sets': 6,
                'reps': 8,
                'perSide': false,
                'restSeconds': 10,
                'segments': [
                  {
                    'id': 'work',
                    'exerciseId': 'h-squat',
                    'mode': 'reps',
                    'reps': 12,
                    'label': '保留动作节奏',
                  },
                ],
              },
            ],
          },
        ],
      };
      final source = old.copyWith(
        params: {
          ...old.params,
          'minutes': param(7),
          'goal': param(['purpose.strength']),
        },
        picks: ['h-squat'],
        seenActionIds: {'h-squat'},
        plans: {
          'p': [
            CoachPlanVersion(
              version: 1,
              plan: plan,
              estimateSec: 625,
              fitLog: const [],
            ),
          ],
        },
      );
      final changed = showPlan(source);
      expect(
        changed.ok,
        isTrue,
        reason: '${changed.error} ${changed.feasibility}',
      );
      expect(changed.needsUserChoice, isFalse);
      final delivered = changed.card!.plan!.plan;
      expect(delivered.targetMinutes, 7);
      expect(delivered.blocks.single.id, 'b1');
      expect(delivered.items.single.exerciseId, 'n-windshield');
      expect(
        delivered.items.single.segments.single.toJson(),
        const PlanCodec().decode(plan).items.single.segments.single.toJson(),
      );
      expect(delivered.equipment, isEmpty);
      final seconds = const PlanDuration().estimateSeconds(delivered, catalog);
      expect((seconds - 420).abs() / 420, lessThanOrEqualTo(.1));
      expect(changed.state.plans['p']!.last.estimateSec, seconds);
    },
  );

  test(
    'agent asks once for infeasible restored refit without rejection or card',
    () async {
      final admitted = showPlan(state()).card!.plan!;
      final client = FakeLlmClient([
        LlmResponse(
          content: '',
          toolCalls: [
            LlmToolCall(
              id: 'show',
              name: CoachTools.showPlan,
              arguments: jsonEncode({'plan_id': 'p', 'note': '已调整。'}),
            ),
          ],
          finishReason: 'tool_calls',
          model: 'fake',
        ),
      ]);
      final agent = CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
      );
      addTearDown(agent.dispose);
      agent.restorePlan(
        admitted,
        planState: CoachPlanState(
          planId: 'p',
          context: const CoachContext(
            scene: 'home',
            equipment: {'mat'},
            minutes: 3,
          ),
          sessionState: impossible(),
        ),
      );
      final result = await agent.send('按已确认条件调整');
      expect(
        result.status,
        TurnStatus.ok,
        reason: '${result.error} ${result.issues}',
      );
      expect(result.question, isNotNull);
      expect(result.plan, isNull);
      expect(result.issues, isEmpty);
      expect(client.requests, hasLength(1));
    },
  );
}
