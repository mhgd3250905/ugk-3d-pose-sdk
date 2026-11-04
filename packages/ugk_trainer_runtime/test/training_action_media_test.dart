import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart' as coach;
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
  final commands = <(int, String, Object?)>[];
  final returns = <Completer<Object?>>[];
  final creates = <Completer<({int playerId, int textureId})>>[];
  final disposals = <Completer<Object?>>[];
  bool delayCreate = false;
  bool delayDispose = false;
  bool delayReturn = false;
  bool failCreate = false;

  @override
  bool get isSupported => true;
  @override
  Stream<Map<Object?, Object?>> get events => eventsController.stream;
  @override
  Future<({int playerId, int textureId})> create(String asset) =>
      throw StateError('Public videos must use verified source URIs');

  @override
  Future<({int playerId, int textureId})> createUri(Uri source) {
    if (failCreate) {
      return Future.error(PlatformException(code: 'packed_alpha'));
    }
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
    commands.add((playerId, type, value));
    if (type == 'dispose') {
      order.add('dispose:$playerId');
      if (delayDispose) {
        final result = Completer<Object?>();
        disposals.add(result);
        return result.future;
      }
    }
    if (type == 'return-to-start') {
      if (delayReturn) {
        final pending = Completer<Object?>();
        returns.add(pending);
        return pending.future;
      }
      return Future.value(true);
    }
    if (type == 'position') return Future.value(1.25);
    if (type == 'prime-first-frame') return Future.value(true);
    return Future.value(null);
  }
}

class _HostAssetPlatform extends _Platform {
  _HostAssetPlatform(super.order);
  @override
  Future<({int playerId, int textureId})> create(String asset) =>
      createUri(Uri(path: asset));
}

class _UnsupportedPlatform extends _Platform {
  _UnsupportedPlatform(super.order);
  @override
  bool get isSupported => false;
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

