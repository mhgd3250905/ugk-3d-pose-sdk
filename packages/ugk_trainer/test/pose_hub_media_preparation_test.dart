import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

import 'support.dart';

/// Deliberately permits callbacks after cancellation to verify generation
/// guards in addition to ordinary StreamSubscription cancellation.
class _ManualStream extends Stream<PoseHubMediaPreparationEvent> {
  _ManualStream() {
    _lifetime = StreamController<PoseHubMediaPreparationEvent>(
      onCancel: () => cancelled = true,
    );
  }
  late final StreamController<PoseHubMediaPreparationEvent> _lifetime;
  void Function(PoseHubMediaPreparationEvent)? _data;
  Function? _error;
  void Function()? _done;
  bool cancelled = false;

  @override
  StreamSubscription<PoseHubMediaPreparationEvent> listen(
    void Function(PoseHubMediaPreparationEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _data = onData;
    _error = onError;
    _done = onDone;
    return _lifetime.stream.listen((_) {});
  }

  void emit(PoseHubMediaPreparationEvent event) => _data?.call(event);
  void fail(Object error) =>
      Function.apply(_error!, [error, StackTrace.current]);
  void finish() => _done?.call();
  Future<void> close() => _lifetime.close();
}

class _HostPreparer implements PoseHubMediaPreparer {
  final actions = <PoseHubPackAction>[];
  final streams = <_ManualStream>[];
  @override
  Stream<PoseHubMediaPreparationEvent> prepareAction(PoseHubPackAction action) {
    actions.add(action);
    final stream = _ManualStream();
    streams.add(stream);
    return stream;
  }
}

class _ThrowingPreparer implements PoseHubMediaPreparer {
  @override
  Stream<PoseHubMediaPreparationEvent> prepareAction(
    PoseHubPackAction action,
  ) => throw StateError('private transport details must not be displayed');
}

class _SyncPreparer implements PoseHubMediaPreparer {
  _SyncPreparer({this.onCancel});
  final VoidCallback? onCancel;
  final controllers = <StreamController<PoseHubMediaPreparationEvent>>[];
  final actions = <PoseHubPackAction>[];

  @override
  Stream<PoseHubMediaPreparationEvent> prepareAction(PoseHubPackAction action) {
    actions.add(action);
    final controller = StreamController<PoseHubMediaPreparationEvent>(
      sync: true,
      onCancel: onCancel,
    );
    controllers.add(controller);
    return controller.stream;
  }

