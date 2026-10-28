import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/session_state.dart';
import 'package:ugk_coach/src/tools/coach_tools.dart';
import 'package:ugk_coach/src/tools/tool_gate.dart';

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
      },
      picks: ['s-figure4', 'h-squat'],
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
      expect(result.changes.map((n) => '${n.id}:${n.status}'), ['output:done']);
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
    'incomplete, missing or incorrect task nodes are rejected atomically',
    () {
      final incomplete = state(complete: false);
      expect(showPlan(incomplete).error!['code'], 'nodes_incomplete');
      expect(incomplete.task!.nodes.last.status, 'current');
      expect(
        showPlan(state(type: 'recommend')).error!['code'],
        'wrong_task_type',
      );
      final malformed = state().copyWith(
        task: CoachTaskState(
          type: 'plan',
          reused: false,
          nodes: [const CoachNodeState(id: 'output', status: 'current')],
        ),
      );
      expect(showPlan(malformed).error!['code'], 'invalid_task_nodes');
    },
  );

  test('only latest current plan with passing check can be shown', () {
    expect(showPlan(state(checked: false)).error!['code'], 'plan_not_checked');
    expect(showPlan(state(), id: 'old').error!['code'], 'invalid_plan_id');
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
    expect(showPlan(newer).error!['code'], 'plan_not_checked');
    expect(newer.plans['p']!.first.check!['ok'], isTrue);
  });

  test(
    'actions must be picks and remain safe under current equipment and limits',
    () {
      final base = state(type: 'recommend');
      expect(
        showActions(base, ids: ['n-windshield']).error!['code'],
        'unpicked_actions',
      );
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
    'note length and sentence punctuation are checked without numeric or gear parsing',
    () {
      final base = state();
      expect(showPlan(base, note: '').error!['code'], 'invalid_note');
      expect(showPlan(base, note: '😀' * 121).error!['code'], 'invalid_note');
      expect(showPlan(base, note: '一。二！三？').error!['code'], 'invalid_note');
      final result = showPlan(base, note: '20.3 分钟 block 哑铃。');
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(result.card!.text, '20.3 分钟 block 哑铃。');
      final twoSentences = showPlan(base, note: '20.3 分钟。准备开始。');
      expect(twoSentences.ok, isTrue, reason: '${twoSentences.error}');
      expect(twoSentences.card!.text, '20.3 分钟。准备开始。');
    },
  );

  test(
    'plan card is rejected if current safety or stored card conditions changed',
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
      expect(showPlan(duration).error!['code'], 'card_conditions_changed');
    },
  );
}
