import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/src/agent/session_state.dart';
import 'package:ugk_coach/src/catalog/catalog.dart';
import 'package:ugk_coach/src/catalog/pose_hub_app_test_pack.dart';
import 'package:ugk_coach/src/profile/coach_profile.dart';

import 'support.dart';

void main() {
  const pack = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final manifest =
      jsonDecode(File('$pack/catalog.json').readAsStringSync())
          as Map<String, Object?>;
  final canonical =
      jsonDecode(File('$pack/catalog/catalog.json').readAsStringSync())
          as Map<String, Object?>;
  final catalog = PoseHubAppTestCatalog.fromJson(
    manifest,
    semanticCatalog: canonical,
  ).toAiCatalog();
  final profile = loadProfile('smartfit');
  final builder = PlanBuilder(profile, catalog, minPicks: 3);
  const warmup = ['h-step-jack', 'forearms-A', 'n-pelvis-circle'];
  const main = [
    'erectors-A',
    'rotator-cuff-A',
    'deltoids-A',
    'h-kneeling-pushup',
    'h-good-morning',
  ];
  const cooldown = ['o-stand-sidebend', 'h-bilateral-upper-back-hug'];
  final r3 = [...warmup, ...main, ...cooldown];
  CoachParamValue param(Object value) =>
      CoachParamValue(value: value, source: 'user', turn: 1);
  CoachSessionState state({
    int minutes = 20,
    List<String>? picks,
    Set<String>? seen,
  }) {
    var current = CoachSessionState(
      userTurns: [const CoachUserTurn(turn: 1, text: '居家徒手核心')],
      params: {
        'scene': param('home'),
        'goal': param(['body.core']),
        'minutes': param(minutes),
        'equipment': param(<String>[]),
        'level': param(1),
        'limits': param(<String>[]),
      },
      seenActionIds: r3.toSet(),
    );
    final gate = NodeGates(profile, catalog, minPicks: 3);
    current = AgentTask.start(
      current,
      'plan',
    ).state.copyWith(seenActionIds: r3.toSet());
    current = gate.check(current, 'understand').state;
    current = gate.check(current, 'parameters').state;
    final checked = gate.check(current, 'actions', picks: picks ?? r3);
    expect(checked.ok, isTrue, reason: '${checked.error}');
    return seen == null
        ? checked.state
        : checked.state.copyWith(seenActionIds: seen);
  }

  Map<String, Object?> r3Draft() => {
    'title': '居家核心',
    'blocks': [
      {
        'kind': 'warmup',
        'items': [
          for (final id in warmup) <String, Object?>{'id': id},
        ],
      },
      {
        'kind': 'main',
        'rounds': 2,
        'items': [
          for (final id in main) <String, Object?>{'id': id},
        ],
      },
      {
        'kind': 'cooldown',
        'items': [
          for (final id in cooldown) <String, Object?>{'id': id},
        ],
      },
    ],
  };

  test(
    'R3 action structure automatically fits 20 minutes and persists the card',
    () {
      final result = builder.draft(state(), r3Draft(), newPlanId: 'r3');
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(result.estimateMinutes, inInclusiveRange(18, 22));
      expect(result.legacyGoal, 'core');
      expect(result.state.activePlanId, 'r3');
      final version = result.state.plans['r3']!.single;
      expect(version.estimateSec, inInclusiveRange(1080, 1320));
      expect(version.plan['equipment'], isEmpty);
      expect(result.toJson().containsKey('plan'), isFalse);
      expect(result.structure.map((b) => b['items']), [3, 5, 2]);
    },
  );

  test('unproven timing gap delivers current heuristic best with its error', () {
    final ids = ['forearms-A', 'n-pelvis-circle', 'h-bilateral-upper-back-hug'];
    final result = builder.draft(state(minutes: 30, picks: ids), {
      'title': '短方案',
      'blocks': [
        {
          'kind': 'warmup',
          'items': [
            for (final id in ids) {'id': id},
          ],
        },
      ],
    }, newPlanId: 'short');
    expect(result.ok, isTrue);
    expect(result.error, isNull);
    // Conservative bounds include all legal rounds/rest, beyond what the
    // bounded heuristic explores. It must not claim mathematical impossibility.
    expect(result.planId, 'short');
    expect(result.durationErrorPercent, isNotNull);
    expect(result.state.plans['short']!.single.version, 1);
  });

  test('model doses are ignored and new versions append', () {
    final request = r3Draft();
    final blocks = request['blocks']! as List<Object?>;
    final warm = blocks.first! as Map<String, Object?>;
    (warm['items']! as List<Object?>)[0] = {
      'id': 'h-step-jack',
      'sets': 99,
      'seconds': 999,
    };
    final first = builder.draft(state(), request, newPlanId: 'p1');
    expect(first.state.plans['p1'], hasLength(1));
    expect(first.note, contains('已忽略'));
    expect(
      first.fitLog.every(
        (step) =>
            step.containsKey('beforeEstimatedSec') &&
            step.containsKey('blockId'),
      ),
      isTrue,
    );
    final savedBlocks =
        first.state.plans['p1']!.single.plan['blocks']! as List<Object?>;
    final savedWarm = savedBlocks.first! as Map<String, Object?>;
    final item =
        (savedWarm['items']! as List<Object?>).first! as Map<String, Object?>;
    expect(item['sets'], inInclusiveRange(1, 3));
    expect(item['workSeconds'], inInclusiveRange(20, 80));
    final second = builder.draft(first.state, {
      ...r3Draft(),
      'plan_id': 'p1',
    }, newPlanId: 'unused');
    expect(second.version, 2);
    expect(second.state.plans['p1'], hasLength(2));
    expect(second.state.plans['p1']!.last.check, isNull);
  });

  test(
    'unseen actions are rejected and searched compatible extras join picks',
    () {
      final request = r3Draft();
      final original = state(seen: {'h-step-jack'});
      final unseen = builder.draft(original, request, newPlanId: 'p');
      expect(unseen.error!['code'], 'incompatible_action');
      expect(unseen.error!['fix'], contains('search_actions'));
      expect(unseen.state.plans, isEmpty);
      final full = state(picks: r3.sublist(0, r3.length - 1));
      final extra = builder.draft(full, request, newPlanId: 'p');
      expect(extra.ok, isTrue, reason: '${extra.error}');
      expect(extra.state.picks, r3);
      expect(
        extra.changes.where((change) => change.id == 'actions'),
        hasLength(1),
      );
      expect(
        extra.changes.singleWhere((change) => change.id == 'actions').status,
        'done',
      );
      expect(
        extra.changes.singleWhere((change) => change.id == 'actions').stamp,
        contains('${r3.length}'),
      );
    },
  );

  test(
    'active plan survives serialization and new task clears the pointer',
    () {
      final first = builder.draft(state(), r3Draft(), newPlanId: 'p1');
      final restored = CoachSessionState.fromJson(
        jsonDecode(jsonEncode(first.state.toJson())) as Map<String, Object?>,
      );
      expect(restored.activePlanId, 'p1');
      expect(
        restored.plans['p1']!.single.toJson(),
        first.state.plans['p1']!.single.toJson(),
      );
      final newTask = AgentTask.start(restored, 'recommend').state;
      expect(newTask.activePlanId, isNull);
      expect(newTask.plans['p1'], hasLength(1));
    },
  );

  test('a reserved active plan ID receives its first draft version', () {
    final reserved = state().copyWith(
      plans: {'reserved': []},
      activePlanId: 'reserved',
    );
    final result = builder.draft(reserved, {
      ...r3Draft(),
      'plan_id': 'reserved',
    }, newPlanId: 'unused');
    expect(result.ok, isTrue, reason: '${result.error}');
    expect((result.planId, result.version), ('reserved', 1));
    expect(result.state.plans['reserved'], hasLength(1));
  });

  test(
    'omitting the reserved ID creates a new plan and keeps nonempty history',
    () {
      final previous = builder.draft(state(), r3Draft(), newPlanId: 'history');
      expect(previous.ok, isTrue, reason: '${previous.error}');
      final reserved = state().copyWith(
        plans: {...previous.state.plans, 'reserved': []},
        activePlanId: 'reserved',
      );
      final result = builder.draft(reserved, r3Draft(), newPlanId: 'fresh');
      expect(result.ok, isTrue, reason: '${result.error}');
      expect((result.planId, result.version), ('fresh', 1));
      expect(result.state.plans, isNot(contains('reserved')));
      expect(
        result.state.plans['history']!.single.toJson(),
        previous.state.plans['history']!.single.toJson(),
      );
    },
  );

  test('an unrelated model ID normalizes to the active reservation', () {
    final unrelated = state().copyWith(
      plans: {'active': [], 'unrelated': []},
      activePlanId: 'active',
    );
    final result = builder.draft(unrelated, {
      ...r3Draft(),
      'plan_id': 'unrelated',
    }, newPlanId: 'unused');
    expect(result.ok, isTrue, reason: '${result.error}');
    expect(result.planId, 'active');
    expect(result.state.plans['unrelated'], isEmpty);
  });

  test('node checks refuse another plan id when active plan is set', () {
    final first = builder.draft(state(), r3Draft(), newPlanId: 'p1');
    final old = first.state.plans['p1']!.single;
    final task = CoachTaskState(
      type: 'plan',
      reused: false,
      nodes: [
        const CoachNodeState(id: 'planning', status: 'current'),
        const CoachNodeState(id: 'review', status: 'pending'),
      ],
    );
    final withOld = first.state.copyWith(
      task: task,
      plans: {
        ...first.state.plans,
        'old': [old],
      },
    );
    final gate = NodeGates(profile, catalog, minPicks: 3);
    expect(
      gate.check(withOld, 'planning', planId: 'old').error!['code'],
      'missing_plan',
    );
    expect(gate.check(withOld, 'planning').ok, isTrue);
  });

  test(
    'legacy snapshot can use its only plan but a fresh task cannot reuse it',
    () {
      final drafted = builder.draft(state(), r3Draft(), newPlanId: 'p1').state;
      final legacyJson = drafted.toJson()..remove('activePlanId');
      final restored = CoachSessionState.fromJson(legacyJson);
      final gate = NodeGates(profile, catalog, minPicks: 3);
      expect(gate.check(restored, 'planning').ok, isTrue);
      final multiple = restored.copyWith(
        plans: {...restored.plans, 'p2': restored.plans['p1']!},
      );
      expect(gate.check(multiple, 'planning').error!['code'], 'missing_plan');
      final newTask = AgentTask.start(restored, 'plan').state;
      expect(newTask.legacyPlanFallback, isFalse);
      final roundtrip = CoachSessionState.fromJson(newTask.toJson());
      expect(roundtrip.legacyPlanFallback, isFalse);
    },
  );

  test('draft rejects actions reset after a parameter change', () {
    final ready = state();
    final changed = NodeGates(
      profile,
      catalog,
      minPicks: 3,
    ).parametersChanged(ready).state;
    expect(
      changed.task!.nodes.firstWhere((n) => n.status == 'current').id,
      'actions',
    );
    final result = builder.draft(changed, r3Draft(), newPlanId: 'p1');
    expect(result.error!['code'], 'wrong_node');
    expect(result.state.plans, isEmpty);
  });

  test('rounds may temporarily overshoot before sets hit the target', () {
    final base = catalog.drills.first;
    final synthetic = Catalog(
      version: 'test',
      drills: [
        for (final id in ['a', 'b', 'c'])
          Drill(
            id: id,
            name: base.name,
            category: 'core',
            position: 'standing',
            unilateral: false,
            level: 1,
            defaultDose: const Dose(
              mode: DoseMode.time,
              sets: 6,
              seconds: 10,
              restSeconds: 0,
            ),
            doseRange: const DoseRange(
              sets: IntRange(1, 6),
              seconds: IntRange(10, 10),
              restSeconds: IntRange(0, 0),
            ),
          ),
      ],
    );
    const customProfile = CoachProfile(id: 'test', appName: 'test');
    final gate = NodeGates(customProfile, synthetic, minPicks: 3);
    var ready = CoachSessionState(
      params: {
        'scene': param('home'),
        'goal': param(['body.core']),
        'minutes': param(3),
        'equipment': param(<String>[]),
        'level': param(1),
        'limits': param(<String>[]),
      },
    );
    ready = AgentTask.start(
      ready,
      'plan',
    ).state.copyWith(seenActionIds: {'a', 'b', 'c'});
    ready = gate.check(ready, 'understand').state;
    ready = gate.check(ready, 'parameters').state;
    final checked = gate.check(ready, 'actions', picks: ['a', 'b', 'c']);
    expect(checked.ok, isTrue, reason: '${checked.error}');
    final result = PlanBuilder(customProfile, synthetic, minPicks: 3).draft(
      checked.state,
      {
        'title': '三分钟',
        'blocks': [
          {
            'kind': 'main',
            'rounds': 1,
            'items': [
              {'id': 'a'},
            ],
          },
        ],
      },
      newPlanId: 'counterexample',
    );
    expect(result.ok, isTrue, reason: '${result.error}');
    expect(
      result.state.plans['counterexample']!.single.estimateSec,
      inInclusiveRange(171, 189),
    );
  });
}
