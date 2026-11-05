import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_coach_chat/ugk_coach_chat.dart';

import 'chat_controller_test.dart';
import 'fixtures/legacy_sf_template_plans.dart';

coach.Catalog _currentCatalog() => coach.PoseHubAppTestCatalog.fromBytes(
  File(
    '../ugk_trainer/assets/pose_hub/app-pack-r2-v2/catalog.json',
  ).readAsBytesSync(),
).toAiCatalog();

class _LegacyHarness {
  _LegacyHarness(this.history, {DateTime? now}) {
    final catalog = _currentCatalog();
    controller = CoachChatController(
      catalog: catalog,
      clock: () => now ?? DateTime.utc(2026, 10, 31, 0, 1),
      profile: CoachAppProfile(
        appId: 'legacy-test',
        scopeManifest: coach.CoachActionScopeManifest.fromCatalogBytes(
          appId: 'legacy-test',
          catalogBytes: utf8.encode(jsonEncode(catalog.toJson())),
          allowedActionIds: catalog.drills.map((drill) => drill.id),
        ),
        coachProfile: const coach.CoachProfile(
          id: 'legacy-test',
          appName: '旧档回归',
        ),
        conversationPolicy: coach.CoachScopeConversationPolicy(
          specialty: '全身训练',
          suggestions: ['拉伸'],
        ),
        executionTiming: (plan) => coach.PlanExecutionTiming(
          totalSeconds: 600,
          blocks: [
            for (final block in plan.blocks)
              coach.PlanBlockExecutionTiming(
                blockId: block.id,
                seconds: 600 / plan.blocks.length,
              ),
          ],
          containsManualCounting: false,
        ),
      ),
      bindings: CoachChatBindings(
        storageNamespace: 'legacy-test',
        gateway: CoachGatewayBinding.shared(client),
        plans: plans,
        history: history,
        preferences: preferences,
        actions: CoachChatHostActions(
          onStartTraining: (_, _) async => null,
          onOpenAction: (_, _) async {},
          onOpenLibrary: (_, _) async {},
          onOpenSavedPlans: (_) async {},
          onOpenCustomPlan: (_) async {},
          onOpenSettings: (_) async {},
        ),
      ),
    );
  }

  final ChatHistory history;
  final plans = ChatPlans();
  final preferences = ChatPreferences();
  final client = coach.FakeLlmClient([], latency: Duration.zero);
  late final CoachChatController controller;

  Future<void> close() async {
    await controller.close();
    controller.dispose();
    await plans.updates.close();
    await preferences.updates.close();
  }
}

