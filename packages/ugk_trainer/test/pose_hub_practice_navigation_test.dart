import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

class _Routes extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

class _Preparer implements PoseHubMediaPreparer {
  @override
  Stream<PoseHubMediaPreparationEvent> prepareAction(
    PoseHubPackAction action,
  ) => const Stream.empty();
}

void main() {
  final catalog = PoseHubAppTestCatalog.fromBytes(
    File('assets/pose_hub/app-test-pack-r1/catalog.json').readAsBytesSync(),
  );
  final action = catalog.semanticCompleteActions.first;
  final mediaBaseUri = Uri.parse('file:///host-prepared/');

  Future<void> tapFirst(WidgetTester tester) =>
      tester.tap(find.byKey(ValueKey('posehub-action-${action.id}')));

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets(
    'host open callback receives all configured inputs and never pushes',
    (tester) async {
      final routes = _Routes();
      final opened = <PoseHubSinglePracticePage>[];
      final theme = TrainerTheme.light.copyWith(radius: 30);
      final preparer = _Preparer();
      final voice = TrainerVoice.silent;
      void finished(PoseHubPracticeResult result) {}
      void started() {}
      Future<void> completed(SessionResult result) async {}

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [routes],
          home: PoseHubActionBrowser(
            catalog: catalog,
            mediaBaseUri: mediaBaseUri,
            theme: theme,
            mediaPreparer: preparer,
            voice: voice,
            onPracticeFinished: finished,
            onStartTraining: started,
            onCompleted: completed,
            onOpenPractice: opened.add,
          ),
        ),
      );
      expect(routes.pushed, hasLength(1));

      await tapFirst(tester);
      expect(opened, hasLength(1));
      final page = opened.single;
      expect(page.action, same(action));
      expect(page.mediaBaseUri, same(mediaBaseUri));
      expect(page.theme, same(theme));
      expect(page.mediaPreparer, same(preparer));
      expect(page.voice, same(voice));
      expect(page.onFinished, same(finished));
      expect(page.onStartTraining, same(started));
      expect(page.onCompleted, same(completed));
      expect(page.startMode, TrainerStartMode.preview);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(routes.pushed, hasLength(1));
      expect(find.byType(PoseHubActionBrowser), findsOneWidget);
      expect(find.byType(PoseHubSinglePracticePage), findsNothing);
      expect(find.byType(TrainerPlayer), findsNothing);
      await unmount(tester);
    },
  );

  testWidgets('open callback receives the inherited resolved theme', (
    tester,
  ) async {
    PoseHubSinglePracticePage? opened;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: PoseHubActionBrowser(
          catalog: catalog,
          mediaBaseUri: mediaBaseUri,
          onOpenPractice: (page) => opened = page,
        ),
      ),
    );
    await tapFirst(tester);
    expect(opened!.theme, same(TrainerTheme.dark));
    expect(opened!.mediaBaseUri, mediaBaseUri);
    expect(opened!.startMode, TrainerStartMode.preview);
    await unmount(tester);
  });

  testWidgets(
    'omitting callback retains the built-in preview route and inputs',
    (tester) async {
      final routes = _Routes();
      final theme = TrainerTheme.light.copyWith(radius: 30);
      final voice = TrainerVoice.silent;
      void finished(PoseHubPracticeResult result) {}
      void started() {}
      Future<void> completed(SessionResult result) async {}

      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [routes],
          home: PoseHubActionBrowser(
            catalog: catalog,
            mediaBaseUri: mediaBaseUri,
            theme: theme,
            voice: voice,
            onPracticeFinished: finished,
            onStartTraining: started,
            onCompleted: completed,
          ),
        ),
      );
      await tapFirst(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(routes.pushed, hasLength(2));
      expect(routes.pushed.last, isA<MaterialPageRoute<void>>());
      final page = tester.widget<PoseHubSinglePracticePage>(
        find.byType(PoseHubSinglePracticePage),
      );
      expect(page.action, same(action));
      expect(page.mediaBaseUri, same(mediaBaseUri));
      expect(page.theme, same(theme));
      expect(page.voice, same(voice));
      expect(page.onFinished, same(finished));
      expect(page.onStartTraining, same(started));
      expect(page.onCompleted, same(completed));
      expect(page.startMode, TrainerStartMode.preview);
      final player = tester.widget<TrainerPlayer>(find.byType(TrainerPlayer));
      expect(player.startMode, TrainerStartMode.preview);
      expect(player.prepSeconds, 10);
      expect(find.byKey(const ValueKey('start-training')), findsOneWidget);
      await unmount(tester);
    },
  );

  testWidgets('host can push its own route without a second SDK push', (
    tester,
  ) async {
    final routes = _Routes();
    final navigator = GlobalKey<NavigatorState>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [routes],
        home: PoseHubActionBrowser(
          catalog: catalog,
          mediaBaseUri: mediaBaseUri,
          onOpenPractice: (page) {
            calls++;
            navigator.currentState!.push<void>(
              PageRouteBuilder<void>(
                settings: const RouteSettings(name: '/host-practice'),
                pageBuilder: (_, _, _) => page,
                transitionsBuilder: (_, animation, _, child) => SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(1, 0),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
            );
          },
        ),
      ),
    );
    await tapFirst(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(calls, 1);
    expect(routes.pushed, hasLength(2));
    expect(routes.pushed.last, isA<PageRouteBuilder<void>>());
    expect(routes.pushed.last.settings.name, '/host-practice');
    expect(find.byType(PoseHubSinglePracticePage), findsOneWidget);
    expect(find.byType(TrainerPlayer), findsOneWidget);
    await unmount(tester);
  });
}
