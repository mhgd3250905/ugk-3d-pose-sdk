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

const _captureKey = ValueKey('player-v1-phase-animation-capture');
const _scaffoldKey = ValueKey('player-v1-scaffold');
const _viewportKey = ValueKey('player-v1-media-viewport');
const _openPlayerKey = ValueKey('open-player-v1');
const _activePosterKey = ValueKey('showcase-active-poster');
const _coverHeroTag = 'ugk-player-cover-lunge';
const _phaseHeaderKey = ValueKey('player-v1-phase-header');
const _phaseCapsulesKey = ValueKey('player-v1-phase-capsules');
const _numberKey = ValueKey('player-v1-countdown-number');
const _unitKey = ValueKey('player-v1-countdown-unit');
const _feedbackSlotKey = ValueKey('player-v1-rest-feedback-slot');
const _sheetKey = ValueKey('player-v1-sheet');

double _paintOpacity(Element element) {
  var opacity = 1.0;
  RenderObject? object = element.renderObject;
  while (object != null) {
    opacity *= switch (object) {
      RenderOpacity(:final opacity) => opacity,
      RenderAnimatedOpacity(:final opacity) => opacity.value,
      RenderOffstage(offstage: true) => 0.0,
      _ => 1.0,
    };
    object = object.parent;
  }
  return opacity;
}

Iterable<Element> _painted(Finder finder) =>
    finder.evaluate().where((element) => _paintOpacity(element) > .002);

Finder _inRegion(Key key, Finder matching) =>
    find.descendant(of: find.byKey(key), matching: matching);

void _expectNoRestOverlap() {
  final strings = TrainerStrings.zh();
  final number = _inRegion(_numberKey, find.byType(Text));
  final unit = _inRegion(_unitKey, find.byType(Text));
  final title = _inRegion(_phaseHeaderKey, find.byType(Text));
  final workDiscomfort = _inRegion(
    _phaseCapsulesKey,
    find.byKey(const ValueKey('discomfort')),
  );
  final upcoming = _inRegion(
    _phaseCapsulesKey,
    find.textContaining(strings.upcomingLabel),
  );
  final digits = _painted(number).toList();
  final unitCount = _painted(unit).length;
  expect(digits.length, inInclusiveRange(1, 2), reason: 'countdown number');
  if (digits.length == 2) {
    Offset center(Element element) {
      final box = element.renderObject! as RenderBox;
      return box.localToGlobal(box.size.center(Offset.zero));
    }

    final first = center(digits.first);
    final last = center(digits.last);
    expect(first.dx, closeTo(last.dx, .01), reason: 'countdown numeric center');
    expect(
      first.dy,
      isNot(closeTo(last.dy, .01)),
      reason: 'vertical number roll',
    );
  }
  expect(unitCount, lessThanOrEqualTo(1), reason: 'countdown unit');
  expect(_painted(title).length, lessThanOrEqualTo(2), reason: 'phase header');
  expect(
    _painted(workDiscomfort).isNotEmpty && _painted(upcoming).isNotEmpty,
    isFalse,
    reason: 'phase capsules',
  );
}

class _RestOverlapSession extends SessionBuilder {
  @override
  List<SessionPhase> phases(TrainingPlan plan) {
    final phases = DemoSessionBuilder(ShowcaseState.training).phases(plan);
    return [
      phases.first.withSeconds(1.6),
      phases.firstWhere((phase) => phase.kind == PhaseKind.rest).withSeconds(2),
      phases.lastWhere((phase) => phase.isWork).withSeconds(3),
      phases.last,
    ];
  }
}

class _TransitionSession extends SessionBuilder {
  _TransitionSession(this.phaseSeconds);

  final double phaseSeconds;

  @override
  List<SessionPhase> phases(TrainingPlan plan) {
    final phases = DemoSessionBuilder(ShowcaseState.training).phases(plan);
    return [
      phases.first.withSeconds(phaseSeconds),
      phases
          .firstWhere((phase) => phase.kind == PhaseKind.rest)
          .withSeconds(phaseSeconds),
      phases.lastWhere((phase) => phase.isWork).withSeconds(4),
      phases.last,
    ];
  }
}

