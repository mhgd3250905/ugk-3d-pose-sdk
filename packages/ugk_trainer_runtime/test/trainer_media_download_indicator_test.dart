import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

const _id = 'h-squat';
const _indicatorKey = ValueKey('media-download-indicator');
const _progressKey = ValueKey('media-download-progress');
const _indeterminateKey = ValueKey('media-download-indeterminate');
const _chipKey = ValueKey('media-download-chip');
const _captureEvidence = bool.fromEnvironment('MEDIA_PROGRESS_SCREENSHOTS');

// Local evidence is opt-in; normal test runs need no host fonts or App checkout.
Future<void> _loadEvidenceFonts() async {
  const cjkPath = String.fromEnvironment('MEDIA_PROGRESS_CJK_FONT');
  const materialPath = String.fromEnvironment('MEDIA_PROGRESS_MATERIAL_FONT');
  if (cjkPath.isEmpty || materialPath.isEmpty) {
    throw StateError('Screenshot evidence requires the two local font paths.');
  }
  final cjk = FontLoader('NotoSansSC')
    ..addFont(File(cjkPath).readAsBytes().then(ByteData.sublistView));
  final material = FontLoader('MaterialIcons')
    ..addFont(File(materialPath).readAsBytes().then(ByteData.sublistView));
  final cupertino = FontLoader('packages/cupertino_icons/CupertinoIcons')
    ..addFont(
      rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
    );
  await Future.wait([cjk.load(), material.load(), cupertino.load()]);
}

CatalogMediaDownloadState _state(
  CatalogMediaDownloadPhase phase, {
  int bytes = 0,
  int total = 0,
}) => CatalogMediaDownloadState(
  phase: phase,
  receivedBytes: bytes,
  totalBytes: total,
);

Future<void> _advance(WidgetTester tester, int milliseconds) async {
  await tester.pump();
  for (var elapsed = 0; elapsed < milliseconds; elapsed += 10) {
    await tester.pump(
      Duration(milliseconds: (milliseconds - elapsed).clamp(0, 10)),
    );
  }
}

