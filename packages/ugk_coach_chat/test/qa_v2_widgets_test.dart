import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_coach_chat/ugk_coach_chat.dart';
import 'package:ugk_coach_chat/src/ui/plan_card.dart';

import 'chat_controller_test.dart'
    show ChatPlans, ChatHistory, ChatPreferences, chatCatalog;

coach.LlmResponse _call(String tool, Map<String, Object?> args) =>
    coach.LlmResponse(
      content: '',
      toolCalls: [
        coach.LlmToolCall(id: tool, name: tool, arguments: jsonEncode(args)),
      ],
    );

Future<void> _pump(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 1)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pump();
}

void main() {
  testWidgets(
    'QA page renders model choices, numbered cards, assumptions and venue chip',
    (tester) async {
      tester.view.physicalSize = const Size(430, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final client = coach.FakeLlmClient([
        _call('ask_user', {
          'step': 'place',
          'question': '你想在哪里练？',
          'options': ['居家', '健身房', '办公室', '直接推荐'],
        }),
        _call('set_conditions', {'place': 'home'}),
        _call('ask_user', {
          'step': 'equipment',
          'question': '手边有哪些器械？',
          'options': ['哑铃', '瑜伽垫', '椅子', '弹力带', '徒手', '直接推荐'],
          'multi': true,
        }),
        _call('set_conditions', {
          'equipment_known': true,
          'equipment': <String>[],
        }),
        _call('reply', {
          'text': '试试这两个动作。',
          'items': [
            {'id': 'one', 'why': '适合当前条件'},
            {'id': 'two', 'why': '动作温和'},
          ],
          'chips': ['换场地'],
        }),
        _call('show_actions', {
          'text': '继续按这些条件。',
          'items': [
            {'id': 'one', 'why': '适合当前条件'},
            {'id': 'two', 'why': '动作温和'},
            {'id': 'three', 'why': '动作温和'},
          ],
          'assumption': '按在家徒手安排',
          'chips': ['换场地'],
        }),
        _call('set_conditions', {'place': 'unknown'}),
        _call('ask_user', {
          'step': 'place',
          'question': '换到哪里练？',
          'options': ['居家', '健身房', '办公室', '直接推荐'],
        }),
      ], latency: Duration.zero);
      final catalog = chatCatalog();
      final stores = (await tester.runAsync(
        () async => (ChatPlans(), ChatPreferences()),
      ))!;
      final (plans, preferences) = stores;
      final controller = (await tester.runAsync(() async {
        final value = CoachChatController(
          profile: CoachAppProfile(
            appId: 'chat-test',
            scopeManifest: coach.CoachActionScopeManifest.fromCatalogBytes(
              appId: 'chat-test',
              catalogBytes: utf8.encode(jsonEncode(catalog.toJson())),
              allowedActionIds: ['one', 'two', 'three', 'four'],
            ),
            coachProfile: const coach.CoachProfile(
              id: 'chat-test',
              appName: '训练助手',
            ),
            conversationPolicy: coach.CoachScopeConversationPolicy(
              specialty: '训练',
              suggestions: ['练背'],
            ),
            executionTiming: (_) => coach.PlanExecutionTiming(
              totalSeconds: 300,
              blocks: [],
              containsManualCounting: false,
            ),
            agentMode: CoachChatAgentMode.qaV2,
            visual: const CoachChatVisuals(
              showStars: false,
              animateBackground: false,
            ),
          ),
          catalog: catalog,
          replyDelay: Duration.zero,
          clock: () => DateTime(2026, 11, 4, 12),
          bindings: CoachChatBindings(
            storageNamespace: 'qa-widgets',
            gateway: CoachGatewayBinding.shared(client),
            plans: plans,
            history: ChatHistory(),
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
        expect((await value.start()).ok, isTrue);
        return value;
      }))!;
      await tester.pumpWidget(
        MaterialApp(home: CoachChatPage(controller: controller)),
      );
      await _pump(tester);
      await tester.enterText(find.byKey(const ValueKey('chat-input')), '想练背');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('chat-send')));
      await _pump(tester);
      final place = controller.messages.last;
      expect(place.question!.multiple, isFalse);
      expect(find.text('你想在哪里练？'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('question-option-${place.id}-0')));
      await _pump(tester);
      final equipment = controller.messages.last;
      expect(equipment.question!.multiple, isTrue);
      expect(place.id, isNot(equipment.id));
      expect(
        controller.canAnswerQuestion(
          controller.messages.firstWhere((m) => m.id == place.id),
        ),
        isFalse,
      );
      await tester.ensureVisible(
        find.byKey(ValueKey('question-option-${equipment.id}-4')),
      );
      await tester.tap(
        find.byKey(ValueKey('question-option-${equipment.id}-4')),
      );
      await _pump(tester);
      expect(
        client.requests,
        hasLength(3),
        reason: 'Multi-select waits for Submit',
      );
      await tester.ensureVisible(
        find.byKey(ValueKey('question-submit-${equipment.id}')),
      );
      await tester.tap(find.byKey(ValueKey('question-submit-${equipment.id}')));
      await _pump(tester);
      expect(controller.messages.where((m) => m.isUser).map((m) => m.text), [
        '想练背',
        '居家',
        '徒手',
      ]);
      expect(find.byKey(const ValueKey('recommend-number-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('recommend-number-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('recommend-number-3')), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('chat-input')), '再推荐');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('chat-send')));
      await _pump(tester);
      final recommendation = controller.messages.last;
      expect(find.text('按在家徒手安排'), findsOneWidget);
      final chip = find.byKey(
        ValueKey('coach-quick-action-${recommendation.id}-0'),
      );
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await _pump(tester);
      expect(controller.messages.where((m) => m.isUser).last.text, '换场地');
      expect(find.text('换到哪里练？'), findsOneWidget);
      expect(client.requests, hasLength(8));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      var closed = false;
      unawaited(controller.close().then((_) => closed = true));
      for (var i = 0; i < 10 && !closed; i++) {
        await _pump(tester);
      }
      expect(closed, isTrue);
      controller.dispose();
      unawaited(plans.updates.close());
      unawaited(preferences.updates.close());
    },
  );

  for (final numbers in [false, true]) {
    testWidgets(
      'plan numbering includes warmup and cooldown, enabled=$numbers',
      (tester) async {
        tester.view.physicalSize = const Size(430, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final original = coach.TrainingPlan(
          id: 'qa-numbering',
          source: 'template',
          title: '全程计划',
          goal: 'relax',
          scene: 'home',
          level: 1,
          targetMinutes: 5,
          blocks: [
            for (final (kind, id) in [
              (coach.BlockType.warmup, 'one'),
              (coach.BlockType.main, 'two'),
              (coach.BlockType.cooldown, 'three'),
            ])
              coach.PlanBlock(
                id: kind.name,
                name: kind.name,
                type: kind,
                items: [
                  coach.PlanItem(
                    exerciseId: id,
                    mode: coach.DoseMode.time,
                    sets: 1,
                    workSeconds: 90,
                    perSide: false,
                    restSeconds: 0,
                  ),
                ],
              ),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            home: CoachChatTheme(
              visual: const CoachChatVisuals(
                showStars: false,
                animateBackground: false,
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: PlanCard(
                      plan: original,
                      library: chatCatalog(),
                      saved: false,
                      showNumbers: numbers,
                      onStart: () {},
                      onSave: () {},
                      onOpen: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await _pump(tester);
        for (var i = 1; i <= 3; i++) {
          expect(
            find.byKey(ValueKey('plan-compact-number-$i')),
            numbers ? findsOneWidget : findsNothing,
          );
        }
        await tester.tap(
          find.byKey(const ValueKey('plan-expand-qa-numbering')),
        );
        await _pump(tester);
        for (final (i, name) in [(1, 'one伸展'), (2, 'two伸展'), (3, 'three伸展')]) {
          expect(
            tester.widget<Text>(find.byKey(ValueKey('plan-name-$i'))).data,
            name,
          );
          final row = find
              .ancestor(
                of: find.byKey(ValueKey('plan-row-thumb-$i')),
                matching: find.byType(Row),
              )
              .first;
          expect(
            find.descendant(of: row, matching: find.text('$i')),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
