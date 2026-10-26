import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

class _UriPlatform extends PackedAlphaPlatform
    implements PackedAlphaUriPlatform {
  bool supported = true;
  final sourceUris = <Uri>[];
  final commands = <(int, String, Object?)>[];
  final _events = StreamController<Map<Object?, Object?>>.broadcast(sync: true);

  @override
  bool get isSupported => supported;
  @override
  Stream<Map<Object?, Object?>> get events => _events.stream;
  @override
  Future<({int playerId, int textureId})> create(String asset) =>
      throw StateError('External media must not enter the bundled asset path');
  @override
  Future<({int playerId, int textureId})> createUri(Uri uri) async {
    sourceUris.add(uri);
    return (playerId: sourceUris.length, textureId: sourceUris.length + 100);
  }

  @override
  Future<Object?> command(int id, String type, [Object? value]) async {
    commands.add((id, type, value));
    return null;
  }

  void emit(int id, String type) => _events.add({'playerId': id, 'type': type});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PoseHubPackAction action;
  late _UriPlatform platform;
  final baseUri = Uri.parse('file:///verified-pack/');
  const cover = ValueKey('pose-hub-pack-cover');

  setUpAll(() {
    action = PoseHubAppTestCatalog.fromBytes(
      File('assets/pose_hub/app-test-pack-r1/catalog.json').readAsBytesSync(),
    ).allActions.first;
  });
  setUp(() {
    platform = _UriPlatform();
    UgkPackedAlphaVideo.debugPlatform = platform;
    UgkPackedAlphaVideo.debugFilterBuilder = (input) => input;
  });
  tearDown(() async {
    UgkPackedAlphaVideo.debugPlatform = null;
    UgkPackedAlphaVideo.debugFilterBuilder = null;
    await platform._events.close();
  });

  Widget show({
    bool playing = false,
    bool paused = false,
    ValueChanged<PoseHubPackPlaybackStatus>? onStatus,
  }) => MaterialApp(
    home: Center(
      child: SizedBox.square(
        dimension: 240,
        child: PoseHubPackMedia(
          action: action,
          baseUri: baseUri,
          playing: playing,
          paused: paused,
          onStatus: onStatus,
        ),
      ),
    ),
  );

  testWidgets('idle preview resolves the original cover without a decoder', (
    tester,
  ) async {
    final statuses = <PoseHubPackPlaybackStatus>[];
    await tester.pumpWidget(show(onStatus: statuses.add));
    await tester.pump();
    expect(find.byKey(cover), findsOneWidget);
    expect(find.byType(UgkPackedAlphaVideo), findsNothing);
    expect(platform.sourceUris, isEmpty);
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<AssetImage>());
    expect(
      (image.image as AssetImage).assetName,
      contains('standing/${action.id}.webp'),
    );
    expect(image.semanticLabel, contains('站位图'));
    expect(statuses, [PoseHubPackPlaybackStatus.cover]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('metadata keeps the cover until a composed native first frame', (
    tester,
  ) async {
    final statuses = <PoseHubPackPlaybackStatus>[];
    await tester.pumpWidget(show(playing: true, onStatus: statuses.add));
    await tester.pump();
    expect(platform.sourceUris, [action.video.resolve(baseUri)]);
    expect(find.byKey(cover), findsOneWidget);
    platform.emit(1, 'ready');
    await tester.pump();
    expect(platform.commands, contains((1, 'play', null)));
    expect(find.byKey(cover), findsOneWidget);
    platform.emit(1, 'first-frame');
    expect(find.byKey(cover), findsOneWidget);
    await tester.pump();
    await tester.pump();
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );
    expect(statuses.last, PoseHubPackPlaybackStatus.playing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(platform.commands.last, (1, 'dispose', null));
  });

  testWidgets(
    'pause retains the decoder and replay reinstates first-frame gate',
    (tester) async {
      await tester.pumpWidget(show(playing: true));
      await tester.pump();
      platform.emit(1, 'ready');
      platform.emit(1, 'first-frame');
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        0,
      );
      await tester.pumpWidget(show(playing: true, paused: true));
      await tester.pump();
      expect(platform.sourceUris, hasLength(1));
      expect(platform.commands.last, (1, 'pause', null));
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        0,
      );
      await tester.pumpWidget(show(playing: true));
      await tester.pump();
      expect(platform.sourceUris, hasLength(1));
      expect(platform.commands.last, (1, 'play', null));
      await tester.pumpWidget(show());
      await tester.pump();
      expect(find.byKey(cover), findsOneWidget);
      expect(platform.commands.last, (1, 'dispose', null));
      await tester.pumpWidget(show(playing: true));
      await tester.pump();
      expect(platform.sourceUris, hasLength(2));
      platform.emit(1, 'first-frame');
      platform.emit(2, 'ready');
      await tester.pump();
      expect(find.byKey(cover), findsOneWidget);
      platform.emit(2, 'first-frame');
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        0,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('unsupported platforms keep an explicit cover-only state', (
    tester,
  ) async {
    platform.supported = false;
    final statuses = <PoseHubPackPlaybackStatus>[];
    await tester.pumpWidget(show(playing: true, onStatus: statuses.add));
    await tester.pump();
    expect(find.byKey(cover), findsOneWidget);
    expect(find.text('当前平台仅显示封面'), findsNothing);
    expect(platform.sourceUris, isEmpty);
    expect(statuses.last, PoseHubPackPlaybackStatus.unsupported);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'network thumbnails use their original file and failed image has fallback',
    (tester) async {
      final networkBase = Uri.parse('https://example.test/pack/');
      await tester.pumpWidget(
        MaterialApp(
          home: PoseHubPackImage(
            file: action.thumbnail,
            baseUri: networkBase,
            semanticLabel: '原始缩略图',
          ),
        ),
      );
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<NetworkImage>());
      expect(
        (image.image as NetworkImage).url,
        action.thumbnail.resolve(networkBase).toString(),
      );
      expect(image.semanticLabel, '原始缩略图');
      final context = tester.element(find.byType(Image));
      await tester.pumpWidget(
        MaterialApp(
          home: image.errorBuilder!(context, StateError('missing'), null),
        ),
      );
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
