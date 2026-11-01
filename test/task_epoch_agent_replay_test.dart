import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
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
  final inputs = _list(fixture['inputs']).cast<String>();
  final batches = _list(fixture['batches']).map(_map).toList();
  LlmResponse recorded(int call) => LlmResponse(
    content: '',
    model: 'recorded-public-tools',
    finishReason: 'tool_calls',
    toolCalls: [
      for (final raw in _list(
        batches.singleWhere((batch) => batch['modelCall'] == call)['tools'],
      ))
        LlmToolCall(
          id: _map(raw)['id']! as String,
          name: _map(raw)['name']! as String,
          arguments: jsonEncode(_map(raw)['arguments']),
        ),
    ],
  );
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File(
      'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog.json',
    ).readAsBytesSync(),
    semanticCatalogBytes: File(
      'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog/catalog.json',
    ).readAsBytesSync(),
  ).toAiCatalog();
  final profile = loadProfile('smartfit');
  CoachAgent coach(FakeLlmClient client) {
    final agent = CoachAgent(
      client: client,
      catalog: () => catalog,
      profile: profile,
      enableUserMemory: false,
      maxRequestRetries: 0,
    );
    addTearDown(agent.dispose);
    return agent;
  }

  test(
    'SF five-3 public three-turn replay keeps A then edits its own version',
    () async {
      // C9/C10 were retries after the original bad C8 rejection. A corrected C8
      // completes the recommendation, so those obsolete retry calls are not a
      // fourth user turn and are not replayed into the following edit request.
      final client = FakeLlmClient([
        for (var call = 1; call <= 8; call++) recorded(call),
        for (var call = 11; call <= 14; call++) recorded(call),
      ], latency: Duration.zero);
      final agent = coach(client);
      final first = await agent.send(inputs[0]);
      expect(
        first.status,
        TurnStatus.ok,
        reason: '${first.issues} ${first.error}',
      );
      expect(first.plan, isNotNull);
      expect(first.plan!.plan.items, isNotEmpty);
      final firstPlan = first.plan!.plan;
      final firstJson = jsonEncode(firstPlan.toJson());
      final firstId = firstPlan.id;
      expect(agent.sessionState.plans[firstId], hasLength(1));
      final second = await agent.send(inputs[1]);
      expect(
        second.status,
        TurnStatus.ok,
        reason: '${second.issues} ${second.error}',
      );
      expect(second.plan, isNull);
      expect(second.actions, isNotNull);
      expect(second.actions!.items, isNotEmpty);
      expect(second.actions!.items.map((action) => action.id), [
        's-butterfly',
        'h-butterfly-active',
        'h-adductor-rock',
      ]);
      expect(agent.sessionState.plans.keys, [firstId]);
      expect(agent.sessionState.plans[firstId], hasLength(1));
      expect(
        jsonEncode(agent.sessionState.plans[firstId]!.first.plan),
        firstJson,
      );
      expect(agent.sessionState.lastDeliveredPlanId, firstId);
      expect(agent.sessionState.lastDeliveredVersion, 1);
      final third = await agent.send(inputs[2]);
      expect(
        third.status,
        TurnStatus.ok,
        reason: '${third.issues} ${third.error}',
      );
      expect(third.plan, isNotNull);
      expect(third.plan!.plan.items, isNotEmpty);
      expect(third.plan!.plan.id, firstId);
      expect(third.plan!.plan.targetMinutes, 5);
      expect(
        catalog.ids.toSet().containsAll(third.plan!.plan.exerciseIds),
        isTrue,
      );
      expect(agent.sessionState.plans.keys, [firstId]);
      expect(agent.sessionState.plans[firstId]!.last.version, greaterThan(1));
      expect(
        jsonEncode(agent.sessionState.plans[firstId]!.first.plan),
        firstJson,
      );
      expect(client.remaining, 0);
      expect(client.requests, hasLength(12));
    },
  );
}
