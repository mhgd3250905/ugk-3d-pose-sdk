import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

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

  FilledButton startButton(WidgetTester tester) => tester.widget<FilledButton>(
    find.byKey(const ValueKey('posehub-practice-toggle')),
  );

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
    'browser and detail browse without preparing; single practice prepares once',
    (tester) async {
      await mount(
        tester,
        app(
          PoseHubActionBrowser(
            catalog: catalog,
            mediaBaseUri: fallbackBase,
            mediaPreparer: host,
          ),
        ),
      );
      expect(host.actions, isEmpty);
      await tester.tap(find.byKey(ValueKey('posehub-action-${first.id}')));
      await tester.pumpAndSettle();
      expect(find.byType(PoseHubActionDetail), findsOneWidget);
      expect(host.actions, isEmpty);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('posehub-practice')),
        300,
      );
      await tester.tap(find.byKey(const ValueKey('posehub-practice')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(host.actions, [first]);
      expect(startButton(tester).onPressed, isNull);
      host.streams.single.emit(PoseHubMediaReady(mediaBaseUri: readyBase));
      await tester.pump();
      await tester.ensureVisible(
        find.byKey(const ValueKey('posehub-practice-toggle')),
      );
      await tester.tap(find.byKey(const ValueKey('posehub-practice-toggle')));
      await tester.pump();
      expect(
        host.actions,
        hasLength(1),
        reason: 'The page must not prepare again through its media widget',
      );
      expect(platform.sources, [first.video.resolve(readyBase)]);
      await unmount(tester);
    },
  );

  testWidgets(
    'preparing and ready do not start time; only an explicit start records activity',
    (tester) async {
      final results = <PoseHubPracticeResult>[];
      await mount(tester, practice(preparer: host, onFinished: results.add));
      expect(startButton(tester).onPressed, isNull);
      host.streams.single.emit(
        const PoseHubMediaProgress(
          fraction: .42,
          receivedBytes: 42,
          totalBytes: 100,
        ),
      );
      await tester.pump();
      expect(find.text('42%'), findsOneWidget);
      expect(find.text('已准备 42 / 100 字节'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .42,
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1050)),
      );
      host.streams.single.emit(PoseHubMediaReady(mediaBaseUri: readyBase));
      await tester.pump();
      expect(startButton(tester).onPressed, isNotNull);
      expect(platform.sources, isEmpty);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1050)),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('0:00'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('posehub-practice-toggle')));
      await tester.pump();
      expect(find.text('暂停'), findsOneWidget);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.tap(find.byKey(const ValueKey('posehub-practice-finish')));
      await tester.pump();
      expect(results, hasLength(1));
      expect(results.single.activeDuration, greaterThan(Duration.zero));
      expect(
        results.single.activeDuration,
        lessThan(const Duration(milliseconds: 900)),
      );
      await unmount(tester);
    },
  );

  testWidgets(
    'host failure is visible and retry remains unstarted until ready and tapped',
    (tester) async {
      await mount(tester, practice(preparer: host));
      host.streams.single.emit(const PoseHubMediaFailed(reason: '网络不可用，请稍后重试'));
      await tester.pump();
      expect(find.text('网络不可用，请稍后重试'), findsOneWidget);
      expect(startButton(tester).onPressed, isNull);
      await tester.tap(
        find.byKey(const ValueKey('posehub-media-preparation-retry')),
      );
      await tester.pump();
      expect(host.actions, hasLength(2));
      expect(find.text('0:00'), findsOneWidget);
      expect(startButton(tester).onPressed, isNull);
      host.streams.last.emit(PoseHubMediaReady(mediaBaseUri: readyBase));
      await tester.pump();
      expect(startButton(tester).onPressed, isNotNull);
      expect(platform.sources, isEmpty);
      await unmount(tester);
    },
  );

  testWidgets(
    'no preparer preserves immediate local practice and existing controls',
    (tester) async {
      await mount(tester, practice());
      expect(find.byType(PoseHubMediaPreparationPanel), findsNothing);
      expect(startButton(tester).onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('posehub-practice-toggle')));
      await tester.pump();
      expect(platform.sources, [first.video.resolve(fallbackBase)]);
      expect(find.text('暂停'), findsOneWidget);
      await unmount(tester);
    },
  );

  testWidgets('action replacement and disposal retire late host events', (
    tester,
  ) async {
    await mount(tester, practice(preparer: host));
    final old = host.streams.single;
    await tester.pumpWidget(practice(action: second, preparer: host));
    await tester.pump();
    expect(old.cancelled, isTrue);
    expect(host.actions, [first, second]);
    old.emit(PoseHubMediaReady(mediaBaseUri: readyBase));
    await tester.pump();
    expect(startButton(tester).onPressed, isNull);
    expect(platform.sources, isEmpty);
    final current = host.streams.last;
    await unmount(tester);
    expect(current.cancelled, isTrue);
    current.emit(PoseHubMediaReady(mediaBaseUri: readyBase));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'replacing a provider after start stops and resets time until explicit restart',
    (tester) async {
      final replacement = _HostPreparer();
      captureHosts.add(replacement);
      final results = <PoseHubPracticeResult>[];
      await mount(tester, practice(preparer: host, onFinished: results.add));
      final old = host.streams.single;
      old.emit(PoseHubMediaReady(mediaBaseUri: readyBase));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('posehub-practice-toggle')));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1050)),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('0:01'), findsOneWidget);
      expect(platform.sources, hasLength(1));

      await tester.pumpWidget(
        practice(preparer: replacement, onFinished: results.add),
      );
      await tester.pump();
      expect(replacement.actions, [first]);
      expect(find.text('0:00'), findsOneWidget);
      expect(startButton(tester).onPressed, isNull);
      expect(
        find.byKey(const ValueKey('posehub-practice-finish')),
        findsNothing,
      );
      old.emit(PoseHubMediaReady(mediaBaseUri: readyBase));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1050)),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('0:00'), findsOneWidget);
      expect(startButton(tester).onPressed, isNull);
      expect(platform.sources, hasLength(1));

      replacement.streams.single.emit(
        PoseHubMediaReady(mediaBaseUri: readyBase),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('0:00'), findsOneWidget);
      expect(startButton(tester).onPressed, isNotNull);
      expect(platform.sources, hasLength(1));
      await tester.tap(find.byKey(const ValueKey('posehub-practice-toggle')));
      await tester.pump();
      expect(platform.sources, hasLength(2));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.tap(find.byKey(const ValueKey('posehub-practice-finish')));
      await tester.pump();
      expect(results, hasLength(1));
      expect(results.single.activeDuration, greaterThan(Duration.zero));
      expect(
        results.single.activeDuration,
        lessThan(const Duration(milliseconds: 900)),
      );
      await unmount(tester);
    },
  );

  for (final (name, theme) in [
    ('light', TrainerTheme.light),
    ('dark', TrainerTheme.dark),
  ]) {
    testWidgets(
      '$name preparation and failure use supplied opaque theme tokens',
      (tester) async {
        await mount(tester, practice(preparer: host, theme: theme));
        final surface = tester.widget<TrainerSurface>(
          find.descendant(
            of: find.byType(PoseHubMediaPreparationPanel),
            matching: find.byType(TrainerSurface),
          ),
        );
        expect(surface.theme, same(theme));
        host.streams.single.emit(const PoseHubMediaFailed(reason: '缓存空间不足'));
        await tester.pump();
        final reason = tester.widget<Text>(
          find.byKey(const ValueKey('posehub-media-preparation-reason')),
        );
        expect(reason.style!.color, theme.caution);
        await tester.pumpWidget(practice(preparer: host, theme: theme));
        await tester.pump();
        expect(
          host.actions,
          hasLength(1),
          reason: 'A theme/rebuild must not retry failed work',
        );
        await unmount(tester);
      },
    );
  }

  testWidgets(
    'media prepares only on playback intent and decodes only after verified ready',
    (tester) async {
      final statuses = <PoseHubPackPlaybackStatus>[];
      await mount(tester, media(onStatus: statuses.add));
      expect(host.actions, isEmpty);
      expect(statuses.last, PoseHubPackPlaybackStatus.cover);
      await tester.pumpWidget(media(playing: true, onStatus: statuses.add));
      await tester.pump();
      expect(host.actions, [first]);
      expect(platform.sources, isEmpty);
      expect(find.byType(UgkPackedAlphaVideo), findsNothing);
      expect(statuses.last, PoseHubPackPlaybackStatus.loading);
      host.streams.single.emit(PoseHubMediaReady(mediaBaseUri: readyBase));
      await tester.pump();
      expect(platform.sources, [first.video.resolve(readyBase)]);
      platform.emit(1, 'ready');
      platform.emit(1, 'first-frame');
      await tester.pump();
      await tester.pump();
      expect(statuses.last, PoseHubPackPlaybackStatus.playing);
      await tester.pumpWidget(
        media(playing: true, paused: true, onStatus: statuses.add),
      );
      await tester.pump();
      expect(statuses.last, PoseHubPackPlaybackStatus.paused);
      expect(host.actions, hasLength(1));
      await tester.pumpWidget(media(onStatus: statuses.add));
      await tester.pump();
      await tester.pumpWidget(media(playing: true, onStatus: statuses.add));
      await tester.pump();
      expect(
        host.actions,
        hasLength(1),
        reason: 'Verified ready state may be reused for the same action',
      );
      expect(platform.sources, hasLength(2));
      await unmount(tester);
    },
  );

  testWidgets(
    'media failure, retry and stopped/replaced streams cannot reveal a stale decoder',
    (tester) async {
      await mount(tester, media(playing: true));
      final old = host.streams.single;
      old.emit(const PoseHubMediaFailed(reason: '校验未通过，请重试'));
      await tester.pump();
      expect(find.text('校验未通过，请重试'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('posehub-media-preparation-retry')),
      );
      await tester.pump();
      final retry = host.streams.last;
      expect(host.actions, hasLength(2));
      await tester.pumpWidget(media(action: second, playing: true));
      await tester.pump();
      expect(retry.cancelled, isTrue);
      old.emit(PoseHubMediaReady(mediaBaseUri: readyBase));
      retry.emit(PoseHubMediaReady(mediaBaseUri: readyBase));
      await tester.pump();
      expect(platform.sources, isEmpty);
      final current = host.streams.last;
      await tester.pumpWidget(media(action: second));
      await tester.pump();
      expect(current.cancelled, isTrue);
      current.emit(PoseHubMediaReady(mediaBaseUri: readyBase));
      await tester.pump();
      expect(platform.sources, isEmpty);
      await unmount(tester);
    },
  );

  testWidgets(
    'optional software captures of light/dark preparing and failed states',
    (tester) async {
      if (captureDirectory == null || captureDirectory.isEmpty) return;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(430, 932);
      final configuredBase = Platform.environment['POSEHUB_CAPTURE_MEDIA_BASE'];
      final captureBase = configuredBase == null || configuredBase.isEmpty
          ? fallbackBase
          : Directory(configuredBase).absolute.uri;
      for (final (name, theme) in [
        ('light', TrainerTheme.light),
        ('dark', TrainerTheme.dark),
      ]) {
        final captureHost = _HostPreparer();
        captureHosts.add(captureHost);
        await tester.pumpWidget(
          RepaintBoundary(
            key: const ValueKey('preparation-capture'),
            child: app(
              PoseHubSinglePracticePage(
                key: ValueKey(name),
                action: first,
                mediaBaseUri: captureBase,
                mediaPreparer: captureHost,
                theme: theme,
              ),
              theme: theme,
            ),
          ),
        );
        await tester.pump();
        // FileImage performs real I/O; allow it to complete without awaiting a
        // cached image future across the test's fake/real async zones.
        for (var frame = 0; frame < 20; frame++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump();
          final image = find.byType(RawImage);
          if (image.evaluate().isNotEmpty &&
              tester.widget<RawImage>(image).image != null) {
            break;
          }
        }
        for (final state in ['preparing', 'failed']) {
          captureHost.streams.single.emit(
            state == 'preparing'
                ? const PoseHubMediaProgress(
                    fraction: .42,
                    receivedBytes: 420000,
                    totalBytes: 1000000,
                  )
                : const PoseHubMediaFailed(reason: '网络连接不可用，请稍后重试'),
          );
          await tester.pump(const Duration(milliseconds: 100));
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('preparation-capture')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final output = File('$captureDirectory/$state-$name.png');
            await output.parent.create(recursive: true);
            await output.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
      tester.view.reset();
    },
  );
}