  Future<void> close() async {
    for (final controller in controllers) {
      await controller.close();
    }
  }
}

class _PackedPlatform extends PackedAlphaPlatform
    implements PackedAlphaUriPlatform {
  final eventsController = StreamController<Map<Object?, Object?>>.broadcast(
    sync: true,
  );
  final sources = <Uri>[];
  final commands = <(int, String, Object?)>[];
  @override
  bool get isSupported => true;
  @override
  Stream<Map<Object?, Object?>> get events => eventsController.stream;
  @override
  Future<({int playerId, int textureId})> create(String asset) =>
      throw StateError('Prepared media uses an installed URI');
  @override
  Future<({int playerId, int textureId})> createUri(Uri sourceUri) async {
    sources.add(sourceUri);
    return (playerId: sources.length, textureId: sources.length + 100);
  }

  @override
  Future<Object?> command(int playerId, String type, [Object? value]) async {
    commands.add((playerId, type, value));
    return null;
  }

  void emit(int id, String type) =>
      eventsController.add({'playerId': id, 'type': type});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PoseHubAppTestCatalog catalog;
  late PoseHubPackAction first, second;
  late _HostPreparer host;
  late _PackedPlatform platform;
  final captureHosts = <_HostPreparer>[];
  final syncHosts = <_SyncPreparer>[];
  final fallbackBase = Uri.parse('file:///not-prepared/');
  final readyBase = Uri.parse('file:///verified-cache/v3/');
  String? captureFont;
  final captureDirectory =
      Platform.environment['POSEHUB_PREPARATION_CAPTURE_DIR'];

  setUpAll(() async {
    final raw =
        jsonDecode(
              await File(
                'assets/pose_hub/app-test-pack-r1/catalog.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    final source = (raw['actions']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .where((a) => a['availableForTraining'] == true)
        .take(2)
        .toList();
    raw['actions'] = source;
    raw['totalCount'] = raw['readyCount'] = source.length;
    raw['pendingCount'] = 0;
    final summary = raw['trainingSemantics']! as Map<String, Object?>;
    summary.remove('semanticRevision');
    summary['definitionCompleteCount'] = source.length;
    summary['definitionCompleteIds'] = [for (final a in source) a['id']];
    summary['incompleteActionIds'] = <Object?>[];
    if (raw['mediaDistribution'] case final Map<String, Object?> distribution) {
      distribution['mediaFiles'] = source.length * 3;
      distribution['mediaBytes'] = source
          .expand((action) => (action['files']! as Map<String, Object?>).values)
          .map((file) => (file! as Map<String, Object?>)['bytes']! as int)
          .fold<int>(0, (total, bytes) => total + bytes);
    }
    catalog = PoseHubAppTestCatalog.fromJson(raw);
    first = catalog.allActions[0];
    second = catalog.allActions[1];
    if (captureDirectory != null && captureDirectory.isNotEmpty) {
      final fontPath = Platform.environment['SHOWCASE_FONT'];
      if (fontPath != null && fontPath.isNotEmpty) {
        final loader = FontLoader('PoseHubPreparationCapture')
          ..addFont(
            Future.value(
              ByteData.sublistView(await File(fontPath).readAsBytes()),
            ),
          );
        await loader.load();
        captureFont = 'PoseHubPreparationCapture';
      }
      final cupertino = FontLoader('packages/cupertino_icons/CupertinoIcons')
        ..addFont(
          rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
        );
      await cupertino.load();
      final configFile = File('.dart_tool/package_config.json');
      final config =
          jsonDecode(await configFile.readAsString()) as Map<String, Object?>;
      final flutter = (config['packages']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .firstWhere((package) => package['name'] == 'flutter');
      final root = flutter['rootUri']! as String;
      final flutterDirectory = Directory.fromUri(
        configFile.absolute.uri.resolve(root.endsWith('/') ? root : '$root/'),
      );
      {
        final font = File(
          '${flutterDirectory.parent.parent.path}/bin/cache/artifacts/'
          'material_fonts/MaterialIcons-Regular.otf',
        );
        if (await font.exists()) {
          final material = FontLoader('MaterialIcons')
            ..addFont(
              Future.value(ByteData.sublistView(await font.readAsBytes())),
            );
          await material.load();
        }
      }
    }
  });
  setUp(() {
    captureHosts.clear();
    syncHosts.clear();
    host = _HostPreparer();
    platform = _PackedPlatform();
    UgkPackedAlphaVideo.debugPlatform = platform;
    UgkPackedAlphaVideo.debugFilterBuilder = (input) => input;
  });
  tearDown(() async {
    UgkPackedAlphaVideo.debugPlatform = null;
    UgkPackedAlphaVideo.debugFilterBuilder = null;
    for (final stream in [
      host,
      ...captureHosts,
    ].expand((owner) => owner.streams)) {
      await stream.close();
    }
    for (final owner in syncHosts) {
      await owner.close();
    }
    await platform.eventsController.close();
  });

  Widget app(Widget child, {TrainerTheme theme = TrainerTheme.light}) =>
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: theme == TrainerTheme.dark
              ? Brightness.dark
              : Brightness.light,
          fontFamily: captureFont,
        ),
        home: child,
      );
  Widget practice({
    PoseHubPackAction? action,
    PoseHubMediaPreparer? preparer,
    TrainerTheme theme = TrainerTheme.light,
    ValueChanged<PoseHubPracticeResult>? onFinished,
  }) => app(
    PoseHubSinglePracticePage(
      action: action ?? first,
      mediaBaseUri: fallbackBase,
      mediaPreparer: preparer,
      theme: theme,
      onFinished: onFinished,
    ),
    theme: theme,
  );
  Widget media({
    PoseHubPackAction? action,
    bool playing = false,
    bool paused = false,
    TrainerTheme theme = TrainerTheme.light,
    ValueChanged<PoseHubPackPlaybackStatus>? onStatus,
  }) => app(
    Center(
      child: SizedBox.square(
        dimension: 300,
        child: PoseHubPackMedia(
          action: action ?? first,
          baseUri: fallbackBase,
          mediaPreparer: host,
          playing: playing,
          paused: paused,
          theme: theme,
          onStatus: onStatus,
        ),
      ),
    ),
  );
  Future<void> mount(WidgetTester tester, Widget widget) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 1400);
    await tester.pumpWidget(widget);
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    tester.view.reset();
  }

  test(
    'gate accepts one terminal outcome, ignores late events and cancels',
    () {
      final gate = PoseHubMediaPreparationController();
      final statuses = <PoseHubMediaPreparationStatus>[];
      gate.addListener(() => statuses.add(gate.state.status));
      gate.start(host, first);
      final stream = host.streams.single;
      stream.emit(
        const PoseHubMediaProgress(receivedBytes: 25, totalBytes: 100),
      );
      expect(gate.state.progress!.value, .25);
      stream.emit(PoseHubMediaReady(mediaBaseUri: readyBase));
      expect(gate.state.mediaBaseUri, readyBase);
      expect(stream.cancelled, isTrue);
      stream.emit(const PoseHubMediaFailed(reason: 'late failure'));
      stream.finish();
      expect(
        statuses.where((s) => s == PoseHubMediaPreparationStatus.ready),
        hasLength(1),
      );
      expect(statuses, isNot(contains(PoseHubMediaPreparationStatus.failed)));
      gate.dispose();
      stream.emit(PoseHubMediaReady(mediaBaseUri: readyBase));
    },
  );

