import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_chat/src/core/app_profile.dart';
import 'package:ugk_coach_chat/src/core/chat_bindings.dart';
import 'package:ugk_coach_chat/src/core/chat_controller.dart';
import 'package:ugk_coach_chat/src/theme/chat_theme.dart';
import 'package:ugk_coach_chat/src/ui/coach_chat_plan_details_page.dart';

import 'chat_controller_test.dart' show ChatHarness, chatCatalog, chatPlan;

Future<CoachChatController> _controller(
  ChatHarness host,
  CoachChatVisuals visual,
) async {
  final base = host.controller.profile;
  final controller = CoachChatController(
    profile: CoachAppProfile(
      appId: base.appId,
      scopeManifest: base.scopeManifest,
      coachProfile: base.coachProfile,
      conversationPolicy: base.conversationPolicy,
      executionTiming: base.executionTiming,
      visual: visual,
    ),
    catalog: chatCatalog(),
    bindings: host.controller.bindings,
    clock: () => DateTime(2026, 10, 30, 12),
  );
  expect((await controller.start()).ok, isTrue);
  addTearDown(controller.dispose);
  return controller;
}

Future<void> _showDetails(
  WidgetTester tester,
  CoachChatController controller,
) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final prepared = controller.prepareSavedPlanDetails(
    CoachSavedPlanSnapshot(
      externalId: 'saved',
      title: '髋部放松',
      plan: chatPlan(),
      storageRevision: 'r1',
    ),
  );
  expect(prepared.ok, isTrue);
  expect(prepared.reference!.plan.items, isNotEmpty);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: CoachChatPlanDetailsPage(
        controller: controller,
        plan: prepared.reference!,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an offscreen preview retires before the next decoder starts', (
    tester,
  ) async {
    final host = ChatHarness();
    final retiring = Completer<void>();
    final retireCalls = <String>[];
    final owners = <String>{};
    var maxOwners = 0;
    final controller = await _controller(
      host,
      CoachChatVisuals(
        previewBuilder: (_, id, playing) {
          if (playing) owners.add(id);
          if (owners.length > maxOwners) maxOwners = owners.length;
          return const ColoredBox(color: Colors.transparent);
        },
        retirePreview: (_, id) async {
          retireCalls.add(id);
          if (id == 'one') await retiring.future;
          owners.remove(id);
        },
      ),
    );
    addTearDown(() {
      if (!retiring.isCompleted) retiring.complete();
    });
    await _showDetails(tester, controller);
    final first = find.byKey(const ValueKey('article-video-toggle-0:0'));
    await tester.ensureVisible(first);
    await tester.tap(first);
    await tester.pump();
    expect(owners, {'one'});

    final second = find.byKey(const ValueKey('article-video-toggle-0:1'));
    await tester.ensureVisible(second);
    await tester.pump();
    expect(retireCalls, contains('one'));
    await tester.tap(second);
    await tester.pump();
    expect(owners, {
      'one',
    }, reason: 'The old host retirement is still pending.');
    retiring.complete();
    await tester.pump();
    await tester.pump();
    expect(owners, {'two'});
    expect(maxOwners, 1);
    expect(controller.focus, isNull);
    expect(host.client.requests, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    controller.dispose();
    host.controller.dispose();
    unawaited(host.plans.updates.close());
    unawaited(host.preferences.updates.close());
    await tester.pump();
  });

  testWidgets(
    'training waits for preview retirement and retains the article scroll',
    (tester) async {
      final retiring = Completer<void>();
      final returned = Completer<void>();
      var gateCompleted = false;
      var sawRetire = false;
      final host = ChatHarness(
        onTraining: (_, request) async {
          final release = request.holdTransition();
          try {
            expect(await request.onStarting(), isTrue);
            gateCompleted = true;
          } finally {
            release();
          }
          await returned.future;
          return null;
        },
      );
      final controller = await _controller(
        host,
        CoachChatVisuals(
          previewBuilder: (_, _, _) =>
              const ColoredBox(color: Colors.transparent),
          retirePreview: (_, _) async {
            sawRetire = true;
            await retiring.future;
          },
        ),
      );
      addTearDown(() {
        if (!retiring.isCompleted) retiring.complete();
        if (!returned.isCompleted) returned.complete();
      });
      await _showDetails(tester, controller);
      final first = find.byKey(const ValueKey('article-video-toggle-0:0'));
      await tester.ensureVisible(first);
      await tester.tap(first);
      await tester.pump();
      final list = find.byKey(const ValueKey('plan-article'));
      final scroll = tester.widget<ListView>(list).controller!;
      scroll.jumpTo(100);
      await tester.pump();
      final offset = scroll.offset;
      await tester.tap(find.byKey(const ValueKey('start')));
      await tester.pump();
      expect(sawRetire, isTrue);
      expect(gateCompleted, isFalse);
      expect(tester.widget<ListView>(list).controller, same(scroll));
      expect(scroll.offset, offset);
      retiring.complete();
      await tester.pump();
      await tester.pump();
      expect(gateCompleted, isTrue);
      expect(host.history.remembered, hasLength(1));
      returned.complete();
      await tester.pump();
      expect(tester.widget<ListView>(list).controller, same(scroll));
      expect(scroll.offset, offset);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      controller.dispose();
      host.controller.dispose();
      unawaited(host.plans.updates.close());
      unawaited(host.preferences.updates.close());
      await tester.pump();
    },
  );
}
