import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_coach_chat/ugk_coach_chat.dart';
import 'package:ugk_coach_chat/src/ui/coach_ui_adapter.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

import 'chat_controller_test.dart' show ChatHarness, chatCatalog, chatPlan;

void main() {
  test(
    'English product strings include derived greetings, safety and save copy',
    () {
      const strings = CoachChatStrings.english();
      expect(strings.languageTag, 'en');
      expect(CoachChatStrings.forLanguage('en-GB').isEn, isTrue);
      expect(
        const CoachChatStrings().greetingFor(DateTime(2026, 11, 7, 8)),
        '早上好',
      );
      final values = [
        strings.greetingFor(DateTime(2026, 11, 7, 8)),
        strings.safetyDisclaimer,
        for (var i = 0; i < strings.safetyQuestions.length; i++) ...[
          strings.safetyQuestionText(i),
          strings.safetyBlockedText(i),
        ],
        strings.saveSuccess('My plan'),
        strings.saveSuccess('My plan', updating: true),
        ...strings.suggestions(),
        ...strings.planSuggestions,
      ];
      expect(
        values.where((text) => RegExp(r'[\u3400-\u9fff]').hasMatch(text)),
        isEmpty,
      );
      expect(strings.safetyQuestionText(0), startsWith('1/4'));
      expect(strings.saveSuccess('My plan'), 'Saved as “My plan”');
    },
  );

  test(
    'English dose, equipment, duration and section labels retain execution amounts',
    () {
      final item = coach.PlanItem(
        exerciseId: 'one',
        mode: coach.DoseMode.time,
        sets: 2,
        workSeconds: 30,
        perSide: true,
        restSeconds: 0,
      );
      expect(chatDoseText(item), '2 组 × 每侧 30 秒');
      expect(chatDoseText(item, language: 'en'), '2 sets × Each side 30 sec');
      expect(chatEquipmentLabel('chair', language: 'en'), 'Chair');
      expect(chatDurationLabel(125, language: 'en'), 'About 2 min');
      final block = coach.PlanBlock(
        id: 'warmup',
        name: '热身',
        type: coach.BlockType.warmup,
        items: [item],
      );
      expect(planSectionLabel(block), '热身');
      expect(planSectionLabel(block, language: 'en'), 'Warm-up');
      final routine = toCoachRoutine(chatPlan(), chatCatalog(), language: 'en');
      expect(routine.metaLabel, contains('3 moves'));
      expect(
        routine.title,
        chatPlan().title,
        reason: 'Plan prose remains the original authored text',
      );
    },
  );

  test(
    'updating localization keeps conversation, focus, scope and gateway lease',
    () async {
      final host = ChatHarness();
      addTearDown(host.close);
      final controller = host.controller;
      await controller.start();
      final plan = chatPlan();
      final selection = CoachSavedPlanSnapshot(
        externalId: 'saved',
        title: '用户计划',
        plan: plan,
        storageRevision: '1',
      );
      expect((await controller.sendPlanToConversation(selection)).ok, isTrue);
      final messages = [...controller.messages];
      final current = controller.currentPlan;
      final leaseCount = host.creations;
      final scope = controller.profile.allowedActionIds;
      final agent = controller.agent;
      final policy = coach.CoachScopeConversationPolicy(
        languageTag: 'en',
        specialty: 'Hip mobility within this app’s scope.',
      );
      controller.updateLocalization(
        strings: const CoachChatStrings.english(),
        language: 'en',
        conversationPolicy: policy,
      );
      expect(controller.messages, orderedEquals(messages));
      expect(controller.currentPlan, same(current));
      expect(controller.agent, same(agent));
      expect(controller.agent.scopePolicy, same(policy));
      expect(host.creations, leaseCount);
      expect(controller.profile.allowedActionIds, scope);
      expect(controller.context.language, 'en');
      expect(controller.profile.strings.sendLabel, 'Send');
    },
  );

  test('English safety choices keep their command payloads', () async {
    final host = ChatHarness(safetyAccepted: false);
    addTearDown(host.close);
    final controller = host.controller;
    controller.updateLocalization(
      strings: const CoachChatStrings.english(),
      language: 'en',
    );
    await controller.start();
    final ack = controller.messages.last;
    expect(ack.options.single.label, 'I understand');
    expect(ack.options.single.value, '@safety:ack');
    await controller.choose(ack, 0);
    final question = controller.messages.last;
    expect(question.options.map((option) => option.label), ['No', 'Yes']);
    expect(question.options.map((option) => option.value), [
      '@safety:no',
      '@safety:yes',
    ]);
    expect(question.text, contains('Pregnant'));
  });

  testWidgets('English plan guide consumes host-authored action copy', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(394, 853)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final host = ChatHarness();
    addTearDown(host.controller.dispose);
    final controller = host.controller;
    controller.updateLocalization(
      strings: const CoachChatStrings.english(),
      language: 'en',
      library: TrainingLibraryConfig(
        scopeManifest: controller.profile.scopeManifest,
        displayText: (id) => TrainingLibraryActionText(
          name: 'Move $id',
          muscles: 'Inner thighs',
          cues: const ['Move slowly.'],
          cautions: const ['Stop if painful.'],
        ),
      ),
    );
    await controller.start();
    final prepared = controller.prepareSavedPlanDetails(
      CoachSavedPlanSnapshot(
        externalId: 'saved',
        title: 'Saved plan',
        plan: chatPlan(),
        storageRevision: '1',
      ),
    );
    expect(prepared.ok, isTrue);
    await tester.pumpWidget(
      MaterialApp(
        home: CoachChatPlanDetailsPage(
          controller: controller,
          plan: prepared.reference!,
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Training guide'), findsOneWidget);
    expect(find.text('Move one'), findsOneWidget);
    expect(find.text('How to do it'), findsWidgets);
    expect(find.text('Move slowly.'), findsWidgets);
    expect(find.text('每侧'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
