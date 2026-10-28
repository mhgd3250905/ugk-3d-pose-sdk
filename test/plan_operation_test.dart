import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/action_search.dart';
import 'package:ugk_coach/src/agent/action_tags.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/plan_builder.dart';
import 'package:ugk_coach/src/agent/session_params.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

void main() {
  const root = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$root/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$root/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();
  final profile = loadProfile('smartfit');
  final gate = NodeGates(profile, catalog, minPicks: 3);
  final builder = PlanBuilder(profile, catalog, minPicks: 3);
  const warmup = ['h-step-jack', 'n-pelvis-circle'];
  const oldMain = ['erectors-A', 'obliques-A', 'h-squat', 'h-good-morning'];
  const newMain = [
    'h-kneeling-pushup',
    'rotator-cuff-A',
    'h-squat',
    'h-good-morning',
  ];
  const cooldown = ['o-stand-sidebend', 'h-bilateral-upper-back-hug'];
  final ids = {...warmup, ...oldMain, ...newMain, ...cooldown}.toList();

  Map<String, Object?> draft(
    List<String> main, {
    String? operation,
    String? id,
  }) => {
    'title': '居家训练',
    'plan_id': ?id,
    'operation': ?operation,
    'blocks': [
      {
        'kind': 'warmup',
        'items': [
          for (final id in warmup) {'id': id},
        ],
      },
      {
        'kind': 'main',
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

  CoachSessionState ready() {
    CoachParamValue param(Object value) =>
        CoachParamValue(value: value, source: 'user', turn: 1);
    var state = CoachSessionState(
      userTurns: [const CoachUserTurn(turn: 1, text: '在家徒手20分钟练核心')],
      params: {
        'scene': param('home'),
        'equipment': param(<String>[]),
        'minutes': param(20),
        'goal': param(['body.core']),
      },
    );
    state = AgentTask.start(state, 'plan').state;
    state = gate.check(state, 'understand').state;
    state = gate.check(state, 'parameters').state;
    state = state.copyWith(seenActionIds: ids.toSet());
    final selected = gate.check(state, 'actions', picks: ids);
    expect(selected.ok, isTrue, reason: '${selected.error}');
    return selected.state;
  }

  CoachSessionState delivered() {
    final initial = builder.draft(
      ready(),
      draft(oldMain),
      newPlanId: 'original',
    );
    expect(initial.ok, isTrue, reason: '${initial.error}');
    final task = initial.state.task!;
    return initial.state.copyWith(
      task: task.copyWith(
        nodes: [
          for (final node in task.nodes)
            node.copyWith(status: 'done', stamp: '完成'),
        ],
      ),
      lastDeliveredPlanId: 'original',
      lastDeliveredVersion: 1,
      lastDeliveredTurn: 1,
      userTurns: [
        ...initial.state.userTurns,
        const CoachUserTurn(turn: 2, text: '换一套'),
      ],
    );
  }

  test('first plan ignores operation; later modification defaults to edit', () {
    final first = builder.draft(
      ready(),
      draft(oldMain, operation: 'edit'),
      newPlanId: 'new',
    );
    expect(first.ok, isTrue, reason: '${first.error}');
    expect(first.toJson()['note'], '首份计划，已忽略 operation');
    expect(first.state.plans['new']!.last.operation, isNull);
    final replaceFirst = builder.draft(
      ready(),
      draft(oldMain, operation: 'replace_all'),
      newPlanId: 'first',
    );
    expect(replaceFirst.ok, isTrue, reason: '${replaceFirst.error}');
    expect(replaceFirst.toJson()['note'], '首份计划，已忽略 operation');
    expect(replaceFirst.state.plans['first']!.last.operation, isNull);
    final prior = delivered();
    final absent = builder.draft(prior, draft(oldMain), newPlanId: 'new');
    expect(absent.ok, isTrue, reason: '${absent.error}');
    expect(absent.planId, 'original');
    expect(absent.state.plans['original']!.last.operation, 'edit');
    final wrongId = builder.draft(
      prior,
      draft(oldMain, operation: 'edit', id: 'other'),
      newPlanId: 'unused',
    );
    expect(wrongId.ok, isTrue, reason: '${wrongId.error}');
    expect(wrongId.planId, 'original');
  });

  test('a new independent task can create a fresh plan after delivery', () {
    var state = AgentTask.start(delivered(), 'plan').state;
    expect(state.seenActionIds, isEmpty);
    state = gate.check(state, 'understand').state;
    state = gate.check(state, 'parameters').state;
    state = state.copyWith(seenActionIds: ids.toSet());
    state = gate.check(state, 'actions', picks: ids).state;
    final result = builder.draft(
      state,
      draft(oldMain),
      newPlanId: 'independent',
    );
    expect(result.ok, isTrue, reason: '${result.error}');
    expect(result.planId, 'independent');
    expect(result.state.lastDeliveredPlanId, 'original');
    expect(result.version, 1);
  });

  test(
    'current-turn sourced operation wins over the legacy compatibility marker',
    () {
      final prior = delivered();
      final sourced = prior.copyWith(
        params: {
          ...prior.params,
          'operation': CoachParamValue(
            value: 'replace_all',
            source: 'user',
            quote: '换一套',
            turn: 2,
          ),
        },
      );
      final result = builder.draft(
        sourced,
        draft(newMain, operation: 'edit'),
        newPlanId: 'unused',
      );
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(result.state.plans['original']!.last.operation, 'replace_all');
      expect(result.notes.any((note) => note.contains('带来源')), isTrue);
    },
  );

  test(
    'old sourced operation does not repeat and invalid legacy markers normalize',
    () {
      final prior = delivered();
      final stale = prior.copyWith(
        params: {
          ...prior.params,
          'operation': CoachParamValue(
            value: 'replace_all',
            source: 'user',
            quote: 'old request',
            turn: 1,
          ),
        },
      );
      final result = builder.draft(
        stale,
        draft(oldMain, operation: 'unknown'),
        newPlanId: 'unused',
      );
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(result.state.plans['original']!.last.operation, 'edit');
      expect(result.notes.any((note) => note.contains('无效旧操作')), isTrue);
    },
  );

  test(
    'repeated same-quote replacement requests keep proof but enforce difference on both turns',
    () {
      final params = SessionParams(ActionTags(profile, catalog));
      Map<String, Object?> request() => {
        'fields': {
          'operation': {
            'value': 'replace_all',
            'source': 'user',
            'quote': '换一套',
          },
        },
      };
      final first = params.set(delivered(), request());
      expect(first.ok, isTrue);
      expect(first.state.lastOperationRequestTurn, 2);
      final firstFailure = builder.draft(
        first.state,
        draft(oldMain),
        newPlanId: 'unused',
      );
      expect(firstFailure.error!['code'], 'replace_too_similar');
      final replaced = builder.draft(
        first.state,
        draft(newMain),
        newPlanId: 'unused',
      );
      expect(replaced.ok, isTrue);
      final next = replaced.state
          .copyWith(
            task: replaced.state.task!.copyWith(
              nodes: [
                for (final node in replaced.state.task!.nodes)
                  node.copyWith(status: 'done'),
              ],
            ),
            lastDeliveredVersion: replaced.version,
            lastDeliveredTurn: 2,
          )
          .appendUserTurn('换一套');
      final second = params.set(next, request());
      expect(second.ok, isTrue);
      expect(second.kept, {'operation'});
      expect(second.changedFields, isEmpty);
      expect(
        second.state.params['operation'],
        same(first.state.params['operation']),
      );
      expect(second.state.params['operation']!.turn, 2);
      expect(second.state.lastOperationRequestTurn, 3);
      final secondFailure = builder.draft(
        second.state,
        draft(newMain),
        newPlanId: 'unused',
      );
      expect(secondFailure.error!['code'], 'replace_too_similar');
      expect(
        secondFailure.state.plans['original']!.last.operation,
        'replace_all',
      );
      final secondSuccess = builder.draft(
        second.state,
        draft(oldMain),
        newPlanId: 'unused',
      );
      expect(secondSuccess.ok, isTrue);
      expect(
        secondSuccess.state.plans['original']!.last.operation,
        'replace_all',
      );
    },
  );

  test(
    'unrelated old request stays inactive and legacy snapshots fall back to proof turn',
    () {
      final params = SessionParams(ActionTags(profile, catalog));
      final request = {
        'fields': {
          'operation': {
            'value': 'replace_all',
            'source': 'user',
            'quote': '换一套',
          },
        },
      };
      final requested = params.set(delivered(), request).state;
      final snapshot = requested.toJson()..remove('lastOperationRequestTurn');
      final legacy = CoachSessionState.fromJson(snapshot);
      expect(legacy.lastOperationRequestTurn, isNull);
      final active = builder.draft(legacy, draft(oldMain), newPlanId: 'unused');
      expect(active.error!['code'], 'replace_too_similar');
      final replay = params.set(requested.appendUserTurn('谢谢'), request);
      expect(replay.ok, isTrue);
      expect(replay.kept, {'operation'});
      expect(replay.state.lastOperationRequestTurn, 2);
      final inactive = builder.draft(
        replay.state,
        draft(oldMain),
        newPlanId: 'unused',
      );
      expect(inactive.ok, isTrue);
      expect(inactive.state.plans['original']!.last.operation, 'edit');
    },
  );

  test('recommendation to plan reuse retains searched actions', () {
    final state = delivered();
    final completed = CoachTaskState(
      type: 'recommend',
      reused: false,
      nodes: [
        for (final id in AgentTask.recommendNodes)
          CoachNodeState(id: id, status: 'done', stamp: '完成'),
      ],
    );
    final reused = AgentTask.start(
      state.copyWith(task: completed),
      'plan',
      reuse: true,
    );
    expect(reused.ok, isTrue, reason: '${reused.error}');
    expect(reused.state.seenActionIds, state.seenActionIds);
    expect(reused.state.picks, state.picks);
  });

  test('edit keeps the delivered ID and resets only the planning stages', () {
    final result = builder.draft(
      delivered(),
      draft(oldMain, operation: 'edit'),
      newPlanId: 'unused',
    );
    expect(result.ok, isTrue, reason: '${result.error}');
    expect((result.planId, result.version), ('original', 2));
    expect(result.state.plans['original']!.last.operation, 'edit');
    expect(result.changes.map((n) => (n.id, n.status)), [
      ('planning', 'current'),
      ('review', 'pending'),
      ('output', 'pending'),
    ]);
    expect(
      result.state.task!.nodes.take(3).every((n) => n.status == 'done'),
      isTrue,
    );
  });

  test('replace_all saves a too-similar version and cannot be bypassed', () {
    final result = builder.draft(
      delivered(),
      draft(oldMain, operation: 'replace_all'),
      newPlanId: 'unused',
    );
    expect(result.error!['code'], 'replace_too_similar');
    expect(result.error!['expected'], '≥ 50% 不同');
    expect(result.error!['actual'], '0/4 不同');
    expect(result.error!['fix'], '替换至少 2 个主体动作。');
    expect(
      result.error!['candidates'],
      containsAll(['h-kneeling-pushup', 'rotator-cuff-A']),
    );
    expect(result.state.plans['original']!.last.operation, 'replace_all');
    expect(result.state.plans['original']!.last.version, 2);
    final withoutOperation = builder.draft(
      result.state,
      draft(oldMain),
      newPlanId: 'unused',
    );
    expect(withoutOperation.error!['code'], 'replace_too_similar');
    final switched = builder.draft(
      result.state,
      draft(oldMain, operation: 'edit'),
      newPlanId: 'unused',
    );
    expect(switched.error!['code'], 'replace_too_similar');
  });

  test('replacement reports unique main action counts', () {
    final result = builder.draft(
      delivered(),
      draft([
        ...oldMain,
        'h-kneeling-pushup',
        'rotator-cuff-A',
      ], operation: 'replace_all'),
      newPlanId: 'unused',
    );
    expect(result.error!['code'], 'replace_too_similar');
    expect(result.error!['expected'], '≥ 50% 不同');
    expect(result.error!['actual'], '2/6 不同');
    expect(result.error!['fix'], '替换至少 1 个主体动作。');
    expect(result.error!['candidates'], isA<List<Object?>>());
    final duplicates = builder.draft(
      delivered(),
      draft([...oldMain, oldMain.first], operation: 'replace_all'),
      newPlanId: 'unused',
    );
    expect(duplicates.error!['actual'], '0/4 不同');
  });

  test(
    'replacement recommends searching when compatible candidates are missing',
    () {
      final original = delivered();
      final state = original.copyWith(seenActionIds: oldMain.toSet());
      final result = builder.draft(state, {
        'title': '训练',
        'operation': 'replace_all',
        'blocks': [
          {
            'kind': 'main',
            'items': [
              for (final id in oldMain) {'id': id},
            ],
          },
        ],
      }, newPlanId: 'unused');
      expect(result.error!['code'], 'replace_too_similar');
      expect(result.error!['candidates'], isEmpty);
      expect(result.error!['fix'], contains('搜索'));
    },
  );

  test(
    'replace_all accepts half-new main actions and survives JSON roundtrip',
    () {
      final result = builder.draft(
        delivered(),
        draft(newMain, operation: 'replace_all'),
        newPlanId: 'unused',
      );
      expect(result.ok, isTrue, reason: '${result.error}');
      expect((result.planId, result.version), ('original', 2));
      final restored = CoachSessionState.fromJson(
        jsonDecode(jsonEncode(result.state.toJson())) as Map<String, dynamic>,
      );
      expect(restored.lastDeliveredPlanId, 'original');
      expect(restored.lastDeliveredVersion, 1);
      expect(restored.plans['original']!.last.operation, 'replace_all');
      expect(restored.plans['original']!.last.createdAtTurn, 2);
    },
  );

  test(
    'replacement can add newly searched actions to picks and emits one update',
    () {
      final initialIds = {...warmup, ...oldMain, ...cooldown};
      var state = delivered().copyWith(
        picks: initialIds.toList(),
        seenActionIds: initialIds,
      );
      final prior = state;
      final resumed = AgentTask.start(state, 'plan', reuse: true);
      expect(resumed.ok, isTrue, reason: '${resumed.error}');
      state = resumed.state;
      expect(state.activePlanId, prior.activePlanId);
      expect(state.picks, prior.picks);
      expect(state.seenActionIds, prior.seenActionIds);
      final search = ActionSearch(profile, catalog, minPicks: 3);
      for (final id in ['h-kneeling-pushup', 'rotator-cuff-A']) {
        final result = search.search(
          state,
          keywords: catalog[id]!.name.of('en'),
        );
        expect(result.ok, isTrue, reason: '${result.error}');
        expect(result.items.map((row) => row['id']), contains(id));
        state = result.state;
      }
      expect(state.picks, isNot(contains('h-kneeling-pushup')));
      final result = builder.draft(
        state,
        draft(newMain, operation: 'replace_all'),
        newPlanId: 'unused',
      );
      expect(result.ok, isTrue, reason: '${result.error}');
      expect(
        result.state.picks,
        containsAll(['h-kneeling-pushup', 'rotator-cuff-A']),
      );
      expect(result.state.seenActionIds, containsAll(initialIds));
      final actionEvents = result.changes
          .where((node) => node.id == 'actions')
          .toList();
      expect(actionEvents, hasLength(1));
      expect(actionEvents.single.status, 'done');
      expect(
        actionEvents.single.stamp,
        contains('${result.state.picks.length}'),
      );
      final restored = CoachSessionState.fromJson(
        jsonDecode(jsonEncode(result.state.toJson())) as Map<String, dynamic>,
      );
      expect(restored.seenActionIds, result.state.seenActionIds);
      expect(restored.picks, result.state.picks);
    },
  );

  test(
    'searched actions are rechecked after equipment becomes unavailable',
    () {
      final original = delivered();
      const matId = 's-figure4';
      final params = Map<String, CoachParamValue>.of(original.params)
        ..['equipment'] = CoachParamValue(
          value: ['equip.mat'],
          source: 'user',
          turn: 2,
        );
      final resumed = AgentTask.start(original, 'plan', reuse: true);
      expect(resumed.ok, isTrue, reason: '${resumed.error}');
      expect(resumed.state.activePlanId, original.activePlanId);
      expect(resumed.state.picks, original.picks);
      expect(resumed.state.seenActionIds, original.seenActionIds);
      var state = resumed.state.copyWith(params: params);
      final searched = ActionSearch(
        profile,
        catalog,
        minPicks: 3,
      ).search(state, keywords: catalog[matId]!.name.of('en'));
      expect(searched.items.map((row) => row['id']), contains(matId));
      state = searched.state.copyWith(
        params: {
          ...searched.state.params,
          'equipment': CoachParamValue(
            value: <String>[],
            source: 'user',
            turn: 2,
          ),
          'equipment_exclude': CoachParamValue(
            value: ['equip.mat'],
            source: 'user',
            turn: 2,
            quote: '不用垫子',
          ),
        },
      );
      final result = builder.draft(
        state,
        draft([matId, ...oldMain], operation: 'edit'),
        newPlanId: 'unused',
      );
      expect(result.error!['code'], 'incompatible_action');
      expect(result.error!['fix'], contains('search_actions'));
      expect(result.state.picks, isNot(contains(matId)));
      expect(result.state.toJson(), state.toJson());
    },
  );

  test(
    'same-turn check failure inherits replacement policy without bypass',
    () {
      final attempt = builder.draft(
        delivered(),
        draft(newMain, operation: 'replace_all'),
        newPlanId: 'unused',
      );
      final versions = List<CoachPlanVersion>.of(
        attempt.state.plans['original']!,
      );
      final last = versions.last;
      versions[versions.length - 1] = CoachPlanVersion(
        version: last.version,
        plan: last.plan,
        estimateSec: last.estimateSec,
        fitLog: last.fitLog,
        createdAtTurn: last.createdAtTurn,
        operation: last.operation,
        check: {'ok': false},
      );
      final repair = attempt.state.copyWith(plans: {'original': versions});
      final switched = builder.draft(
        repair,
        draft(oldMain, id: 'original', operation: 'edit'),
        newPlanId: 'unused',
      );
      expect(switched.error!['code'], 'replace_too_similar');
      final result = builder.draft(
        repair,
        draft(oldMain, id: 'original'),
        newPlanId: 'unused',
      );
      expect(result.error!['code'], 'replace_too_similar');
      expect(result.state.plans['original']!.last.operation, 'replace_all');
      expect(result.version, 3);
    },
  );
}
