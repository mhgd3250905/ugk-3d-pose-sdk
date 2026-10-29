import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';

import 'support.dart';
import 'support_v2_plan_flow.dart';

const _selectionPrefix = '用户从「我的计划」选中了计划（系统生成）：';
const _statePrefix = '当前状态（系统生成）：';
const _mainIds = ['s-kneel-hipflex', 'n-thomas-test', 's-butterfly'];
const _cooldownId = 'h-bilateral-upper-back-hug';
const _freshId = 'n-pelvis-circle';

LlmToolCall _call(String id, String name, Object args) =>
    LlmToolCall(id: id, name: name, arguments: jsonEncode(args));

LlmResponse _calls(List<LlmToolCall> values) => LlmResponse(
  content: '',
  toolCalls: values,
  finishReason: 'tool_calls',
  model: 'fake',
);

Map<String, dynamic> _receipt(LlmRequest request, String id) =>
    jsonDecode(request.messages.lastWhere((m) => m.toolCallId == id).content)
        as Map<String, dynamic>;

Map<String, dynamic> _tail(LlmRequest request) {
  final message = request.messages.last;
  expect(message.role, LlmRole.user);
  expect(message.content, startsWith(_statePrefix));
  return jsonDecode(message.content.substring(_statePrefix.length))
      as Map<String, dynamic>;
}

