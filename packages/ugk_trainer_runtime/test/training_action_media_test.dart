import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
    return Future.value(null);
  }
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

TrainerPlayer _player(String id) => TrainerPlayer(
  plan: _plan(id),
  drillOf: (id) => TrainerDrill(id: id, name: id),
  strings: TrainerStrings.en(),
  prepSeconds: 0,
  transitionSeconds: 0,
  keepAlive: false,
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
        '../ugk_trainer/assets/pose_hub/app-pack-r2-v1/catalog.json',
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
    final context = await _mount(
      tester,
      bundle,
      child: SizedBox.square(
        dimension: 200,
        child: TrainingActionMedia(actionId: _actionId, policy: policy),
      ),
    );
    await _warm(tester, context, policy.posterAssetFor(_actionId)!);
    repository.fail(catalog.tryGet(_actionId)!.video);
    await tester.pump();
    await _advance(tester, 2000);
    expect(repository.calls, hasLength(1));
    expect(find.byKey(const ValueKey('public-action-retry')), findsOneWidget);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    expect(platform.sources, isEmpty);
    await tester.tap(find.byKey(const ValueKey('public-action-retry')));
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
      expect(find.byKey(const ValueKey('public-action-retry')), findsOneWidget);
      final before = _seconds(tester);
      await _advance(tester, 2000);
      expect(_seconds(tester), lessThan(before));
      expect(find.byType(TrainerPoster), findsOneWidget);
    });
  });

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
}