class _FullFlowSession extends SessionBuilder {
  @override
  List<SessionPhase> phases(TrainingPlan plan) {
    final phases = DemoSessionBuilder(ShowcaseState.preview).phases(plan);
    return [
      phases[0].withSeconds(3),
      phases[1].withSeconds(1.6),
      phases[2].withSeconds(.8),
      phases[3].withSeconds(1.6),
      phases[4].withSeconds(1.6),
      phases[5].withSeconds(2.4),
      phases[6],
    ];
  }
}

class _ManualFlowSession extends SessionBuilder {
  @override
  List<SessionPhase> phases(TrainingPlan plan) {
    final phases = DemoSessionBuilder(ShowcaseState.training).phases(plan);
    return [
      phases.first.withSeconds(8),
      phases.lastWhere((phase) => phase.isWork).withSeconds(8),
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
  final fullFlowPath = Platform.environment['SHOWCASE_FULL_FLOW_FRAMES'];
  final fullFlowOutput = fullFlowPath == null || fullFlowPath.isEmpty
      ? null
      : Directory(fullFlowPath);
  final fullFlowClips = Platform.environment['SHOWCASE_FULL_FLOW_CLIPS']
      ?.split(',')
      .toSet();
  final sheets =
      output != null && Platform.environment['SHOWCASE_PHASE_SHEETS'] == '1';
  final fps = sheets ? 25 : 30;
  // Both phase boundaries land exactly on a 40 ms sample for the sheets.
  final phaseMilliseconds = sheets ? 1600 : 1500;
  String? fontFamily;

  setUpAll(() async {
    if (output == null && fullFlowOutput == null) return;
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
    await output?.create(recursive: true);
    await fullFlowOutput?.create(recursive: true);
  });

  Future<TrainerSlideRoute<void>?> mount(
    WidgetTester tester, {
    bool reducedMotion = false,
    bool dark = false,
    bool withCoverRoute = false,
    double phaseSeconds = 1.5,
    SessionBuilder? sessionBuilder,
    ValueChanged<SessionResult>? onSaved,
  }) async {
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
    final theme = (dark ? TrainerTheme.playerV1Dark : TrainerTheme.playerV1)
        .copyWith(fontFamily: fontFamily);
    final coverAsset = _drill('lunge')!.media!.posterAsset;
    Widget player({Future<void>? startGate}) => TrainerPlayer(
      plan: demoPlan,
      drillOf: _drill,
      theme: theme,
      strings: TrainerStrings.zh(),
      sessionBuilder: sessionBuilder ?? _TransitionSession(phaseSeconds),
      keepAlive: false,
      voice: TrainerVoice.silent,
      tick: const Duration(milliseconds: 20),
      startGate: startGate,
      coverHeroTag: withCoverRoute ? _coverHeroTag : null,
      coverHeroAsset: withCoverRoute ? coverAsset : null,
      mediaBuilder: (_, request) => TrainerPoster(
        key: _activePosterKey,
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
      onFinished: (result) async => onSaved?.call(result),
    );
    TrainerSlideRoute<void>? openedRoute;
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: theme.brightness, fontFamily: fontFamily),
        builder: (context, child) => RepaintBoundary(
          key: _captureKey,
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reducedMotion),
            child: child!,
          ),
        ),
        home: withCoverRoute
            ? Scaffold(
                body: Builder(
                  builder: (context) => Center(
                    child: GestureDetector(
                      key: _openPlayerKey,
                      onTap: () {
                        late final TrainerSlideRoute<void> route;
                        route = TrainerSlideRoute<void>(
                          context: context,
                          trainerTheme: theme,
                          builder: (_) =>
                              player(startGate: route.control.startGate),
                        );
                        openedRoute = route;
                        Navigator.of(context).push(route);
                      },
                      child: SizedBox(
                        width: 144,
                        height: 144,
                        child: Hero(
                          tag: _coverHeroTag,
                          child: TrainerPoster(asset: coverAsset),
                        ),
                      ),
                    ),
                  ),
                ),
              )
            : player(),
      ),
    );
    await tester.pump();
    if (withCoverRoute) {
      await tester.tap(find.byKey(_openPlayerKey));
      await tester.pump();
      await tester.pump();
    }
    return openedRoute;
  }

  Future<void> captureNamed(
    WidgetTester tester,
    String name,
    Directory? frameOutput,
  ) async {
    if (frameOutput == null) return;
    if (fullFlowClips != null &&
        output?.path != frameOutput.path &&
        !fullFlowClips.any((clip) => name.startsWith('$clip-'))) {
      return;
    }
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('${frameOutput.path}/$name.png').writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      } finally {
        image.dispose();
      }
    });
  }

  Future<void> captureFrame(
    WidgetTester tester,
    int frame,
    Directory? frameOutput,
  ) => captureNamed(
    tester,
    'frame-${frame.toString().padLeft(3, '0')}',
    frameOutput,
  );

  for (final dark in sheets ? [false, true] : [false]) {
    testWidgets('natural work and rest transitions retain the media viewport '
        '(${dark ? 'dark' : 'light'})', (tester) async {
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
          await mount(
            tester,
            dark: dark,
            phaseSeconds: phaseMilliseconds / 1000,
          );
          final themeName = dark ? 'dark' : 'light';
          final frameOutput = sheets
              ? Directory('${output.path}/$themeName')
              : output;
          if (frameOutput != null) {
            await tester.runAsync(() => frameOutput.create(recursive: true));
          }
          final scaffold = find.byKey(_scaffoldKey);
          final viewport = find.byKey(_viewportKey);
          final dock = find.byKey(const ValueKey('player-v1-dock'));
          final player = tester.state(find.byType(TrainerPlayer));
          final scaffoldElement = tester.element(scaffold);
          final scaffoldState = tester.state(scaffold);
          final viewportBox = tester.renderObject<RenderBox>(viewport);
          final stageRect = tester.getRect(viewport);
          expect(stageRect.size.shortestSide, greaterThan(0));
          final restFrame = phaseMilliseconds * fps ~/ 1000;
          final nextWorkFrame = 2 * restFrame;
          final restSettledFrame = restFrame + fps;
          final workSettledFrame = nextWorkFrame + fps;

          var previousTime = Duration.zero;
          var sawDockExpand = false;
          var sawDockCollapse = false;
          for (var frame = 0; frame <= 5 * fps; frame++) {
            final time = Duration(
              microseconds: (frame * Duration.microsecondsPerSecond / fps)
                  .round(),
            );
            if (frame != 0) await tester.pump(time - previousTime);
            previousTime = time;
            expect(tester.state(find.byType(TrainerPlayer)), same(player));
            expect(tester.element(scaffold), same(scaffoldElement));
            expect(tester.state(scaffold), same(scaffoldState));
            expect(tester.renderObject<RenderBox>(viewport), same(viewportBox));
            final currentRect = tester.getRect(viewport);
            expect(currentRect, stageRect, reason: 'frame $frame');
            final dockHeight = tester.getSize(dock).height;
            if (dockHeight > 172 && dockHeight < 300) {
              if (frame >= restFrame && frame < restSettledFrame) {
                sawDockExpand = true;
              }
              if (frame >= nextWorkFrame && frame < workSettledFrame) {
                sawDockCollapse = true;
              }
            }
            if (frame == fps ||
                frame == restSettledFrame ||
                frame == workSettledFrame) {
              final rest = frame == restSettledFrame;
              expect(dockHeight, rest ? 300 : 172);
              final feedback = find.text('刚才感觉怎么样？').hitTestable();
              expect(feedback, rest ? findsOneWidget : findsNothing);
              if (rest) {
                expect(find.textContaining('即将开始'), findsOneWidget);
              } else {
                expect(
                  find.text(frame == fps ? '半跪髋屈肌拉伸' : '仰卧四字拉伸'),
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
            if (sheets) {
              for (final (direction, firstFrame) in [
                ('work-to-rest', restFrame),
                ('rest-to-work', nextWorkFrame),
              ]) {
                final relativeFrame = frame - firstFrame;
                if (relativeFrame < -1 || relativeFrame > 12) continue;
                final offset = relativeFrame * 40;
                debugPrint(
                  'media viewport $themeName $direction t=$offset ms '
                  'frame=$frame rect=$currentRect',
                );
                if (relativeFrame >= 0) {
                  await captureFrame(tester, frame, frameOutput);
                }
              }
            } else {
              await captureFrame(tester, frame, frameOutput);
            }
          }
          expect(sawDockExpand, isTrue);
          expect(sawDockCollapse, isTrue);
          expect(
            haptics.where((impact) => !impact.endsWith('selectionClick')),
            [
              'HapticFeedbackType.mediumImpact',
              'HapticFeedbackType.mediumImpact',
            ],
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        });
      } finally {
        debugDisableShadows = oldShadows;
      }
    });
  }

  for (final dark in [false, true]) {
    testWidgets('full Player V1 phase sequence (${dark ? 'dark' : 'light'})', (
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
          final results = <SessionResult>[];
          final palette = dark ? 'dark' : 'light';
          final folder = fullFlowOutput == null
              ? null
              : Directory('${fullFlowOutput.path}/$palette');
          if (folder != null) {
            await tester.runAsync(() => folder.create(recursive: true));
          }
          await mount(
            tester,
            dark: dark,
            sessionBuilder: _FullFlowSession(),
            onSaved: results.add,
          );

          final player = tester.state(find.byType(TrainerPlayer));
          final scaffold = find.byKey(_scaffoldKey);
          final viewport = find.byKey(_viewportKey);
          final scaffoldState = tester.state(scaffold);
          final stage = tester.renderObject<RenderBox>(viewport);
          final rect = tester.getRect(viewport);
          final pause = find.byKey(const ValueKey('pause'));
          final discomfort = find.byKey(const ValueKey('discomfort'));
          final continueAction = find.byKey(
            const ValueKey('discomfort-continueEasier'),
          );
          final finish = find.byKey(const ValueKey('finish'));
          var elapsed = 0;

          void verifyStage() {
            expect(tester.state(find.byType(TrainerPlayer)), same(player));
            expect(tester.state(scaffold), same(scaffoldState));
            expect(tester.renderObject<RenderBox>(viewport), same(stage));
            expect(
              tester.getRect(viewport),
              rect,
              reason: '$palette $elapsed ms',
            );
          }

          Future<void> advance(int time) async {
            expect(time, greaterThanOrEqualTo(elapsed));
            while (elapsed < time) {
              final step = (time - elapsed).clamp(1, 40);
              await tester.pump(Duration(milliseconds: step));
              elapsed += step;
              verifyStage();
              expect(
                tester.takeException(),
                isNull,
                reason: '$palette $elapsed ms',
              );
            }
          }

          Future<void> clip(
            String name,
            int start,
            int duration, {
            VoidCallback? checkFrame,
          }) async {
            for (var offset = 0; offset <= duration; offset += 40) {
              await advance(start + offset);
              checkFrame?.call();
              await captureNamed(
                tester,
                '$name-${offset.toString().padLeft(3, '0')}',
                folder,
              );
            }
          }

          Future<void> landmark(String name) async {
            verifyStage();
            debugPrint('full flow $palette $name t=$elapsed ms rect=$rect');
            await captureNamed(tester, name, folder);
          }

          void expectPlaying(bool playing) {
            expect(tester.widget<UgkPlayPauseButton>(pause).isPlaying, playing);
          }

          final strings = TrainerStrings.zh();
          await advance(200);
          expect(find.textContaining(strings.prepFirst), findsWidgets);
          await landmark('01-prep');
          await clip('prep-to-right', 3000, 560);
          await advance(3600);
          expect(
            find.textContaining(strings.sideName(Side.right)),
            findsWidgets,
          );
          await landmark('02-work-right');
          await clip('right-to-switch', 4600, 480);
          expect(
            find.textContaining(strings.switchTo(Side.left)),
            findsWidgets,
          );
          await landmark('03-switch');
          await clip('switch-to-left', 5400, 480);
          await advance(6040);
          expect(
            find.textContaining(strings.sideName(Side.left)),
            findsWidgets,
          );
          await landmark('04-work-left');
          await clip(
            'left-to-rest',
            7000,
            760,
            checkFrame: _expectNoRestOverlap,
          );
          expect(find.text('刚才感觉怎么样？').hitTestable(), findsOneWidget);
          await landmark('05-rest');
          await clip(
            'rest-to-next',
            8600,
            480,
            checkFrame: _expectNoRestOverlap,
          );
          await advance(9200);
          expect(find.text('仰卧四字拉伸'), findsWidgets);
          expectPlaying(true);
          await landmark('06-next-work');

          final pauseStartedAt = elapsed;
          await tester.tap(pause);
          await tester.pump();
          await clip('work-to-pause', elapsed, 480);
          expectPlaying(false);
          await landmark('07-paused');
          final pausedFor = elapsed - pauseStartedAt;
          await tester.tap(pause);
          await tester.pump();
          await clip('pause-to-work', elapsed, 480);
          expectPlaying(true);
          await landmark('08-resumed');

          final sheetOpenedAt = elapsed;
          await tester.tap(discomfort);
          await tester.pump();
          await clip('discomfort-open', elapsed, 480);
          expect(continueAction.hitTestable(), findsOneWidget);
          expect(
            tester.getSize(find.byKey(_sheetKey)).height,
            lessThan(tester.view.physicalSize.height / 2),
          );
          expectPlaying(false);
          await landmark('09-discomfort');
          await tester.tap(continueAction);
          await tester.pump();
          await clip('discomfort-close', elapsed, 480);
          expect(continueAction, findsNothing);
          expectPlaying(true);
          await landmark('10-continued');

          // Clock time spent on a paused phase or open sheet does not count
          // toward the session's natural work boundary.
          final sheetPause = elapsed - sheetOpenedAt - 480;
          final idle = pausedFor + sheetPause;
          final doneAt = 11000 + idle;
          await clip('work-to-done', doneAt, 2400);
          expect(finish.hitTestable(), findsOneWidget);
          expect(results, hasLength(1));
          expect(results.single.full, isTrue);
          expect(results.single.completedExercises, 2);
          expect(
            results.single.discomfort.single.action,
            DiscomfortAction.continueEasier,
          );
          expect(
            find.descendant(of: viewport, matching: find.byType(TrainerPoster)),
            findsNothing,
          );
          expect(
            haptics.where((impact) => impact.endsWith('mediumImpact')),
            hasLength(3),
          );
          expect(
            haptics.where((impact) => impact.endsWith('heavyImpact')),
            hasLength(1),
          );
          await landmark('11-completion');
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          expect(tester.takeException(), isNull);
        });
      } finally {
        debugDisableShadows = oldShadows;
      }
    });
  }

  for (final dark in [false, true]) {
    final palette = dark ? 'dark' : 'light';
    testWidgets('rest transitions paint one phase at a time ($palette)', (
      tester,
    ) async {
      await withClock(Clock(tester.binding.clock.now), () async {
        await mount(tester, dark: dark, sessionBuilder: _RestOverlapSession());
        final viewport = find.byKey(_viewportKey);
        final stage = tester.renderObject<RenderBox>(viewport);
        final rect = tester.getRect(viewport);
        final header = _inRegion(_phaseHeaderKey, find.byType(Text));
        final number = _inRegion(_numberKey, find.byType(Text));
        final unit = _inRegion(_unitKey, find.byType(Text));
        final feedback = _inRegion(_feedbackSlotKey, find.text('刚才感觉怎么样？'));
        final feedbackOptions = [
          for (final label in ['舒服', '有点紧', '疼'])
            _inRegion(_feedbackSlotKey, find.text(label)),
        ];

        void expectRegionsPainted() {
          expect(_painted(header), hasLength(2));
          expect(_painted(number), hasLength(1));
          expect(_painted(unit), hasLength(1));
        }

        void expectFrame() {
          expect(tester.renderObject<RenderBox>(viewport), same(stage));
          expect(tester.getRect(viewport), rect);
          _expectNoRestOverlap();
          expect(tester.takeException(), isNull);
        }

        // Advance the initial work phase without combining multiple motion
        // ticks into a single frame at the transition boundary.
        for (var time = 40; time <= 1600; time += 40) {
          await tester.pump(const Duration(milliseconds: 40));
        }
        expectRegionsPainted();

        for (var time = 0; time <= 760; time += 40) {
          if (time != 0) {
            await tester.pump(const Duration(milliseconds: 40));
          }
          expectFrame();
          if (time < 380) {
            expect(_painted(feedback), isEmpty, reason: 'title at $time ms');
            for (final option in feedbackOptions) {
              expect(_painted(option), isEmpty, reason: 'button at $time ms');
              expect(option.hitTestable(), findsNothing);
            }
          }
        }
        expectRegionsPainted();
        expect(_painted(feedback), hasLength(1));
        for (final option in feedbackOptions) {
          expect(_painted(option), hasLength(1));
          expect(option.hitTestable(), findsOneWidget);
        }

        for (var time = 800; time <= 2000; time += 40) {
          await tester.pump(const Duration(milliseconds: 40));
        }
        for (var time = 0; time <= 480; time += 40) {
          if (time != 0) {
            await tester.pump(const Duration(milliseconds: 40));
          }
          expectFrame();
        }
        expectRegionsPainted();
        expect(_painted(feedback), isEmpty);
        expect(find.text('仰卧四字拉伸'), findsWidgets);
        debugPrint('rest transitions $palette verified rect=$rect');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    });
  }

  for (final dark in [false, true]) {
    final palette = dark ? 'dark' : 'light';
    testWidgets('host cover lands in the Player V1 viewport ($palette)', (
      tester,
    ) async {
      await withClock(Clock(tester.binding.clock.now), () async {
        final folder = fullFlowOutput == null
            ? null
            : Directory('${fullFlowOutput.path}/$palette');
        if (folder != null) {
          await tester.runAsync(() => folder.create(recursive: true));
        }
        final route = (await mount(
          tester,
          dark: dark,
          withCoverRoute: true,
          sessionBuilder: _FullFlowSession(),
        ))!;
        final viewport = find.byKey(_viewportKey);
        final coverAsset = _drill('lunge')!.media!.posterAsset;
        final media = find.byKey(_activePosterKey);
        final coverPoster = find.byWidgetPredicate(
          (widget) => widget is TrainerPoster && widget.asset == coverAsset,
        );
        final target = find.descendant(
          of: viewport,
          matching: find.byWidgetPredicate(
            (widget) => widget is Hero && widget.tag == _coverHeroTag,
          ),
        );
        final player = tester.state(find.byType(TrainerPlayer));
        final rect = tester.getRect(viewport);
        final landing = Rect.fromCenter(
          center: rect.center,
          width: rect.width,
          height: rect.width,
        );
        expect(route.transitionDuration, const Duration(milliseconds: 420));
        expect(route.control.entered, isFalse);

        for (var time = 0; time <= 680; time += 40) {
          if (time != 0) {
            await tester.pump(const Duration(milliseconds: 40));
          }
          expect(tester.state(find.byType(TrainerPlayer)), same(player));
          expect(tester.getRect(viewport), rect);
          if (time == 200) {
            expect(route.control.entered, isFalse);
            final staged = find
                .descendant(of: viewport, matching: coverPoster)
                .evaluate()
                .toSet();
            final flightFinder = find.byElementPredicate(
              (element) =>
                  element.widget is TrainerPoster &&
                  (element.widget as TrainerPoster).asset == coverAsset &&
                  !staged.contains(element),
            );
            expect(flightFinder, findsOneWidget);
            final flight = tester.getRect(flightFinder);
            expect(flight.width, greaterThan(144));
            expect(flight.width, lessThan(rect.width));
            expect(flight.center.dy, inExclusiveRange(rect.center.dy, 400.0));
          } else if (time == 440) {
            expect(route.control.entered, isTrue);
            expect(target, findsOneWidget);
            final landedCover = find.descendant(
              of: target,
              matching: coverPoster,
            );
            expect(landedCover, findsOneWidget);
            expect(tester.getRect(landedCover), landing);
          } else if (time == 680) {
            expect(target, findsNothing);
            expect(coverPoster, findsOneWidget);
            expect(media, findsOneWidget);
            expect(tester.widget<TrainerPoster>(media).asset, coverAsset);
            expect(tester.getRect(media), landing);
            expect(media.hitTestable(), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          await captureNamed(
            tester,
            'cover-entry-${time.toString().padLeft(3, '0')}',
            folder,
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    });

    testWidgets('manual navigation and exit confirmation ($palette)', (
      tester,
    ) async {
      await withClock(Clock(tester.binding.clock.now), () async {
        final folder = fullFlowOutput == null
            ? null
            : Directory('${fullFlowOutput.path}/$palette');
        if (folder != null) {
          await tester.runAsync(() => folder.create(recursive: true));
        }
        final results = <SessionResult>[];
        await mount(
          tester,
          dark: dark,
          sessionBuilder: _ManualFlowSession(),
          onSaved: results.add,
        );
        await tester.pump(const Duration(milliseconds: 680));

        final viewport = find.byKey(_viewportKey);
        final stage = tester.renderObject<RenderBox>(viewport);
        final rect = tester.getRect(viewport);
        final scaffold = find.byKey(_scaffoldKey);
        final scaffoldState = tester.state(scaffold);
        final pause = find.byKey(const ValueKey('pause'));
        final keepTraining = find.byKey(const ValueKey('close-cancel'));

        Future<void> tapAndCapture(Finder button, String name) async {
          expect(button.hitTestable(), findsOneWidget);
          await tester.tap(button);
          await tester.pump();
          for (var time = 0; time <= 480; time += 40) {
            if (time != 0) {
              await tester.pump(const Duration(milliseconds: 40));
            }
            expect(tester.state(scaffold), same(scaffoldState));
            expect(tester.renderObject<RenderBox>(viewport), same(stage));
            expect(tester.getRect(viewport), rect);
            expect(tester.takeException(), isNull);
            await captureNamed(
              tester,
              '$name-${time.toString().padLeft(3, '0')}',
              folder,
            );
          }
        }

        await tapAndCapture(find.byKey(const ValueKey('skip')), 'manual-next');
        expect(find.byKey(const ValueKey('media-reach')), findsOneWidget);
        await tapAndCapture(find.byKey(const ValueKey('prev')), 'manual-prev');
        expect(find.byKey(const ValueKey('media-lunge')), findsOneWidget);
        await tapAndCapture(find.byKey(const ValueKey('close')), 'exit-open');
        expect(keepTraining.hitTestable(), findsOneWidget);
        expect(
          tester.getSize(find.byKey(_sheetKey)).height,
          lessThan(tester.view.physicalSize.height / 2),
        );
        expect(tester.widget<UgkPlayPauseButton>(pause).isPlaying, isFalse);
        await tapAndCapture(keepTraining, 'exit-dismiss');
        expect(keepTraining, findsNothing);
        expect(tester.widget<UgkPlayPauseButton>(pause).isPlaying, isTrue);
        expect(results, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    });
  }

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
