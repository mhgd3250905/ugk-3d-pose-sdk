import 'dart:async';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/session_params.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  final catalog = loadCatalog();
  final profile = loadProfile('hiplab');
  final gates = NodeGates(profile, catalog, minPicks: profile.minActions);
  final initialContext = const CoachContext(
    scene: 'home',
    equipment: {'mat'},
    minutes: 10,
    avoid: {},
  );

  ValidatedPlan admittedPlan() {
    final plan = TrainingPlan(
      id: 'plan-host',
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
    final admitted = ToolGate(
      catalog: catalog,
      profile: profile,
    ).admitTemplate(plan, initialContext);
    expect(admitted, isNotNull);
    return admitted!;
  }

  CoachSessionState savedState(ValidatedPlan admitted) {
    var state = CoachSessionState(
      userTurns: [const CoachUserTurn(turn: 1, text: '在家做大腿内侧训练')],
      params: {
        'goal': CoachParamValue(
          value: ['body.inner_thigh'],
          source: 'user',
          quote: '大腿内侧',
          turn: 1,
        ),
      },
    );
    state = SessionParams(gates.tags).applyHost(state, initialContext).state;
    state = AgentTask.start(state, 'plan').state;
    state = gates.check(state, 'understand').state;
    final params = gates.check(state, 'parameters');
    expect(params.ok, isTrue, reason: '${params.error}');
    state = params.state;
    final matching = profile
        .scope(catalog)
        .where((drill) => gates.actionProblem(state, drill.id) == null)
        .toList();
    final mat = matching.firstWhere((drill) => drill.equipment.contains('mat'));
    final bodyweight = matching
        .where(
          (drill) =>
              drill.equipment.isEmpty ||
              drill.equipment.every((id) => id == 'none'),
        )
        .take(2)
        .toList();
    expect(bodyweight, hasLength(2));
    final ids = [mat.id, ...bodyweight.map((drill) => drill.id)];
    state = state.copyWith(seenActionIds: ids.toSet());
    final actions = gates.check(state, 'actions', picks: ids);
    expect(actions.ok, isTrue, reason: '${actions.error}');
    state = actions.state.copyWith(
      plans: {
        admitted.plan.id: [
          CoachPlanVersion(
            version: 1,
            plan: admitted.plan.toJson(),
            estimateSec: 600,
            fitLog: const [],
            check: {'ok': true},
          ),
        ],
      },
    );
    state = gates.check(state, 'planning', planId: admitted.plan.id).state;
    state = gates.check(state, 'review', planId: admitted.plan.id).state;
    return state;
  }

  CoachAgent restored(
    FakeLlmClient client,
    CoachSessionState state,
    ValidatedPlan admitted,
  ) {
    final coach = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      enableUserMemory: false,
      maxRequestRetries: 0,
    );
    coach.restorePlan(
      admitted,
      planState: CoachPlanState(
        planId: admitted.plan.id,
        context: initialContext,
        sessionState: state,
      ),
    );
    addTearDown(coach.dispose);
    return coach;
  }

  test(
    'host context update resets nodes and filters picks before the model',
    () async {
      final admitted = admittedPlan();
      final initial = savedState(admitted);
      final client = FakeLlmClient(['已收到。'], latency: Duration.zero);
      final coach = restored(client, initial, admitted);
      final events = <AgentEvent>[];
      final sub = coach.events.listen(events.add);
      addTearDown(sub.cancel);
      await coach.send('继续', context: const CoachContext(equipment: {}));
      final state = coach.sessionState;
      expect(state.params['equipment']!.value, isEmpty);
      expect(state.task!.nodes[1].status, 'updated');
      expect(state.task!.nodes[1].stamp, contains('徒手（App 设置）'));
      expect(state.task!.nodes.skip(2).map((n) => n.status), [
        'current',
        'pending',
        'pending',
        'pending',
      ]);
      expect(state.picks, hasLength(2));
      expect(state.picks, isNot(contains(initial.picks.first)));
      expect(state.plans[admitted.plan.id]!.last.check, isNull);
      final nodeEvents = events
          .where((e) => e.kind == AgentEventKind.node)
          .toList();
      expect(nodeEvents.map((e) => e.node!.id), [
        'parameters',
        'actions',
        'planning',
        'review',
        'output',
      ]);
      expect(nodeEvents.every((e) => identical(e.task, state.task)), isTrue);
    },
  );

  test(
    'host safety replacement updates nodes and does not repeat unchanged updates',
    () {
      final admitted = admittedPlan();
      final coach = restored(FakeLlmClient([]), savedState(admitted), admitted);
      final events = <AgentEvent>[];
      final sub = coach.events.listen(events.add);
      addTearDown(sub.cancel);
      coach.replaceSafetyAvoid({'膝'});
      expect(
        coach.sessionState.params['limits']!.value,
        contains('limit.knee'),
      );
      expect(coach.sessionState.task!.nodes[1].stamp, contains('膝（App 设置）'));
      expect(coach.sessionState.task!.nodes[2].status, 'current');
      expect(events.where((e) => e.kind == AgentEventKind.node), isNotEmpty);
      events.clear();
      coach.replaceSafetyAvoid({'膝'});
      expect(events.where((e) => e.kind == AgentEventKind.node), isEmpty);
    },
  );

  test(
    'cancelled turn retains host node reset and latest safety change',
    () async {
      final admitted = admittedPlan();
      final initial = savedState(admitted);
      final response = Completer<Object>();
      final entered = Completer<void>();
      final coach = restored(
        FakeLlmClient([
          (LlmRequest _) {
            entered.complete();
            return response.future;
          },
        ], latency: Duration.zero),
        initial,
        admitted,
      );
      final token = CancelToken();
      final events = <AgentEvent>[];
      final sub = coach.events.listen(events.add);
      addTearDown(sub.cancel);
      final pending = coach.send(
        '取消这一轮',
        context: const CoachContext(equipment: {}),
        cancel: token,
      );
      await entered.future;
      coach.replaceSafetyAvoid({'膝'});
      token.cancel();
      expect((await pending).status, TurnStatus.cancelled);
      expect(coach.sessionState.userTurns.map((t) => t.text), ['在家做大腿内侧训练']);
      expect(coach.sessionState.params['equipment']!.value, isEmpty);
      expect(
        coach.sessionState.params['limits']!.value,
        contains('limit.knee'),
      );
      expect(coach.sessionState.task!.nodes[1].status, 'updated');
      expect(coach.sessionState.task!.nodes[2].status, 'current');
      expect(coach.sessionState.task!.nodes[1].doneAtTurn, 1);
      final lastNodeEvent = events.lastWhere(
        (e) => e.kind == AgentEventKind.node,
      );
      expect(lastNodeEvent.task!.nodes[1].doneAtTurn, 1);
      response.complete('迟到内容');
      await Future<void>.delayed(Duration.zero);
      expect(coach.sessionState.task!.nodes[2].status, 'current');
    },
  );
}
