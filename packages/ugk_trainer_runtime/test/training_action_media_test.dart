import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
import 'package:ugk_trainer_runtime/src/ui/trainer_media_download_indicator.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

const _actionId = 'h-squat';
const _posterRoot = 'public-posters/';
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';

class _Bundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key == 'AssetManifest.bin') {
      return const StandardMessageCodec().encodeMessage({})!;
    }
    if (key.startsWith(_posterRoot)) {
      return ByteData.sublistView(base64Decode(_png));
    }
    throw FlutterError('Not bundled: $key');
  }
}

class _Repository implements CatalogMediaRepository {
  _Repository(this.catalog, this.events);
  @override
  final coach.PoseHubAppTestCatalog catalog;
  final List<String> events;
  final calls = <coach.PoseHubPackFile>[];
  final pending = <String, Completer<Uri>>{};
  final states = <String, ValueNotifier<CatalogMediaDownloadState>>{};
  bool ready = false;

  @override
  Uri get mediaBaseUri => Uri.parse('file:///verified-public-videos/');

  @override
  Future<Uri> ensureFile(coach.PoseHubPackFile file) {
    calls.add(file);
    if (ready) return Future.value(file.resolve(mediaBaseUri));
    return pending.putIfAbsent(file.path, Completer<Uri>.new).future;
  }

  void fail(coach.PoseHubPackFile file) {
    states[file.path]?.value = const CatalogMediaDownloadState(
      phase: CatalogMediaDownloadPhase.failed,
      error: 'offline',
    );
    pending.remove(file.path)!.completeError(const SocketException('offline'));
  }

  void complete(coach.PoseHubPackFile file) {
    states[file.path]?.value = CatalogMediaDownloadState(
      phase: CatalogMediaDownloadPhase.ready,
      receivedBytes: file.bytes,
      totalBytes: file.bytes,
    );
    pending.remove(file.path)!.complete(file.resolve(mediaBaseUri));
  }

  @override
  ValueListenable<CatalogMediaDownloadState> watchFile(
    coach.PoseHubPackFile file,
  ) => states.putIfAbsent(
    file.path,
    () => ValueNotifier(
      const CatalogMediaDownloadState(phase: CatalogMediaDownloadPhase.queued),
    ),
  );

  @override
  VoidCallback retainVideo(String id) {
    events.add('pin:$id');
    var retained = true;
    return () {
      if (!retained) return;
      retained = false;
      events.add('release:$id');
    };
  }

