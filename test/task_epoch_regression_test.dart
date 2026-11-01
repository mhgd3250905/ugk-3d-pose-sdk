import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/src/agent/agent_task.dart';
import 'package:ugk_coach/src/agent/node_gates.dart';
import 'package:ugk_coach/src/agent/structured_tool_handler.dart';
import 'package:ugk_coach/src/agent/terminal_tool_handler.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';

Map<String, Object?> _map(Object? value) =>
    Map<String, Object?>.from(value! as Map);
List<Object?> _list(Object? value) => value! as List<Object?>;

void main() {
  final fixture = _map(
    jsonDecode(
      File('test/fixtures/task-epoch/five-3-public.json').readAsStringSync(),
    ),
  );
  final batches = _list(fixture['batches']).map(_map).toList();
  Map<String, Object?> toolAt(int modelCall, [int index = 0]) => _map(
    _list(
      batches.singleWhere((entry) => entry['modelCall'] == modelCall)['tools'],
    )[index],
  );
  Map<String, Object?> argumentsAt(int modelCall, [int index = 0]) =>
      _map(toolAt(modelCall, index)['arguments']);
  final inputs = _list(fixture['inputs']).cast<String>();
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File(
      'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog.json',
    ).readAsBytesSync(),
    semanticCatalogBytes: File(
      'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog/catalog.json',
    ).readAsBytesSync(),
  ).toAiCatalog();
  final profile = loadProfile('smartfit');
  final gate = ToolGate(catalog: catalog, profile: profile);
  final terminal = TerminalToolHandler(gate);
  final nodes = NodeGates(profile, catalog, minPicks: profile.minActions);
  var nextId = 0;
  StructuredToolHandler handler() => StructuredToolHandler(
    profile,
    catalog,
    newPlanId: () => 'epoch-plan-${nextId++}',
    files: SkillFiles.build(profile, catalog, memory: false),
  );
  final originalVersion = CoachPlanVersion.fromJson(
    _map(fixture['initialSavedVersion']),
  );
  final originalId = originalVersion.plan['id']! as String;
  final selected = _list(argumentsAt(6)['ids']).cast<String>();

  CoachSessionState initial() {
    var state = CoachSessionState(
      userTurns: [CoachUserTurn(turn: 1, text: inputs[0])],
      task: CoachTaskState(
        type: 'plan',
        nodes: [
          for (final name in AgentTask.planNodes)
            CoachNodeState(id: name, status: 'done', doneAtTurn: 1),
        ],
        reused: false,
      ),
      params: {
        for (final entry in _map(argumentsAt(2)['fields']).entries)
          entry.key: CoachParamValue.fromJson({
            ..._map(entry.value),
            'turn': 1,
          }),
        'limits': CoachParamValue(
          value: const <String>[],
          source: 'default',
          turn: 1,
        ),
      },
      picks: const PlanCodec()
          .decode(originalVersion.plan)
          .exerciseIds
          .toList(),
      plans: {
        originalId: [originalVersion],
      },
      activePlanId: originalId,
      lastDeliveredPlanId: originalId,
      lastDeliveredVersion: 1,
      lastDeliveredTurn: 1,
    );
    for (var index = 0; index < 2; index++) {
      final result = handler().search(
        state,
        AgentTools.searchActions,
        jsonEncode(argumentsAt(3, index)),
        'zh',
      );
      expect(_map(jsonDecode(result.response))['ok'], isTrue);
      state = result.state;
    }
    expect(state.seenActionIds, containsAll(selected));
    return state;
  }

  TerminalToolResult show(CoachSessionState state, int modelCall) =>
      terminal.show(
        state,
        AgentTools.showActions,
        jsonEncode(argumentsAt(modelCall)),
        language: 'zh',
      );
  StructuredToolResult search(CoachSessionState state, int modelCall) =>
      handler().search(
        state,
        AgentTools.searchActions,
        jsonEncode(argumentsAt(modelCall)),
        'zh',
      );
  CoachSessionState recommend() {
    final rejected = show(initial().appendUserTurn(inputs[1]), 6);
    expect(rejected.rejected, isTrue);
    final found = search(rejected.state!, 7);
    expect(_map(jsonDecode(found.response))['ok'], isTrue);
    final shown = show(found.state, 8);
    expect(shown.rejected, isFalse, reason: shown.response);
    expect(shown.output, isNotNull);
    expect(shown.output!.card!.actions!.items, isNotEmpty);
    return shown.output!.state;
  }

  test('public fixture is pinned to the actual SF five-3 case', () {
    expect(
      fixture['sourceCaseSha256'],
      'ffe472247656aecbccfeb77d743464377e46a5c6040d6e2849fc3018ad69c3f0',
    );
    expect(fixture['privacy'], {
      'reasoningIncluded': false,
      'systemMessagesIncluded': false,
      'headersIncluded': false,
      'credentialsIncluded': false,
    });
    expect(originalVersion.version, 1);
    expect(originalVersion.estimateSec, 625);
    expect(toolAt(6)['name'], AgentTools.showActions);
    expect(toolAt(7)['name'], AgentTools.searchActions);
    expect(toolAt(8)['name'], AgentTools.showActions);
    expect(selected, ['s-butterfly', 'h-butterfly-active', 'h-adductor-rock']);
  });

  test(
    'C6 C7 C8 use one effective recommendation task and real search pool',
    () {
      final before = initial();
      final planBefore = jsonEncode(before.plans[originalId]!.single.toJson());
      final rejected = show(before.appendUserTurn(inputs[1]), 6);
      expect(_map(jsonDecode(rejected.response))['code'], 'unseen_actions');
      expect(rejected.output, isNull);
      expect(rejected.state!.task!.type, 'recommend');
      expect(rejected.state!.seenActionIds, isEmpty);
      expect(rejected.state!.picks, isEmpty);
      expect(rejected.changes.map((node) => node.id), AgentTask.recommendNodes);
      final found = search(rejected.state!, 7);
      final rows = _list(_map(jsonDecode(found.response))['items']).map(_map);
      final returned = {for (final row in rows) row['id']! as String};
      expect(returned, isNotEmpty);
      expect(returned, containsAll(selected));
      expect(found.state.seenActionIds, returned);
      expect(found.state.pendingSearchIds, returned);
      expect(found.state.pendingSearchTurn, 2);
      final shown = show(found.state, 8);
      expect(shown.rejected, isFalse, reason: shown.response);
      expect(shown.output, isNotNull);
      final actions = shown.output!.card!.actions!;
      expect(actions.items, isNotEmpty);
      expect(actions.items.map((action) => action.id), selected);
      expect(
        shown.output!.state.task!.nodes.every((n) => n.status == 'done'),
        isTrue,
      );
      expect(
        shown.output!.changes.where(
          (node) => node.id == 'understand' && node.status == 'current',
        ),
        isEmpty,
        reason: 'C8 cannot create a second task and clear the C7 search source',
      );
      expect(shown.output!.state.plans.keys, [originalId]);
      expect(shown.output!.state.plans[originalId], hasLength(1));
      expect(
        jsonEncode(shown.output!.state.plans[originalId]!.single.toJson()),
        planBefore,
      );
      expect(shown.output!.state.lastDeliveredPlanId, originalId);
      expect(shown.output!.state.lastDeliveredVersion, 1);
    },
  );

  test('malformed typed output cannot establish or reset a task', () {
    final before = initial().appendUserTurn(inputs[1]);
    final rejected = terminal.show(
      before,
      AgentTools.showActions,
      jsonEncode({'ids': 7}),
      language: 'zh',
    );
    expect(rejected.rejected, isTrue);
    expect(rejected.output, isNull);
    expect(rejected.state!.toJson(), before.toJson());
    expect(rejected.changes, isEmpty);
  });

  test('repeated rejected shows do not borrow the old plan seen pool', () {
    final first = show(initial().appendUserTurn(inputs[1]), 6);
    final second = show(first.state!, 8);
    expect(second.rejected, isTrue);
    expect(_map(jsonDecode(second.response))['code'], 'unseen_actions');
    expect(second.output, isNull);
    expect(second.state!.task!.toJson(), first.state!.task!.toJson());
    expect(second.state!.seenActionIds, isEmpty);
    expect(second.state!.plans.keys, [originalId]);
    expect(second.state!.plans[originalId], hasLength(1));
    expect(second.changes, isEmpty);
  });

  test(
    'search before an implicit switch lends only this turn returned IDs',
    () {
      final before = initial().appendUserTurn(inputs[1]);
      final found = search(before, 7);
      final returned = {
        for (final row in _list(_map(jsonDecode(found.response))['items']))
          _map(row)['id']! as String,
      };
      final oldOnly = before.seenActionIds.difference(returned);
      expect(returned, isNotEmpty);
      expect(
        oldOnly,
        isNotEmpty,
        reason: 'the prior plan must have unrelated IDs',
      );
      final shown = show(found.state, 8);
      expect(shown.rejected, isFalse, reason: shown.response);
      expect(shown.output!.card!.actions!.items, isNotEmpty);
      expect(shown.output!.state.seenActionIds, returned);
      expect(shown.output!.state.seenActionIds.intersection(oldOnly), isEmpty);
    },
  );

  test(
    'a previous user turn pending search cannot cross a new task boundary',
    () {
      final found = search(initial().appendUserTurn(inputs[1]), 7);
      expect(found.state.pendingSearchIds, isNotEmpty);
      final rejected = show(found.state.appendUserTurn('另一个推荐请求'), 8);
      expect(rejected.rejected, isTrue);
      expect(rejected.output, isNull);
      expect(rejected.state!.seenActionIds, isEmpty);
    },
  );

  test('admission and safety changes invalidate pending search receipts', () {
    final found = search(initial().appendUserTurn(inputs[1]), 7);
    expect(found.state.pendingSearchIds, isNotEmpty);
    final updated = nodes.parametersChanged(
      found.state.copyWith(
        params: {
          ...found.state.params,
          'equipment_exclude': CoachParamValue(
            value: const ['equip.mat'],
            source: 'user',
            turn: 2,
          ),
        },
      ),
      changedFields: const {'equipment_exclude'},
      valueChangedFields: const {'equipment_exclude'},
    );
    expect(updated.state.pendingSearchIds, isEmpty);
    expect(updated.state.pendingSearchTurn, isNull);
    final rejected = show(updated.state, 8);
    expect(rejected.rejected, isTrue);
    expect(rejected.output, isNull);
    expect(
      rejected.state!.plans[originalId]!.single.plan,
      originalVersion.plan,
    );
  });

  test('pending search sources survive state codecs and are consumed once', () {
    final found = search(initial().appendUserTurn(inputs[1]), 7);
    final restored = CoachSessionState.fromJson(found.state.toJson());
    expect(restored.pendingSearchIds, isNotEmpty);
    expect(restored.pendingSearchIds, found.state.pendingSearchIds);
    final started = AgentTask.start(restored, 'recommend');
    expect(started.state.seenActionIds, restored.pendingSearchIds);
    expect(started.state.pendingSearchIds, isEmpty);
    expect(started.state.pendingSearchTurn, isNull);
  });

  test('third-turn edit uses the original A version after recommendation', () {
    var state = recommend().appendUserTurn(inputs[2]);
    final before = state.plans[originalId]!.single;
    final changed = handler().setParams(state, argumentsAt(11), 'zh', const []);
    expect(_map(jsonDecode(changed.response))['ok'], isTrue);
    state = changed.state;
    expect(state.task!.type, 'recommend');
    expect(state.task!.nodes.last.status, 'done');
    expect(state.plans[originalId]!.single.toJson(), before.toJson());
    final found = handler().search(
      state,
      AgentTools.searchActions,
      jsonEncode(argumentsAt(11, 1)),
      'zh',
    );
    expect(_map(jsonDecode(found.response))['ok'], isTrue);
    // The original C12 draft legitimately fails the unchanged difference
    // requirement. C13 is its actual recorded repair, not a fallback selection.
    final attempted = handler().draft(
      found.state,
      jsonEncode(argumentsAt(12)),
      'zh',
    );
    expect(_map(jsonDecode(attempted.response))['ok'], isFalse);
    expect(_map(jsonDecode(attempted.response))['code'], 'replace_too_similar');
    final repaired = handler().draft(
      attempted.state,
      jsonEncode(argumentsAt(13)),
      'zh',
    );
    expect(
      _map(jsonDecode(repaired.response))['ok'],
      isTrue,
      reason: repaired.response,
    );
    expect(repaired.state.activePlanId, originalId);
    expect(repaired.state.plans.keys, [originalId]);
    expect(repaired.state.plans[originalId]!.first.plan, before.plan);
    expect(repaired.state.plans[originalId]!.first.version, 1);
    expect(repaired.state.plans[originalId]!.last.version, greaterThan(1));
    final shown = terminal.show(
      repaired.state,
      AgentTools.showPlan,
      jsonEncode(argumentsAt(14)),
      language: 'zh',
    );
    expect(shown.rejected, isFalse, reason: shown.response);
    expect(shown.output, isNotNull);
    expect(shown.output!.card!.plan, isNotNull);
    final plan = shown.output!.card!.plan!.plan;
    expect(plan.items, isNotEmpty);
    expect(plan.id, originalId);
    expect(plan.targetMinutes, 5);
    expect(catalog.ids.toSet().containsAll(plan.exerciseIds), isTrue);
  });

  test('forged IDs never become seen through a typed draft boundary', () {
    final before = recommend().appendUserTurn('新建一个训练计划');
    final rejected = handler().draft(
      before,
      jsonEncode({
        'blocks': [
          {
            'kind': 'main',
            'items': [
              {'id': 'forged-not-a-catalog-id'},
            ],
          },
        ],
      }),
      'zh',
    );
    expect(_map(jsonDecode(rejected.response))['ok'], isFalse);
    expect(rejected.state.task!.type, 'plan');
    expect(
      rejected.state.seenActionIds,
      isNot(contains('forged-not-a-catalog-id')),
    );
    expect(rejected.state.plans.keys, before.plans.keys);
    expect(
      rejected.state.plans[originalId]!.single.toJson(),
      originalVersion.toJson(),
    );
    expect(
      rejected.state.plans.values.every((versions) => versions.isNotEmpty),
      isTrue,
    );
  });

  test(
    'focused saved version remains the edit target after a recommendation',
    () {
      const focusId = 'ext:epoch-fixture';
      final focused = CoachPlanVersion(
        version: 1,
        plan: {...originalVersion.plan, 'id': focusId},
        estimateSec: originalVersion.estimateSec,
        fitLog: const [],
        check: const {'ok': true},
        createdAtTurn: 1,
      );
      var state = recommend()
          .copyWith(
            plans: {
              originalId: [originalVersion],
              focusId: [focused],
            },
            focusPlanId: focusId,
            savedRef: const CoachSavedPlanRef(
              externalId: 'epoch-fixture',
              baseVersion: 1,
            ),
          )
          .appendUserTurn('改成5分钟');
      final changed = handler().setParams(
        state,
        {
          'fields': {
            'minutes': {'value': 5, 'source': 'user', 'quote': '改成5分钟'},
          },
        },
        'zh',
        const [],
      );
      expect(_map(jsonDecode(changed.response))['ok'], isTrue);
      final found = handler().search(
        changed.state,
        AgentTools.searchActions,
        jsonEncode(argumentsAt(11, 1)),
        'zh',
      );
      expect(_map(jsonDecode(found.response))['ok'], isTrue);
      state = found.state;
      final revised = handler().draft(state, jsonEncode(argumentsAt(13)), 'zh');
      expect(
        _map(jsonDecode(revised.response))['ok'],
        isTrue,
        reason: revised.response,
      );
      expect(revised.state.focusPlanId, focusId);
      expect(revised.state.activePlanId, focusId);
      expect(revised.state.savedRef, state.savedRef);
      expect(revised.state.savedRef!.baseVersion, 1);
      expect(
        revised.state.plans[originalId]!.single.toJson(),
        originalVersion.toJson(),
      );
      expect(revised.state.plans[focusId]!.first.plan, focused.plan);
      expect(revised.state.plans[focusId]!.last.version, greaterThan(1));
      final shown = terminal.show(
        revised.state,
        AgentTools.showPlan,
        jsonEncode({'plan_id': focusId, 'note': '保留当前讨论的保存计划。'}),
        language: 'zh',
      );
      expect(shown.rejected, isFalse, reason: shown.response);
      expect(shown.output, isNotNull);
      expect(shown.output!.card!.plan, isNotNull);
      expect(shown.output!.card!.plan!.plan.items, isNotEmpty);
      expect(shown.output!.card!.plan!.savedRef, state.savedRef);
    },
  );

  test('unknown plan metadata cannot create a visible action source', () {
    const focusId = 'ext:metadata';
    const forgedSource = 'h-squat';
    expect(catalog[forgedSource], isNotNull);
    expect(
      const PlanCodec().decode(originalVersion.plan).exerciseIds,
      isNot(contains(forgedSource)),
    );
    final blocks = _list(originalVersion.plan['blocks']).map(_map).toList();
    blocks.first['unrecognizedMetadata'] = {'exerciseId': forgedSource};
    final focused = CoachPlanVersion(
      version: 1,
      plan: {...originalVersion.plan, 'id': focusId, 'blocks': blocks},
      estimateSec: originalVersion.estimateSec,
      fitLog: const [],
    );
    final state = initial().copyWith(
      seenActionIds: const {},
      focusPlanId: focusId,
      plans: {
        focusId: [focused],
      },
    );
    expect(
      nodes.actionProblem(state, forgedSource),
      isNull,
      reason: 'the test targets provenance, not an incompatible action',
    );
    final resumed = nodes.resumeVisiblePlanActions(state);
    expect(resumed.seenActionIds, isNotEmpty);
    expect(resumed.seenActionIds, isNot(contains(forgedSource)));
    expect(resumed.plans[focusId]!.single.plan, focused.plan);
  });
}