void main() {
  for (final template in legacySfTemplateRows.entries) {
    test(
      'original SF ${template.key} template stays visible unchanged across boots without granting training',
      () async {
        final row = template.value;
        final originalPlan = row['plan']! as Map;
        final history = ChatHistory()
          ..legacy = CoachChatLegacyData(chat: [row]);
        final first = _LegacyHarness(history);
        addTearDown(first.close);
        final restored = await first.controller.start();
        expect(restored.ok, isTrue, reason: '${restored.error}');
        final card = first.controller.messages.single;
        expect(card.id, row['id']);
        expect(card.plan!.toJson(), originalPlan);
        expect(card.request!.toJson(), row['request']);
        expect(card.validatedPlan, isNull);
        expect(first.controller.currentPlan!.toJson(), originalPlan);
        expect(await first.controller.started(card.plan!), isFalse);
        await expectLater(
          first.controller.savePlanCard(card),
          throwsA(isA<CoachPlanStorageException>()),
        );
        expect(first.plans.writes, isEmpty);
        expect(first.history.remembered, isEmpty);
        expect(first.client.requests, isEmpty);
        await first.controller.close();
        expect(history.snapshot!.messages.single['plan'], originalPlan);

        final next = _LegacyHarness(history);
        addTearDown(next.close);
        expect((await next.controller.start()).ok, isTrue);
        final retained = next.controller.messages.single;
        expect(retained.id, row['id']);
        expect(retained.plan!.toJson(), originalPlan);
        expect(next.controller.currentPlan!.toJson(), originalPlan);
        expect(next.client.requests, isEmpty);
        expect(history.legacy!.chat.single, row);
      },
    );
  }

  test(
    'legacy mixed fixture retains all 12 raw cards and 72 timestamps',
    () async {
      final catalog = _currentCatalog();
      final plan = coach.TrainingPlan(
        id: 'performance_plan_v1',
        source: 'template',
        title: '内测固定全身计划',
        summary: '仅供滑动对照，不会开始训练或下载视频。',
        goal: 'mixed',
        scene: 'home',
        equipment: const [],
        level: 1,
        targetMinutes: 8,
        blocks: [
          coach.PlanBlock(
            id: 'performance_main_v1',
            name: '固定动作组',
            type: coach.BlockType.main,
            items: [
              for (final id in ['h-squat', 'h-calf-raise', 'w-dead-bug'])
                coach.PlanItem(
                  exerciseId: id,
                  mode: catalog[id]!.defaultDose.mode,
                  sets: 1,
                  reps: catalog[id]!.defaultDose.mode == coach.DoseMode.reps
                      ? 10
                      : null,
                  workSeconds:
                      catalog[id]!.defaultDose.mode == coach.DoseMode.time
                      ? 30
                      : null,
                  perSide: catalog[id]!.unilateral,
                  restSeconds: 20,
                ),
            ],
          ),
        ],
      );
      final reference = DateTime.utc(2000, 1, 1, 8);
      final rows = [
        for (var index = 0; index < 72; index++)
          ChatMessage(
            id: 'plan_cards_72_v1_$index',
            role: index.isEven ? ChatRole.user : ChatRole.assistant,
            at: reference.add(Duration(seconds: index * 20)),
            text: '原显示消息 $index',
            plan: index % 6 == 5 ? plan : null,
            request: index % 6 == 5 ? requestForPlan(plan) : null,
          ).toJson(),
      ];
      final history = ChatHistory()..legacy = CoachChatLegacyData(chat: rows);
      final h = _LegacyHarness(
        history,
        now: reference.add(const Duration(minutes: 30)),
      );
      addTearDown(h.close);
      expect((await h.controller.start()).ok, isTrue);
      expect(h.controller.messages, hasLength(72));
      final cards = h.controller.messages.where((message) => message.isPlan);
      expect(cards, hasLength(12));
      expect(
        cards.map((card) => card.plan!.toJson()),
        everyElement(plan.toJson()),
      );
      expect(
        h.controller.messages.map((message) => message.at),
        List.generate(
          72,
          (index) => reference.add(Duration(seconds: index * 20)),
        ),
      );
      expect(h.client.requests, isEmpty);
    },
  );

  test('rejected restored startup hands the source to the host before a fresh '
      'conversation may replace it', () async {
    final source = ChatHarness(
      allowedActionIds: const ['one', 'two', 'three', 'four', 'outside'],
    );
    addTearDown(source.close);
    expect(
      (await source.controller.sendPlanToConversation(
        CoachSavedPlanSnapshot(
          externalId: 'outside-plan',
          title: '其他 App 的已存计划',
          plan: chatPlan(third: 'outside'),
          storageRevision: 'r1',
        ),
      )).ok,
      isTrue,
    );
    final snapshot = source.controller.exportSnapshot();
    final original = snapshot.toJson();
    final history = _PreservingHistory()..snapshot = snapshot;
    var released = 0;
    final target = ChatHarness(history: history, release: () => released++);
    addTearDown(target.close);
    // Degraded start: the chat must stay usable instead of going silent.
    expect((await target.controller.start()).ok, isTrue);
    expect(history.preserved, hasLength(1));
    expect(history.preserved.single.toJson(), original);
    expect(history.writesBeforePreserve, 0);
    expect(
      target.controller.messages.map((m) => m.text),
      contains(const CoachChatStrings().historyUnreadable),
    );
    await target.controller.close();
    expect(history.snapshot!.toJson(), isNot(original));
    expect(released, 1);
  });
}

class _PreservingHistory extends ChatHistory {
  final preserved = <CoachChatSnapshot>[];
  int? writesBeforePreserve;
  @override
  Future<void> preserveUnreadable(
    String namespace,
    CoachChatSnapshot snapshot,
    Object? error,
  ) async {
    writesBeforePreserve ??= writes.length;
    preserved.add(snapshot);
  }
}
