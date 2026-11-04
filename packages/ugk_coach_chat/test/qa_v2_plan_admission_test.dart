import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_coach/ugk_coach_qa_v2.dart' as qa;
import 'package:ugk_coach_chat/ugk_coach_chat.dart';

import 'chat_controller_test.dart' show ChatPlans, ChatHistory, ChatPreferences;

const _mainIds = [
  'h-db-rdl',
  'h-db-press',
  'h-db-curl',
  'h-db-reverse-fly',
  'h-squat',
  'h-suitcase-hold',
];
const _warmIds = ['n-squat-shift', 'h-wall-angel'];
const _coolIds = [
  'h-bilateral-upper-back-hug',
  'h-close-stance-forward-fold-native',
];

void main() {
  test(
    '20 minute home plan admits, plays, saves and restores with actual equipment',
    () async {
      final meta = File(
        '../ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog.json',
      );
      final descriptor = coach.PoseHubAppTestCatalog.fromBytes(
        meta.readAsBytesSync(),
      );
      final all = coach.PoseHubAppTestCatalog.fromBytes(
        meta.readAsBytesSync(),
        semanticCatalogBytes: File(
          '${meta.parent.path}/${descriptor.semanticCatalogFile.path}',
        ).readAsBytesSync(),
      ).toAiCatalog();
      final ids = {..._mainIds, ..._warmIds, ..._coolIds};
      final catalog = coach.Catalog.fromJson({
        ...all.toJson(),
        'drills': [
          for (final d in all.drills)
            if (ids.contains(d.id)) d.toJson(),
        ],
      });
      // Synthetic App configuration: no production tag dataset is bundled.
      final tags = <String, Map<String, Object?>>{
        for (final d in catalog.drills)
          d.id: {
            'format': 'pose-hub-ai-tags@1',
            'requiredEquipment': d.equipment,
            'scenes': ['home', 'gym'],
            'primaryMuscles': d.muscleGroups,
            'stretchedMuscles': d.muscleGroups,
            'trainingType': [
              _mainIds.contains(d.id)
                  ? 'strength'
                  : _warmIds.contains(d.id)
                  ? 'mobility'
                  : 'static-stretch',
            ],
            'sessionRole': [
              _mainIds.contains(d.id)
                  ? 'main'
                  : _warmIds.contains(d.id)
                  ? 'warmup'
                  : 'cooldown',
            ],
            'difficulty': 1,
          },
      };
      final profile = coach.CoachProfile.fromJson(
        jsonDecode(File('../../profiles/smartfit.json').readAsStringSync()),
      );
      final index = qa.QaActionIndex(catalog, aiTags: tags);
      final before = qa.QaPlanBuilder(qa.QaFinder(index, profile: profile)).build(
        mainIds: _mainIds,
        minutes: 20,
        base: qa.QaQuery(
          scene: 'home',
          equipment: {'dumbbell'},
          strict: true,
          types: {'strength'},
        ),
        // v3：热身、收操由模型指定（下面的 build_plan 给同一组）。
        warmIds: _warmIds,
        coolIds: _coolIds,
      );
      final oldDeclaration = const coach.PlanCodec().decodeStrict({
        ...before.plan.toJson(),
        'source': 'ai',
        'summary': 'A complete workout',
        'equipment': ['dumbbell'],
      }).plan!;
      final beforeErrors =
          coach.PlanValidator(catalog: catalog, profile: profile)
              .validate(
                oldDeclaration,
                const coach.CoachContext(
                  scene: 'home',
                  equipment: {'dumbbell'},
                  minutes: 20,
                ),
              )
              .errors;
      expect(beforeErrors.map((i) => (i.code, i.exerciseId)), [
        ('equipment', 'h-wall-angel'),
      ]);
      expect(
        before.plan.items.length,
        lessThanOrEqualTo(profile.limits.maxItems),
      );

      coach.PlanExecutionTiming timing(coach.TrainingPlan plan) =>
          coach.PlanExecutionTiming(
            totalSeconds:
                const coach.PlanDuration().estimateSeconds(plan, catalog) +
                plan.items.length * 10,
            blocks: [
              for (final b in plan.blocks)
                coach.PlanBlockExecutionTiming(blockId: b.id, seconds: 0),
            ],
          );
      final config = CoachAppProfile(
        appId: profile.id,
        scopeManifest: coach.CoachActionScopeManifest.fromCatalogBytes(
          appId: profile.id,
          catalogBytes: utf8.encode(jsonEncode(catalog.toJson())),
          allowedActionIds: ids,
        ),
        coachProfile: profile,
        conversationPolicy: coach.CoachScopeConversationPolicy(
          specialty: 'Training',
          suggestions: ['Workout'],
        ),
        executionTiming: timing,
        agentMode: CoachChatAgentMode.qaV2,
        aiTags: tags,
      );
      coach.LlmResponse call(String name, Map<String, Object?> value) =>
          coach.LlmResponse(
            content: '',
            toolCalls: [
              coach.LlmToolCall(
                id: name,
                name: name,
                arguments: jsonEncode(value),
              ),
            ],
          );
      final client = coach.FakeLlmClient([
        call('set_conditions', {
          'place': 'home',
          'equipment_known': true,
          'equipment': ['dumbbell'],
          'minutes': 20,
        }),
        call('search_actions', {'limit': 12}),
        call('build_plan', {
          'mode': 'new',
          'text': '这套训练按20分钟安排。',
          'title': '全身训练',
          'minutes': 20,
          'main_ids': _mainIds,
          'warmup_ids': _warmIds,
          'cooldown_ids': _coolIds,
          'chips': <String>[],
        }),
      ], latency: Duration.zero);
      final plans = ChatPlans(),
          history = ChatHistory(),
          preferences = ChatPreferences();
      CoachChatController controller(
        coach.LlmClient client,
        CoachChatHistoryStore store,
      ) => CoachChatController(
        profile: config,
        catalog: catalog,
        replyDelay: Duration.zero,
        bindings: CoachChatBindings(
          storageNamespace: 'twenty',
          gateway: CoachGatewayBinding.shared(client),
          plans: plans,
          history: store,
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
      final chat = controller(client, history);
      addTearDown(() async {
        await chat.close();
        chat.dispose();
        await plans.updates.close();
        await preferences.updates.close();
      });
      final result = await chat.send('在家只有哑铃，20 分钟全身');
      expect(result?.status, coach.TurnStatus.ok, reason: '${result?.error}');
      final plan = result!.plan!.plan;
      expect(plan.equipment.toSet(), {'dumbbell', 'wall'});
      expect([for (final i in plan.items) i.exerciseId], before.orderedIds);
      expect(
        const coach.PlanDuration().estimateSeconds(plan, chat.catalog),
        inInclusiveRange(1080, 1320),
      );
      expect(timing(plan).totalSeconds, inInclusiveRange(1080, 1320));
      expect(
        chat.agent.prepareTraining(
          plan,
          context: coach.CoachContext(
            scene: plan.scene,
            equipment: plan.equipment.toSet(),
            minutes: 20,
          ),
        ),
        isNotNull,
      );
      expect(
        (await chat.savePlanCard(chat.messages.last)).plan.toJson(),
        plan.toJson(),
      );
      final snapshot = CoachChatSnapshot.fromJson(
        jsonDecode(jsonEncode(chat.exportSnapshot().toJson()))
            as Map<String, Object?>,
      );
      final restored = controller(coach.FakeLlmClient(const []), ChatHistory());
      addTearDown(() async {
        await restored.close();
        restored.dispose();
      });
      expect((await restored.restoreSnapshot(snapshot)).ok, isTrue);
      expect(
        restored.messages.lastWhere((m) => m.plan != null).plan!.toJson(),
        plan.toJson(),
      );
      expect(restored.qaAgent.state.lastPlan!.plan.toJson(), plan.toJson());
      expect(client.requests, hasLength(3));
    },
  );
}
