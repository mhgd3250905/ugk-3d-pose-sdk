import 'dart:convert';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/ugk_coach.dart';

const _profile = CoachProfile(
  id: 'duration-delivery',
  appName: 'duration-delivery',
  minActions: 1,
  limits: PlanLimits(
    sets: IntRange(1, 3),
    rounds: IntRange(1, 2),
    restBetweenRoundsSeconds: IntRange(0, 0),
    minutes: IntRange(1, 60),
  ),
);

final _catalog = Catalog(
  version: 'duration-delivery',
  drills: [
    Drill(
      id: 'a',
      name: const LocalizedText({'zh': '动作 A'}),
      category: 'core',
      muscleGroups: const ['abs'],
      position: 'standing',
      unilateral: false,
      level: 1,
      scenes: const ['home'],
      defaultDose: const Dose(
        mode: DoseMode.time,
        sets: 1,
        seconds: 100,
        restSeconds: 0,
      ),
      doseRange: const DoseRange(
        sets: IntRange(1, 3),
        seconds: IntRange(100, 100),
        restSeconds: IntRange(0, 10),
      ),
    ),
  ],
);

CoachParamValue _param(Object value) => CoachParamValue(
  value: value,
  source: 'user',
  quote: '每个动作一组，练三分钟',
  turn: 1,
);

CoachSessionState _saved({
  int minutes = 5,
  int sets = 1,
  int rounds = 1,
  int restSeconds = 0,
  num? cachedSeconds,
  bool focus = false,
  bool lockSets = false,
}) {
  final id = focus ? 'ext:my-plan' : 'p';
  final plan = TrainingPlan(
    id: id,
    source: 'ai',
    title: '恢复的计划',
    summary: '恢复的计划',
    goal: 'core',
    scene: 'home',
    equipment: const [],
    level: 1,
    targetMinutes: minutes,
    blocks: [
      PlanBlock(
        id: 'b1',
        name: 'main',
        type: BlockType.main,
        rounds: rounds,
        restBetweenRoundsSeconds: 0,
        items: [
          PlanItem(
            exerciseId: 'a',
            mode: DoseMode.time,
            sets: sets,
            workSeconds: 100,
            perSide: false,
            restSeconds: restSeconds,
          ),
        ],
      ),
    ],
  );
  return CoachSessionState(
    userTurns: const [CoachUserTurn(turn: 1, text: '每个动作一组，练三分钟')],
    task: CoachTaskState(
      type: 'plan',
      reused: true,
      nodes: [
        for (final node in AgentTask.planNodes)
          CoachNodeState(
            id: node,
            status: node == 'output' ? 'current' : 'done',
          ),
      ],
    ),
    params: {
      'scene': _param('home'),
      'minutes': _param(minutes),
      'goal': _param(['body.abs']),
      'equipment': _param(<String>[]),
      'limits': _param(<String>[]),
      if (lockSets)
        'dose': _param([
          {'field': 'sets', 'value': 1},
        ]),
    },
    seenActionIds: const {'a'},
    picks: const ['a'],
    recommendationHintShown: true,
    activePlanId: id,
    focusPlanId: focus ? id : null,
    savedRef: focus
        ? const CoachSavedPlanRef(externalId: 'my-plan', baseVersion: 1)
        : null,
    lastDeliveredPlanId: id,
    lastDeliveredVersion: 1,
    lastDeliveredTurn: 1,
    plans: {
      id: [
        CoachPlanVersion(
          version: 1,
          plan: plan.toJson(),
          estimateSec:
              cachedSeconds ??
              const PlanDuration().estimateSeconds(plan, _catalog),
          fitLog: const [],
          check: const {'ok': true},
        ),
      ],
    },
  );
}

AgentOutputResult _show(CoachSessionState state) =>
    ToolGate(catalog: _catalog, profile: _profile).checkAgentOutput(
      state,
      CoachTools.showPlan,
      {'plan_id': state.activePlanId, 'note': '计划已准备好。'},
    );

