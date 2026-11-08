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

// This harness measures controlled widget time, not Android/network performance.
// Network completion is fixed at 200 ms and a fake decoder emits its frame
// 100 ms after creation. The baseline switch is only for reproducing the parent
// revision; the default expectations cover the corrected behavior.
const _baseline = bool.fromEnvironment('MEDIA_TIMING_BASELINE');
const _id = 'h-squat';
const _posters = 'timing-posters/';
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';

class _Bundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key == 'AssetManifest.bin') {
      return const StandardMessageCodec().encodeMessage({})!;
    }
    if (key.startsWith(_posters)) {
      return ByteData.sublistView(base64Decode(_png));
    }
    throw FlutterError('Not bundled: $key');
  }
}

class _TimingRepository implements CatalogMediaRepository {
  _TimingRepository(this.catalog, this.record);
  @override
  final coach.PoseHubAppTestCatalog catalog;
  final void Function(String) record;
  final _jobs = <String, Future<Uri>>{};
  final _states = <String, ValueNotifier<CatalogMediaDownloadState>>{};
  final calls = <String>[];

  @override
  Uri get mediaBaseUri => Uri.parse('file:///controlled-timing/');

  @override
  Future<Uri> ensureFile(coach.PoseHubPackFile file) {
    calls.add(file.path);
    return _jobs.putIfAbsent(file.path, () async {
      record('ensure');
      final state = watchFile(file) as ValueNotifier<CatalogMediaDownloadState>;
      state.value = CatalogMediaDownloadState(
        phase: CatalogMediaDownloadPhase.downloading,
        totalBytes: file.bytes,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      record('verified');
      state.value = CatalogMediaDownloadState(
        phase: CatalogMediaDownloadPhase.ready,
        receivedBytes: file.bytes,
        totalBytes: file.bytes,
      );
      return file.resolve(mediaBaseUri);
    });
  }

  @override
  ValueListenable<CatalogMediaDownloadState> watchFile(
    coach.PoseHubPackFile file,
  ) => _states.putIfAbsent(
    file.path,
    () => ValueNotifier(
      const CatalogMediaDownloadState(phase: CatalogMediaDownloadPhase.idle),
    ),
  );

  @override
  VoidCallback retainVideo(String actionId) => () {};

  @override
  void dispose() {
    for (final state in _states.values) {
      state.dispose();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TimingPlatform extends PackedAlphaPlatform
    implements PackedAlphaUriPlatform {
  _TimingPlatform(this.record);
  final void Function(String) record;
  final _events = StreamController<Map<Object?, Object?>>.broadcast(sync: true);
  final _timers = <Timer>[];
  int created = 0;

  @override
  bool get isSupported => true;
  @override
  Stream<Map<Object?, Object?>> get events => _events.stream;
  @override
  Future<({int playerId, int textureId})> create(String asset) =>
      throw StateError('Expected a verified URI');

  @override
  Future<({int playerId, int textureId})> createUri(Uri source) async {
    final id = ++created;
    record('decoder-created');
    _timers.add(
      Timer(const Duration(milliseconds: 100), () {
        record('first-frame');
        _events.add({'playerId': id, 'type': 'ready'});
        _events.add({'playerId': id, 'type': 'first-frame'});
      }),
    );
    return (playerId: id, textureId: id + 100);
  }

  @override
  Future<Object?> command(int playerId, String type, [Object? value]) async =>
      null;

  Future<void> close() async {
    for (final timer in _timers) {
      timer.cancel();
    }
    await _events.close();
  }
}

coach.TrainingPlan _plan() => coach.TrainingPlan(
  id: 'controlled-media-timing',
  source: 'template',
  title: 'Controlled timing',
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
          exerciseId: _id,
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

Future<void> _advance(
  WidgetTester tester,
  int milliseconds, {
  VoidCallback? afterPump,
}) async {
  for (var elapsed = 0; elapsed < milliseconds; elapsed += 50) {
    await tester.pump(const Duration(milliseconds: 50));
    afterPump?.call();
  }
}

void main() {
  late coach.PoseHubAppTestCatalog catalog;
  setUpAll(() {
    catalog = coach.PoseHubAppTestCatalog.fromBytes(
      File(
        '../ugk_trainer/assets/pose_hub/app-pack-r2-v10/catalog.json',
      ).readAsBytesSync(),
    );
  });

  for (final launch in [false, true]) {
    testWidgets(
      launch
          ? 'controlled launcher timing downloads during 18 second preparation'
          : 'controlled current-action timing downloads while playback waits',
      (tester) async {
        final stages = <String, int>{};
        final entered = tester.binding.clock.now();
        void record(String stage) => stages.putIfAbsent(
          stage,
          () => tester.binding.clock.now().difference(entered).inMilliseconds,
        );
        void recordRevealed() {
          final poster = find.byKey(const ValueKey('public-action-poster'));
          if (poster.evaluate().length == 1 &&
              tester.widget<AnimatedOpacity>(poster).opacity == 0) {
            record('poster-fade-started');
            final fade = find.descendant(
              of: poster,
              matching: find.byType(FadeTransition),
            );
            if (fade.evaluate().isNotEmpty &&
                tester.widget<FadeTransition>(fade.first).opacity.value < 1) {
              record('video-visible');
            }
          }
        }

        final repo = _TimingRepository(catalog, record);
        final platform = _TimingPlatform(record);
        final policy = TrainingMediaPolicy(
          repository: repo,
          posterAssetRoot: _posters,
          // No speculative lookahead. The original launcher did nothing with
          // this flag; the corrected launcher still prepares its current clip.
          prefetchBeforeTraining: false,
        );
        UgkPackedAlphaVideo.debugPlatform = platform;
        UgkPackedAlphaVideo.debugFilterBuilder = (input) => input;
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final playing = ValueNotifier(false);
        late BuildContext source;
        final bundle = _Bundle();
        await tester.pumpWidget(
          MaterialApp(
            home: DefaultAssetBundle(
              bundle: bundle,
              child: Builder(
                builder: (context) {
                  source = context;
                  return Scaffold(
                    body: launch
                        ? const SizedBox.expand()
                        : ValueListenableBuilder<bool>(
                            valueListenable: playing,
                            builder: (_, canPlay, _) => TrainingActionMedia(
                              policy: policy,
                              actionId: _id,
                              playing: canPlay,
                              prefetchWhenIdle: !_baseline,
                            ),
                          ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => TrainingPosterImages.prepareAsset(
            source,
            policy.posterAssetFor(_id)!,
            timeout: const Duration(seconds: 2),
          ),
        );

        await withClock(Clock(tester.binding.clock.now), () async {
          if (launch) {
            unawaited(
              TrainerLauncher.open<void>(
                source,
                firstPosterAsset: null,
                mediaPolicy: policy,
                planActionIds: const [_id],
                builder: (_) => TrainerPlayer(
                  plan: _plan(),
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
            await _advance(tester, 1000, afterPump: recordRevealed);
            expect(stages['ensure'], isNotNull);
            expect(stages['ensure'], lessThan(1000));
            expect(stages['first-frame'], lessThan(1000));
            await _advance(tester, 17 * 1000, afterPump: recordRevealed);
          } else {
            await _advance(tester, 18 * 1000, afterPump: recordRevealed);
            if (_baseline) {
              expect(repo.calls, isEmpty);
              expect(
                find.byKey(const ValueKey('public-action-progress')),
                findsNothing,
              );
            } else {
              expect(stages['ensure'], 0);
              expect(stages['first-frame'], lessThan(500));
            }
            record('playback-enabled');
            playing.value = true;
            await tester.pump();
            recordRevealed();
            await _advance(tester, 500, afterPump: recordRevealed);
          }
          expect(stages['first-frame'], isNotNull);
          expect(stages['video-visible'], isNotNull);
          if (!launch && _baseline) {
            expect(stages['ensure'], 18000);
            expect(stages['first-frame'], inInclusiveRange(18300, 18400));
          }
          // The poster is actually retired after the decoder's first frame.
          expect(
            tester
                .widget<AnimatedOpacity>(
                  find.byKey(const ValueKey('public-action-poster')),
                )
                .opacity,
            0,
          );
          debugPrint(
            'media.timing controlled-widget '
            '${launch ? 'launcher-prep18' : 'playing-false18'} '
            '${_baseline ? 'before' : 'after'} ${jsonEncode(stages)}',
          );
          await tester.runAsync(() async {
            final directory = Directory('../../build/media-progress-r1');
            await directory.create(recursive: true);
            await File(
              '${directory.path}/${_baseline ? 'before' : 'after'}-'
              '${launch ? 'launcher-prep18' : 'playing-false18'}.json',
            ).writeAsString(
              jsonEncode({
                'method': 'controlled-widget',
                'networkDelayMs': 200,
                'fakeDecoderDelayMs': 100,
                'stagesMsSinceEntry': stages,
              }),
            );
          });
        });
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        UgkPackedAlphaVideo.debugPlatform = null;
        UgkPackedAlphaVideo.debugFilterBuilder = null;
        playing.dispose();
        repo.dispose();
        await platform.close();
      },
    );
  }
}
