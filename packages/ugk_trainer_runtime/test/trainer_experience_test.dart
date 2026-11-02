import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer_runtime/src/media/media_view.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

const _redPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';
const _greenPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNg+M/wHwAEAQH/cetH5QAAAABJRU5ErkJggg==';

class _Bundle extends CachingAssetBundle {
  _Bundle({this.green});

  final slow = Completer<ByteData>();
  final Completer<ByteData>? green;

  @override
  Future<ByteData> load(String key) async {
    if (key == 'AssetManifest.bin') {
      return const StandardMessageCodec().encodeMessage({})!;
    }
    if (key == 'slow.png') return slow.future;
    if (key == 'b.png' && green != null) return green!.future;
    if (key == 'a.png' || key == 'b.png') {
      return ByteData.sublistView(
        base64Decode(key == 'a.png' ? _redPng : _greenPng),
      );
    }
    throw FlutterError('Not bundled: $key');
  }
}

DrillMedia _media(String id) => DrillMedia(
  id: id,
  videoAsset: '$id.mp4',
  posterAsset: '$id.png',
  duration: 30,
  bundledOnly: true,
);

TrainingPlan _plan() => TrainingPlan(
  id: 'experience',
  source: 'template',
  title: 'Experience',
  goal: 'core',
  scene: 'home',
  level: 1,
  targetMinutes: 1,
  blocks: [
    PlanBlock(
      id: 'main',
      name: 'Main',
      type: BlockType.main,
      items: [
        for (final id in ['a', 'b'])
          PlanItem(
            exerciseId: id,
            mode: DoseMode.time,
            sets: 1,
            workSeconds: 30,
            perSide: false,
            restSeconds: 0,
          ),
      ],
    ),
  ],
);

Future<BuildContext> _host(WidgetTester tester, _Bundle bundle) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late BuildContext source;
  await tester.pumpWidget(
    MaterialApp(
      home: DefaultAssetBundle(
        bundle: bundle,
        child: Builder(
          builder: (context) {
            source = context;
            return const Scaffold(body: Text('source'));
          },
        ),
      ),
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  return source;
}

Future<void> _warm(
  WidgetTester tester,
  BuildContext context,
  String asset,
) async {
  final ready = await tester.runAsync(
    () => TrainingPosterImages.prepareAsset(
      context,
      asset,
      timeout: const Duration(seconds: 2),
    ),
  );
  expect(ready, isTrue);
}

Future<void> _enter(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(microseconds: 1));
  await tester.pump();
}

void _sideGlyphs(WidgetTester tester) {
  for (final pair in [
    ('prev', CupertinoIcons.backward_end_fill),
    ('skip', CupertinoIcons.forward_end_fill),
  ]) {
    final icons = find.descendant(
      of: find.byKey(ValueKey(pair.$1)),
      matching: find.byType(Icon),
    );
    expect(icons, findsOneWidget);
    expect(tester.widget<Icon>(icons).icon, pair.$2);
  }
}

Future<List<int>> _posterPixel(WidgetTester tester) async {
  final image = tester.widget<RawImage>(find.byType(RawImage)).image!;
  final bytes = await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  return bytes!.buffer.asUint8List(bytes.offsetInBytes, 4).toList();
}

