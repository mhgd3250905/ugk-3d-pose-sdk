import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

class _LegacyPlatform extends PackedAlphaPlatform
    implements PackedAlphaUriPlatform {
  _LegacyPlatform({this.supported = true});
  final bool supported;
  final eventsController = StreamController<Map<Object?, Object?>>.broadcast(
    sync: true,
  );
  final sources = <Object>[];
  final commands = <(int, String, Object?)>[];
  int nextId = 0;

  @override
  bool get isSupported => supported;
  @override
  Stream<Map<Object?, Object?>> get events => eventsController.stream;
  @override
  Future<({int playerId, int textureId})> create(String asset) async {
    sources.add(asset);
    final id = ++nextId;
    return (playerId: id, textureId: id + 100);
  }

  @override
  Future<({int playerId, int textureId})> createUri(Uri sourceUri) async {
    sources.add(sourceUri);
    final id = ++nextId;
    return (playerId: id, textureId: id + 100);
  }

  @override
  Future<Object?> command(int playerId, String type, [Object? value]) async {
    commands.add((playerId, type, value));
    return null;
  }

  void emit(int id, String type) =>
      eventsController.add({'playerId': id, 'type': type});
}

class _RgbaPlatform extends _LegacyPlatform implements PackedAlphaRgbaPlatform {
  _RgbaPlatform({super.supported, this.rgbaSupported = true});
  final bool rgbaSupported;
  final rgbaSources = <({String? asset, Uri? sourceUri})>[];
  Completer<({int playerId, int textureId})>? pending;

  @override
  bool get isRgbaSupported => rgbaSupported;
  @override
  Future<({int playerId, int textureId})> createRgba({
    String? asset,
    Uri? sourceUri,
  }) async {
    rgbaSources.add((asset: asset, sourceUri: sourceUri));
    final delayed = pending;
    if (delayed != null) return delayed.future;
    final id = ++nextId;
    return (playerId: id, textureId: id + 100);
  }
}

Widget _surface(
  DrillMediaController controller, {
  bool nativeAlpha = false,
  Uri? source,
  double size = 200,
}) => MaterialApp(
  home: Center(
    child: SizedBox.square(
      dimension: size,
      child: source == null
          ? UgkPackedAlphaVideo(
              asset: 'packed.mp4',
              controller: controller,
              nativeAlpha: nativeAlpha,
            )
          : UgkPackedAlphaVideo.source(
              sourceUri: source,
              controller: controller,
              nativeAlpha: nativeAlpha,
            ),
    ),
  ),
);

