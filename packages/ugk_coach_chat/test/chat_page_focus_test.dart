import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_chat/ugk_coach_chat.dart';

import 'chat_controller_test.dart' show ChatHarness, chatCatalog;

Future<CoachChatController> _showChat(
  WidgetTester tester, {
  required Future<void> Function(BuildContext) openSavedPlans,
}) async {
  final host = ChatHarness();
  final original = host.controller;
  final profile = original.profile;
  final binding = original.bindings;
  final controller = CoachChatController(
    profile: CoachAppProfile(
      appId: profile.appId,
      scopeManifest: profile.scopeManifest,
      coachProfile: profile.coachProfile,
      conversationPolicy: profile.conversationPolicy,
      executionTiming: profile.executionTiming,
      visual: const CoachChatVisuals(animateBackground: false),
    ),
    catalog: chatCatalog(),
    bindings: CoachChatBindings(
      storageNamespace: binding.storageNamespace,
      gateway: binding.gateway,
      plans: binding.plans,
      history: binding.history,
      preferences: binding.preferences,
      actions: CoachChatHostActions(
        onStartTraining: binding.actions.onStartTraining,
        onOpenAction: binding.actions.onOpenAction,
        onOpenLibrary: binding.actions.onOpenLibrary,
        onOpenSavedPlans: openSavedPlans,
        onOpenCustomPlan: binding.actions.onOpenCustomPlan,
        onOpenSettings: binding.actions.onOpenSettings,
      ),
    ),
  );
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    host.controller.dispose();
    unawaited(host.plans.updates.close());
    unawaited(host.preferences.updates.close());
    await tester.pump();
  });
  expect((await controller.start()).ok, isTrue);
  await tester.pumpWidget(
    MaterialApp(home: CoachChatPage(controller: controller)),
  );
  await tester.pumpAndSettle();
  return controller;
}

EditableText _editor(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText));

void main() {
  testWidgets('saved-plans compose focuses the retained conversation input', (
    tester,
  ) async {
    late CoachChatController controller;
    controller = await _showChat(
      tester,
      openSavedPlans: (context) => Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (routeContext) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  Navigator.of(routeContext).pop();
                  controller.requestCompose();
                },
                child: const Text('去排一套'),
              ),
            ),
          ),
        ),
      ),
    );
    final originalInput = _editor(tester).focusNode;
    await tester.tap(find.byKey(const ValueKey('chat-panel-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('panel-plans')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('去排一套'));
    await tester.pumpAndSettle();
    expect(_editor(tester).focusNode, same(originalInput));
    expect(originalInput.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
  });

  testWidgets('foreground return hides the keyboard until explicit compose', (
    tester,
  ) async {
    final controller = await _showChat(tester, openSavedPlans: (_) async {});
    await tester.tap(find.byKey(const ValueKey('chat-input')));
    await tester.pump();
    expect(_editor(tester).focusNode.hasFocus, isTrue);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(_editor(tester).focusNode.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    controller.requestCompose();
    await tester.pumpAndSettle();
    expect(_editor(tester).focusNode.hasFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);
  });
}
