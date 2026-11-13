import 'dart:io';
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';
import 'package:ugk_trainer_showcase/main.dart';

const _fps = 30;
const _captureKey = ValueKey('player-v1-phase-animation-capture');
const _scaffoldKey = ValueKey('player-v1-scaffold');
const _viewportKey = ValueKey('player-v1-media-viewport');

class _TransitionSession extends SessionBuilder {
  @override
  List<SessionPhase> phases(TrainingPlan plan) {
    final phases = DemoSessionBuilder(ShowcaseState.training).phases(plan);
    return [
      phases.first.withSeconds(1.5),
      phases
          .firstWhere((phase) => phase.kind == PhaseKind.rest)
          .withSeconds(1.5),
      phases.lastWhere((phase) => phase.isWork).withSeconds(4),
      phases.last,
    ];
  }
}

TrainerDrill? _drill(String id) => switch (id) {
  'lunge' => TrainerDrill(
    id: id,
    name: '半跪髋屈肌拉伸',
    cues: const ['收紧腹部，慢慢把髋向前移', '保持呼吸，感受髋前侧伸展'],
    media: _posterMedia(id),
  ),
  'reach' => TrainerDrill(
    id: id,
    name: '仰卧四字拉伸',
    cues: const ['放松肩颈，保持均匀呼吸'],
    media: _posterMedia(id),
  ),
  _ => null,
};

