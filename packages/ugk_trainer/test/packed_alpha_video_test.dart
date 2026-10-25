import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/src/media/media_view.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

class _Platform extends PackedAlphaPlatform {
  bool supported = true;
  final _events = StreamController<Map<Object?, Object?>>.broadcast(sync: true);
  final creates = <String>[];
  final commands = <(int, String, Object?)>[];
  final pending = <Completer<({int playerId, int textureId})>>[];
  bool delayCreate = false;
  bool earlyReady = false;
  bool positionThrows = false;

  @override
  bool get isSupported => supported;
  @override
  Stream<Map<Object?, Object?>> get events => _events.stream;
  @override
  Future<({int playerId, int textureId})> create(String asset) async {
    creates.add(asset);
    final id = creates.length;
    if (delayCreate) {
      final completer = Completer<({int playerId, int textureId})>();
      pending.add(completer);
      return completer.future;
    }
    if (earlyReady) emit(id, 'ready');
    return (playerId: id, textureId: id + 100);
  }

  void emit(int id, String type) => _events.add({'playerId': id, 'type': type});

  @override
  Future<Object?> command(int playerId, String type, [Object? value]) async {
    commands.add((playerId, type, value));
    if (type == 'position' && positionThrows) {
      throw StateError('Native query unavailable');
    }
    return type == 'position' ? 2.375 : null;
  }
}

