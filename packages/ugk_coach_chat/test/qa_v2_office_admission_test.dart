import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_coach/ugk_coach_qa_v2.dart' as qa;
import 'package:ugk_coach_chat/ugk_coach_chat.dart';

import 'chat_controller_test.dart' show ChatPlans, ChatHistory, ChatPreferences;

const _fold = 'h-close-stance-forward-fold-native';
const _groups = [
  ['n-chair-wiper', 'o-seated-fig4', 'o-seated-sidebend'],
  // The device group also named o-stand-ham, o-supported-hip-ir and the fold;
  // with these synthetic tags only these two reach the model's candidate list.
  // The full device list is exercised at builder level above.
  ['o-stand-crossreach', 'n-wide-fold'],
];
const _floor = {'supine', 'prone', 'quadruped', 'kneeling', 'side_lying'};

/// Regression for SF office plans: the App tag for [_fold] lists office while
/// the App catalogue lists only home/gym. QA selection, refit, delivery and
/// restore must all reach the same core verdict instead of the plan being
/// assembled under tags and rejected by the core gate.
void main() {
  final meta = File(
    '../ugk_trainer/assets/pose_hub/app-test-pack-r1/catalog.json',
  );
  final descriptor = coach.PoseHubAppTestCatalog.fromBytes(
    meta.readAsBytesSync(),
  );
  final catalog = coach.PoseHubAppTestCatalog.fromBytes(
    meta.readAsBytesSync(),
    semanticCatalogBytes: File(
      '${meta.parent.path}/${descriptor.semanticCatalogFile.path}',
    ).readAsBytesSync(),
  ).toAiCatalog();
  final profile = coach.CoachProfile.fromJson(
    jsonDecode(File('../../profiles/smartfit.json').readAsStringSync()),
  );
  // Synthetic tags mirroring SF's: catalogue facts, except the fold also
  // claims office (as SF's ai-tags row does).
  final tags = <String, Map<String, Object?>>{
    for (final d in catalog.drills)
      d.id: {
        'format': 'pose-hub-ai-tags@1',
        'requiredEquipment': d.equipment,
        'scenes': [...d.scenes, if (d.id == _fold) 'office'],
        'floorRequired': _floor.contains(d.position),
        'space': 'in-place',
        'primaryMuscles': d.muscleGroups,
        'stretchedMuscles': d.id == _fold
            ? ['hamstrings', 'erectors', 'calves']
            : d.muscleGroups,
        'trainingType': [
          switch (d.category) {
            'stretch' => 'static-stretch',
            'mobility' => 'mobility',
            _ => 'strength',
          },
        ],
        'sessionRole': [
          switch (d.category) {
            'stretch' => 'cooldown',
            'mobility' => 'warmup',
            _ => 'main',
          },
        ],
        'difficulty': 1,
      },
  };
  coach.PlanExecutionTiming timing(coach.TrainingPlan plan) =>
      coach.PlanExecutionTiming(
        totalSeconds: const coach.PlanDuration().estimateSeconds(plan, catalog),
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
      allowedActionIds: {for (final d in catalog.drills) d.id},
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

  test('QA selection uses the core verdict for the office fold', () {
    final finder = qa.QaFinder(
      qa.QaActionIndex(catalog, aiTags: tags),
      profile: profile,
    );
    final fold = finder.index[_fold]!;
    expect(fold.scenes, contains('office'));
    expect(
      finder.admission.problem(
        _fold,
        scene: 'office',
        equipment: fold.requiredEquipment,
        avoid: const [],
      ),
      isNotNull,
    );
    final office = qa.QaQuery(
      scene: 'office',
      equipment: const {},
      strict: true,
      noFloor: true,
      smallSpace: true,
    );
    expect(finder.passes(fold, office), isFalse);
    expect(finder.inScope(office).map((a) => a.id), isNot(contains(_fold)));

    // The SF device group named the fold directly: the builder's scope check
    // is the same verdict, so the delivered card and its refit agree.
    final builder = qa.QaPlanBuilder(finder);
    final built = builder.build(
      mainIds: const [
        'o-stand-crossreach',
        'n-wide-fold',
        'o-stand-ham',
        'o-supported-hip-ir',
        _fold,
      ],
      minutes: 15,
      base: office.copyWith(types: const {'static-stretch', 'mobility'}),
    );
    expect(built.orderedIds, isNot(contains(_fold)));
    final decoded = const coach.PlanCodec().decodeStrict({
      ...built.plan.toJson(),
      'source': 'ai',
      'summary': 'office',
    }).plan!;
    final fitted = builder.fitForExecution(
      decoded,
      profile: profile,
      executionTiming: timing,
    );
    expect(
      fitted.seconds,
      inInclusiveRange((15 * 60 * .9).floor(), (15 * 60 * 1.1).ceil()),
    );
  });

  for (final mainIds in _groups) {
    test('office chair stretch plan ${mainIds.first} admits, fits and '
        'restores under its stored conditions', () async {
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
        call('fill_form', {
          'language': 'zh',
          'intent': 'plan',
          'answer_status': 'none',
          'place': 'office',
          'place_word': '公司',
          'equipment_known': true,
          'equipment': <String>[],
          'no_floor': true,
          'small_space': true,
          'stretch_muscles': [
            'hip-flexors',
            'hip-rotators',
            'erectors',
            'quadriceps',
            'hamstrings',
            'glute-max',
            'obliques',
            'hip-abductors',
            'adductors',
          ],
          'types': ['static-stretch', 'mobility'],
          'minutes': 15,
          'next': 'answer',
        }),
        call('build_plan', {
          'title': '办公室拉伸',
          'text': '按15分钟安排。',
          'minutes': 15,
          'main_ids': mainIds,
          'block_names': {'warmup': '热身', 'main': '拉伸', 'cooldown': '放松'},
          'chips': ['再来'],
        }),
        // 代码先退回「时长对不上」的原因；模型坚持原样重交，代码才按原因补动作。
        call('build_plan', {
          'title': '办公室拉伸',
          'text': '按15分钟安排。',
          'minutes': 15,
          'main_ids': mainIds,
          'block_names': {'warmup': '热身', 'main': '拉伸', 'cooldown': '放松'},
          'chips': ['再来'],
        }),
      ], latency: Duration.zero);
      final plans = ChatPlans(),
          history = ChatHistory(),
          preferences = ChatPreferences();
      final events = <(String, Object?)>[];
      CoachChatController controller(
        coach.LlmClient client,
        CoachChatHistoryStore store,
      ) => CoachChatController(
        profile: config,
        catalog: catalog,
        replyDelay: Duration.zero,
        bindings: CoachChatBindings(
          storageNamespace: 'office',
          observer: (event, detail) => events.add((event, detail)),
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
      final result = await chat.send('帮我做成一个训练组');
      expect(result?.status, coach.TurnStatus.ok, reason: '${result?.error}');
      final plan = result!.plan!.plan;
      expect(plan.scene, 'office');
      expect(plan.exerciseIds, isNot(contains(_fold)));
      final seconds = const coach.PlanDuration().estimateSeconds(
        plan,
        chat.catalog,
      );
      expect(seconds, inInclusiveRange(15 * 60 * .9, 15 * 60 * 1.1));
      expect(
        chat.agent.prepareTraining(
          plan,
          context: coach.CoachContext(
            scene: plan.scene,
            equipment: plan.equipment.toSet(),
            avoid: plan.avoid,
            minutes: 15,
          ),
        ),
        isNotNull,
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
      final outcome = await restored.restoreSnapshot(snapshot);
      expect(outcome.ok, isTrue, reason: '$outcome');
      expect(
        restored.messages.lastWhere((m) => m.plan != null).plan!.toJson(),
        plan.toJson(),
      );
      expect(restored.qaAgent.state.lastPlan!.plan.toJson(), plan.toJson());

      // A failed turn reports a bounded message through the observer.
      expect(await restored.send('再来一组'), isNotNull);
      final error = events.lastWhere((e) => e.$1 == 'chat.turn.error').$2;
      expect(error, isA<Map<String, Object?>>());
      final detail = error! as Map<String, Object?>;
      expect(detail['errorType'], isNotEmpty);
      expect((detail['message']! as String).length, inInclusiveRange(1, 300));
    });
  }
}
