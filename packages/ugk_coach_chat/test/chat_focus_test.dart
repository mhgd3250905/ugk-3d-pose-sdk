import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_chat/src/core/chat_bindings.dart';
import 'package:ugk_coach_chat/src/core/chat_snapshot.dart';

import 'chat_controller_test.dart';

CoachSavedPlanSnapshot selectedPlan({String third = 'three'}) =>
    CoachSavedPlanSnapshot(
      externalId: 'saved',
      title: '我的髋部计划',
      plan: chatPlan(third: third),
      storageRevision: 'r1',
      sdkVersion: 7,
    );

void main() {
  test(
    'a host selection focuses locally and keeps host revision separate from SDK baseVersion',
    () async {
      final selected = selectedPlan();
      final h = ChatHarness(plans: ChatPlans([selected]));
      addTearDown(h.close);
      await h.controller.start();
      final focused = await h.controller.sendPlanToConversation(selected);
      expect(focused.ok, isTrue, reason: '${focused.errors}');
      expect(focused.persisted, isTrue);
      expect(h.controller.focus!.planId, 'ext:saved');
      expect(h.controller.focus!.savedRef.baseVersion, 1);
      final card = h.controller.messages.lastWhere((m) => m.plan != null);
      expect(card.plan, same(selected.plan));
      expect(card.storageRevision, 'r1');
      expect(card.sdkVersion, 7);
      expect(h.controller.isPlanCardSaved(card), isTrue);
      expect(h.client.requests, isEmpty);
      expect(h.plans.writes, isEmpty);
    },
  );

  test(
    'an invalid external plan is rejected before focus or display changes',
    () async {
      final h = ChatHarness(plans: ChatPlans([selectedPlan()]));
      addTearDown(h.close);
      await h.controller.sendPlanToConversation(selectedPlan());
      final before = h.controller.exportSnapshot().toJson();
      final rejected = await h.controller.sendPlanToConversation(
        selectedPlan(third: 'outside'),
      );
      expect(rejected.ok, isFalse);
      expect(rejected.scopePreview, isNotNull);
      expect(h.controller.exportSnapshot().toJson(), before);
      expect(h.client.requests, isEmpty);
    },
  );

  test(
    'snapshot round trip retains focus versions and the card storage revision',
    () async {
      final first = ChatHarness(
        plans: ChatPlans([selectedPlan()]),
        script: chatEditScript('four'),
      );
      addTearDown(first.close);
      await first.controller.sendPlanToConversation(selectedPlan());
      final edited = await first.controller.send('替换第3个动作');
      expect(
        edited?.plan,
        isNotNull,
        reason: '${edited?.issues} ${edited?.error}',
      );
      expect(edited!.plan!.version, 2);
      final snapshot = CoachChatSnapshot.fromJson(
        Map<String, Object?>.from(
          jsonDecode(jsonEncode(first.controller.exportSnapshot().toJson()))
              as Map,
        ),
      );
      final history = ChatHistory()..snapshot = snapshot;
      final restored = ChatHarness(
        plans: ChatPlans([selectedPlan()]),
        history: history,
      );
      addTearDown(restored.close);
      expect((await restored.controller.start()).ok, isTrue);
      expect(restored.controller.focus!.version, 2);
      expect(restored.controller.focus!.savedRef.baseVersion, 1);
      final card = restored.controller.messages.lastWhere(
        (m) => m.plan != null,
      );
      expect(card.plan!.items, isNotEmpty);
      expect(card.plan!.items.last.exerciseId, 'four');
      expect(card.storageRevision, 'r1');
      expect(restored.client.requests, isEmpty);
    },
  );

  test(
    'a snapshot containing actions from another scope preserves the destination on rejection',
    () async {
      final source = ChatHarness(
        allowedActionIds: const ['one', 'two', 'three', 'four', 'outside'],
      );
      final target = ChatHarness();
      addTearDown(source.close);
      addTearDown(target.close);
      expect(
        (await source.controller.sendPlanToConversation(
          selectedPlan(third: 'outside'),
        )).ok,
        isTrue,
      );
      expect(
        (await target.controller.sendPlanToConversation(selectedPlan())).ok,
        isTrue,
      );
      final before = target.controller.exportSnapshot().toJson();
      final result = await target.controller.restoreSnapshot(
        source.controller.exportSnapshot(),
      );
      expect(result.ok, isFalse);
      expect(target.controller.exportSnapshot().toJson(), before);
      expect(target.client.requests, isEmpty);
    },
  );
}
