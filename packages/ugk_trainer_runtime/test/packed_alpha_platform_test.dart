import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer_runtime/src/media/packed_alpha_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ugk_trainer/packed_alpha');

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final target in TargetPlatform.values) {
    test(
      '$target packed support requires a native backend and shader filter',
      () {
        debugDefaultTargetPlatformOverride = target;
        expect(
          MethodChannelPackedAlphaPlatform().isSupported,
          (target == TargetPlatform.android || target == TargetPlatform.iOS) &&
              ui.ImageFilter.isShaderFilterSupported,
        );
      },
    );
  }

  test(
    'iOS uses the existing asset, URI and command channel contract',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.method == 'create'
                ? {'playerId': 7, 'textureId': 107}
                : null;
          });
      final platform = MethodChannelPackedAlphaPlatform();
      expect(await platform.create('assets/demo.mp4'), (
        playerId: 7,
        textureId: 107,
      ));
      final source = Uri.parse('file:///verified-cache/demo.mp4');
      expect(await platform.createUri(source), (playerId: 7, textureId: 107));
      await platform.command(7, 'visible', false);
      expect(calls.map((call) => call.method), ['create', 'create', 'visible']);
      expect(calls.map((call) => call.arguments), [
        {'asset': 'assets/demo.mp4'},
        {'sourceUri': source.toString()},
        {'playerId': 7, 'value': false},
      ]);
    },
  );
}