void _install(WidgetTester tester, _LegacyPlatform platform) {
  final oldPlatform = UgkPackedAlphaVideo.debugPlatform;
  final oldFilter = UgkPackedAlphaVideo.debugFilterBuilder;
  final oldRgbaTexture = UgkPackedAlphaVideo.debugRgbaTextureBuilder;
  UgkPackedAlphaVideo.debugPlatform = platform;
  UgkPackedAlphaVideo.debugFilterBuilder = (input) => input;
  UgkPackedAlphaVideo.debugRgbaTextureBuilder = null;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await platform.eventsController.close();
    UgkPackedAlphaVideo.debugPlatform = oldPlatform;
    UgkPackedAlphaVideo.debugFilterBuilder = oldFilter;
    UgkPackedAlphaVideo.debugRgbaTextureBuilder = oldRgbaTexture;
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'capable backends still use the legacy packed output by default',
    (tester) async {
      final platform = _RgbaPlatform();
      _install(tester, platform);
      final controller = DrillMediaController();
      await tester.pumpWidget(_surface(controller));
      await tester.pump();
      expect(platform.sources, ['packed.mp4']);
      expect(platform.rgbaSources, isEmpty);
      expect(
        find.byKey(const ValueKey('packed-alpha-full-input')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('packed-alpha-native-rgba')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      controller.dispose();
    },
  );

  testWidgets(
    'native RGBA output needs no shader support and reveals only after its real first frame',
    (tester) async {
      final platform = _RgbaPlatform(supported: false);
      _install(tester, platform);
      var packedFilters = 0;
      UgkPackedAlphaVideo.debugFilterBuilder = (input) {
        packedFilters++;
        return input;
      };
      final controller = DrillMediaController();
      expect(UgkPackedAlphaVideo.isSupported, isFalse);
      expect(UgkPackedAlphaVideo.isSupportedFor(nativeAlpha: true), isTrue);
      await tester.pumpWidget(_surface(controller, nativeAlpha: true));
      await tester.pump();
      expect(platform.sources, isEmpty);
      expect(platform.rgbaSources, [(asset: 'packed.mp4', sourceUri: null)]);
      expect(packedFilters, 0);
      expect(find.byType(Texture), findsOneWidget);
      final texture = find.byKey(const ValueKey('packed-alpha-native-rgba'));
      expect(tester.widget<Texture>(texture).textureId, 101);
      expect(tester.getSize(texture), const Size(200, 200));
      expect(find.byType(ImageFiltered), findsNothing);
      expect(
        find.byKey(const ValueKey('packed-alpha-full-input')),
        findsNothing,
      );
      platform.emit(1, 'ready');
      await tester.pump();
      expect(controller.ready, isTrue);
      expect(controller.hasFrame, isFalse);
      platform.emit(1, 'first-frame');
      expect(controller.hasFrame, isFalse);
      await tester.pump();
      expect(controller.hasFrame, isTrue);
      expect(controller.failed, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      controller.dispose();
    },
  );

  testWidgets(
    'resizing a native URI surface keeps its one decoder and texture',
    (tester) async {
      final platform = _RgbaPlatform();
      _install(tester, platform);
      final controller = DrillMediaController();
      final source = Uri.parse('file:///verified-pack/drill.mp4');
      await tester.pumpWidget(
        _surface(controller, nativeAlpha: true, source: source),
      );
      await tester.pump();
      final surface = find.byType(UgkPackedAlphaVideo);
      final element = tester.element(surface);
      platform.emit(1, 'ready');
      platform.emit(1, 'first-frame');
      await tester.pump();
      await tester.pumpWidget(
        _surface(controller, nativeAlpha: true, source: source, size: 310),
      );
      await tester.pump();
      expect(tester.element(surface), same(element));
      expect(
        tester.widget<UgkPackedAlphaVideo>(surface).controller,
        same(controller),
      );
      expect(platform.rgbaSources, [(asset: null, sourceUri: source)]);
      expect(platform.sources, isEmpty);
      expect(controller.hasFrame, isTrue);
      expect(find.byType(Texture), findsOneWidget);
      final texture = find.byKey(const ValueKey('packed-alpha-native-rgba'));
      expect(tester.widget<Texture>(texture).textureId, 101);
      expect(tester.getSize(texture), const Size(310, 310));
      expect(platform.commands.where((c) => c.$2 == 'dispose'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(platform.commands.where((c) => c.$2 == 'dispose').toList(), [
        (1, 'dispose', null),
      ]);
      controller.dispose();
    },
  );

  testWidgets(
    'a retired pending native create releases its late texture once',
    (tester) async {
      final platform = _RgbaPlatform()
        ..pending = Completer<({int playerId, int textureId})>();
      _install(tester, platform);
      final controller = DrillMediaController();
      await tester.pumpWidget(_surface(controller, nativeAlpha: true));
      await tester.pump();
      expect(platform.rgbaSources, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      platform.pending!.complete((playerId: 7, textureId: 107));
      await tester.pump();
      await tester.pump();
      expect(platform.commands.where((c) => c.$2 == 'dispose').toList(), [
        (7, 'dispose', null),
      ]);
      expect(find.byType(Texture), findsNothing);
      expect(controller.hasFrame, isFalse);
      controller.dispose();
    },
  );

  testWidgets(
    'a disabled optional capability falls back to the packed backend',
    (tester) async {
      final platform = _RgbaPlatform(rgbaSupported: false);
      _install(tester, platform);
      final controller = DrillMediaController();
      await tester.pumpWidget(_surface(controller, nativeAlpha: true));
      await tester.pump();
      expect(platform.rgbaSources, isEmpty);
      expect(platform.sources, ['packed.mp4']);
      expect(
        find.byKey(const ValueKey('packed-alpha-full-input')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      controller.dispose();
    },
  );

  testWidgets('legacy URI backends need not implement native RGBA capability', (
    tester,
  ) async {
    final platform = _LegacyPlatform();
    _install(tester, platform);
    final controller = DrillMediaController();
    final source = Uri.parse('https://media.example/pack/drill.mp4');
    await tester.pumpWidget(
      _surface(controller, nativeAlpha: true, source: source),
    );
    await tester.pump();
    expect(platform.sources, [source]);
    expect(
      find.byKey(const ValueKey('packed-alpha-full-input')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('packed-alpha-native-rgba')),
      findsNothing,
    );
    expect(controller.failed, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    controller.dispose();
  });

  test(
    'the native bridge opts in explicitly and validates trusted source URIs',
    () async {
      const channel = MethodChannel('ugk_trainer/packed_alpha');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return {'playerId': calls.length, 'textureId': 100 + calls.length};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final platform = MethodChannelPackedAlphaPlatform();
      final source = Uri.parse('file:///verified-pack/drill.mp4');
      expect(await platform.create('packed.mp4'), (
        playerId: 1,
        textureId: 101,
      ));
      await platform.createUri(source);
      await platform.createRgba(asset: 'packed.mp4');
      expect(await platform.createRgba(sourceUri: source), (
        playerId: 4,
        textureId: 104,
      ));
      expect(calls.map((call) => call.method), everyElement('create'));
      expect(calls.map((call) => call.arguments).toList(), [
        {'asset': 'packed.mp4'},
        {'sourceUri': source.toString()},
        {'asset': 'packed.mp4', 'nativeAlpha': true},
        {'sourceUri': source.toString(), 'nativeAlpha': true},
      ]);
      await expectLater(platform.createRgba(), throwsArgumentError);
      await expectLater(
        platform.createRgba(asset: 'packed.mp4', sourceUri: source),
        throwsArgumentError,
      );
      for (final invalid in [
        Uri.parse('https://media.example/drill.mp4?token=not-allowed'),
        Uri.parse('https://name:secret@media.example/drill.mp4'),
        Uri.parse('relative/drill.mp4'),
      ]) {
        await expectLater(
          platform.createRgba(sourceUri: invalid),
          throwsFormatException,
        );
      }
      expect(calls, hasLength(4));
    },
  );
}