void main() {
  const base = 'packages/ugk_trainer/assets/pose_hub/app-test-pack-r1';
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('$base/catalog.json').readAsBytesSync(),
    semanticCatalogBytes: File('$base/catalog/catalog.json').readAsBytesSync(),
  ).toAiCatalog();
  final profile = loadProfile('smartfit');

  CoachConversationController controller(
    FakeLlmClient client, {
    ContextBudgetConfig contextBudgetConfig = const ContextBudgetConfig(),
  }) {
    final value = CoachConversationController(
      agent: CoachAgent(
        client: client,
        catalog: () => catalog,
        profile: profile,
        enableUserMemory: false,
        maxRequestRetries: 0,
        contextBudgetConfig: contextBudgetConfig,
      ),
    );
    addTearDown(value.dispose);
    return value;
  }

  PlanItem item(String id, {int workSeconds = 30, int reps = 8}) {
    final drill = catalog[id]!;
    return PlanItem(
      exerciseId: id,
      mode: drill.defaultDose.mode,
      sets: 1,
      workSeconds: drill.defaultDose.mode == DoseMode.time ? workSeconds : null,
      reps: drill.defaultDose.mode == DoseMode.reps ? reps : null,
      perSide: drill.unilateral,
      restSeconds: 10,
    );
  }

  TrainingPlan plan({
    String id = 'host-saved-id',
    String title = '我的髋部放松',
    int workSeconds = 30,
  }) => TrainingPlan(
    id: id,
    source: 'template',
    title: title,
    summary: '按原顺序保存的动作和剂量',
    goal: 'relax',
    scene: 'home',
    equipment: ['mat'],
    level: 1,
    targetMinutes: 10,
    blocks: [
      PlanBlock(
        id: 'saved-main',
        name: '放松',
        type: BlockType.main,
        items: [for (final id in _mainIds) item(id, workSeconds: workSeconds)],
      ),
      PlanBlock(
        id: 'saved-cooldown',
        name: '收尾',
        type: BlockType.cooldown,
        items: [item(_cooldownId)],
      ),
    ],
  );

  void expectCompleteSummary(Object? raw, TrainingPlan source, int version) {
    final focus = raw! as Map;
    expect(focus['plan_id'], startsWith('ext:'));
    expect(focus['version'], version);
    expect(focus['title'], source.title);
    expect(focus['equipment'], source.equipment);
    expect(
      focus['estimateSec'],
      const PlanDuration().estimateSeconds(source, catalog),
    );
    final items = focus['items'] as List;
    final expected = source.items.toList();
    expect(items, hasLength(expected.length));
    for (var i = 0; i < expected.length; i++) {
      final row = items[i] as Map;
      expect(row['index'], i + 1);
      expect(row['actionId'], expected[i].exerciseId);
      expect(row['name'], catalog[expected[i].exerciseId]!.name.of('zh'));
      final dose = row['dose'] as Map;
      for (final entry in expected[i].toJson().entries) {
        if (entry.key != 'exerciseId') expect(dose[entry.key], entry.value);
      }
    }
  }

  List<Object> editScript({
    required List<String> main,
    required String quote,
    int? minutes,
    bool stalePlanId = false,
    int expectedVersion = 2,
  }) => [
    _calls([
      _call('edit-start', AgentTools.startTask, {
        'type': 'plan',
        'reuse': true,
      }),
      _call('edit-params', AgentTools.setParams, {
        'fields': {
          'operation': {'value': 'edit', 'source': 'user', 'quote': quote},
          if (minutes != null)
            'minutes': {
              'value': minutes,
              'source': 'user',
              'quote': '$minutes分钟',
            },
        },
      }),
      if (main.contains(_freshId))
        _call('edit-search', AgentTools.searchActions, {
          'tags': <String>[],
          'keywords': catalog[_freshId]!.name.of('en'),
        }),
    ]),
    (LlmRequest request) {
      final params = _receipt(request, 'edit-params');
      expect(params['ok'], isTrue, reason: '$params');
      if (main.contains(_freshId)) {
        final search = _receipt(request, 'edit-search');
        expect(search['ok'], isTrue, reason: '$search');
      }
      return _calls([
        _call('edit-draft', AgentTools.draftPlan, {
          'plan_id': stalePlanId ? 'ext:A' : 'ext:B',
          'title': '编辑后的髋部放松',
          'blocks': [
            {
              'kind': 'main',
              'items': [
                for (final id in main) {'id': id},
              ],
            },
            {
              'kind': 'cooldown',
              'items': [
                {'id': _cooldownId},
              ],
            },
          ],
        }),
      ]);
    },
    (LlmRequest request) {
      final drafted = _receipt(request, 'edit-draft');
      expect(drafted['ok'], isTrue, reason: '$drafted');
      expect(drafted['plan_id'], 'ext:B');
      expect(drafted['version'], expectedVersion);
      return _calls([
        _call('edit-planning', AgentTools.check, {'node': 'planning'}),
        _call('edit-check', AgentTools.checkPlan, {'plan_id': 'ext:B'}),
      ]);
    },
    (LlmRequest request) {
      final checked = _receipt(request, 'edit-check');
      expect(checked['ok'], isTrue, reason: '$checked');
      return _calls([
        _call('edit-review', AgentTools.check, {'node': 'review'}),
        _call('edit-show', AgentTools.showPlan, {
          'plan_id': 'ext:B',
          'note': '已修改当前讨论计划。',
        }),
      ]);
    },
  ];

  test(
    'focusing a complete external plan is local, observable and model-visible',
    () async {
      final client = FakeLlmClient(['好的，按当前计划讨论。'], latency: Duration.zero);
      final c = controller(client);
      final original = plan();
      final notifications = <CoachPlanFocus?>[];
      c.addListener(() => notifications.add(c.state.focus));
      final result = c.focusExternalPlan(externalId: 'B', plan: original);

      expect(result.ok, isTrue, reason: '${result.errors}');
      expect(result.errors, isEmpty);
      expect(result.planId, 'ext:B');
      expect(result.version, 1);
      expect(client.requests, isEmpty);
      expect(c.agent.sessionState.activePlanId, 'ext:B');
      expect(c.agent.sessionState.focusPlanId, 'ext:B');
      expect(c.focus!.planId, 'ext:B');
      expect(c.state.focus!.title, original.title);
      expect(c.focus!.version, 1);
      expect(c.focus!.savedRef.toJson(), {'externalId': 'B', 'baseVersion': 1});
      expect(notifications, hasLength(1));
      final generated = c.agent.history.lastWhere(
        (m) => m.content.startsWith(_selectionPrefix),
      );
      expect(generated.role, LlmRole.user);
      expectCompleteSummary(
        jsonDecode(generated.content.substring(_selectionPrefix.length)),
        original,
        1,
      );

      await c.send('解释一下这个计划');
      expectCompleteSummary(
        _tail(client.requests.first)['focus_plan'],
        original,
        1,
      );
      expect(
        client.requests.first.messages.first.content,
        contains('focus_plan'),
      );
      expect(
        jsonEncode(
          client.requests.first.tools
              .singleWhere((tool) => tool.name == AgentTools.draftPlan)
              .parameters,
        ),
        contains('sourceIndex'),
      );
    },
  );

  test(
    'unknown actions, invalid dose and invalid structure reject atomically',
    () {
      final client = FakeLlmClient([], latency: Duration.zero);
      final c = controller(client);
      expect(c.focusExternalPlan(externalId: 'A', plan: plan()).ok, isTrue);
      final stateBefore = c.state;
      final factsBefore = jsonEncode(c.agent.sessionState.toJson());
      final historyBefore = jsonEncode(
        c.agent.history.map((m) => m.toJson()).toList(),
      );
      final snapshotBefore = jsonEncode(c.exportSession().toJson());
      var changes = 0;
      c.addListener(() => changes++);
      final invalid = [
        plan().copyWith(
          blocks: [
            PlanBlock(
              id: 'bad',
              name: '无效动作',
              type: BlockType.main,
              items: [
                item(_mainIds.first).copyWith(exerciseId: 'missing-action'),
              ],
            ),
          ],
        ),
        plan().copyWith(
          blocks: [
            PlanBlock(
              id: 'bad',
              name: '无效剂量',
              type: BlockType.main,
              items: [item(_mainIds.first).copyWith(sets: 0)],
            ),
          ],
        ),
        plan().copyWith(blocks: []),
      ];
      for (final value in invalid) {
        final rejected = c.focusExternalPlan(externalId: 'B', plan: value);
        expect(rejected.ok, isFalse);
        expect(rejected.errors, isNotEmpty);
        expect(rejected.planId, isNull);
        expect(rejected.version, isNull);
        expect(identical(c.state, stateBefore), isTrue);
        expect(jsonEncode(c.agent.sessionState.toJson()), factsBefore);
        expect(
          jsonEncode(c.agent.history.map((m) => m.toJson()).toList()),
          historyBefore,
        );
        expect(jsonEncode(c.exportSession().toJson()), snapshotBefore);
      }
      expect(changes, 0);
      expect(client.requests, isEmpty);
    },
  );

  test('same external content reuses its version; changed content appends', () {
    final c = controller(FakeLlmClient([], latency: Duration.zero));
    final original = plan();
    final first = c.focusExternalPlan(externalId: 'B', plan: original);
    expect(first.ok, isTrue);
    final initialVersion = c.agent.sessionState.plans['ext:B']!.single;
    final same = c.focusExternalPlan(
      externalId: 'B',
      plan: original.copyWith(id: 'different-host-object-id'),
    );
    expect(same.ok, isTrue);
    expect(same.version, 1);
    expect(c.agent.sessionState.plans['ext:B'], hasLength(1));
    final changed = c.focusExternalPlan(
      externalId: 'B',
      plan: plan(workSeconds: 40),
    );
    expect(changed.ok, isTrue, reason: '${changed.errors}');
    expect(changed.version, 2);
    expect(c.agent.sessionState.plans['ext:B'], hasLength(2));
    expect(
      c.agent.sessionState.plans['ext:B']!.first.toJson(),
      initialVersion.toJson(),
    );
    expect(c.focus!.version, 2);
    expect(c.focus!.savedRef.baseVersion, 2);
    final repeated = c.focusExternalPlan(
      externalId: 'B',
      plan: plan(workSeconds: 40),
    );
    expect(repeated.version, 2);
    expect(c.agent.sessionState.plans['ext:B'], hasLength(2));
  });

  test(
    'clearPlanFocus retains plans and removes only current focus from the next tail',
    () async {
      final client = FakeLlmClient(['现在没有指定讨论计划。'], latency: Duration.zero);
      final c = controller(client);
      c.focusExternalPlan(externalId: 'B', plan: plan());
      final versions = c.agent.sessionState.plans['ext:B'];
      var notifications = 0;
      c.addListener(() => notifications++);
      c.clearPlanFocus();
      expect(c.focus, isNull);
      expect(c.state.focus, isNull);
      expect(c.agent.sessionState.focusPlanId, isNull);
      expect(c.agent.sessionState.savedRef, isNull);
      expect(c.agent.sessionState.plans['ext:B'], versions);
      expect(notifications, 1);
      expect(client.requests, isEmpty);
      await c.send('聊聊日常活动');
      expect(_tail(client.requests.last).containsKey('focus_plan'), isFalse);
    },
  );

  for (final operation in [
    'replace third',
    'insert',
    'delete',
    'five minutes',
  ]) {
    test(
      'focus edits $operation append B while A and the imported B remain intact',
      () async {
        final main = switch (operation) {
          'replace third' => [_mainIds[0], _mainIds[1], _freshId],
          'insert' => [_mainIds[0], _freshId, _mainIds[1], _mainIds[2]],
          'delete' => [_mainIds[0], _mainIds[2]],
          _ => _mainIds,
        };
        final quote = switch (operation) {
          'replace third' => '替换第3个动作',
          'insert' => '插入一个动作',
          'delete' => '删除第2个动作',
          _ => '缩到5分钟',
        };
        final client = FakeLlmClient(
          editScript(
            main: main,
            quote: quote,
            minutes: operation == 'five minutes' ? 5 : null,
            stalePlanId: operation == 'replace third',
          ),
          latency: Duration.zero,
        );
        final c = controller(client);
        expect(
          c
              .focusExternalPlan(
                externalId: 'A',
                plan: plan(title: '先前的计划A'),
              )
              .ok,
          isTrue,
        );
        final aBefore = jsonEncode(
          c.agent.sessionState.plans['ext:A']!.map((v) => v.toJson()).toList(),
        );
        expect(c.focusExternalPlan(externalId: 'B', plan: plan()).ok, isTrue);
        final bBefore = c.agent.sessionState.plans['ext:B']!.single.toJson();
        final result = await c.send(quote);
        expect(
          result!.status,
          TurnStatus.ok,
          reason: '${result.error}; ${result.issues}',
        );
        expect(result.plan, isNotNull, reason: '${result.issues}');
        final updated = result.plan!;
        expect(updated.plan.id, 'ext:B');
        expect(updated.version, 2);
        expect(updated.savedRef!.toJson(), {
          'externalId': 'B',
          'baseVersion': 1,
        });
        expect(updated.plan.items.map((item) => item.exerciseId), [
          ...main,
          _cooldownId,
        ]);
        if (operation == 'five minutes') {
          expect(updated.plan.targetMinutes, 5);
          expect(
            const PlanDuration().estimateSeconds(updated.plan, catalog),
            inInclusiveRange(270, 330),
          );
        }
        expect(
          jsonEncode(
            c.agent.sessionState.plans['ext:A']!
                .map((v) => v.toJson())
                .toList(),
          ),
          aBefore,
        );
        expect(c.agent.sessionState.plans['ext:B'], hasLength(2));
        expect(c.agent.sessionState.plans['ext:B']!.first.toJson(), bBefore);
        expect(c.focus!.planId, 'ext:B');
        expect(c.focus!.version, 2);
        expect(c.focus!.savedRef.baseVersion, 1);
        final card = c.state.messages
            .lastWhere((message) => message.plan != null)
            .plan!;
        expect(card.version, 2);
        expect(card.savedRef!.externalId, 'B');
        for (final request in client.requests) {
          expect((_tail(request)['focus_plan'] as Map)['plan_id'], 'ext:B');
        }
      },
    );
  }

  test(
    'export and restore preserve focus versions, provenance and continuation',
    () async {
      final original = controller(
        FakeLlmClient(
          editScript(
            main: [_mainIds[0], _mainIds[1], _freshId],
            quote: '替换第3个动作',
          ),
          latency: Duration.zero,
        ),
      );
      original.focusExternalPlan(externalId: 'B', plan: plan());
      final edited = await original.send('替换第3个动作');
      expect(
        edited!.plan,
        isNotNull,
        reason: '${edited.issues}; ${edited.error}',
      );
      final snapshot = CoachSessionSnapshot.fromJson(
        jsonDecode(jsonEncode(original.exportSession().toJson())),
      );
      expect(snapshot.isValid, isTrue, reason: snapshot.invalidReason);
      final client = FakeLlmClient(
        editScript(
          main: [_mainIds[0], _freshId],
          quote: '删除第2个动作',
          expectedVersion: 3,
        ),
        latency: Duration.zero,
      );
      final restored = controller(client)
        ..restoreSession(snapshot, original.state.messages);
      expect(client.requests, isEmpty);
      expect(restored.focus!.planId, 'ext:B');
      expect(restored.focus!.version, 2);
      expect(restored.focus!.savedRef.toJson(), {
        'externalId': 'B',
        'baseVersion': 1,
      });
      expect(restored.agent.sessionState.activePlanId, 'ext:B');
      expect(restored.agent.sessionState.plans['ext:B'], hasLength(2));
      expect(
        restored.exportSession().sessionState.toJson(),
        snapshot.sessionState.toJson(),
      );
      final continuation = await restored.send('删除第2个动作');
      expect(
        continuation!.plan,
        isNotNull,
        reason: '${continuation.issues}; ${continuation.error}',
      );
      expect(continuation.plan!.version, 3);
      expect(continuation.plan!.savedRef!.baseVersion, 1);
      expect(restored.agent.sessionState.plans['ext:B'], hasLength(3));
      expectCompleteSummary(
        _tail(client.requests.first)['focus_plan'],
        edited.plan!.plan,
        2,
      );
    },
  );

  test(
    'folding completed history keeps the complete focus in every generated state',
    () async {
      final client = FakeLlmClient(
        List<Object>.generate(
          7,
          (i) => LlmResponse(content: '训练知识说明$i。${'保持日常活动。' * 35}'),
        ),
        latency: Duration.zero,
      );
      final c = controller(
        client,
        contextBudgetConfig: const ContextBudgetConfig(
          softOffBytes: 1000,
          softOnBytes: 1000,
          hardBytes: 65536,
        ),
      );
      final original = plan();
      expect(c.focusExternalPlan(externalId: 'B', plan: original).ok, isTrue);
      for (var i = 0; i < 7; i++) {
        final result = await c.send('解释第$i个常识');
        expect(result!.status, TurnStatus.ok, reason: '${result.error}');
      }
      expect(c.agent.contextRequestDiagnostics.any((d) => d.folded), isTrue);
      for (final request in client.requests) {
        expectCompleteSummary(_tail(request)['focus_plan'], original, 1);
      }
    },
  );

  test(
    'clearing focus cancels an in-flight edit and late delivery cannot revive it',
    () async {
      final pendingResponse = Completer<Object>();
      final requestStarted = Completer<void>();
      addTearDown(() {
        if (!pendingResponse.isCompleted) {
          pendingResponse.complete(const LlmResponse(content: '已取消。'));
        }
      });
      final client = FakeLlmClient([
        ...editScript(
          main: [_mainIds[0], _mainIds[1], _freshId],
          quote: '替换第3个动作',
        ).take(3),
        (LlmRequest request) {
          final checked = _receipt(request, 'edit-check');
          expect(checked['ok'], isTrue, reason: '$checked');
          requestStarted.complete();
          return pendingResponse.future;
        },
        '已回到普通对话。',
      ], latency: Duration.zero);
      final c = controller(client);
      expect(c.focusExternalPlan(externalId: 'B', plan: plan()).ok, isTrue);
      final plansBefore = jsonEncode(c.agent.sessionState.toJson()['plans']);
      final historyBefore = c.agent.history.map((m) => m.toJson()).toList();
      final viewBefore = c.state.messages;
      final edit = c.send('替换第3个动作');
      await requestStarted.future;
      expect(c.state.isWaiting, isTrue);
      expect(c.agent.sessionState.plans['ext:B'], hasLength(2));

      expect(c.clearPlanFocus(), isTrue);
      expect(c.focus, isNull);
      expect(c.state.focus, isNull);
      expect(c.state.isWaiting, isFalse);
      expect(c.agent.isBusy, isFalse);
      expect(jsonEncode(c.agent.sessionState.toJson()['plans']), plansBefore);
      expect(c.agent.history.map((m) => m.toJson()), historyBefore);
      expect(c.state.messages, viewBefore);
      expect(await edit.timeout(const Duration(seconds: 2)), isNull);
      final exported = c.exportSession().toJson()['sessionState']! as Map;
      expect(exported.containsKey('focusPlanId'), isFalse);
      expect(exported.containsKey('savedRef'), isFalse);

      // The cancelled transport may still be unresolved when a new send starts.
      final next = await c.send('聊聊日常活动');
      expect(next!.status, TurnStatus.ok, reason: '${next.error}');
      expect(_tail(client.requests.last).containsKey('focus_plan'), isFalse);
      expect(
        client.requests.last.messages.first.content,
        isNot(contains('focus_plan')),
      );
      expect(
        jsonEncode(
          client.requests.last.tools
              .singleWhere((tool) => tool.name == AgentTools.draftPlan)
              .parameters,
        ),
        isNot(contains('sourceIndex')),
      );
      final viewAfterNext = c.state.messages;
      final historyAfterNext = c.agent.history.map((m) => m.toJson()).toList();
      pendingResponse.complete(
        _calls([
          _call('late-review', AgentTools.check, {'node': 'review'}),
          _call('late-show', AgentTools.showPlan, {
            'plan_id': 'ext:B',
            'note': '迟到的新版。',
          }),
        ]),
      );
      await Future<void>.delayed(Duration.zero);
      expect(c.focus, isNull);
      expect(c.state.messages, viewAfterNext);
      expect(c.agent.history.map((m) => m.toJson()), historyAfterNext);
      expect(jsonEncode(c.agent.sessionState.toJson()['plans']), plansBefore);
      expect(c.state.messages.where((m) => m.plan != null), isEmpty);
    },
  );

  test(
    'focused preset fallback retains version and host save provenance',
    () async {
      final localCatalog = loadCatalog();
      final client = FakeLlmClient([
        _calls([
          _call('start', AgentTools.startTask, {'type': 'plan'}),
        ]),
        const LlmException(LlmErrorKind.network, 'offline'),
      ], latency: Duration.zero);
      final c = CoachConversationController(
        agent: CoachAgent(
          client: client,
          catalog: () => localCatalog,
          profile: loadProfile('hiplab'),
          maxRequestRetries: 0,
          enableUserMemory: false,
        ),
      );
      addTearDown(c.dispose);
      final saved = const PlanCodec().decode(
        planOf(okEnvelope())..['id'] = 'ordinary-template-id',
      );
      expect(c.focusExternalPlan(externalId: 'host-b', plan: saved).ok, isTrue);
      final base = c.agent.sessionState.plans['ext:host-b']!.single.toJson();
      final failed = await c.send('修改这个计划');
      expect(failed!.status, TurnStatus.error);
      expect(failed.isPlanningFailure, isTrue);
      expect(c.canOfferPreset(saved), isTrue);
      final requestsBeforePreset = client.requests.length;

      final selected = c.requestPreset(saved);
      expect(selected, isNotNull);
      expect(selected!.status, TurnStatus.fallback);
      expect(selected.plan, isNotNull);
      expect(selected.plan!.plan.id, 'ext:host-b');
      expect(selected.plan!.version, 2);
      expect(selected.plan!.savedRef!.toJson(), {
        'externalId': 'host-b',
        'baseVersion': 1,
      });
      expect(c.focus!.version, 2);
      expect(c.focus!.savedRef.baseVersion, 1);
      expect(c.agent.sessionState.plans['ext:host-b'], hasLength(2));
      expect(c.agent.sessionState.plans['ext:host-b']!.first.toJson(), base);
      expect(
        c.agent.sessionState.plans.containsKey('ordinary-template-id'),
        isFalse,
      );
      final card = c.state.messages.lastWhere((m) => m.plan != null);
      expect(card.plan!.version, 2);
      expect(card.plan!.savedRef!.externalId, 'host-b');
      expect(card.planState!.sessionState!.savedRef!.baseVersion, 1);
      expect(client.requests, hasLength(requestsBeforePreset));
    },
  );

  test(
    'directly constructed corrupt focus snapshots fall back without throwing',
    () {
      final c = controller(FakeLlmClient([], latency: Duration.zero));
      expect(c.focusExternalPlan(externalId: 'B', plan: plan()).ok, isTrue);
      final valid = c.exportSession();
      final old = valid.sessionState.plans['ext:B']!.single;
      final invalid = CoachSessionSnapshot(
        sessionState: valid.sessionState.copyWith(
          plans: {
            'ext:B': [
              CoachPlanVersion(
                version: old.version,
                plan: {...old.plan, 'title': 12},
                estimateSec: old.estimateSec,
                fitLog: const [],
              ),
            ],
          },
        ),
        ledger: valid.ledger,
      );
      expect(() => c.restoreSession(invalid, []), returnsNormally);
      expect(c.focus, isNull);
      expect(c.agent.sessionState.focusPlanId, isNull);
    },
  );

  test(
    'legacy restoreHistory without session state sets the active plan',
    () async {
      final flow = ScriptedV2PlanFlow(catalog);
      final first = controller(
        FakeLlmClient(flow.initial(), latency: Duration.zero),
      );
      final result = await first.send('在家有瑜伽垫，10分钟做髋部放松');
      expect(
        result!.plan,
        isNotNull,
        reason: '${result.issues}; ${result.error}',
      );
      final legacyMessages = [
        for (final message in first.state.messages)
          CoachConversationMessage(
            id: message.id,
            at: message.at,
            isUser: message.isUser,
            text: message.text,
            plan: message.plan,
          ),
      ];
      final restored = controller(FakeLlmClient([], latency: Duration.zero))
        ..restoreHistory(legacyMessages);
      expect(restored.agent.sessionState.activePlanId, result.plan!.plan.id);
      expect(
        restored.agent.sessionState.plans[result.plan!.plan.id],
        isNotEmpty,
      );
      expect(restored.focus, isNull);
    },
  );
}