/// An inherited catalog from a different revision must not resolve a bundled
/// packed clip or its bundled opaque fallback. Unexpected repository access
/// fails loudly; the resolver counter is the download-path probe.
class _Repository extends ChangeNotifier implements TrainingMediaRepository {
  int resolves = 0;
  @override
  int get cacheRevision => 0;
  @override
  Future<TrainingMediaResource> ensureVideo(
    String id, {
    String skin = 'realistic',
    String theme = 'dark',
  }) async {
    resolves++;
    throw StateError('Bundled media must not resolve through this catalog');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _show(DrillMediaController controller, {String asset = 'packed.mp4'}) =>
    MaterialApp(
      home: Center(
        child: SizedBox.square(
          dimension: 200,
          child: UgkPackedAlphaVideo(asset: asset, controller: controller),
        ),
      ),
    );

void main() {
  late _Platform platform;
  setUp(() {
    platform = _Platform();
    UgkPackedAlphaVideo.debugPlatform = platform;
    // Widget tests run Skia, not the hardware shader. Keep the complete input
    // inspectable; the synthetic Android probe validates actual GPU pixels.
    UgkPackedAlphaVideo.debugFilterBuilder = (input) => input;
  });
  tearDown(() async {
    UgkPackedAlphaVideo.debugPlatform = null;
    UgkPackedAlphaVideo.debugFilterBuilder = null;
    await platform._events.close();
  });

  testWidgets(
    'unsupported backend reports failure without creating a decoder',
    (tester) async {
      platform.supported = false;
      final controller = DrillMediaController();
      await tester.pumpWidget(_show(controller));
      await tester.pump();
      expect(controller.failed, isTrue);
      expect(platform.creates, isEmpty);
      expect(find.byType(Texture), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'full 2h input survives square layout and metadata cannot reveal a frame',
    (tester) async {
      platform.earlyReady = true;
      final controller = DrillMediaController()..toggle();
      await tester.pumpWidget(_show(controller));
      await tester.pump();
      expect(controller.ready, isTrue);
      expect(controller.hasFrame, isFalse);
      expect(
        tester.getSize(find.byType(UgkPackedAlphaVideo)),
        const Size(200, 200),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('packed-alpha-full-input'))),
        const Size(200, 400),
      );
      expect(platform.commands, contains((1, 'play', null)));
      platform.emit(1, 'first-frame');
      expect(
        controller.hasFrame,
        isFalse,
        reason: 'allow the first texture composition under the poster',
      );
      await tester.pump();
      expect(controller.hasFrame, isTrue);
      controller.pause();
      await tester.pump();
      expect(platform.commands.last, (1, 'pause', null));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(platform.commands.last, (1, 'dispose', null));
      controller.dispose();
    },
  );

  testWidgets(
    'late decoder creation is retired and old events cannot ready a replacement',
    (tester) async {
      platform.delayCreate = true;
      final first = DrillMediaController();
      final second = DrillMediaController();
      await tester.pumpWidget(_show(first, asset: 'first.mp4'));
      await tester.pumpWidget(_show(second, asset: 'second.mp4'));
      platform.pending[0].complete((playerId: 1, textureId: 101));
      await tester.pump();
      expect(platform.commands, contains((1, 'dispose', null)));
      platform.pending[1].complete((playerId: 2, textureId: 102));
      await tester.pump();
      platform.emit(1, 'ready');
      platform.emit(1, 'first-frame');
      await tester.pump();
      expect(first.ready, isFalse);
      expect(second.ready, isFalse);
      expect(second.hasFrame, isFalse);
      platform.emit(2, 'ready');
      platform.emit(2, 'first-frame');
      await tester.pump();
      expect(second.ready, isTrue);
      expect(second.hasFrame, isTrue);
      expect(tester.widget<Texture>(find.byType(Texture)).textureId, 102);
      await tester.pumpWidget(const SizedBox.shrink());
      first.dispose();
      second.dispose();
    },
  );

  testWidgets(
    'position is queried once on demand and never polled during playback',
    (tester) async {
      platform.earlyReady = true;
      final controller = DrillMediaController();
      await tester.pumpWidget(_show(controller));
      await tester.pump();
      platform.emit(1, 'first-frame');
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(platform.commands.where((c) => c.$2 == 'position'), isEmpty);
      expect(await controller.readPosition(), 2.375);
      expect(platform.commands.where((c) => c.$2 == 'position'), hasLength(1));
      await tester.pump(const Duration(seconds: 2));
      expect(platform.commands.where((c) => c.$2 == 'position'), hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'failed position inspection returns null without changing playback',
    (tester) async {
      platform.earlyReady = true;
      platform.positionThrows = true;
      final controller = DrillMediaController()..toggle();
      await tester.pumpWidget(_show(controller));
      await tester.pump();
      platform.emit(1, 'first-frame');
      await tester.pump();
      expect(await controller.readPosition(), isNull);
      expect(controller.failed, isFalse);
      expect(controller.hasFrame, isTrue);
      expect(controller.wantsPlay, isTrue);
      expect(platform.commands.where((c) => c.$2 == 'position'), hasLength(1));
      expect(platform.commands.where((c) => c.$2 == 'dispose'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'bundled packed media and its fallback never show repository download UI',
    (tester) async {
      platform.earlyReady = true;
      final repository = _Repository();
      await tester.pumpWidget(
        MaterialApp(
          home: TrainingMediaScope(
            repository: repository,
            child: const Center(
              child: SizedBox.square(
                dimension: 200,
                child: DrillMediaView(
                  media: DrillMedia(
                    id: 'new-catalog-action',
                    videoAsset: 'opaque.mp4',
                    posterAsset: 'opaque.webp',
                    duration: 4,
                    packedAlphaVideoAsset: 'packed.mp4',
                    packedAlphaPosterAsset: 'frame-zero-alpha.webp',
                    bundledOnly: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      platform.emit(1, 'first-frame');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        tester
            .widget<UgkPackedAlphaVideo>(find.byType(UgkPackedAlphaVideo))
            .controller
            .hasFrame,
        isTrue,
      );
      expect(find.text('正在加载动作视频'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      repository.notifyListeners();
      await tester.pump();
      expect(repository.resolves, 0);

      // Decoder failure chooses the ordinary bundled movie, not this inherited
      // repository. A desktop test cannot decode it, but can verify its source.
      platform.emit(1, 'error');
      await tester.pump();
      repository.notifyListeners();
      await tester.pump();
      expect(find.byType(UgkPackedAlphaVideo), findsNothing);
      expect(
        tester
            .widget<DrillMediaPlatformView>(find.byType(DrillMediaPlatformView))
            .videoAsset,
        'opaque.mp4',
      );
      expect(find.text('正在加载动作视频'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(repository.resolves, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      repository.dispose();
    },
  );

  testWidgets(
    'unsupported packed-only media keeps its transparent frame-zero still without an empty player',
    (tester) async {
      platform.supported = false;
      final repository = _Repository();
      await tester.pumpWidget(
        MaterialApp(
          home: TrainingMediaScope(
            repository: repository,
            child: const Center(
              child: SizedBox.square(
                dimension: 200,
                child: DrillMediaView(
                  media: DrillMedia(
                    id: 'packed-only',
                    videoAsset: '',
                    posterAsset: '',
                    duration: 4,
                    packedAlphaVideoAsset: 'packed-only.mp4',
                    packedAlphaPosterAsset: 'only-frame0-alpha.webp',
                    bundledOnly: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final poster = find.byKey(
        const ValueKey('drill-poster-only-frame0-alpha.webp'),
      );
      expect(poster, findsOneWidget);
      expect(
        (tester.widget<Image>(poster).image as AssetImage).assetName,
        'only-frame0-alpha.webp',
      );
      expect(find.byType(UgkPackedAlphaVideo), findsNothing);
      expect(find.byType(DrillMediaPlatformView), findsNothing);
      expect(platform.creates, isEmpty);
      expect(repository.resolves, 0);
      final stages = tester.widgetList<ColoredBox>(
        find.descendant(
          of: find.byType(DrillMediaView),
          matching: find.byType(ColoredBox),
        ),
      );
      expect(stages, isNotEmpty);
      expect(
        stages.every((stage) => stage.color == Colors.transparent),
        isTrue,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      repository.dispose();
    },
  );
}