Future<void> _mount(
  WidgetTester tester, {
  required ValueNotifier<CatalogMediaDownloadState> state,
  required DrillMediaPlaybackHandle handle,
  String id = _id,
  TrainerTheme theme = TrainerTheme.dark,
  TrainerStrings? strings,
  VoidCallback? onRetry,
  bool supported = true,
  bool mirrored = false,
  GlobalKey? captureKey,
}) async {
  if (_captureEvidence) theme = theme.copyWith(fontFamily: 'NotoSansSC');
  tester.view.physicalSize = const Size(390, 320);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        brightness: theme.brightness,
        fontFamily: theme.fontFamily,
      ),
      home: Scaffold(
        backgroundColor: theme.background,
        body: RepaintBoundary(
          key: captureKey,
          child: ColoredBox(
            color: theme.mediaStage,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: Transform.flip(
                    flipX: mirrored,
                    child: Icon(
                      Icons.directions_walk,
                      size: 150,
                      color: theme.muted,
                    ),
                  ),
                ),
                Positioned(
                  top: 24,
                  right: 20,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      TrainerSurface(
                        theme: theme,
                        height: 32,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              CupertinoIcons.waveform_path_ecg,
                              size: 14,
                              color: theme.caution,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              (strings ?? TrainerStrings.zh()).discomfort,
                              style: TextStyle(
                                fontSize: 13,
                                color: theme.caution,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: TrainerSpace.x2),
                      TrainerMediaDownloadIndicator(
                        state: state,
                        actionId: id,
                        theme: theme,
                        strings: strings ?? TrainerStrings.zh(),
                        playbackHandle: handle,
                        onRetry: onRetry ?? () {},
                        videoSupported: supported,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

CircularProgressIndicator _ring(WidgetTester tester) =>
    tester.widget<CircularProgressIndicator>(find.byKey(_progressKey));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (_captureEvidence) await _loadEvidenceFonts();
  });
  late ValueNotifier<CatalogMediaDownloadState> state;
  late DrillMediaPlaybackHandle handle;

  setUp(() {
    state = ValueNotifier(_state(CatalogMediaDownloadPhase.queued));
    handle = DrillMediaPlaybackHandle();
  });
  tearDown(() {
    state.dispose();
    handle.dispose();
  });

  void cleanUp(WidgetTester tester) {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      tester.view.reset();
    });
  }

  testWidgets('ready within 400ms never flashes a download indicator', (
    tester,
  ) async {
    cleanUp(tester);
    await _mount(tester, state: state, handle: handle);
    await _advance(tester, 390);
    expect(find.byKey(_indicatorKey), findsNothing);
    state.value = _state(CatalogMediaDownloadPhase.ready);
    await _advance(tester, 1000);
    expect(find.byKey(_indicatorKey), findsNothing);
  });

  testWidgets('queued and checking rotate after the 400ms delay', (
    tester,
  ) async {
    cleanUp(tester);
    await _mount(tester, state: state, handle: handle);
    await _advance(tester, 399);
    expect(find.byKey(_indicatorKey), findsNothing);
    await _advance(tester, 151);
    expect(find.byKey(_indeterminateKey), findsOneWidget);
    final rotation = tester.widget<RotationTransition>(
      find.byKey(_indeterminateKey),
    );
    final start = rotation.turns.value;
    await _advance(tester, 300);
    expect(rotation.turns.value - start, closeTo(.25, .02));
    state.value = _state(CatalogMediaDownloadPhase.checking);
    await tester.pump();
    expect(find.byKey(_indeterminateKey), findsOneWidget);
  });

  testWidgets(
    'determinate progress uses theme tokens and never moves backwards',
    (tester) async {
      cleanUp(tester);
      state.value = _state(
        CatalogMediaDownloadPhase.downloading,
        bytes: 42,
        total: 100,
      );
      await _mount(tester, state: state, handle: handle);
      await _advance(tester, 550);
      expect(find.byKey(_indeterminateKey), findsNothing);
      expect(_ring(tester).value, closeTo(.42, .001));
      expect(_ring(tester).color, TrainerTheme.dark.accent);
      expect(
        _ring(tester).backgroundColor,
        TrainerTheme.dark.text.withValues(alpha: .12),
      );
      expect(_ring(tester).strokeWidth, 2);
      expect(_ring(tester).strokeCap, StrokeCap.round);
      expect(tester.getSize(find.byKey(_indicatorKey)), const Size(44, 44));
      expect(tester.getSize(find.byKey(_progressKey)), const Size(22, 22));
      expect(
        tester.getSize(find.byKey(const ValueKey('media-download-surface'))),
        const Size(36, 36),
      );
      final arrow = tester.widget<Icon>(
        find.byKey(const ValueKey('media-download-arrow')),
      );
      expect(arrow.icon, CupertinoIcons.arrow_down);
      expect(arrow.size, 12);
      expect(arrow.color, TrainerTheme.dark.accent);
      state.value = _state(
        CatalogMediaDownloadPhase.downloading,
        bytes: 30,
        total: 100,
      );
      await _advance(tester, 200);
      expect(_ring(tester).value, closeTo(.42, .001));
      state.value = _state(
        CatalogMediaDownloadPhase.downloading,
        bytes: 64,
        total: 100,
      );
      await _advance(tester, 100);
      expect(_ring(tester).value, inExclusiveRange(.42, .64));
      await _advance(tester, 100);
      expect(_ring(tester).value, closeTo(.64, .001));
    },
  );

  testWidgets('a download without total bytes stays indeterminate', (
    tester,
  ) async {
    cleanUp(tester);
    state.value = _state(CatalogMediaDownloadPhase.downloading, bytes: 42);
    await _mount(tester, state: state, handle: handle);
    await _advance(tester, 550);
    expect(find.byKey(_indeterminateKey), findsOneWidget);
    await tester.tap(find.byKey(_indicatorKey));
    await tester.pump();
    expect(find.text('正在下载示范…'), findsOneWidget);
  });

  testWidgets('verification fills the ring and pulses the download arrow', (
    tester,
  ) async {
    cleanUp(tester);
    await _mount(tester, state: state, handle: handle);
    await _advance(tester, 550);
    state.value = _state(CatalogMediaDownloadPhase.verifying);
    await _advance(tester, 200);
    expect(_ring(tester).value, 1);
    expect(find.byKey(_indeterminateKey), findsNothing);
    final pulse = tester.widget<FadeTransition>(
      find.byKey(const ValueKey('media-download-verifying')),
    );
    final start = pulse.opacity.value;
    await _advance(tester, 200);
    expect(pulse.opacity.value, isNot(start));
  });

  for (final readyFirst in [true, false]) {
    testWidgets(
      '${readyFirst ? 'ready then frame' : 'frame then ready'} checks for 400ms and fades for 200ms',
      (tester) async {
        cleanUp(tester);
        final decoder = DrillMediaController();
        addTearDown(decoder.dispose);
        handle.bind(owner: decoder, mediaId: _id, controller: decoder);
        await _mount(tester, state: state, handle: handle);
        await _advance(tester, 550);
        if (readyFirst) {
          state.value = _state(CatalogMediaDownloadPhase.ready);
        } else {
          decoder.receive({'source': 'drill-media', 'type': 'first-frame'});
        }
        await _advance(tester, 1000);
        expect(find.byKey(_indicatorKey), findsOneWidget);
        expect(
          find.byKey(const ValueKey('media-download-ready')),
          findsNothing,
        );
        if (readyFirst) {
          decoder.receive({'source': 'drill-media', 'type': 'first-frame'});
        } else {
          state.value = _state(CatalogMediaDownloadPhase.ready);
        }
        // The handle coalesces notifications in a microtask; the next frame then
        // rebuilds the HUD. No real I/O or unbounded animation settling is needed.
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(const ValueKey('media-download-ready')),
          findsOneWidget,
        );
        await _advance(tester, 390);
        expect(find.byKey(_indicatorKey), findsOneWidget);
        FadeTransition visibility() => tester.widget<FadeTransition>(
          find.byKey(const ValueKey('media-download-visibility')),
        );
        expect(visibility().opacity.value, 1);
        await _advance(tester, 10);
        expect(
          find.byKey(const ValueKey('media-download-ready')),
          findsOneWidget,
        );
        await _advance(tester, 100);
        expect(visibility().opacity.value, inExclusiveRange(0, 1));
        await _advance(tester, 100);
        expect(find.byKey(_indicatorKey), findsNothing);
      },
    );
  }

  testWidgets(
    'losing the current frame cancels completion during hold or fade',
    (tester) async {
      cleanUp(tester);
      DrillMediaController bindDecoder() {
        final decoder = DrillMediaController();
        addTearDown(decoder.dispose);
        handle.bind(owner: decoder, mediaId: _id, controller: decoder);
        return decoder;
      }

      final first = bindDecoder();
      first.receive({'source': 'drill-media', 'type': 'first-frame'});
      await _mount(tester, state: state, handle: handle);
      await _advance(tester, 550);
      state.value = _state(CatalogMediaDownloadPhase.ready);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('media-download-ready')),
        findsOneWidget,
      );
      await _advance(tester, 200);
      final second = bindDecoder();
      await tester.pump();
      await tester.pump();
      await _advance(tester, 1000);
      expect(find.byKey(_indicatorKey), findsOneWidget);
      expect(find.byKey(const ValueKey('media-download-ready')), findsNothing);

      second.receive({'source': 'drill-media', 'type': 'first-frame'});
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('media-download-ready')),
        findsOneWidget,
      );
      await _advance(tester, 500);
      double opacity() => tester
          .widget<FadeTransition>(
            find.byKey(const ValueKey('media-download-visibility')),
          )
          .opacity
          .value;
      expect(opacity(), inExclusiveRange(0, 1));
      final third = bindDecoder();
      await tester.pump();
      await tester.pump();
      await _advance(tester, 1000);
      expect(find.byKey(_indicatorKey), findsOneWidget);
      expect(find.byKey(const ValueKey('media-download-ready')), findsNothing);
      expect(opacity(), 1);

      third.receive({'source': 'drill-media', 'type': 'first-frame'});
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('media-download-ready')),
        findsOneWidget,
      );
      await _advance(tester, 390);
      expect(opacity(), 1);
      await _advance(tester, 210);
      expect(find.byKey(_indicatorKey), findsNothing);
    },
  );

  testWidgets(
    'external ready waits for the custom renderer to bind a decoded frame',
    (tester) async {
      cleanUp(tester);
      await _mount(tester, state: state, handle: handle);
      await _advance(tester, 550);
      state.value = _state(CatalogMediaDownloadPhase.ready);
      await _advance(tester, 1000);
      expect(find.byKey(_indicatorKey), findsOneWidget);
      expect(find.byKey(const ValueKey('media-download-ready')), findsNothing);
      final decoder = DrillMediaController();
      addTearDown(decoder.dispose);
      handle.bind(owner: decoder, mediaId: _id, controller: decoder);
      decoder.receive({'source': 'drill-media', 'type': 'first-frame'});
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('media-download-ready')),
        findsOneWidget,
      );
      await _advance(tester, 600);
      expect(find.byKey(_indicatorKey), findsNothing);
    },
  );

  testWidgets(
    'failure uses caution and retries without repeating the automatic hint',
    (tester) async {
      cleanUp(tester);
      state.value = _state(CatalogMediaDownloadPhase.failed);
      var retries = 0;
      await _mount(
        tester,
        state: state,
        handle: handle,
        onRetry: () {
          retries++;
          state.value = _state(CatalogMediaDownloadPhase.queued);
        },
      );
      await _advance(tester, 150);
      expect(_ring(tester).value, 0);
      expect(_ring(tester).color?.a, 0);
      expect(
        _ring(tester).backgroundColor,
        TrainerTheme.dark.text.withValues(alpha: .12),
      );
      final retry = tester.widget<Icon>(
        find.byKey(const ValueKey('media-download-retry')),
      );
      expect(retry.icon, CupertinoIcons.arrow_clockwise);
      expect(retry.size, 12);
      expect(retry.color, TrainerTheme.dark.caution);
      expect(find.text('视频暂不可用，训练继续 · 点击重试'), findsOneWidget);
      await tester.tap(find.byKey(_indicatorKey));
      await tester.pump();
      expect(retries, 1);
      expect(find.byKey(_indeterminateKey), findsOneWidget);
      await _advance(tester, 3000);
      expect(find.byKey(_chipKey), findsNothing);
      state.value = _state(CatalogMediaDownloadPhase.failed);
      await _advance(tester, 200);
      expect(
        find.byKey(const ValueKey('media-download-retry')),
        findsOneWidget,
      );
      expect(find.byKey(_chipKey), findsNothing);
    },
  );

  testWidgets('a decoder failure overrides a successfully cached download', (
    tester,
  ) async {
    cleanUp(tester);
    final decoder = DrillMediaController();
    addTearDown(decoder.dispose);
    handle.bind(owner: decoder, mediaId: _id, controller: decoder);
    state.value = _state(CatalogMediaDownloadPhase.ready);
    await _mount(tester, state: state, handle: handle);
    decoder.receive({'source': 'drill-media', 'type': 'error'});
    await _advance(tester, 200);
    expect(find.byKey(const ValueKey('media-download-retry')), findsOneWidget);
    expect(_ring(tester).value, 0);
    expect(_ring(tester).color?.a, 0);
    expect(
      _ring(tester).backgroundColor,
      TrainerTheme.dark.text.withValues(alpha: .12),
    );
    final retry = tester.widget<Icon>(
      find.byKey(const ValueKey('media-download-retry')),
    );
    expect(retry.icon, CupertinoIcons.arrow_clockwise);
    expect(retry.size, 12);
    expect(retry.color, TrainerTheme.dark.caution);
  });

  testWidgets('switching action resets its delay, hint and progress', (
    tester,
  ) async {
    cleanUp(tester);
    state.value = _state(CatalogMediaDownloadPhase.failed);
    await _mount(tester, state: state, handle: handle);
    await _advance(tester, 150);
    final next = ValueNotifier(
      _state(CatalogMediaDownloadPhase.downloading, bytes: 15, total: 100),
    );
    addTearDown(next.dispose);
    await _mount(tester, state: next, handle: handle, id: 'h-step');
    expect(find.byKey(_indicatorKey), findsNothing);
    expect(find.byKey(_chipKey), findsNothing);
    await _advance(tester, 550);
    expect(_ring(tester).value, closeTo(.15, .001));
  });

  testWidgets('an unsupported video platform has no download control', (
    tester,
  ) async {
    cleanUp(tester);
    state.value = _state(CatalogMediaDownloadPhase.failed);
    await _mount(tester, state: state, handle: handle, supported: false);
    await _advance(tester, 1000);
    expect(find.byKey(_indicatorKey), findsNothing);
  });

  testWidgets(
    'progress tap shows a two second hint and percentages are not live announcements',
    (tester) async {
      cleanUp(tester);
      final semantics = tester.ensureSemantics();
      try {
        state.value = _state(
          CatalogMediaDownloadPhase.downloading,
          bytes: 42,
          total: 100,
        );
        await _mount(tester, state: state, handle: handle, mirrored: true);
        await _advance(tester, 550);
        final ancestors = tester.widgetList<Transform>(
          find.ancestor(
            of: find.byKey(_indicatorKey),
            matching: find.byType(Transform),
          ),
        );
        expect(
          ancestors.where((transform) => transform.transform.storage[0] < 0),
          isEmpty,
        );
        final node = tester.getSemantics(
          find.byKey(const ValueKey('media-download-status')),
        );
        expect(node.label, '示范视频下载中 42%');
        expect(
          node.getSemanticsData().hasAction(ui.SemanticsAction.tap),
          isTrue,
        );
        await tester.tap(find.byKey(_indicatorKey));
        await tester.pump();
        expect(find.text('正在下载示范 42%'), findsOneWidget);
        await _advance(tester, 1990);
        expect(find.byKey(_chipKey), findsOneWidget);
        await _advance(tester, 20);
        expect(find.byKey(_chipKey), findsNothing);
        state.value = _state(
          CatalogMediaDownloadPhase.downloading,
          bytes: 43,
          total: 100,
        );
        await tester.pump();
        final updated = tester.widget<Semantics>(
          find.byKey(const ValueKey('media-download-status')),
        );
        expect(updated.properties.label, '示范视频下载中 43%');
        expect(updated.properties.liveRegion, isFalse);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('English download and failure copy comes from TrainerStrings', (
    tester,
  ) async {
    cleanUp(tester);
    state.value = _state(
      CatalogMediaDownloadPhase.downloading,
      bytes: 42,
      total: 100,
    );
    await _mount(
      tester,
      state: state,
      handle: handle,
      strings: TrainerStrings.en(),
    );
    await _advance(tester, 550);
    await tester.tap(find.byKey(_indicatorKey));
    await tester.pump();
    expect(find.text('Downloading demo 42%'), findsOneWidget);
    state.value = _state(CatalogMediaDownloadPhase.failed);
    await tester.pump();
    expect(
      find.text('Video unavailable, training continues · Tap to retry'),
      findsOneWidget,
    );
  });

  for (final example in [
    'downloading-42',
    'indeterminate',
    'failed',
    'light-mirrored',
  ]) {
    testWidgets('captures $example HUD evidence', (tester) async {
      cleanUp(tester);
      final capture = GlobalKey();
      final failed = example == 'failed';
      state.value = _state(
        failed
            ? CatalogMediaDownloadPhase.failed
            : example == 'indeterminate'
            ? CatalogMediaDownloadPhase.queued
            : CatalogMediaDownloadPhase.downloading,
        bytes: 42,
        total: example == 'indeterminate' ? 0 : 100,
      );
      await _mount(
        tester,
        state: state,
        handle: handle,
        theme: example == 'light-mirrored'
            ? TrainerTheme.light
            : TrainerTheme.dark,
        mirrored: example == 'light-mirrored',
        captureKey: capture,
      );
      await _advance(tester, 550);
      if (!failed && example != 'indeterminate') {
        await tester.tap(find.byKey(_indicatorKey));
        await tester.pump();
      }
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 3);
        try {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final directory = Directory(
            '../../build/screenshots/media-progress-r1',
          );
          await directory.create(recursive: true);
          await File(
            '${directory.path}/$example.png',
          ).writeAsBytes(png!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
      expect(find.byKey(_indicatorKey), findsOneWidget);
    }, skip: !_captureEvidence);
  }
}