  test('error, thrown prepare and premature stream completion fail safely', () {
    final gate = PoseHubMediaPreparationController();
    gate.start(host, first);
    host.streams.last.fail(StateError('secret=private'));
    expect(gate.state.status, PoseHubMediaPreparationStatus.failed);
    expect(gate.state.failureReason, isNot(contains('secret')));
    gate.start(host, first);
    host.streams.last.finish();
    expect(gate.state.status, PoseHubMediaPreparationStatus.failed);
    expect(gate.state.failureReason, contains('未完成'));
    gate.start(_ThrowingPreparer(), first);
    expect(gate.state.status, PoseHubMediaPreparationStatus.failed);
    expect(gate.state.failureReason, isNot(contains('private')));
    gate.dispose();
  });

  for (final operation in ['terminal', 'start', 'cancel']) {
    for (final reentry in ['cancel', 'start', 'dispose']) {
      test('$operation yields to synchronous onCancel $reentry reentry', () {
        final gate = PoseHubMediaPreparationController();
        var disposed = false;
        var cancellations = 0;
        final statuses = <PoseHubMediaPreparationStatus>[];
        gate.addListener(() => statuses.add(gate.state.status));
        final winner = _SyncPreparer();
        final superseded = _SyncPreparer();
        final original = _SyncPreparer(
          onCancel: () {
            cancellations++;
            switch (reentry) {
              case 'cancel':
                gate.cancel();
              case 'start':
                gate.start(winner, second);
                winner.controllers.single.add(
                  const PoseHubMediaProgress(fraction: .5),
                );
              case 'dispose':
                disposed = true;
                gate.dispose();
            }
          },
        );
        syncHosts.addAll([original, superseded, winner]);
        try {
          gate.start(original, first);
          switch (operation) {
            case 'terminal':
              original.controllers.single.add(
                PoseHubMediaReady(mediaBaseUri: readyBase),
              );
            case 'start':
              gate.start(superseded, first);
            case 'cancel':
              gate.cancel();
          }
          expect(cancellations, 1);
          expect(
            superseded.actions,
            isEmpty,
            reason: 'A superseded outer start must not invoke the host',
          );
          expect(
            statuses,
            isNot(contains(PoseHubMediaPreparationStatus.ready)),
          );
          switch (reentry) {
            case 'cancel':
              expect(gate.state.status, PoseHubMediaPreparationStatus.idle);
              expect(statuses, [
                PoseHubMediaPreparationStatus.preparing,
                PoseHubMediaPreparationStatus.idle,
              ]);
            case 'start':
              expect(winner.actions, [second]);
              expect(
                gate.state.status,
                PoseHubMediaPreparationStatus.preparing,
              );
              expect(gate.state.progress!.value, .5);
              winner.controllers.single.add(
                PoseHubMediaReady(mediaBaseUri: readyBase),
              );
              expect(gate.state.status, PoseHubMediaPreparationStatus.ready);
              expect(gate.state.mediaBaseUri, readyBase);
            case 'dispose':
              expect(statuses, [PoseHubMediaPreparationStatus.preparing]);
          }
        } finally {
          if (!disposed) gate.dispose();
        }
      });
    }
  }

  test('dispose retires callbacks before host onCancel can dispose again', () {
    final gate = PoseHubMediaPreparationController();
    var cancellations = 0;
    final original = _SyncPreparer(
      onCancel: () {
        cancellations++;
        gate.dispose();
      },
    );
    syncHosts.add(original);
    gate.start(original, first);
    gate.dispose();
    expect(cancellations, 1);
    gate.start(host, first);
    expect(host.actions, isEmpty);
  });

