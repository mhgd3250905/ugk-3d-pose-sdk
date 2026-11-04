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
      'test/fixtures/pose_hub/r1-v3/catalog.json',
    ).readAsBytesSync(),
    semanticCatalogBytes: File(
      'test/fixtures/pose_hub/r1-v3/catalog/catalog.json',
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
}
