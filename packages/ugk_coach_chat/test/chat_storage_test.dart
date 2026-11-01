import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_chat/src/core/chat_bindings.dart';
import 'package:ugk_coach_chat/src/core/chat_models.dart';
import 'package:ugk_coach_chat/src/core/chat_snapshot.dart';

import 'chat_controller_test.dart';
import 'chat_focus_test.dart' show selectedPlan;

class _DelayedPlans extends ChatPlans {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<CoachPlanWriteResult> save(CoachPlanWriteRequest request) async {
    entered.complete();
    await release.future;
    return super.save(request);
  }
}

void main() {
  test(
    'a save completing after new conversation preserves the new display',
    () async {
      final plans = _DelayedPlans();
      final h = ChatHarness(plans: plans, script: chatPlanScript());
      addTearDown(h.close);
      final result = await h.controller.send('在家拉伸5分钟');
      expect(
        result?.plan,
        isNotNull,
        reason: '${result?.issues} ${result?.error}',
      );
      final card = h.controller.messages.lastWhere(
        (message) => message.plan != null,
      );
      final saving = h.controller.savePlanCard(card);
      await plans.entered.future;
      await h.controller.newConversation();
      final ids = h.controller.messages.map((message) => message.id).toList();
      plans.release.complete();
      final saved = await saving;
      expect(saved.plan.id, card.plan!.id);
      expect(h.savedNotifications, 1);
      expect(h.controller.messages.map((message) => message.id), ids);
      expect(
        h.controller.messages.any((message) => message.plan != null),
        isFalse,
      );
      expect(
        h.history.writes.last.messages.any(
          (message) => message['plan'] != null,
        ),
        isFalse,
      );
    },
  );

  test(
    'two edited cards retain independent CAS revisions after one is saved',
    () async {
      final h = ChatHarness(
        plans: ChatPlans([selectedPlan()]),
        script: [
          ...chatEditScript('four'),
          ...chatEditScript('three'),
          ...chatEditScript('four'),
        ],
      );
      addTearDown(h.close);
      await h.controller.sendPlanToConversation(selectedPlan());
      final one = await h.controller.send('替换第3个动作');
      expect(one?.plan, isNotNull, reason: '${one?.issues} ${one?.error}');
      final firstCard = h.controller.messages.lastWhere((m) => m.plan != null);
      final two = await h.controller.send('替换第3个动作');
      expect(two?.plan, isNotNull, reason: '${two?.issues} ${two?.error}');
      final otherCard = h.controller.messages.lastWhere((m) => m.plan != null);
      expect(firstCard.storageRevision, 'r1');
      expect(otherCard.storageRevision, 'r1');
      final saved = await h.controller.savePlanCard(firstCard);
      expect(saved.storageRevision, 'r2');
      expect(h.plans.writes.single.expectedStorageRevision, 'r1');
      expect(h.plans.writes.single.savedRef!.baseVersion, 1);
      expect(h.savedNotifications, 1);
      await expectLater(
        h.controller.savePlanCard(otherCard),
        throwsA(
          isA<CoachPlanStorageException>().having(
            (e) => e.result.status,
            'status',
            CoachPlanWriteStatus.conflict,
          ),
        ),
      );
      expect(
        h.controller.messages
            .firstWhere((m) => m.id == otherCard.id)
            .storageRevision,
        'r1',
      );
      final third = await h.controller.send('替换第3个动作');
      expect(
        third?.plan,
        isNotNull,
        reason: '${third?.issues} ${third?.error}',
      );
      expect(
        h.controller.messages.lastWhere((m) => m.plan != null).storageRevision,
        'r2',
      );
    },
  );

  test(
    'queued display writes capture ordered snapshots rather than later mutable state',
    () async {
      final history = ChatHistory()..firstWrite = Completer<void>();
      final h = ChatHarness(history: history);
      addTearDown(h.close);
      await h.controller.start();
      final older = h.controller.flushPersistence();
      await h.controller.dispatch(
        const CoachChatCommand(CoachChatCommandKind.showHistory),
      );
      final newer = h.controller.flushPersistence();
      history.firstWrite!.complete();
      await Future.wait([older, newer]);
      expect(history.writes.first.messages, hasLength(1));
      expect(history.writes.last.messages, hasLength(2));
      expect(history.writes.last.messages.last['text'], '还没有训练记录。');
    },
  );

  test(
    'legacy SF display restores the stored plan context without deleting the source',
    () async {
      final source = ChatHarness();
      addTearDown(source.close);
      await source.controller.start();
      final original = source.controller.exportSnapshot();
      final plan = chatPlan(equipment: const ['mat']);
      final legacy = CoachChatLegacyData(
        chat: [
          ...original.messages,
          ChatMessage(
            id: 'legacy-plan',
            role: ChatRole.assistant,
            at: DateTime(2026, 10, 30, 12),
            text: '慢慢完成。',
            plan: plan,
            request: requestForPlan(plan),
            aiVisible: true,
          ).toJson(),
        ],
      );
      final history = ChatHistory()..legacy = legacy;
      final target = ChatHarness(history: history, equipment: const ['mat']);
      addTearDown(target.close);
      final result = await target.controller.start();
      expect(result.ok, isTrue);
      expect(target.controller.messages.first.text, '中午好\n说说今天想怎么练？');
      expect(target.controller.messages.last.plan!.items, isNotEmpty);
      expect(target.controller.agent.sessionState.activePlanId, plan.id);
      expect(history.snapshot, isNotNull);
      expect(identical(history.legacy, legacy), isTrue);
      expect(target.client.requests, isEmpty);
    },
  );
}