void main() {
  testWidgets('warming and painting use the same bundle and decode key', (
    tester,
  ) async {
    final bundle = _Bundle();
    final source = await _host(tester, bundle);
    await _warm(tester, source, 'a.png');
    final width = TrainingPosterImages.decodeWidth(source);
    final provider = TrainingPosterImages.provider(
      'a.png',
      width,
      bundle: bundle,
    );
    final key = await provider.obtainKey(createLocalImageConfiguration(source));
    unawaited(
      TrainerLauncher.open<void>(
        source,
        firstPosterAsset: 'a.png',
        builder: (_) => const TrainerPoster(asset: 'a.png'),
      ),
    );
    await tester.pump();
    await tester.pump();
    final posterContext = tester.element(find.byType(TrainerPoster));
    final painted = TrainingPosterImages.provider(
      'a.png',
      TrainingPosterImages.decodeWidth(posterContext),
      bundle: DefaultAssetBundle.of(posterContext),
    );
    expect(
      await painted.obtainKey(createLocalImageConfiguration(posterContext)),
      key,
    );
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(find.byType(AnimatedOpacity), findsNothing);
  });

  testWidgets(
    'default entry holds video and clock, keeping side glyphs stable',
    (tester) async {
      final source = await _host(tester, _Bundle());
      await _warm(tester, source, 'a.png');
      unawaited(
        TrainerLauncher.open<void>(
          source,
          firstPosterAsset: 'a.png',
          builder: (_) => TrainerPlayer(
            plan: _plan(),
            drillOf: (id) => TrainerDrill(id: id, name: id, media: _media(id)),
            strings: TrainerStrings.en(),
            prepSeconds: 0,
            transitionSeconds: 0,
            keepAlive: false,
            onFinished: (_) async {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      for (var frame = 0; frame < 19; frame++) {
        expect(find.byType(DrillMediaPlatformView), findsNothing);
        expect(find.byType(UgkPackedAlphaVideo), findsNothing);
        expect(
          tester.widget<RawImage>(find.byType(RawImage).first).image,
          isNotNull,
        );
        _sideGlyphs(tester);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(microseconds: 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byType(DrillMediaPlatformView), findsOneWidget);
      _sideGlyphs(tester);
      final playerContext = tester.element(find.byType(TrainerPlayer));
      TrainerExperienceScope.read(playerContext)!.control.beginExit();
      await tester.pump();
      expect(find.byType(DrillMediaPlatformView), findsNothing);
      expect(
        tester.widget<RawImage>(find.byType(RawImage).first).image,
        isNotNull,
      );
      _sideGlyphs(tester);
    },
  );

  testWidgets('shared switching retains target poster until real first frame', (
    tester,
  ) async {
    final source = await _host(tester, _Bundle());
    await _warm(tester, source, 'a.png');
    await _warm(tester, source, 'b.png');
    final selected = ValueNotifier('a');
    addTearDown(selected.dispose);
    unawaited(
      TrainerLauncher.open<void>(
        source,
        firstPosterAsset: 'a.png',
        builder: (_) => ValueListenableBuilder(
          valueListenable: selected,
          builder: (_, id, _) => Center(
            child: SizedBox.square(
              dimension: 200,
              child: DrillMediaHandoff(
                child: DrillMediaView(media: _media(id)),
              ),
            ),
          ),
        ),
      ),
    );
    await _enter(tester);
    await tester.pump(const Duration(milliseconds: 150));
    expect(await _posterPixel(tester), [255, 0, 0, 255]);
    selected.value = 'b';
    await tester.pump();
    expect(
      tester.widget<TrainerPoster>(find.byType(TrainerPoster)).asset,
      'b.png',
    );
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(await _posterPixel(tester), [0, 255, 0, 255]);
    expect(find.byType(DrillMediaPlatformView), findsNothing);
    await tester.pump(const Duration(milliseconds: 150));
    final surface = tester.widget<DrillMediaPlatformView>(
      find.byType(DrillMediaPlatformView),
    );
    expect(surface.media.id, 'b');
    surface.controller.failed = false;
    surface.controller.receive({'source': 'drill-media', 'type': 'ready'});
    await tester.pump();
    final reveal = find.byKey(
      ValueKey(('drill-video-reveal', surface.controller)),
    );
    expect(tester.widget<AnimatedOpacity>(reveal).opacity, 1 / 255);
    surface.controller.receive({
      'source': 'drill-media',
      'type': 'first-frame',
    });
    await tester.pump();
    expect(tester.widget<AnimatedOpacity>(reveal).opacity, 1);
  });

  testWidgets('one launch per navigator stays locked through route removal', (
    tester,
  ) async {
    final source = await _host(tester, _Bundle());
    await _warm(tester, source, 'a.png');
    var builds = 0;
    Future<int?> launch() => TrainerLauncher.open<int>(
      source,
      firstPosterAsset: 'a.png',
      builder: (_) {
        builds++;
        return const SizedBox();
      },
    );
    final first = launch();
    expect(await launch(), isNull);
    await _enter(tester);
    expect(builds, 1);
    Navigator.of(source).pop();
    await tester.pump();
    expect(await launch(), isNull);
    await tester.pumpAndSettle();
    expect(await first, isNull);
    unawaited(launch());
    await _enter(tester);
    expect(builds, 2);
  });

  testWidgets('cold target poster retains captured still while decoding', (
    tester,
  ) async {
    final green = Completer<ByteData>();
    final bundle = _Bundle(green: green);
    final source = await _host(tester, bundle);
    await _warm(tester, source, 'a.png');
    final selected = ValueNotifier('a');
    addTearDown(selected.dispose);
    unawaited(
      TrainerLauncher.open<void>(
        source,
        firstPosterAsset: 'a.png',
        builder: (_) => ValueListenableBuilder(
          valueListenable: selected,
          builder: (_, id, _) => SizedBox.square(
            dimension: 200,
            child: DrillMediaHandoff(child: DrillMediaView(media: _media(id))),
          ),
        ),
      ),
    );
    await _enter(tester);
    await tester.pump(const Duration(milliseconds: 150));
    final old = tester
        .widget<DrillMediaPlatformView>(find.byType(DrillMediaPlatformView))
        .controller;
    old.failed = false;
    old.receive({'source': 'drill-media', 'type': 'first-frame'});
    old.attach((command) {
      if (command['type'] == 'capture-and-pause') {
        old.receive({
          'source': 'drill-media',
          'type': 'frame',
          'captureId': command['captureId'],
          'frame': _redPng,
        });
      }
    });
    selected.value = 'b';
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 45));
    await tester.pump();
    final retained = tester.widget<Image>(
      find.byKey(const ValueKey('drill-static-frame')),
    );
    expect((retained.image as MemoryImage).bytes, base64Decode(_redPng));
    expect(green.isCompleted, isFalse);
    await tester.pump(const Duration(milliseconds: 105));
    final current = tester.widget<DrillMediaPlatformView>(
      find.byType(DrillMediaPlatformView),
    );
    expect(current.media.id, 'b');
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(ValueKey(('drill-video-reveal', current.controller))),
          )
          .opacity,
      1 / 255,
    );
    green.complete(ByteData.sublistView(base64Decode(_greenPng)));
    await _warm(tester, source, 'b.png');
    await tester.pump();
    expect(await _posterPixel(tester), [0, 255, 0, 255]);
    expect(find.byKey(const ValueKey('drill-static-frame')), findsNothing);
  });

  testWidgets('leaving foreground during warmup never starts or pushes', (
    tester,
  ) async {
    final source = await _host(tester, _Bundle());
    await _warm(tester, source, 'a.png');
    var starts = 0;
    var builds = 0;
    final launch = TrainerLauncher.open<int>(
      source,
      firstPosterAsset: 'a.png',
      onStarting: () async {
        starts++;
        return true;
      },
      builder: (_) {
        builds++;
        return const SizedBox();
      },
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(await launch, isNull);
    expect(starts, 0);
    expect(builds, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('failed or timed-out first poster never opens a route', (
    tester,
  ) async {
    final source = await _host(tester, _Bundle());
    var builds = 0;
    var starts = 0;
    var holds = 0;
    var releases = 0;
    for (final asset in ['missing.png', 'slow.png']) {
      final future = TrainerLauncher.open<int>(
        source,
        firstPosterAsset: asset,
        builder: (_) {
          builds++;
          return const SizedBox();
        },
        onStarting: () async {
          starts++;
          return true;
        },
        holdTransition: () {
          holds++;
          return () => releases++;
        },
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 151));
      expect(await future, isNull);
      expect(find.text('source'), findsOneWidget);
    }
    expect(builds, 0);
    expect(starts, 0);
    expect(holds, 2);
    expect(releases, 2);
  });
}
