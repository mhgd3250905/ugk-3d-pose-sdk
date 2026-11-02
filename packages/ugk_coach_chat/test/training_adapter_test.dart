import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach_chat/ugk_coach_chat.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

import 'chat_controller_test.dart' show ChatHarness, chatPlan;

class _DelayedPosterBundle extends CachingAssetBundle {
  final image = Completer<ByteData>();

  @override
  Future<ByteData> load(String key) async {
    if (key == 'poster.png') return image.future;
    if (key == 'AssetManifest.bin') {
      return const StandardMessageCodec().encodeMessage(<String, Object>{})!;
    }
    return rootBundle.load(key);
  }
}

ByteData _posterBytes() => ByteData.sublistView(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
  ),
);

CoachAppProfile _configured(CoachAppProfile source) => CoachAppProfile(
  appId: source.appId,
  scopeManifest: source.scopeManifest,
  coachProfile: source.coachProfile,
  conversationPolicy: source.conversationPolicy,
  executionTiming: source.executionTiming,
  trainingExperience: const TrainerExperienceConfig(
    posterWarmupTimeout: Duration(milliseconds: 20),
  ),
);

void main() {
  testWidgets('chat adapter opens the shared route with default experience', (
    tester,
  ) async {
    final host = ChatHarness();
    await host.controller.start();
    final plan = chatPlan();
    final admitted = host.controller.agent.prepareTraining(
      plan,
      context: requestForPlan(plan),
    )!;
    final bundle = _DelayedPosterBundle()..image.complete(_posterBytes());
    late BuildContext context;
    await tester.pumpWidget(
      DefaultAssetBundle(
        bundle: bundle,
        child: MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(
      await tester.runAsync(
        () => TrainingPosterImages.prepareAsset(
          context,
          'poster.png',
          timeout: const Duration(seconds: 2),
        ),
      ),
      isTrue,
    );
    var starts = 0;
    var holds = 0;
    final request = CoachChatTrainingRequest(
      plan: admitted,
      sourceEntry: 'chat',
      messageId: 'card-1',
      onStarting: () async {
        starts++;
        return true;
      },
      holdTransition: () {
        holds++;
        return () => holds--;
      },
    );
    final adapter = CoachChatTrainingAdapter(
      profile: host.controller.profile,
      firstPosterAsset: (_, _) => 'poster.png',
      pageBuilder: (_, received) {
        expect(identical(received, request), isTrue);
        return const ColoredBox(color: Colors.white);
      },
    );
    expect(host.controller.profile.trainingExperience, isNull);
    var routeCompleted = false;
    final launched = adapter(context, request).then((result) {
      routeCompleted = true;
      return result;
    });
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(microseconds: 1));
    await tester.pump();
    final pageContext = tester.element(find.byType(ColoredBox).last);
    expect(ModalRoute.of(pageContext), isA<TrainerSlideRoute<SessionResult>>());
    expect(starts, 1);
    expect(holds, 0);
    Navigator.of(pageContext).pop();
    await tester.pumpAndSettle();
    expect(routeCompleted, isTrue, reason: 'route must finish after removal');
    expect(await launched, isNull);
    await tester.pumpWidget(const SizedBox());
    // The shared chat harness closes asynchronous broadcast streams, like the
    // existing controller widget test's cleanup in a real async zone.
    await tester.runAsync(host.close);
  });

  testWidgets('profile poster timeout keeps chat and bookkeeping untouched', (
    tester,
  ) async {
    final host = ChatHarness();
    await host.controller.start();
    final plan = chatPlan();
    final admitted = host.controller.agent.prepareTraining(
      plan,
      context: requestForPlan(plan),
    )!;
    final bundle = _DelayedPosterBundle();
    late BuildContext context;
    await tester.pumpWidget(
      DefaultAssetBundle(
        bundle: bundle,
        child: MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const Text('conversation');
            },
          ),
        ),
      ),
    );
    var starts = 0;
    var holds = 0;
    final request = CoachChatTrainingRequest(
      plan: admitted,
      sourceEntry: 'chat',
      messageId: 'card-1',
      onStarting: () async {
        starts++;
        return true;
      },
      holdTransition: () {
        holds++;
        return () => holds--;
      },
    );
    final adapter = CoachChatTrainingAdapter(
      profile: _configured(host.controller.profile),
      firstPosterAsset: (_, _) => 'poster.png',
      pageBuilder: (_, _) => const Text('training'),
    );
    expect(await tester.runAsync(() => adapter(context, request)), isNull);
    expect(find.text('conversation'), findsOneWidget);
    expect(find.text('training'), findsNothing);
    expect(starts, 0);
    expect(holds, 0);
    bundle.image.complete(_posterBytes());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(host.close);
  });
}
