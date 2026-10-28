import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/output_gate.dart';
import 'package:ugk_coach/src/agent/session_params.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('hiplab');
  final gates = NodeGates(profile, catalog, minPicks: profile.minActions);
  const context = CoachContext(scene: 'home', equipment: {'mat'}, minutes: 10);

  final plan = TrainingPlan(
    id: 'saved-plan',
    source: 'ai',
    title: '髋部放松',
    summary: '放松髋部',
    goal: 'relax',
    scene: 'home',
    equipment: const ['mat'],
    level: 1,
    targetMinutes: 10,
    blocks: const [
      PlanBlock(
        id: 'main',
        name: '训练',
        type: BlockType.main,
        items: [
          PlanItem(
            exerciseId: 's-figure4',
            mode: DoseMode.time,
            sets: 1,
            workSeconds: 40,
            perSide: true,
            restSeconds: 10,
          ),
        ],
      ),
    ],
  );

  CoachAgent coach(UsageSink usage) {
    final admitted = ToolGate(
      catalog: catalog,
      profile: profile,
    ).admitTemplate(plan, context);
    expect(admitted, isNotNull);
    var state = CoachSessionState(
      userTurns: [const CoachUserTurn(turn: 1, text: '推荐臀部动作')],
      params: {
        'goal': CoachParamValue(
          value: ['body.glute_max'],
          source: 'user',
          quote: '臀部',
          turn: 1,
        ),
      },
    );
    state = SessionParams(gates.tags).applyHost(state, context).state;
    state = AgentTask.start(state, 'recommend').state;
    state = gates.check(state, 'understand').state;
    final parameters = gates.check(state, 'parameters');
    expect(parameters.ok, isTrue, reason: '${parameters.error}');
    state = parameters.state;
    expect(gates.actionProblem(state, 'h-squat'), isNull);
    final picks = [
      'h-squat',
      ...profile
          .scope(catalog)
          .where(
            (d) =>
                d.id != 'h-squat' && gates.actionProblem(state, d.id) == null,
          )
          .take(profile.minActions - 1)
          .map((d) => d.id),
    ];
    state = state.copyWith(seenActionIds: picks.toSet());
    final checked = gates.check(state, 'actions', picks: picks);
    expect(checked.ok, isTrue, reason: '${checked.error}');
    expect(checked.state.task!.nodes.last.status, 'current');

    final call = LlmToolCall(
      id: 'show',
      name: AgentTools.showActions,
      arguments: jsonEncode({'ids': picks, 'note': '可以从这个动作开始。'}),
    );
    final output = OutputGate(profile, catalog).prepare(
      checked.state,
      AgentTools.showActions,
      jsonDecode(call.arguments),
    );
    expect(output.ok, isTrue, reason: '${output.error}');
    expect(output.actions!.map((action) => action.id), picks);
    final client = FakeLlmClient([
      LlmResponse(
        content: '可以从这个动作开始。',
        toolCalls: [call],
        finishReason: 'tool_calls',
      ),
    ], latency: Duration.zero);
    final agent = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      usage: usage,
      enableUserMemory: false,
      maxRequestRetries: 0,
    );
    agent.restorePlan(
      admitted!,
      planState: CoachPlanState(
        planId: plan.id,
        context: context,
        sessionState: checked.state,
      ),
    );
    addTearDown(agent.dispose);
    return agent;
  }

  test('unchanged host conditions permit the admitted action card', () async {
    final agent = coach(MemoryUsageSink());
    final result = await agent.send('继续推荐');
    expect(
      result.status,
      TurnStatus.ok,
      reason: '${result.error}; ${result.issues}',
    );
    expect(result.actions!.items, hasLength(3));
    expect(result.actions!.items.map((item) => item.id), contains('h-squat'));
  });

  test(
    'host safety update at final usage await invalidates the old card',
    () async {
      final entered = Completer<UsageRecord>();
      final release = Completer<void>();
      final sink = CallbackUsageSink((record) {
        if (!entered.isCompleted) entered.complete(record);
        return release.future;
      });
      final agent = coach(sink);
      final pending = agent.send('继续推荐');
      final recorded = await entered.future;
      expect(
        recorded.outcome,
        CallOutcome.passed,
        reason: 'the old action card has already passed the gate',
      );
      expect(recorded.turnOutcome, TurnOutcome.model);
      agent.replaceSafetyAvoid({'膝'});
      expect(
        agent.sessionState.params['limits']!.value,
        contains('limit.knee'),
      );
      release.complete();
      final result = await pending;
      expect(result.actions, isNull);
      expect(result.plan, isNull);
      expect(result.status, isNot(TurnStatus.ok));
      expect(
        agent.sessionState.params['limits']!.value,
        contains('limit.knee'),
      );
      expect(agent.sessionState.task!.nodes[1].status, 'updated');
      expect(agent.sessionState.task!.nodes[2].status, 'current');
      expect(agent.sessionState.picks, isNot(contains('h-squat')));
    },
  );
}