DrillMedia _posterMedia(String id) => DrillMedia(
  id: id,
  videoAsset: '',
  posterAsset: playerV1PosterAssets[id]!,
  duration: 0,
  videoAvailable: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final outputPath = Platform.environment['SHOWCASE_PHASE_FRAMES'];
  final output = outputPath == null || outputPath.isEmpty
      ? null
      : Directory(outputPath);
  String? fontFamily;

  setUpAll(() async {
    if (output == null) return;
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
          rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
        ))
        .load();
    final fontPath = Platform.environment['SHOWCASE_FONT'];
    if (fontPath != null && fontPath.isNotEmpty) {
      final bytes = await File(fontPath).readAsBytes();
      await (FontLoader(
        'PlayerPhaseCapture',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      fontFamily = 'PlayerPhaseCapture';
    }
    await output.create(recursive: true);
  });

  Future<void> mount(WidgetTester tester, {bool reducedMotion = false}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    final warmup = GlobalKey();
    await tester.pumpWidget(MaterialApp(home: Scaffold(key: warmup)));
    final warmed = await tester.runAsync(
      () => Future.wait([
        for (final asset in playerV1PosterAssets.values)
          TrainingPosterImages.prepareAsset(
            warmup.currentContext!,
            asset,
            timeout: const Duration(seconds: 3),
          ),
      ]),
    );
    expect(warmed, everyElement(isTrue));
    await tester.runAsync(() async {
      for (final asset in playerV1PosterAssets.values) {
        await precacheImage(AssetImage(asset), warmup.currentContext!);
      }
    });
    final theme = TrainerTheme.playerV1.copyWith(fontFamily: fontFamily);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(fontFamily: fontFamily),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reducedMotion),
          child: child!,
        ),
        home: RepaintBoundary(
          key: _captureKey,
          child: TrainerPlayer(
            plan: demoPlan,
            drillOf: _drill,
            theme: theme,
            strings: TrainerStrings.zh(),
            sessionBuilder: _TransitionSession(),
            keepAlive: false,
            voice: TrainerVoice.silent,
            tick: const Duration(milliseconds: 20),
            mediaBuilder: (_, request) => TrainerPoster(
              asset: playerV1PosterAssets[request.drill.id]!,
              mirrored: request.mirrored,
            ),
            restFeedbackBuilder: (_, _) => TrainerRestFeedbackPanel(
              theme: theme,
              title: '刚才感觉怎么样？',
              recordedTitle: '已记录',
              description: '给刚完成的动作记下一个感受',
              comfortableLabel: '舒服',
              tightLabel: '有点紧',
              painLabel: '疼',
              onComfortable: () {},
              onTight: () {},
              onPain: () {},
            ),
            onFinished: (_) async {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> captureFrame(WidgetTester tester, int frame) async {
    if (output == null) return;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        final number = frame.toString().padLeft(3, '0');
        await File('${output.path}/frame-$number.png').writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      } finally {
        image.dispose();
      }
    });
  }

  testWidgets('natural work and rest transitions retain the media viewport', (
    tester,
  ) async {
    final haptics = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final oldShadows = debugDisableShadows;
    debugDisableShadows = false;
    try {
      await withClock(Clock(tester.binding.clock.now), () async {
        await mount(tester);
        final scaffold = find.byKey(_scaffoldKey);
        final viewport = find.byKey(_viewportKey);
        final dock = find.byKey(const ValueKey('player-v1-dock'));
        final player = tester.state(find.byType(TrainerPlayer));
        final scaffoldElement = tester.element(scaffold);
        final scaffoldState = tester.state(scaffold);
        final viewportBox = tester.renderObject<RenderBox>(viewport);
        final stageRect = tester.getRect(viewport);
        expect(stageRect.size.shortestSide, greaterThan(0));

        var previousTime = Duration.zero;
        var sawDockExpand = false;
        var sawDockCollapse = false;
        for (var frame = 0; frame <= 5 * _fps; frame++) {
          final time = Duration(
            microseconds: (frame * Duration.microsecondsPerSecond / _fps)
                .round(),
          );
          if (frame != 0) await tester.pump(time - previousTime);
          previousTime = time;
          expect(tester.state(find.byType(TrainerPlayer)), same(player));
          expect(tester.element(scaffold), same(scaffoldElement));
          expect(tester.state(scaffold), same(scaffoldState));
          expect(tester.renderObject<RenderBox>(viewport), same(viewportBox));
          expect(tester.getRect(viewport), stageRect, reason: 'frame $frame');
          final dockHeight = tester.getSize(dock).height;
          if (dockHeight > 172 && dockHeight < 300) {
            if (frame >= 45 && frame < 75) sawDockExpand = true;
            if (frame >= 90 && frame < 120) sawDockCollapse = true;
          }
          if (frame == 30 || frame == 75 || frame == 120) {
            final rest = frame == 75;
            expect(dockHeight, rest ? 300 : 172);
            final feedback = find.text('刚才感觉怎么样？').hitTestable();
            expect(feedback, rest ? findsOneWidget : findsNothing);
            if (rest) {
              expect(find.textContaining('即将开始'), findsOneWidget);
            } else {
              expect(
                find.text(frame == 30 ? '半跪髋屈肌拉伸' : '仰卧四字拉伸'),
                findsWidgets,
              );
            }
            final poster = find.descendant(
              of: viewport,
              matching: find.byType(RawImage),
            );
            expect(poster, findsOneWidget);
            expect(tester.widget<RawImage>(poster).image, isNotNull);
          }
          expect(tester.takeException(), isNull, reason: 'frame $frame');
          await captureFrame(tester, frame);
        }
        expect(sawDockExpand, isTrue);
        expect(sawDockCollapse, isTrue);
        expect(haptics.where((impact) => !impact.endsWith('selectionClick')), [
          'HapticFeedbackType.lightImpact',
          'HapticFeedbackType.lightImpact',
          'HapticFeedbackType.mediumImpact',
        ]);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    } finally {
      debugDisableShadows = oldShadows;
    }
  });

  testWidgets('reduced motion applies phase changes without moving the stage', (
    tester,
  ) async {
    await withClock(Clock(tester.binding.clock.now), () async {
      await mount(tester, reducedMotion: true);
      final viewport = find.byKey(_viewportKey);
      final stageRect = tester.getRect(viewport);
      final feedback = find.text('刚才感觉怎么样？').hitTestable();
      expect(feedback, findsNothing);
      await tester.pump(const Duration(milliseconds: 1600));
      await tester.pump();
      expect(tester.getRect(viewport), stageRect);
      await tester.pump(const Duration(milliseconds: 160));
      expect(feedback, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pump();
      expect(tester.getRect(viewport), stageRect);
      await tester.pump(const Duration(milliseconds: 160));
      expect(feedback, findsNothing);
      expect(find.text('仰卧四字拉伸'), findsWidgets);
      expect(tester.getRect(viewport), stageRect);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  testWidgets(
    'rapid phase changes show the latest action and retain the stage',
    (tester) async {
      await withClock(Clock(tester.binding.clock.now), () async {
        await mount(tester);
        final viewport = find.byKey(_viewportKey);
        final scaffold = find.byKey(_scaffoldKey);
        final stageRect = tester.getRect(viewport);
        final scaffoldElement = tester.element(scaffold);
        final skip = find.byKey(const ValueKey('skip'));
        await tester.tap(skip);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.getRect(viewport), stageRect);
        await tester.tap(skip);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 550));
        await tester.pump();
        expect(tester.element(scaffold), same(scaffoldElement));
        expect(tester.getRect(viewport), stageRect);
        expect(find.text('仰卧四字拉伸'), findsWidgets);
        expect(
          find.byType(TrainerRestFeedbackPanel).hitTestable(),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    },
  );
}
