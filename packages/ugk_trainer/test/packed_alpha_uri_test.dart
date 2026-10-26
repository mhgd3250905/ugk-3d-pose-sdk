import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer/src/media/packed_alpha_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ugk_trainer/packed_alpha');
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return {'playerId': 4, 'textureId': 104};
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'external source is additive and the legacy asset map stays unchanged',
    () async {
      final platform = MethodChannelPackedAlphaPlatform();
      expect(await platform.create('packages/ugk_trainer/assets/old.mp4'), (
        playerId: 4,
        textureId: 104,
      ));
      expect(calls.single.method, 'create');
      expect(calls.single.arguments, {
        'asset': 'packages/ugk_trainer/assets/old.mp4',
      });
      calls.clear();
      final uri = Uri.parse('file:///verified-pack/media/001/render.mp4');
      expect(await platform.createUri(uri), (playerId: 4, textureId: 104));
      expect(calls.single.method, 'create');
      expect(calls.single.arguments, {'sourceUri': uri.toString()});
    },
  );

  test('only absolute trusted file or HTTP MP4 sources reach native', () async {
    for (final value in [
      'file:///verified-pack/media/001/render.mp4',
      'http://127.0.0.1:7362/__posehub_pack__/media/001/render.mp4',
      'https://media.example.test/verified-pack/render.MP4',
    ]) {
      expect(
        () => validatePackedAlphaSourceUri(Uri.parse(value)),
        returnsNormally,
      );
    }
    final platform = MethodChannelPackedAlphaPlatform();
    for (final value in [
      'relative.mp4',
      'content://media/render.mp4',
      'data:video/mp4,test',
      'ftp://example.test/render.mp4',
      'file://server/pack/render.mp4',
      'https://user:secret@example.test/render.mp4',
      'https://example.test/render.mp4?token=secret',
      'https://example.test/render.mp4#fragment',
      'https://example.test/render.webp',
      'https:/render.mp4',
    ]) {
      await expectLater(
        platform.createUri(Uri.parse(value)),
        throwsFormatException,
        reason: value,
      );
    }
    expect(calls, isEmpty);
    // Dart canonicalizes this spelling to file:///relative.mp4 before this API
    // receives it. Validate the resolved URI; its original spelling is lost.
    expect(Uri.parse('file:relative.mp4').path, '/relative.mp4');
    expect(
      () => validatePackedAlphaSourceUri(Uri.parse('file:relative.mp4')),
      returnsNormally,
    );
  });
}