  @override
  void dispose() {
    for (final state in states.values) {
      state.dispose();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Platform extends PackedAlphaPlatform implements PackedAlphaUriPlatform {
  _Platform(this.order);
  final List<String> order;
  final eventsController = StreamController<Map<Object?, Object?>>.broadcast(
    sync: true,
  );
  final sources = <Uri>[];
  final creates = <Completer<({int playerId, int textureId})>>[];
  final disposals = <Completer<Object?>>[];
  bool delayCreate = false;
  bool delayDispose = false;

  @override
  bool get isSupported => true;
  @override
  Stream<Map<Object?, Object?>> get events => eventsController.stream;
  @override
  Future<({int playerId, int textureId})> create(String asset) =>
      throw StateError('Public videos must use verified source URIs');

  @override
  Future<({int playerId, int textureId})> createUri(Uri source) {
    sources.add(source);
    final id = sources.length;
    order.add('create:$id');
    if (!delayCreate) return Future.value((playerId: id, textureId: id + 100));
    final result = Completer<({int playerId, int textureId})>();
    creates.add(result);
    return result.future;
  }

  void emit(int id, String type) =>
      eventsController.add({'playerId': id, 'type': type});

  @override
  Future<Object?> command(int playerId, String type, [Object? value]) {
    if (type == 'dispose') {
      order.add('dispose:$playerId');
      if (delayDispose) {
        final result = Completer<Object?>();
        disposals.add(result);
        return result.future;
      }
    }
    return Future.value(null);
  }
}

class _HostAssetPlatform extends _Platform {
  _HostAssetPlatform(super.order);
  @override
  Future<({int playerId, int textureId})> create(String asset) =>
      createUri(Uri(path: asset));
}

coach.TrainingPlan _plan(String id) => coach.TrainingPlan(
  id: 'public-media',
  source: 'template',
  title: 'Public media',
  goal: 'core',
  scene: 'home',
  level: 1,
  targetMinutes: 1,
  blocks: [
    coach.PlanBlock(
      id: 'main',
      name: 'Main',
      type: coach.BlockType.main,
      items: [
        coach.PlanItem(
          exerciseId: id,
          mode: coach.DoseMode.time,
          sets: 1,
          workSeconds: 30,
          perSide: false,
          restSeconds: 0,
        ),
      ],
    ),
  ],
);

TrainerPlayer _player(
  String id, {
  ValueListenable<CatalogMediaDownloadState>? downloadState,
  VoidCallback? onDownloadRetry,
  bool showIndicator = true,
  TrainerMediaBuilder? mediaBuilder,
  TrainerTheme theme = TrainerTheme.dark,
  Animation<double>? chromeAnimation,
}) => TrainerPlayer(
  plan: _plan(id),
  drillOf: (id) => TrainerDrill(id: id, name: id),
  strings: TrainerStrings.en(),
  prepSeconds: 0,
  transitionSeconds: 0,
  keepAlive: false,
  theme: theme,
  chromeAnimation: chromeAnimation,
  mediaDownloadState: downloadState,
  onMediaDownloadRetry: onDownloadRetry,
  showMediaDownloadIndicator: showIndicator,
  mediaBuilder: mediaBuilder,
  onFinished: (_) async {},
);

Future<BuildContext> _mount(
  WidgetTester tester,
  _Bundle bundle, {
  Widget child = const Text('source'),
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: DefaultAssetBundle(
        bundle: bundle,
        child: Builder(
          builder: (source) {
            context = source;
            return Scaffold(body: Center(child: child));
          },
        ),
      ),
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  return context;
}

Future<void> _warm(
  WidgetTester tester,
  BuildContext context,
  String poster,
) async {
  expect(
    await tester.runAsync(
      () => TrainingPosterImages.prepareAsset(
        context,
        poster,
        timeout: const Duration(seconds: 2),
      ),
    ),
    isTrue,
  );
  await tester.pump();
}

Future<void> _enter(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 301));
  await tester.pump();
  // The route opens its start gate at the frame boundary; allow the player's
  // first timer tick to publish the initial work counter before comparing it.
  await _advance(tester, 200);
}

Future<void> _advance(WidgetTester tester, int milliseconds) async {
  for (var elapsed = 0; elapsed < milliseconds; elapsed += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

int _seconds(WidgetTester tester) => int.parse(
  tester
      .widget<TrainerCountdownDigits>(find.byType(TrainerCountdownDigits))
      .value,
);

void main() {
  late coach.PoseHubAppTestCatalog catalog;
  late _Repository repository;
  late _Platform platform;
  late TrainingMediaPolicy policy;
  late _Bundle bundle;
  late List<String> order;

  setUpAll(() {
    catalog = coach.PoseHubAppTestCatalog.fromBytes(
      File(
        '../ugk_trainer/assets/pose_hub/app-pack-r2-v10/catalog.json',
      ).readAsBytesSync(),
    );
  });
  setUp(() {
    order = [];
    repository = _Repository(catalog, order);
    platform = _Platform(order);
    policy = TrainingMediaPolicy(
      repository: repository,
      posterAssetRoot: _posterRoot,
    );
    bundle = _Bundle();
    UgkPackedAlphaVideo.debugPlatform = platform;
    UgkPackedAlphaVideo.debugFilterBuilder = (input) => input;
  });
  tearDown(() async {
    UgkPackedAlphaVideo.debugPlatform = null;
    UgkPackedAlphaVideo.debugFilterBuilder = null;
    repository.dispose();
    await platform.eventsController.close();
  });

  testWidgets('both themes retain one poster key until a real first frame', (
    tester,
  ) async {
    repository.ready = true;
    Widget media() => SizedBox.square(
      dimension: 200,
      child: TrainingActionMedia(actionId: _actionId, policy: policy),
    );
    var context = await _mount(tester, bundle, child: media());
    await _warm(tester, context, policy.posterAssetFor(_actionId)!);
    Future<Object> imageKey(BuildContext context) =>
        TrainingPosterImages.provider(
          tester.widget<TrainerPoster>(find.byType(TrainerPoster)).asset,
          TrainingPosterImages.decodeWidth(context),
          bundle: bundle,
        ).obtainKey(createLocalImageConfiguration(context));
    final key = await imageKey(context);
    context = await _mount(
      tester,
      bundle,
      child: media(),
      brightness: Brightness.dark,
    );
    expect(await imageKey(context), key);
    expect(platform.sources, hasLength(1));
    platform.emit(1, 'ready');
    await tester.pump();
    final posterFade = find.byKey(const ValueKey('public-action-poster'));
    final videoFade = find.ancestor(
      of: find.byType(UgkPackedAlphaVideo),
      matching: find.byType(AnimatedOpacity),
    );
    expect(tester.widget<AnimatedOpacity>(posterFade).opacity, 1);
    expect(tester.widget<AnimatedOpacity>(videoFade).opacity, 1 / 255);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    platform.emit(1, 'first-frame');
    await tester.pump();
    await tester.pump();
    expect(tester.widget<AnimatedOpacity>(posterFade).opacity, 0);
    expect(tester.widget<AnimatedOpacity>(videoFade).opacity, 1);
  });

  testWidgets('offline failure retains poster and retries only on one tap', (
    tester,
  ) async {
    final handle = DrillMediaPlaybackHandle();
    addTearDown(handle.dispose);
    final video = catalog.tryGet(_actionId)!.video;
    final context = await _mount(
      tester,
      bundle,
      child: SizedBox.square(
        dimension: 200,
        child: Stack(
          children: [
            TrainingActionMedia(
              actionId: _actionId,
              policy: policy,
              playbackHandle: handle,
            ),
            Positioned(
              right: 0,
              top: 0,
              child: TrainerMediaDownloadIndicator(
                state: repository.watchFile(video),
                actionId: _actionId,
                theme: TrainerTheme.light,
                strings: TrainerStrings.zh(),
                playbackHandle: handle,
                onRetry: handle.retry,
              ),
            ),
          ],
        ),
      ),
    );
    await _warm(tester, context, policy.posterAssetFor(_actionId)!);
    repository.fail(catalog.tryGet(_actionId)!.video);
    await tester.pump();
    await _advance(tester, 2000);
    expect(repository.calls, hasLength(1));
    expect(find.byKey(const ValueKey('media-download-retry')), findsOneWidget);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(platform.sources, isEmpty);
    await tester.tap(find.byKey(const ValueKey('media-download-retry')));
    await tester.pump();
    expect(repository.calls, hasLength(2));
    repository.complete(catalog.tryGet(_actionId)!.video);
    await tester.pump();
    await tester.pump();
    expect(platform.sources, hasLength(1));
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
  });

  testWidgets(
    'launcher prefetches only video while pending training advances',
    (tester) async {
      await withClock(Clock(tester.binding.clock.now), () async {
        final context = await _mount(tester, bundle);
        final poster = policy.posterAssetFor(_actionId)!;
        await _warm(tester, context, poster);
        unawaited(
          TrainerLauncher.open<void>(
            context,
            firstPosterAsset: poster,
            mediaPolicy: policy,
            planActionIds: const [_actionId],
            builder: (_) => _player(_actionId),
          ),
        );
        await _enter(tester);
        expect(find.byType(TrainerPlayer), findsOneWidget);
        expect(repository.pending, isNotEmpty);
        expect(repository.calls, isNotEmpty);
        expect(
          repository.calls.every((file) => file.path.endsWith('.mp4')),
          isTrue,
        );
        final before = _seconds(tester);
        expect(before, greaterThan(0));
        await _advance(tester, 2000);
        expect(_seconds(tester), lessThan(before));
        expect(platform.sources, isEmpty);
      });
    },
  );

  testWidgets(
    'unknown supine action starts without a substituted public clip',
    (tester) async {
      const id = 'supine-cross-demo';
      expect(policy.actionFor(id), isNull);
      await withClock(Clock(tester.binding.clock.now), () async {
        final context = await _mount(tester, bundle);
        var starts = 0;
        unawaited(
          TrainerLauncher.open<void>(
            context,
            firstPosterAsset: null,
            mediaPolicy: policy,
            planActionIds: const [id],
            onStarting: () async {
              starts++;
              return true;
            },
            builder: (_) => _player(id),
          ),
        );
        await _enter(tester);
        expect(starts, 1);
        expect(find.byType(TrainerPlayer), findsOneWidget);
        expect(
          find.byKey(const ValueKey('public-action-missing')),
          findsOneWidget,
        );
        expect(find.byType(TrainerPoster), findsNothing);
        expect(repository.calls, isEmpty);
        expect(platform.sources, isEmpty);
        final before = _seconds(tester);
        expect(before, greaterThan(0));
        await _advance(tester, 2000);
        expect(_seconds(tester), lessThan(before));
      });
    },
  );

  testWidgets('a failed download does not pause the running training clock', (
    tester,
  ) async {
    await withClock(Clock(tester.binding.clock.now), () async {
      final context = await _mount(
        tester,
        bundle,
        child: TrainingMediaPolicyScope(
          policy: policy,
          child: _player(_actionId),
        ),
      );
      await _warm(tester, context, policy.posterAssetFor(_actionId)!);
      repository.fail(catalog.tryGet(_actionId)!.video);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('media-download-retry')),
        findsOneWidget,
      );
      final before = _seconds(tester);
      await _advance(tester, 2000);
      expect(_seconds(tester), lessThan(before));
      expect(find.byType(TrainerPoster), findsOneWidget);
    });
  });

  testWidgets('native dispose acknowledgement precedes playback pin release', (
    tester,
  ) async {
    repository.ready = true;
    platform.delayDispose = true;
    await _mount(
      tester,
      bundle,
      child: TrainingActionMedia(actionId: _actionId, policy: policy),
    );
    await tester.pump();
    await tester.pump();
    expect(platform.sources, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(order, contains('dispose:1'));
    expect(order, isNot(contains('release:$_actionId')));
    platform.disposals.single.complete(null);
    await tester.pump();
    expect(order.last, 'release:$_actionId');
  });

  testWidgets('late create after unmount disposes before releasing its pin', (
    tester,
  ) async {
    repository.ready = true;
    platform.delayCreate = true;
    platform.delayDispose = true;
    await _mount(
      tester,
      bundle,
      child: TrainingActionMedia(actionId: _actionId, policy: policy),
    );
    await tester.pump();
    await tester.pump();
    expect(platform.creates, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(order, isNot(contains('release:$_actionId')));
    platform.creates.single.complete((playerId: 1, textureId: 101));
    await tester.pump();
    expect(order, contains('dispose:1'));
    expect(order, isNot(contains('release:$_actionId')));
    platform.disposals.single.complete(null);
    await tester.pump();
    expect(order, [
      'pin:$_actionId',
      'create:1',
      'dispose:1',
      'release:$_actionId',
    ]);
  });

  testWidgets('player without policy or host state has no download HUD', (
    tester,
  ) async {
    await _mount(tester, bundle, child: _player(_actionId));
    await _advance(tester, 650);
    expect(
      find.byKey(const ValueKey('media-download-indicator')),
      findsNothing,
    );
    expect(repository.calls, isEmpty);
  });

  testWidgets('policy keeps an explicitly unavailable video poster-only', (
    tester,
  ) async {
    final context = await _mount(
      tester,
      bundle,
      child: TrainingMediaPolicyScope(
        policy: policy,
        child: TrainerPlayer(
          plan: _plan(_actionId),
          drillOf: (id) => TrainerDrill(
            id: id,
            name: id,
            media: const DrillMedia(
              id: _actionId,
              videoAsset: '',
              posterAsset: '$_posterRoot$_actionId.webp',
              duration: 0,
              videoAvailable: false,
            ),
          ),
          strings: TrainerStrings.en(),
          prepSeconds: 0,
          keepAlive: false,
          onFinished: (_) async {},
        ),
      ),
    );
    await _warm(tester, context, policy.posterAssetFor(_actionId)!);
    await _advance(tester, 650);
    expect(repository.calls, isEmpty);
    expect(platform.sources, isEmpty);
    expect(find.byType(TrainerPoster), findsOneWidget);
    expect(
      find.byKey(const ValueKey('media-download-indicator')),
      findsNothing,
    );
  });

  for (final hudTheme in [TrainerTheme.light, TrainerTheme.dark]) {
    testWidgets(
      'host download HUD aligns below discomfort with ${hudTheme.brightness}',
      (tester) async {
        final state = ValueNotifier(
          const CatalogMediaDownloadState(
            phase: CatalogMediaDownloadPhase.downloading,
            receivedBytes: 42,
            totalBytes: 100,
          ),
        );
        addTearDown(state.dispose);
        TrainerMediaRequest? request;
        await _mount(
          tester,
          bundle,
          child: _player(
            _actionId,
            theme: hudTheme,
            downloadState: state,
            chromeAnimation: const AlwaysStoppedAnimation<double>(1),
            mediaBuilder: (_, value) {
              request = value;
              return Transform.flip(
                flipX: true,
                child: const ColoredBox(color: Colors.transparent),
              );
            },
          ),
        );
        await _advance(tester, 650);
        final indicator = find.byKey(
          const ValueKey('media-download-indicator'),
        );
        expect(indicator, findsOneWidget);
        expect(request?.playbackHandle, isNotNull);
        expect(
          find.byKey(const ValueKey('trainer-chrome-hud')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('trainer-chrome-media-download')),
          findsOneWidget,
        );
        final transforms = tester.widgetList<Transform>(
          find.ancestor(of: indicator, matching: find.byType(Transform)),
        );
        expect(transforms.where((t) => t.transform.storage[0] < 0), isEmpty);
        final indicatorVisual = find.descendant(
          of: indicator,
          matching: find.byType(TrainerSurface),
        );
        final discomfortVisual = find.descendant(
          of: find.byKey(const ValueKey('discomfort')),
          matching: find.byType(TrainerSurface),
        );
        expect(
          tester.getRect(indicatorVisual).right,
          closeTo(tester.getRect(discomfortVisual).right, .5),
        );
        expect(
          tester.getRect(indicatorVisual).top -
              tester.getRect(discomfortVisual).bottom,
          TrainerSpace.x2,
        );
        expect(tester.getSize(indicator), const Size(44, 44));
      },
    );
  }

  testWidgets(
    'player host state takes precedence over a policy with custom media',
    (tester) async {
      final state = ValueNotifier(
        const CatalogMediaDownloadState(
          phase: CatalogMediaDownloadPhase.downloading,
          receivedBytes: 42,
          totalBytes: 100,
        ),
      );
      addTearDown(state.dispose);
      final videoState =
          repository.watchFile(catalog.tryGet(_actionId)!.video)
              as ValueNotifier<CatalogMediaDownloadState>;
      videoState.value = const CatalogMediaDownloadState(
        phase: CatalogMediaDownloadPhase.failed,
        error: 'offline',
      );
      await _mount(
        tester,
        bundle,
        child: TrainingMediaPolicyScope(
          policy: policy,
          child: _player(
            _actionId,
            downloadState: state,
            mediaBuilder: (_, _) => const SizedBox.expand(),
          ),
        ),
      );
      await _advance(tester, 650);
      expect(
        find.byKey(const ValueKey('media-download-arrow')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('media-download-retry')), findsNothing);
      expect(repository.calls, isNotEmpty);
    },
  );

  testWidgets('player opt-out hides the host download and failure HUD', (
    tester,
  ) async {
    final state = ValueNotifier(
      const CatalogMediaDownloadState(
        phase: CatalogMediaDownloadPhase.failed,
        error: 'offline',
      ),
    );
    addTearDown(state.dispose);
    await _mount(
      tester,
      bundle,
      child: TrainingMediaPolicyScope(
        policy: policy,
        child: _player(
          _actionId,
          downloadState: state,
          showIndicator: false,
          mediaBuilder: (_, _) => const SizedBox.expand(),
        ),
      ),
    );
    await _advance(tester, 650);
    expect(
      find.byKey(const ValueKey('media-download-indicator')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('media-download-chip')), findsNothing);
    expect(repository.calls, isNotEmpty);
  });

  testWidgets('custom media without a host override watches the policy video', (
    tester,
  ) async {
    await _mount(
      tester,
      bundle,
      child: TrainingMediaPolicyScope(
        policy: policy,
        child: _player(
          _actionId,
          mediaBuilder: (_, _) => const SizedBox.expand(),
        ),
      ),
    );
    await _advance(tester, 650);
    expect(
      find.byKey(const ValueKey('media-download-indeterminate')),
      findsOneWidget,
    );
    repository.fail(catalog.tryGet(_actionId)!.video);
    await tester.pump();
    expect(find.byKey(const ValueKey('media-download-retry')), findsOneWidget);
  });

  testWidgets('player routes a failed host download retry to its host', (
    tester,
  ) async {
    final state = ValueNotifier(
      const CatalogMediaDownloadState(
        phase: CatalogMediaDownloadPhase.failed,
        error: 'offline',
      ),
    );
    addTearDown(state.dispose);
    var retries = 0;
    await _mount(
      tester,
      bundle,
      child: _player(
        _actionId,
        downloadState: state,
        onDownloadRetry: () {
          retries++;
          state.value = const CatalogMediaDownloadState(
            phase: CatalogMediaDownloadPhase.queued,
          );
        },
      ),
    );
    expect(find.byKey(const ValueKey('media-download-retry')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('media-download-indicator')));
    await tester.pump();
    expect(retries, 1);
    expect(find.byKey(const ValueKey('media-download-retry')), findsNothing);
    expect(
      find.byKey(const ValueKey('media-download-indeterminate')),
      findsOneWidget,
    );
    expect(repository.calls, isEmpty);
  });

  for (final customBuilder in [false, true]) {
    testWidgets(
      'host HUD accepts an aliased media id with ${customBuilder ? 'custom' : 'default'} rendering',
      (tester) async {
        final assetPlatform = _HostAssetPlatform(order);
        UgkPackedAlphaVideo.debugPlatform = assetPlatform;
        addTearDown(assetPlatform.eventsController.close);
        final state = ValueNotifier(
          const CatalogMediaDownloadState(
            phase: CatalogMediaDownloadPhase.downloading,
            receivedBytes: 42,
            totalBytes: 100,
          ),
        );
        addTearDown(state.dispose);
        final context = await _mount(
          tester,
          bundle,
          child: TrainerPlayer(
            plan: _plan(_actionId),
            drillOf: (id) => TrainerDrill(
              id: id,
              name: id,
              media: const DrillMedia(
                id: 'host-media-id',
                actionId: _actionId,
                videoAsset: '',
                posterAsset: '$_posterRoot$_actionId.webp',
                packedAlphaVideoAsset: 'assets/fixture/rgb-alpha.mp4',
                packedAlphaPosterAsset: '$_posterRoot$_actionId.webp',
                duration: 1,
              ),
            ),
            strings: TrainerStrings.en(),
            prepSeconds: 0,
            keepAlive: false,
            mediaDownloadState: state,
            mediaBuilder: customBuilder
                ? (_, request) => DrillMediaView(
                    media: request.drill.media!,
                    paused: request.paused || !request.canPlay,
                    mirrored: request.mirrored,
                    playbackHandle: request.playbackHandle,
                  )
                : null,
            onFinished: (_) async {},
          ),
        );
        await _warm(tester, context, policy.posterAssetFor(_actionId)!);
        await _advance(tester, 650);
        expect(assetPlatform.sources, hasLength(1));
        state.value = const CatalogMediaDownloadState(
          phase: CatalogMediaDownloadPhase.ready,
          receivedBytes: 100,
          totalBytes: 100,
        );
        assetPlatform.emit(1, 'ready');
        assetPlatform.emit(1, 'first-frame');
        await tester.pump();
        await tester.pump();
        expect(
          find.byKey(const ValueKey('media-download-ready')),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets('standalone idle media stays offline until playback is enabled', (
    tester,
  ) async {
    final playing = ValueNotifier(false);
    addTearDown(playing.dispose);
    final context = await _mount(
      tester,
      bundle,
      child: ValueListenableBuilder<bool>(
        valueListenable: playing,
        builder: (_, enabled, _) => TrainingActionMedia(
          actionId: _actionId,
          policy: policy,
          playing: enabled,
        ),
      ),
    );
    await _warm(tester, context, policy.posterAssetFor(_actionId)!);
    await _advance(tester, 2000);
    expect(repository.calls, isEmpty);
    expect(platform.sources, isEmpty);
    expect(order, isNot(contains('pin:$_actionId')));
    expect(find.byType(TrainerPoster), findsOneWidget);

    playing.value = true;
    await tester.pump();
    final video = catalog.tryGet(_actionId)!.video;
    expect(repository.calls, [video]);
    expect(order.where((event) => event == 'pin:$_actionId'), hasLength(1));
    repository.complete(video);
    await tester.pump();
    await tester.pump();
    expect(platform.sources, hasLength(1));
  });

  testWidgets(
    'player prepares the current video during entry then only its next video',
    (tester) async {
      await withClock(Clock(tester.binding.clock.now), () async {
        final actions = [
          catalog.tryGet(_actionId)!,
          ...catalog.semanticCompleteActions
              .where((action) => action.id != _actionId)
              .take(2),
        ];
        final plan = coach.TrainingPlan(
          id: 'current-next-preparation',
          source: 'template',
          title: 'Current and next',
          goal: 'core',
          scene: 'home',
          level: 1,
          targetMinutes: 2,
          blocks: [
            coach.PlanBlock(
              id: 'main',
              name: 'Main',
              type: coach.BlockType.main,
              items: [
                for (final action in actions)
                  coach.PlanItem(
                    exerciseId: action.id,
                    mode: coach.DoseMode.time,
                    sets: 1,
                    workSeconds: 30,
                    perSide: false,
                    restSeconds: 0,
                  ),
              ],
            ),
          ],
        );
        final context = await _mount(tester, bundle);
        await _warm(tester, context, policy.posterAssetFor(_actionId)!);
        unawaited(
          TrainerLauncher.open<void>(
            context,
            // The policy's body poster is already warm. Skip the launcher's
            // independent poster lease so the first entry frame is observable
            // without waiting for real image work inside the fake clock.
            firstPosterAsset: null,
            mediaPolicy: policy,
            planActionIds: actions.map((action) => action.id),
            builder: (_) => TrainerPlayer(
              plan: plan,
              drillOf: (id) => TrainerDrill(id: id, name: id),
              strings: TrainerStrings.en(),
              prepSeconds: 18,
              transitionSeconds: 0,
              keepAlive: false,
              onFinished: (_) async {},
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        final current = tester.widget<TrainingActionMedia>(
          find.byType(TrainingActionMedia),
        );
        expect(current.playing, isFalse);
        expect(current.prefetchWhenIdle, isTrue);
        expect(repository.pending.keys, [actions[0].video.path]);
        expect(repository.calls.map((file) => file.path).toSet(), {
          actions[0].video.path,
        });
        expect(order.where((event) => event == 'pin:$_actionId'), hasLength(1));

        await _enter(tester);
        await _advance(tester, 1000);
        expect(_seconds(tester), greaterThan(0));
        expect(
          tester
              .widget<TrainingActionMedia>(find.byType(TrainingActionMedia))
              .playing,
          isTrue,
        );
        expect(order.where((event) => event == 'pin:$_actionId'), hasLength(1));
        expect(repository.pending.keys, [actions[0].video.path]);
        repository.complete(actions[0].video);
        await tester.pump();
        await tester.pump();
        expect(repository.pending.keys, [actions[1].video.path]);
        expect(repository.calls.map((file) => file.path).toSet(), {
          actions[0].video.path,
          actions[1].video.path,
        });
        expect(platform.sources, hasLength(1));
        repository.complete(actions[1].video);
        await tester.pump();
        await _advance(tester, 1000);
        expect(repository.pending, isEmpty);
        expect(repository.calls.map((file) => file.path).toSet(), {
          actions[0].video.path,
          actions[1].video.path,
        });
      });
    },
  );
}