  test('invalid progress and remote/native-ready directories are rejected', () {
    final gate = PoseHubMediaPreparationController();
    for (final event in <PoseHubMediaPreparationEvent>[
      const PoseHubMediaProgress(fraction: double.nan),
      const PoseHubMediaProgress(receivedBytes: -1),
      const PoseHubMediaProgress(receivedBytes: 11, totalBytes: 10),
      PoseHubMediaReady(mediaBaseUri: Uri.parse('https://github.com/release/')),
      PoseHubMediaReady(
        mediaBaseUri: Uri.parse('file:///cache/no-trailing-slash'),
      ),
      PoseHubMediaReady(mediaBaseUri: Uri.parse('file://server/cache/')),
      PoseHubMediaReady(mediaBaseUri: Uri.parse('file:///cache/?token=secret')),
      PoseHubMediaReady(mediaBaseUri: Uri.parse('file:///cache%2F')),
      PoseHubMediaReady(mediaBaseUri: Uri.parse('file:///cache%5Cprivate/')),
    ]) {
      gate.start(host, first);
      host.streams.last.emit(event);
      expect(
        gate.state.status,
        PoseHubMediaPreparationStatus.failed,
        reason: event is PoseHubMediaReady ? '${event.mediaBaseUri}' : '$event',
      );
    }
    gate.dispose();
  });

  testWidgets(
    'training starts immediately and media failure retries silently',
    (tester) async {
      final results = <PoseHubPracticeResult>[];
      await mount(tester, practice(preparer: host, onFinished: results.add));
      expect(find.byType(TrainerPlayer), findsOneWidget);
      expect(host.actions, [first]);
      expect(find.byType(PoseHubMediaPreparationPanel), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      host.streams.single.emit(
        const PoseHubMediaProgress(receivedBytes: 42, totalBytes: 100),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('字节'), findsNothing);
      host.streams.single.emit(const PoseHubMediaFailed(reason: '网络不可用'));
      await tester.pump();
      expect(find.text('网络不可用'), findsNothing);
      // The deliberately hand-written host subscription completes cancellation
      // on the real async boundary. Allow it to finish before advancing timers.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 2100));
      expect(host.actions, hasLength(2));
      expect(platform.sources, isEmpty);
      host.streams.last.emit(PoseHubMediaReady(mediaBaseUri: readyBase));
      await tester.pump();
      expect(platform.sources, [first.video.resolve(readyBase)]);
      await unmount(tester);
      expect(results, hasLength(1));
      expect(results.single.activeDuration, greaterThan(Duration.zero));
    },
  );

  testWidgets(
    'media prepares on intent, holds bundled still and dissolves after first frame',
    (tester) async {
      await mount(tester, media());
      expect(host.actions, isEmpty);
      expect(tester.widget<Image>(find.byType(Image)).image, isA<AssetImage>());
      await tester.pumpWidget(media(playing: true));
      await tester.pump();
      expect(host.actions, [first]);
      expect(platform.sources, isEmpty);
      host.streams.single.emit(PoseHubMediaReady(mediaBaseUri: readyBase));
      await tester.pump();
      await tester.pump();
      platform.emit(1, 'ready');
      await tester.pump();
      platform.emit(1, 'first-frame');
      await tester.pump();
      await tester.pump();
      final fade = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(fade.opacity, 0);
      expect(fade.duration, const Duration(milliseconds: 180));
      await unmount(tester);
    },
  );

  testWidgets(
    'replacing a provider cancels stale downloads without restarting training',
    (tester) async {
      final replacement = _HostPreparer();
      captureHosts.add(replacement);
      await mount(tester, practice(preparer: host));
      final old = host.streams.single;
      await tester.pumpWidget(practice(preparer: replacement));
      await tester.pump();
      expect(old.cancelled, isTrue);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(replacement.actions, [first]);
      old.emit(PoseHubMediaReady(mediaBaseUri: readyBase));
      await tester.pump();
      expect(platform.sources, isEmpty);
      replacement.streams.single.emit(
        PoseHubMediaReady(mediaBaseUri: readyBase),
      );
      await tester.pump();
      expect(platform.sources, [first.video.resolve(readyBase)]);
      await unmount(tester);
    },
  );

  testWidgets(
    'plan timing and speech finish normally while all media are pending',
    (tester) async {
      final output = RecordingOutput();
      final saved = <SessionResult>[];
      await mount(
        tester,
        app(
          TrainerPlayer(
            plan: planOf([timed(first.id, 2), timed(second.id, 2)]),
            drillOf: (id) => TrainerDrill(id: id, name: id),
            strings: TrainerStrings.zh(),
            keepAlive: false,
            prepSeconds: 0,
            transitionSeconds: 1,
            voice: TrainerVoice(source: hipSource(), output: output),
            poseHubCatalog: catalog,
            poseHubMediaPreparer: host,
            poseHubMediaBaseUri: fallbackBase,
            onFinished: (result) async {
              saved.add(result);
            },
          ),
        ),
      );
      expect(host.actions, [first, second]);
      for (var i = 0; i < 65; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(saved, hasLength(1));
      expect(saved.single.full, isTrue);
      expect(platform.sources, isEmpty);
      expect(output.spoken.isNotEmpty || output.chimes.isNotEmpty, isTrue);
      expect(find.byType(PoseHubMediaPreparationPanel), findsNothing);
      await unmount(tester);
    },
  );
}