  Future<void> finishTransition(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 432));
    await tester.pump();
    await tester.pump();
  }

  TrainingActionMedia pausedMedia({bool retain = true}) => TrainingActionMedia(
    key: const ValueKey('covered-paused-media'),
    actionId: _actionId,
    policy: policy,
    paused: true,
    prepareFirstFrame: true,
    retainPausedSurfaceWhileCovered: retain,
  );

  Future<BuildContext> readyPaused(
    WidgetTester tester, {
    Widget? child,
    bool frame = true,
  }) async {
    repository.ready = true;
    final context = await _mount(tester, bundle, child: child ?? pausedMedia());
    await tester.pump();
    await tester.pump();
    platform.emit(1, 'ready');
    await tester.pump();
    await tester.pump();
    if (frame) {
      platform.emit(1, 'first-frame');
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 140));
    }
    return context;
  }

  void cover(BuildContext context) => unawaited(
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 400),
        reverseTransitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (_, animation, secondaryAnimation) =>
            const Scaffold(body: Text('covering page')),
      ),
    ),
  );

  testWidgets(
    'opt-in paused frame survives cover and return on the same native surface',
    (tester) async {
      final context = await readyPaused(tester);
      final surface = find.byType(UgkPackedAlphaVideo, skipOffstage: false);
      final element = tester.element(surface);
      final controller = tester.widget<UgkPackedAlphaVideo>(surface).controller;
      void expectSameFrame() {
        expect(tester.element(surface), same(element));
        expect(
          tester.widget<UgkPackedAlphaVideo>(surface).controller,
          same(controller),
        );
        expect(
          tester
              .widget<Texture>(find.byType(Texture, skipOffstage: false))
              .textureId,
          101,
        );
        expect(
          tester
              .widget<AnimatedOpacity>(
                find.byKey(
                  const ValueKey('public-action-poster'),
                  skipOffstage: false,
                ),
              )
              .opacity,
          0,
        );
        expect(controller.hasFrame, isTrue);
        expect(controller.wantsPlay, isFalse);
        expect(platform.sources, hasLength(1));
        expect(
          platform.commands.where((c) => c.$2 == 'prime-first-frame'),
          hasLength(1),
        );
        expect(
          platform.commands.where(
            (c) =>
                c.$2 == 'dispose' ||
                c.$2 == 'play' ||
                c.$2.contains('seek') ||
                c.$2.contains('return-to-start'),
          ),
          isEmpty,
        );
      }

      cover(context);
      await tester.pump();
      for (var elapsed = 0; elapsed < 432; elapsed += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        expectSameFrame();
      }
      // Completed cover disables the underlying route's ticker mode.
      await tester.pump(const Duration(seconds: 2));
      expectSameFrame();
      Navigator.of(context).pop();
      await tester.pump();
      for (var elapsed = 0; elapsed < 432; elapsed += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        expectSameFrame();
      }
      await finishTransition(tester);
      expectSameFrame();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a retained covered frame still releases on background and waits for return',
    (tester) async {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final context = await readyPaused(tester);
      cover(context);
      await finishTransition(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      await tester.pump();
      expect(platform.commands.where((c) => c.$2 == 'dispose'), [
        (1, 'dispose', null),
      ]);
      expect(
        find.byType(UgkPackedAlphaVideo, skipOffstage: false),
        findsNothing,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(platform.sources, hasLength(1));
      Navigator.of(context).pop();
      await finishTransition(tester);
      expect(platform.sources, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a covered media without a genuine first frame is not retained', (
    tester,
  ) async {
    final context = await readyPaused(tester, frame: false);
    expect(find.byType(UgkPackedAlphaVideo), findsOneWidget);
    cover(context);
    await finishTransition(tester);
    expect(platform.sources, hasLength(1));
    expect(platform.commands.where((c) => c.$2 == 'dispose'), [
      (1, 'dispose', null),
    ]);
    expect(find.byType(UgkPackedAlphaVideo, skipOffstage: false), findsNothing);
    // A late event from that retired decoder cannot synthesize retained media.
    platform.emit(1, 'first-frame');
    await tester.pump();
    expect(find.byType(UgkPackedAlphaVideo, skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pending download is not started as hidden video by covered retention',
    (tester) async {
      final context = await _mount(tester, bundle, child: pausedMedia());
      expect(repository.calls, hasLength(1));
      cover(context);
      await finishTransition(tester);
      repository.complete(catalog.tryGet(_actionId)!.video);
      await tester.pump();
      await tester.pump();
      expect(platform.sources, isEmpty);
      expect(
        find.byType(UgkPackedAlphaVideo, skipOffstage: false),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'default paused hosts still retire the native surface when covered',
    (tester) async {
      final context = await readyPaused(
        tester,
        child: pausedMedia(retain: false),
      );
      cover(context);
      await tester.pump();
      expect(
        find.byType(UgkPackedAlphaVideo, skipOffstage: false),
        findsNothing,
      );
      await finishTransition(tester);
      expect(platform.commands.where((c) => c.$2 == 'dispose'), [
        (1, 'dispose', null),
      ]);
      Navigator.of(context).pop();
      await finishTransition(tester);
      expect(platform.sources, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'turning covered retention off releases and turning it on does not revive hidden media',
    (tester) async {
      final retain = ValueNotifier(true);
      addTearDown(retain.dispose);
      final context = await readyPaused(
        tester,
        child: ValueListenableBuilder<bool>(
          valueListenable: retain,
          builder: (_, value, _) => pausedMedia(retain: value),
        ),
      );
      cover(context);
      await finishTransition(tester);
      expect(platform.commands.where((c) => c.$2 == 'dispose'), isEmpty);
      retain.value = false;
      await tester.pump();
      await tester.pump();
      expect(platform.commands.where((c) => c.$2 == 'dispose'), [
        (1, 'dispose', null),
      ]);
      retain.value = true;
      await tester.pump();
      await tester.pump();
      expect(platform.sources, hasLength(1));
      expect(
        find.byType(UgkPackedAlphaVideo, skipOffstage: false),
        findsNothing,
      );
      Navigator.of(context).pop();
      await finishTransition(tester);
      expect(platform.sources, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );

  for (final change in ['playing', 'paused', 'action', 'policy']) {
    testWidgets(
      'changing $change retires a retained covered surface without loading hidden media',
      (tester) async {
        final changed = ValueNotifier(false);
        addTearDown(changed.dispose);
        final alternative = catalog.allActions
            .firstWhere((action) => action.id != _actionId)
            .id;
        final alternatePolicy = TrainingMediaPolicy(
          repository: repository,
          posterAssetRoot: _posterRoot,
        );
        final context = await readyPaused(
          tester,
          child: ValueListenableBuilder<bool>(
            valueListenable: changed,
            builder: (_, value, _) => TrainingActionMedia(
              key: const ValueKey('covered-paused-media'),
              actionId: value && change == 'action' ? alternative : _actionId,
              policy: value && change == 'policy' ? alternatePolicy : policy,
              playing: !(value && change == 'playing'),
              paused: !(value && change == 'paused'),
              prepareFirstFrame: true,
              retainPausedSurfaceWhileCovered: true,
            ),
          ),
        );
        cover(context);
        await finishTransition(tester);
        expect(platform.commands.where((c) => c.$2 == 'dispose'), isEmpty);
        changed.value = true;
        await tester.pump();
        await tester.pump();
        expect(platform.commands.where((c) => c.$2 == 'dispose'), [
          (1, 'dispose', null),
        ]);
        expect(platform.sources, hasLength(1));
        expect(
          find.byType(UgkPackedAlphaVideo, skipOffstage: false),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'an unrelated disabled TickerMode releases after a retained route returns',
    (tester) async {
      final enabled = ValueNotifier(true);
      addTearDown(enabled.dispose);
      final context = await readyPaused(
        tester,
        child: ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (_, value, _) =>
              TickerMode(enabled: value, child: pausedMedia()),
        ),
      );
      cover(context);
      await finishTransition(tester);
      Navigator.of(context).pop();
      await finishTransition(tester);
      expect(platform.sources, hasLength(1));
      expect(platform.commands.where((c) => c.$2 == 'dispose'), isEmpty);
      enabled.value = false;
      await tester.pump();
      await tester.pump();
      expect(platform.commands.where((c) => c.$2 == 'dispose'), [
        (1, 'dispose', null),
      ]);
      expect(find.byType(UgkPackedAlphaVideo), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

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

  testWidgets(
    'silent preparation keeps its poster without loading semantics until a real first frame',
    (tester) async {
      final context = await _mount(
        tester,
        bundle,
        child: SizedBox.square(
          dimension: 200,
          child: TrainingActionMedia(
            actionId: _actionId,
            policy: policy,
            showLoadingIndicator: false,
          ),
        ),
      );
      await _warm(tester, context, policy.posterAssetFor(_actionId)!);
      final poster = find.byKey(const ValueKey('public-action-poster'));
      final posterElement = tester.element(poster);
      final loadingSemantics = find.descendant(
        of: find.byType(TrainingActionMedia),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.liveRegion == true,
        ),
      );
      expect(repository.pending, isNotEmpty);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(loadingSemantics, findsNothing);
      expect(tester.widget<AnimatedOpacity>(poster).opacity, 1);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      repository.complete(catalog.tryGet(_actionId)!.video);
      await tester.pump();
      await tester.pump();
      platform.emit(1, 'ready');
      await tester.pump();
      final surface = find.byType(UgkPackedAlphaVideo);
      final surfaceElement = tester.element(surface);
      expect(platform.sources, hasLength(1));
      expect(tester.element(poster), same(posterElement));
      expect(tester.widget<AnimatedOpacity>(poster).opacity, 1);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(loadingSemantics, findsNothing);
      platform.emit(1, 'first-frame');
      await tester.pump();
      await tester.pump();
      expect(tester.element(surface), same(surfaceElement));
      expect(tester.widget<AnimatedOpacity>(poster).opacity, 0);
      final videoOpacity = find.ancestor(
        of: surface,
        matching: find.byType(AnimatedOpacity),
      );
      expect(tester.widget<AnimatedOpacity>(videoOpacity).opacity, 1);
      expect(platform.sources, hasLength(1));
      expect(platform.commands.where((c) => c.$2 == 'dispose'), isEmpty);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(loadingSemantics, findsNothing);
    },
  );

  testWidgets(
    'loading visibility keeps the default spinner and existing decoder while silent errors remain retryable',
    (tester) async {
      const mediaKey = ValueKey('same-loading-action');
      Widget media(bool show) => SizedBox.square(
        dimension: 200,
        child: TrainingActionMedia(
          key: mediaKey,
          actionId: _actionId,
          policy: policy,
          showLoadingIndicator: show,
        ),
      );
      final context = await _mount(
        tester,
        bundle,
        child: SizedBox.square(
          dimension: 200,
          child: TrainingActionMedia(
            key: mediaKey,
            actionId: _actionId,
            policy: policy,
          ),
        ),
      );
      await _warm(tester, context, policy.posterAssetFor(_actionId)!);
      final state = tester.state(find.byType(TrainingActionMedia));
      expect(
        tester
            .widget<TrainingActionMedia>(find.byType(TrainingActionMedia))
            .showLoadingIndicator,
        isTrue,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await _mount(tester, bundle, child: media(false));
      await tester.pump();
      expect(tester.state(find.byType(TrainingActionMedia)), same(state));
      expect(repository.calls, hasLength(1));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      repository.complete(catalog.tryGet(_actionId)!.video);
      await tester.pump();
      await tester.pump();
      platform.emit(1, 'ready');
      await tester.pump();
      final surface = find.byType(UgkPackedAlphaVideo);
      final surfaceElement = tester.element(surface);
      await _mount(tester, bundle, child: media(true));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.element(surface), same(surfaceElement));
      await _mount(tester, bundle, child: media(false));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.element(surface), same(surfaceElement));
      expect(repository.calls, hasLength(1));
      expect(platform.sources, hasLength(1));
      expect(platform.commands.where((c) => c.$2 == 'dispose'), isEmpty);

      platform.emit(1, 'error');
      await tester.pump();
      await tester.pump();
      final retry = find.byKey(const ValueKey('public-action-retry'));
      expect(retry, findsOneWidget);
      expect(tester.widget<TextButton>(retry).onPressed, isNotNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('public-action-poster')),
            )
            .opacity,
        1,
      );
      repository.ready = true;
      await tester.tap(retry);
      await tester.pump();
      await tester.pump();
      expect(repository.calls, hasLength(2));
      expect(platform.sources, hasLength(2));
      expect(retry, findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

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

  for (final failCreate in [true, false]) {
    testWidgets(
      'iOS ${failCreate ? 'create' : 'ready'} failure shows explicit retry status',
      (tester) async {
        repository.ready = true;
        platform.failCreate = failCreate;
        await _mount(
          tester,
          bundle,
          child: TrainingActionMedia(actionId: _actionId, policy: policy),
        );
        await tester.pump();
        await tester.pump();
        if (!failCreate) platform.emit(1, 'error');
        await tester.pump();
        await tester.pump();
        expect(find.text('视频暂不可用，训练继续 · 重试'), findsOneWidget);
        expect(find.byType(TrainerPoster), findsOneWidget);
        expect(find.byType(UgkPackedAlphaVideo), findsNothing);
        expect(order, contains('release:$_actionId'));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }

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

  testWidgets(
    'frame readiness reports a composed frame and releases only after the frame boundary',
    (tester) async {
      repository.ready = true;
      final reports = <bool>[];
      final phases = <SchedulerPhase>[];
      void changed(bool ready) {
        reports.add(ready);
        phases.add(SchedulerBinding.instance.schedulerPhase);
      }

      await _mount(
        tester,
        bundle,
        child: TrainingActionMedia(
          actionId: _actionId,
          policy: policy,
          paused: true,
          prepareFirstFrame: true,
          onFrameReadyChanged: changed,
        ),
      );
      await tester.pump();
      platform.emit(1, 'ready');
      await tester.pump();
      await tester.pump();
      expect(
        reports,
        isEmpty,
        reason: 'Metadata and prime acknowledgement are not a composed frame',
      );
      platform.emit(1, 'first-frame');
      expect(reports, isEmpty);
      await tester.pump();
      await tester.pump();
      expect(reports, [true]);
      platform.emit(1, 'first-frame');
      await tester.pump();
      expect(reports, [true]);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(reports, [true]);
      await tester.pump();
      expect(reports, [true, false]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      platform.emit(2, 'ready');
      platform.emit(2, 'first-frame');
      await tester.pump();
      await tester.pump();
      expect(reports, [true, false, true]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(reports, [true, false, true, false]);
      expect(phases, everyElement(SchedulerPhase.postFrameCallbacks));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a queued old-source readiness report cannot mark a replacement source ready',
    (tester) async {
      repository.ready = true;
      final reports = <bool>[];
      final callback = reports.add;
      Widget media(String id) => TrainingActionMedia(
        key: const ValueKey('readiness-source'),
        actionId: id,
        policy: policy,
        paused: true,
        prepareFirstFrame: true,
        onFrameReadyChanged: callback,
      );
      await _mount(tester, bundle, child: media(_actionId));
      await tester.pump();
      platform.emit(1, 'ready');
      await tester.pump();
      platform.emit(1, 'first-frame');
      // This frame composes the native frame and queues the parent's report.
      await tester.pump();
      expect(reports, isEmpty);
      final alternative = catalog.allActions
          .firstWhere((a) => a.id != _actionId)
          .id;
      await _mount(tester, bundle, child: media(alternative));
      await tester.pump();
      expect(reports, [false]);
      expect(platform.sources, hasLength(2));
      platform.emit(1, 'first-frame');
      platform.emit(2, 'ready');
      await tester.pump();
      expect(reports, [false]);
      platform.emit(2, 'first-frame');
      await tester.pump();
      await tester.pump();
      expect(reports, [false, true]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'replacing a readiness listener invalidates its queued predecessor without replacing media',
    (tester) async {
      repository.ready = true;
      final oldReports = <bool>[];
      final newReports = <bool>[];
      Widget media(ValueChanged<bool> changed) => TrainingActionMedia(
        key: const ValueKey('readiness-listener'),
        actionId: _actionId,
        policy: policy,
        paused: true,
        prepareFirstFrame: true,
        onFrameReadyChanged: changed,
      );
      await _mount(tester, bundle, child: media(oldReports.add));
      await tester.pump();
      platform.emit(1, 'ready');
      await tester.pump();
      final surface = find.byType(UgkPackedAlphaVideo);
      final element = tester.element(surface);
      platform.emit(1, 'first-frame');
      await tester.pump();
      expect(oldReports, isEmpty);
      await _mount(tester, bundle, child: media(newReports.add));
      await tester.pump();
      expect(oldReports, isEmpty);
      expect(newReports, [true]);
      expect(tester.element(surface), same(element));
      expect(platform.sources, hasLength(1));
      expect(platform.commands.where((c) => c.$2 == 'dispose'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a concealed paused frame stays prepared and can reveal without a decoder or playback change',
    (tester) async {
      repository.ready = true;
      final reports = <bool>[];
      final callback = reports.add;
      Widget media({bool reveal = false, bool paused = true}) =>
          TrainingActionMedia(
            key: const ValueKey('concealed-paused-media'),
            actionId: _actionId,
            policy: policy,
            paused: paused,
            prepareFirstFrame: true,
            revealPausedFrame: reveal,
            onFrameReadyChanged: callback,
          );
      await _mount(tester, bundle, child: media());
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      platform.emit(1, 'ready');
      await tester.pump();
      await tester.pump();
      final surface = find.byType(UgkPackedAlphaVideo);
      final element = tester.element(surface);
      final controller = tester.widget<UgkPackedAlphaVideo>(surface).controller;
      platform.emit(1, 'first-frame');
      await tester.pump();
      await tester.pump();
      expect(reports, [true]);
      expect(controller.hasFrame, isTrue);
      final poster = find.byKey(const ValueKey('public-action-poster'));
      final video = find.ancestor(
        of: surface,
        matching: find.byType(AnimatedOpacity),
      );
      expect(tester.widget<AnimatedOpacity>(poster).opacity, 1);
      expect(tester.widget<AnimatedOpacity>(video).opacity, 1 / 255);
      expect(
        platform.commands.where((c) => c.$2 == 'prime-first-frame'),
        hasLength(1),
      );
      expect(platform.commands.where((c) => c.$2 == 'play'), isEmpty);
      final before = List<(int, String, Object?)>.of(platform.commands);

      await _mount(tester, bundle, child: media(reveal: true));
      await tester.pump();
      expect(tester.widget<AnimatedOpacity>(poster).opacity, 0);
      expect(tester.widget<AnimatedOpacity>(video).opacity, 1);
      expect(tester.element(surface), same(element));
      expect(
        tester.widget<UgkPackedAlphaVideo>(surface).controller,
        same(controller),
      );
      expect(platform.commands, before);

      await _mount(tester, bundle, child: media());
      await tester.pump();
      expect(tester.widget<AnimatedOpacity>(poster).opacity, 1);
      expect(platform.commands, before);
      // Suppression is for paused previews only; playing still reveals normally.
      await _mount(tester, bundle, child: media(paused: false));
      await tester.pump();
      expect(tester.widget<AnimatedOpacity>(poster).opacity, 0);
      expect(platform.commands.where((c) => c.$2 == 'play'), hasLength(1));
      expect(platform.sources, hasLength(1));
      expect(platform.commands.where((c) => c.$2 == 'dispose'), isEmpty);
      expect(tester.element(surface), same(element));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'concealing a paused frame suppresses progress but keeps a real download failure retryable',
    (tester) async {
      await _mount(
        tester,
        bundle,
        child: TrainingActionMedia(
          actionId: _actionId,
          policy: policy,
          paused: true,
          prepareFirstFrame: true,
          revealPausedFrame: false,
        ),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      repository.fail(catalog.tryGet(_actionId)!.video);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('public-action-retry')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('public-action-poster')),
            )
            .opacity,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'opt-in paused media primes once and preserves its native surface across play and pause',
    (tester) async {
      repository.ready = true;
      Widget media({bool paused = true}) => TrainingActionMedia(
        key: const ValueKey('primed-public-action'),
        actionId: _actionId,
        policy: policy,
        paused: paused,
        prepareFirstFrame: true,
      );
      await _mount(tester, bundle, child: media());
      await tester.pump();
      await tester.pump();
      platform.emit(1, 'ready');
      await tester.pump();
      await tester.pump();
      final surface = find.byType(UgkPackedAlphaVideo);
      final surfaceElement = tester.element(surface);
      final controller = tester.widget<UgkPackedAlphaVideo>(surface).controller;
      expect(platform.commands.where((c) => c.$2 == 'prime-first-frame'), [
        (1, 'prime-first-frame', null),
      ]);
      expect(platform.commands.where((c) => c.$2 == 'play'), isEmpty);
      expect(
        controller.hasFrame,
        isFalse,
        reason: 'A successful prime RPC cannot invent a composed first frame',
      );
      await _mount(tester, bundle, child: media());
      platform.emit(1, 'ready');
      await tester.pump();
      await tester.pump();
      expect(
        platform.commands.where((c) => c.$2 == 'prime-first-frame'),
        hasLength(1),
      );

      platform.emit(1, 'first-frame');
      await tester.pump();
      await tester.pump();
      expect(controller.hasFrame, isTrue);
      expect(controller.wantsPlay, isFalse);
      expect(
        tester
            .widget<TrainingActionMedia>(find.byType(TrainingActionMedia))
            .paused,
        isTrue,
      );
      expect(tester.widget<Texture>(find.byType(Texture)).textureId, 101);
      await _mount(tester, bundle, child: media(paused: false));
      await tester.pump();
      expect(platform.commands, contains((1, 'play', null)));
      expect(tester.element(surface), same(surfaceElement));
      expect(
        tester.widget<UgkPackedAlphaVideo>(surface).controller,
        same(controller),
      );
      await _mount(tester, bundle, child: media());
      await tester.pump();
      expect(platform.commands.last, (1, 'pause', null));
      expect(tester.element(surface), same(surfaceElement));
      expect(
        tester.widget<UgkPackedAlphaVideo>(surface).controller,
        same(controller),
      );
      expect(tester.widget<Texture>(find.byType(Texture)).textureId, 101);
      expect(platform.sources, hasLength(1));
      expect(
        platform.commands.where((c) => c.$2 == 'prime-first-frame'),
        hasLength(1),
      );
      expect(platform.commands.where((c) => c.$2 == 'dispose'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(platform.commands.where((c) => c.$2 == 'dispose').single.$1, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('ordinary paused hosts do not prime a frame without opting in', (
    tester,
  ) async {
    repository.ready = true;
    await _mount(
      tester,
      bundle,
      child: TrainingActionMedia(
        actionId: _actionId,
        policy: policy,
        paused: true,
      ),
    );
    await tester.pump();
    await tester.pump();
    platform.emit(1, 'ready');
    await tester.pump();
    await tester.pump();
    final controller = tester
        .widget<UgkPackedAlphaVideo>(find.byType(UgkPackedAlphaVideo))
        .controller;
    expect(
      platform.commands.where((c) => c.$2 == 'prime-first-frame'),
      isEmpty,
    );
    expect(platform.commands.where((c) => c.$2 == 'play'), isEmpty);
    expect(controller.hasFrame, isFalse);
    expect(controller.wantsPlay, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(platform.commands.where((c) => c.$2 == 'dispose').single.$1, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a primed paused surface is still released when the app backgrounds',
    (tester) async {
      repository.ready = true;
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      await _mount(
        tester,
        bundle,
        child: TrainingActionMedia(
          actionId: _actionId,
          policy: policy,
          paused: true,
          prepareFirstFrame: true,
        ),
      );
      await tester.pump();
      await tester.pump();
      platform.emit(1, 'ready');
      await tester.pump();
      await tester.pump();
      platform.emit(1, 'first-frame');
      await tester.pump();
      await tester.pump();
      expect(
        platform.commands.where((c) => c.$2 == 'prime-first-frame'),
        hasLength(1),
      );
      expect(find.byType(UgkPackedAlphaVideo), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      await tester.pump();
      expect(find.byType(UgkPackedAlphaVideo), findsNothing);
      expect(platform.commands.where((c) => c.$2 == 'dispose').single.$1, 1);
      expect(platform.sources, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'optional playback control binds and releases without changing the read-only default handle',
    (tester) async {
      repository.ready = true;
      final handle = DrillMediaPlaybackHandle();
      final control = DrillMediaPlaybackControl();
      Widget media({bool controlled = false}) => TrainingActionMedia(
        key: const ValueKey('same-public-action'),
        actionId: _actionId,
        policy: policy,
        playbackHandle: handle,
        playbackControl: controlled ? control : null,
      );
      await _mount(tester, bundle, child: media());
      await tester.pump();
      await tester.pump();
      platform.emit(1, 'ready');
      platform.emit(1, 'first-frame');
      await tester.pump();
      await tester.pump();
      final state = tester.state(find.byType(TrainingActionMedia));
      final before = await handle.capture();
      expect(before!.mediaId, _actionId);
      expect(before.ready, isTrue);
      expect(before.videoSeconds, 1.25);
      expect(
        platform.commands.where((c) => c.$2 == 'return-to-start'),
        isEmpty,
      );

      await _mount(tester, bundle, child: media(controlled: true));
      await tester.pump();
      expect(tester.state(find.byType(TrainingActionMedia)), same(state));
      expect(platform.sources, hasLength(1));
      final returned = control.returnToStart();
      await tester.pump();
      await tester.pump();
      expect(await returned, isTrue);
      expect(platform.commands.where((c) => c.$2 == 'return-to-start').single, (
        1,
        'return-to-start',
        400,
      ));
      expect((await handle.capture())!.mediaId, _actionId);

      await _mount(tester, bundle, child: media());
      await tester.pump();
      expect(await control.returnToStart(), isFalse);
      expect((await handle.capture())!.videoSeconds, 1.25);
      expect(platform.sources, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(await handle.capture(), isNull);
      expect(await control.returnToStart(), isFalse);
      handle.dispose();
      control.dispose();
    },
  );

  testWidgets(
    'replacing a media control cancels its pending return without replacing the decoder',
    (tester) async {
      repository.ready = true;
      platform.delayReturn = true;
      final first = DrillMediaPlaybackControl();
      final second = DrillMediaPlaybackControl();
      Widget media(DrillMediaPlaybackControl control) => TrainingActionMedia(
        key: const ValueKey('same-public-action'),
        actionId: _actionId,
        policy: policy,
        playbackControl: control,
      );
      await _mount(tester, bundle, child: media(first));
      await tester.pump();
      await tester.pump();
      platform.emit(1, 'ready');
      platform.emit(1, 'first-frame');
      await tester.pump();
      await tester.pump();
      final state = tester.state(find.byType(TrainingActionMedia));
      final retired = first.returnToStart();
      expect(platform.returns, hasLength(1));
      await _mount(tester, bundle, child: media(second));
      await tester.pump();
      expect(await retired, isFalse);
      expect(await first.returnToStart(), isFalse);
      expect(tester.state(find.byType(TrainingActionMedia)), same(state));
      expect(platform.sources, hasLength(1));
      final current = second.returnToStart();
      expect(platform.returns, hasLength(2));
      var currentCompleted = false;
      unawaited(current.then((_) => currentCompleted = true));
      platform.returns.first.complete(true);
      await tester.pump();
      expect(currentCompleted, isFalse);
      platform.returns.last.complete(true);
      await tester.pump();
      await tester.pump();
      expect(await current, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(await second.returnToStart(), isFalse);
      first.dispose();
      second.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'opt-in route exit retains its paused native surface until the reverse transition unmounts it',
    (tester) async {
      repository.ready = true;
      final context = await _mount(tester, bundle);
      final paused = ValueNotifier(false);
      final route = RawDialogRoute<void>(
        barrierDismissible: false,
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (context, animation, secondaryAnimation) =>
            DefaultAssetBundle(
              bundle: bundle,
              child: Scaffold(
                body: ValueListenableBuilder<bool>(
                  valueListenable: paused,
                  builder: (context, value, child) => TrainingActionMedia(
                    key: const ValueKey('retained-exit-media'),
                    actionId: _actionId,
                    policy: policy,
                    paused: value,
                    retainSurfaceDuringRouteExit: true,
                  ),
                ),
              ),
            ),
      );
      unawaited(Navigator.of(context).push(route));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      platform.emit(1, 'ready');
      platform.emit(1, 'first-frame');
      await tester.pump();
      await tester.pump();
      paused.value = true;
      await tester.pump();
      final surface = find.byType(UgkPackedAlphaVideo);
      final element = tester.element(surface);
      expect(tester.widget<Texture>(find.byType(Texture)).textureId, 101);
      expect(platform.sources, hasLength(1));

      Navigator.of(context).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      expect(route.animation!.status, AnimationStatus.reverse);
      expect(tester.element(surface), same(element));
      expect(tester.widget<Texture>(find.byType(Texture)).textureId, 101);
      expect(platform.commands.where((c) => c.$2 == 'dispose'), isEmpty);
      await tester.pumpAndSettle();
      expect(surface, findsNothing);
      expect(platform.commands.where((c) => c.$2 == 'dispose').single.$1, 1);
      paused.dispose();
      expect(tester.takeException(), isNull);
    },
  );

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

  testWidgets(
    'idle prefetch reuses its decoder when paused first-frame preparation opens',
    (tester) async {
      final reports = <bool>[];
      final callback = reports.add;
      Widget media({required bool playing}) => TrainingActionMedia(
        key: const ValueKey('prefetched-first-frame'),
        actionId: _actionId,
        policy: policy,
        playing: playing,
        prefetchWhenIdle: true,
        paused: true,
        prepareFirstFrame: true,
        revealPausedFrame: false,
        onFrameReadyChanged: callback,
      );
      final context = await _mount(
        tester,
        bundle,
        child: media(playing: false),
      );
      await _warm(tester, context, policy.posterAssetFor(_actionId)!);
      final video = catalog.tryGet(_actionId)!.video;
      expect(repository.calls, [video]);
      repository.complete(video);
      await tester.pump();
      await tester.pump();
      final surface = find.byType(UgkPackedAlphaVideo);
      final element = tester.element(surface);
      final controller = tester.widget<UgkPackedAlphaVideo>(surface).controller;
      platform.emit(1, 'ready');
      await tester.pump();
      await tester.pump();
      expect(
        platform.commands.where((c) => c.$2 == 'prime-first-frame'),
        isEmpty,
      );
      expect(reports, isEmpty);

      await _mount(tester, bundle, child: media(playing: true));
      await tester.pump();
      await tester.pump();
      expect(tester.element(surface), same(element));
      expect(
        tester.widget<UgkPackedAlphaVideo>(surface).controller,
        same(controller),
      );
      expect(repository.calls, [video]);
      expect(platform.sources, hasLength(1));
      expect(order.where((event) => event == 'pin:$_actionId'), hasLength(1));
      expect(platform.commands.where((c) => c.$2 == 'prime-first-frame'), [
        (1, 'prime-first-frame', null),
      ]);
      expect(controller.hasFrame, isFalse);
      expect(reports, isEmpty);
      expect(platform.commands.where((c) => c.$2 == 'play'), isEmpty);

      platform.emit(1, 'first-frame');
      await tester.pump();
      await tester.pump();
      expect(controller.hasFrame, isTrue);
      expect(reports, [true]);
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('public-action-poster')),
            )
            .opacity,
        1,
      );
      expect(platform.commands.where((c) => c.$2 == 'dispose'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unsupported native alpha rebinds the current handle without a stale failure or download',
    (tester) async {
      final handle = DrillMediaPlaybackHandle();
      addTearDown(handle.dispose);
      Widget media(String id, {bool nativeAlpha = false}) =>
          TrainingActionMedia(
            key: const ValueKey('unsupported-current-action'),
            actionId: id,
            policy: policy,
            nativeAlpha: nativeAlpha,
            playbackHandle: handle,
          );
      final context = await _mount(tester, bundle, child: media(_actionId));
      await _warm(tester, context, policy.posterAssetFor(_actionId)!);
      final video = catalog.tryGet(_actionId)!.video;
      repository.fail(video);
      await tester.pump();
      await tester.pump();
      expect(handle.failed, isTrue);
      expect(repository.calls, [video]);

      final unsupported = _UnsupportedPlatform(order);
      addTearDown(unsupported.eventsController.close);
      UgkPackedAlphaVideo.debugPlatform = unsupported;
      final replacement = catalog.allActions.firstWhere(
        (a) => a.id != _actionId,
      );
      await _mount(
        tester,
        bundle,
        child: media(replacement.id, nativeAlpha: true),
      );
      await tester.pump();
      expect(handle.isBound, isTrue);
      expect(handle.mediaId, replacement.id);
      expect(handle.failed, isFalse);
      expect(handle.hasFrame, isFalse);
      final snapshot = await handle.capture();
      expect(snapshot!.mediaId, replacement.id);
      expect(snapshot.ready, isFalse);
      expect(repository.calls, [video]);
      expect(repository.pending, isEmpty);
      expect(order.where((event) => event == 'pin:${replacement.id}'), isEmpty);
      expect(unsupported.sources, isEmpty);
      expect(find.byType(UgkPackedAlphaVideo), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