void main() {
  for (final restore in [false, true]) {
    test(
      'same-target approximate saved card is refitted (restore=$restore)',
      () {
        final original = _saved(cachedSeconds: 300);
        final source = restore
            ? CoachSessionState.fromJson(
                (jsonDecode(jsonEncode(original.toJson())) as Map)
                    .cast<String, Object?>(),
              )
            : original;
        final result = _show(source);
        expect(result.ok, isTrue, reason: '${result.error}');
        expect(result.needsUserChoice, isFalse);
        final delivered = result.card!.plan!.plan;
        final seconds = const PlanDuration().estimateSeconds(
          delivered,
          _catalog,
        );
        expect(seconds, inInclusiveRange(270, 330));
        expect(result.state.plans['p']!.map((version) => version.version), [
          1,
          2,
        ]);
        expect(
          source.plans['p']!.single.plan,
          original.plans['p']!.single.plan,
        );
        expect(result.state.task!.nodes.last.status, 'done');
      },
    );
  }

  test(
    'focused same-target edit fits before appending its only new version',
    () {
      final saved = _saved(focus: true, cachedSeconds: 300);
      final source = saved.copyWith(
        task: saved.task!.copyWith(
          nodes: [
            for (final node in saved.task!.nodes) node.copyWith(status: 'done'),
          ],
        ),
      );
      final original = source.toJson();
      // The imported card claims five minutes but actually lasts only 110s.
      // Keeping the same action and changing its title still needs one fit,
      // rather than committing a bad v2 and repairing it with v3 on show_plan.
      final drafted = PlanBuilder(_profile, _catalog, minPicks: 1).draft(
        source,
        {
          'title': '重新整理的计划',
          'blocks': [
            {
              'kind': 'main',
              'items': [
                {'id': 'a'},
              ],
            },
          ],
        },
        newPlanId: 'must-not-replace-focused-id',
      );
      expect(drafted.ok, isTrue, reason: '${drafted.error}');
      expect(drafted.feasibility, isNull);
      expect(drafted.planId, 'ext:my-plan');
      expect(drafted.version, 2);
      expect(
        drafted.state.plans['ext:my-plan']!.map((version) => version.version),
        [1, 2],
      );
      final fitted = drafted.state.plans['ext:my-plan']!.last;
      expect(fitted.estimateSec, inInclusiveRange(270, 330));
      expect(fitted.fitLog, isNotEmpty);
      expect(source.toJson(), original);
      expect(drafted.state.focusPlanId, 'ext:my-plan');
      expect(drafted.state.savedRef, source.savedRef);

      final output = _show(drafted.state);
      expect(output.ok, isTrue, reason: '${output.error}');
      expect(output.card!.plan!.version, 2);
      expect(output.card!.plan!.savedRef, source.savedRef);
      expect(
        output.state.plans['ext:my-plan']!.map((version) => version.version),
        [1, 2],
      );
      expect(
        output.state.plans['ext:my-plan']!.last.estimateSec,
        fitted.estimateSec,
      );
    },
  );

  test('compliant card keeps its version despite a stale cached estimate', () {
    final source = _saved(sets: 3, cachedSeconds: 10);
    final result = _show(source);
    expect(result.ok, isTrue, reason: '${result.error}');
    expect(result.state.plans['p']!.single.version, 1);
    expect(result.card!.plan!.plan.items.single.sets, 3);
    expect(
      const PlanDuration().estimateSeconds(result.card!.plan!.plan, _catalog),
      310,
    );
  });

  test('exact +10 percent boundary remains deliverable without refitting', () {
    final source = _saved(sets: 3, restSeconds: 10);
    final result = _show(source);
    expect(result.ok, isTrue, reason: '${result.error}');
    expect(result.state.plans['p']!.single.version, 1);
    expect(
      const PlanDuration().estimateSeconds(result.card!.plan!.plan, _catalog),
      330,
    );
  });

  for (final focus in [false, true]) {
    test('integer gap blocks restored approximate delivery (focus=$focus)', () {
      // Sets are fixed at one. The legal 110/225-second endpoints straddle
      // 180 seconds, but neither lies inside 162..198 seconds. An old check
      // and cached in-range estimate cannot make this a valid final card.
      final source = _saved(
        minutes: 3,
        rounds: 2,
        cachedSeconds: 180,
        lockSets: true,
        focus: focus,
      );
      final before = source.toJson();
      final result = _show(source);
      expect(result.ok, isFalse);
      expect(result.error!['code'], 'duration_fit_failed');
      expect(result.card, isNull);
      expect(result.state.toJson(), before);
      expect(result.changes, isEmpty);
      expect(result.state.lastDeliveredVersion, 1);
      expect(result.state.task!.nodes.last.status, 'current');
      expect(result.state.plans[source.activePlanId]!.length, 1);
      if (focus) {
        expect(result.state.focusPlanId, 'ext:my-plan');
        expect(
          result.state.savedRef,
          const CoachSavedPlanRef(externalId: 'my-plan', baseVersion: 1),
        );
      }
    });
  }

  test(
    'unconfirmed action outside bounds requires rebuilding without a new version',
    () {
      final source = _saved(minutes: 1, lockSets: true);
      final before = source.toJson();
      final result = _show(source);
      expect(result.ok, isFalse);
      expect(result.needsUserChoice, isFalse);
      expect(result.feasibility, isNull);
      expect(result.error!['code'], 'duration_fit_failed');
      expect(result.error!['minEstimatedSec'], 110);
      expect(result.error!['maxEstimatedSec'], 225);
      expect(result.error!['direction'], 'remove_action');
      expect(result.error!['userConfirmedDose'], isTrue);
      expect(result.error!['confirmedActionIds'], isEmpty);
      expect(result.error!['clarificationAllowed'], isFalse);
      expect(result.error!['needsDraftRebuild'], isTrue);
      expect(result.card, isNull);
      expect(result.state.toJson(), before);
      expect(result.changes, isEmpty);
      expect(result.state.plans['p']!.single.version, 1);
      expect(
        result.state.plans['p']!.single.plan,
        source.plans['p']!.single.plan,
      );
      expect(result.state.lastDeliveredVersion, 1);
      expect(result.state.task!.nodes.last.status, 'current');
    },
  );
}
