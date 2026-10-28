import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_search.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/plan_checker.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$pack/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$pack/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();
  final profile = loadProfile('smartfit');
  CoachParamValue param(Object value) =>
      CoachParamValue(value: value, source: 'user', turn: 1);
  PlanItem item(String id) {
    final dose = catalog[id]!.defaultDose;
    return PlanItem(
      exerciseId: id,
      mode: dose.mode,
      sets: 1,
      reps: dose.reps,
      workSeconds: dose.seconds,
      perSide: catalog[id]!.unilateral,
      restSeconds: dose.restSeconds,
    );
  }

  CoachSessionState state(
    List<String> ids, {
    List<String> goals = const ['body.deltoids', 'purpose.strength'],
    List<String> warmup = const [],
  }) {
    final plan = TrainingPlan(
      id: 'p',
      source: 'ai',
      title: 'Shoulders',
      summary: 'Shoulders',
      goal: goals.contains('body.core') ? 'core' : 'strength',
      scene: 'home',
      level: 1,
      targetMinutes: 15,
      equipment: const ['dumbbell'],
      blocks: [
        if (warmup.isNotEmpty)
          PlanBlock(
            id: 'b0',
            name: 'warmup',
            type: BlockType.warmup,
            items: [for (final id in warmup) item(id)],
          ),
        PlanBlock(
          id: 'b1',
          name: 'main',
          type: BlockType.main,
          items: [for (final id in ids) item(id)],
        ),
      ],
    );
    return CoachSessionState(
      task: CoachTaskState(
        type: 'plan',
        reused: false,
        nodes: [
          for (final id in [
            'understand',
            'parameters',
            'actions',
            'planning',
            'review',
            'output',
          ])
            CoachNodeState(
              id: id,
              status: id == 'review'
                  ? 'current'
                  : id == 'output'
                  ? 'pending'
                  : 'done',
            ),
        ],
      ),
      params: {
        'scene': param('home'),
        'minutes': param(15),
        'goal': param(goals),
        'equipment': param(['equip.dumbbell']),
        'limits': param(<String>[]),
      },
      seenActionIds: {...ids, ...warmup},
      activePlanId: 'p',
      plans: {
        'p': [
          CoachPlanVersion(
            version: 1,
            plan: plan.toJson(),
            estimateSec: 0,
            fitLog: const [],
          ),
        ],
      },
    );
  }

  PlanCheckResult check(
    CoachSessionState s, {
    List<PlanRule> extra = const [],
  }) => PlanChecker(
    profile,
    catalog,
    minPicks: 3,
    extraRules: extra,
  ).check(s, 'p');

  test(
    'four shoulder actions pass once unchanged and balance does not apply to single-body goals',
    () {
      const ids = [
        'h-db-press',
        'h-db-lateral',
        'h-db-front-raise',
        'h-db-reverse-fly',
      ];
      final result = check(state(ids, warmup: ['h-wall-angel']));
      expect(result.ok, isTrue, reason: '${result.toJson()}');
      expect(result.rules.containsKey('duration'), isFalse);
      final balance = result.rules['balance'] as Map;
      expect(balance['applicable'], isFalse);
      expect(
        result.warningDetails.any(
          (w) => w['code'].toString().startsWith('plan_balance'),
        ),
        isFalse,
      );
      final plan = const PlanCodec().decode(result.state.plans['p']!.last.plan);
      expect(
        plan.blocks
            .where((b) => b.type == BlockType.main)
            .single
            .items
            .map((i) => i.exerciseId),
        ids,
      );
    },
  );

  test(
    'dead bug preparation warns once across repeated checks and restored sessions',
    () {
      final first = check(
        state(['h-crunch'], goals: ['body.core'], warmup: ['w-dead-bug']),
      );
      expect(first.ok, isTrue, reason: '${first.toJson()}');
      expect(
        first.warningDetails.where((w) => w['code'] == 'plan_block_purpose'),
        hasLength(1),
      );
      final restored = CoachSessionState.fromJson(
        jsonDecode(jsonEncode(first.state.toJson())) as Map<String, Object?>,
      );
      final again = check(restored);
      expect(again.ok, isTrue);
      expect(again.warningDetails, isEmpty);
      expect(again.state.plans['p']!.last.check!['warningDetails'], isNotEmpty);
    },
  );

  test(
    'multi-body balance and missing stages are advisories, not hard errors',
    () {
      final result = check(
        state(
          [
            'h-db-press',
            'h-db-lateral',
            'h-db-front-raise',
            'h-db-reverse-fly',
          ],
          goals: ['body.deltoids', 'body.chest', 'purpose.strength'],
        ),
      );
      expect(result.ok, isTrue, reason: '${result.toJson()}');
      expect(
        result.warningDetails.map((w) => w['code']),
        containsAll(['plan_structure', 'plan_balance_sequence']),
      );
      expect(result.errors, isEmpty);
    },
  );

  test(
    'single inner-thigh recommendation delivers and only duplicate IDs are normalized',
    () {
      final initial = state(['s-butterfly'], goals: ['body.inner_thigh']);
      final ready = AgentTask.start(
        initial,
        'recommend',
      ).state.copyWith(seenActionIds: {'s-butterfly'});
      final result = ToolGate(profile: profile, catalog: catalog)
          .checkAgentOutput(ready, CoachTools.showActions, {
            'ids': ['s-butterfly', 's-butterfly'],
            'note': '',
          });
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(result.card!.actions!.items.map((i) => i.id), ['s-butterfly']);
      expect(result.notices, contains('已合并重复的推荐动作ID。'));
      expect(result.state.task!.nodes.last.status, 'done');
    },
  );

  test(
    'no compatible candidates ends normally, while unsafe or unseen selections still fail',
    () {
      final initial = state([], goals: ['body.inner_thigh']);
      final ready = AgentTask.start(initial, 'recommend').state;
      final gate = ToolGate(profile: profile, catalog: catalog);
      final unavailable = gate.checkAgentOutput(ready, CoachTools.showActions, {
        'ids': [],
      });
      expect(unavailable.ok, isTrue);
      expect(unavailable.unavailable, isTrue);
      expect(unavailable.card, isNull);
      expect(unavailable.state.task, isNull);
      final unseen = gate.checkAgentOutput(ready, CoachTools.showActions, {
        'ids': ['s-butterfly'],
      });
      expect(unseen.ok, isFalse);
      expect(unseen.error!['code'], 'unseen_actions');
    },
  );

  test('host extraRules remain hard and are not reclassified as advisory', () {
    final result = check(
      state(['h-db-press']),
      extra: [
        (_, _, _) => const [PlanIssue('host-rule', 'Host restriction')],
      ],
    );
    expect(result.ok, isFalse);
    expect(result.errors.map((e) => e['code']), contains('host-rule'));
  });

  test(
    'missing pending-search and user-turn markers cannot authorize an old pool',
    () {
      final unowned = CoachSessionState(
        seenActionIds: {'s-butterfly'},
        picks: ['s-butterfly'],
      );
      final started = AgentTask.start(unowned, 'recommend');
      expect(started.state.seenActionIds, isEmpty);
      expect(started.state.picks, isEmpty);
      expect(started.state.pendingSearchTurn, isNull);
    },
  );

  test(
    'only a real current user-turn search can carry candidates into a fresh task',
    () {
      final searched = CoachSessionState(
        userTurns: const [CoachUserTurn(turn: 2, text: '练大腿内侧')],
        seenActionIds: {'s-butterfly'},
        picks: ['s-butterfly'],
        pendingSearchTurn: 2,
      );
      final started = AgentTask.start(searched, 'recommend');
      expect(started.state.seenActionIds, {'s-butterfly'});
      expect(started.state.picks, isEmpty);
      expect(started.state.task!.reused, isFalse);
      expect(started.state.pendingSearchTurn, isNull);
      final stale = AgentTask.start(
        searched.copyWith(pendingSearchTurn: 1),
        'recommend',
      );
      expect(stale.state.seenActionIds, isEmpty);
    },
  );

  test(
    'actual same-turn search before start remains deliverable after task initialization',
    () {
      final beforeSearch = state([], goals: ['body.inner_thigh']).copyWith(
        clearTask: true,
        userTurns: const [CoachUserTurn(turn: 3, text: '想拉伸大腿内侧')],
        seenActionIds: {'h-db-press'},
      );
      final searched = ActionSearch(
        profile,
        catalog,
        minPicks: 3,
      ).search(beforeSearch, tags: ['body.inner_thigh'], keywords: '蝴蝶');
      expect(searched.ok, isTrue);
      expect(searched.state.seenActionIds, contains('s-butterfly'));
      expect(searched.state.seenActionIds, isNot(contains('h-db-press')));
      final started = AgentTask.start(searched.state, 'recommend');
      expect(started.state.seenActionIds, searched.state.seenActionIds);
      final shown = ToolGate(profile: profile, catalog: catalog)
          .checkAgentOutput(started.state, CoachTools.showActions, {
            'ids': ['s-butterfly'],
          });
      expect(shown.ok, isTrue, reason: '${shown.error}');
      expect(shown.card!.actions!.items.single.id, 's-butterfly');
    },
  );

  test(
    'changing output task type cannot revive a previous task candidate pool',
    () {
      final previous = state(['s-butterfly'], goals: ['body.inner_thigh']);
      final result = ToolGate(profile: profile, catalog: catalog)
          .checkAgentOutput(previous, CoachTools.showActions, {
            'ids': ['s-butterfly'],
          });
      expect(result.ok, isFalse);
      expect(result.error!['code'], 'unseen_actions');
      expect(previous.task!.type, 'plan');
      expect(previous.seenActionIds, {'s-butterfly'});
    },
  );

  test(
    'same-task graph repair preserves sources without authorizing unrelated tasks',
    () {
      final malformed = state(['s-butterfly'], goals: ['body.inner_thigh'])
          .copyWith(
            task: CoachTaskState(
              type: 'recommend',
              reused: false,
              nodes: const [CoachNodeState(id: 'output', status: 'current')],
            ),
          );
      final result = ToolGate(profile: profile, catalog: catalog)
          .checkAgentOutput(malformed, CoachTools.showActions, {
            'ids': ['s-butterfly'],
          });
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(result.state.seenActionIds, {'s-butterfly'});
      expect(result.card!.actions!.items.single.id, 's-butterfly');
      expect(result.state.task!.nodes.last.status, 'done');
    },
  );

  test(
    'completed recommendation promotion uses genuine reuse but no historical plan reference',
    () {
      final initial = state(['s-butterfly'], goals: ['body.inner_thigh']);
      final recommendation = AgentTask.start(
        initial,
        'recommend',
      ).state.copyWith(seenActionIds: {'s-butterfly'});
      final shown = ToolGate(profile: profile, catalog: catalog)
          .checkAgentOutput(recommendation, CoachTools.showActions, {
            'ids': ['s-butterfly'],
          });
      expect(shown.ok, isTrue);
      final promoted = AgentTask.start(shown.state, 'plan');
      expect(promoted.state.task!.reused, isTrue);
      expect(promoted.state.seenActionIds, {'s-butterfly'});
      expect(promoted.state.picks, ['s-butterfly']);
      expect(promoted.state.activePlanId, isNull);
    },
  );
}
