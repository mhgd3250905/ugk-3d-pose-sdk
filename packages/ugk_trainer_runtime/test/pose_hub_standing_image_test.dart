import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

PoseHubPackFile _file(
  String role, {
  String revision = 'r2-v8',
  String id = 'action',
}) => PoseHubPackFile.fromJson({
  'path': 'media/$id/$revision/$role.${role == 'video' ? 'mp4' : 'webp'}',
  'bytes': role == 'video' ? 10 : _pixel.length,
  'sha256': role == 'video' ? 'a' * 64 : sha256.convert(_pixel).toString(),
});

class _Bundle extends CachingAssetBundle {
  _Bundle({this.matches = false, this.hasImage = true, this.hasRecord = true});
  final bool matches;
  final bool hasImage;
  final bool hasRecord;
  @override
  Future<ByteData> load(String key) async {
    if (key.endsWith('AssetManifest.bin')) {
      return const StandardMessageCodec().encodeMessage(<String, Object?>{})!;
    }
    if (key.endsWith('/index.json')) {
      return ByteData.sublistView(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'schema': 1,
              'actions': {
                if (hasRecord)
                  'action': {
                    'videoPath': _file(
                      'video',
                      revision: matches ? 'r2-v8' : 'r2-v7',
                    ).path,
                    'videoSha256': 'a' * 64,
                  },
              },
            }),
          ),
        ),
      );
    }
    if (key.endsWith('/action.webp') && hasImage) {
      return ByteData.sublistView(_pixel);
    }
    throw FlutterError('No fixture asset: $key');
  }
}

class _Cache extends PoseHubImageCache {
  final calls = <PoseHubPackFile>[];
  final completion = Completer<Uri>();
  @override
  Future<Uri> ensureFile(PoseHubPackFile file, {Uri? mediaBaseUri}) {
    calls.add(file);
    return completion.future;
  }
}

Widget _card(
  _Bundle bundle,
  _Cache cache, {
  bool thumbnail = false,
  String id = 'action',
}) => MaterialApp(
  home: DefaultAssetBundle(
    bundle: bundle,
    child: PoseHubCatalogImage(
      id: id,
      name: 'Action',
      video: _file('video', id: id),
      cover: _file('cover', id: id),
      thumbnailFile: _file('thumbnail', id: id),
      thumbnail: thumbnail,
      cache: cache,
    ),
  ),
);

void main() {
  testWidgets(
    'matching video identity uses bundled standing without requesting media',
    (tester) async {
      final cache = _Cache();
      await tester.pumpWidget(_card(_Bundle(matches: true), cache));
      await tester.pumpAndSettle();
      expect(cache.calls, isEmpty);
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<AssetImage>());
      expect((image.image as AssetImage).package, 'ugk_trainer');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'changed video requests cover and keeps old standing while waiting',
    (tester) async {
      final cache = _Cache();
      await tester.pumpWidget(_card(_Bundle(), cache));
      await tester.pumpAndSettle();
      expect(cache.calls.single.path, _file('cover').path);
      expect(tester.widget<Image>(find.byType(Image)).image, isA<AssetImage>());
      cache.completion.completeError(
        const CatalogMediaException('sha256', 'Bad checksum'),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Image>(find.byType(Image)).image, isA<AssetImage>());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an unbundled list action requests thumbnail and offline failure stays quiet',
    (tester) async {
      final cache = _Cache();
      await tester.pumpWidget(
        _card(
          _Bundle(hasImage: false, hasRecord: false),
          cache,
          thumbnail: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(cache.calls.single.path, _file('thumbnail').path);
      cache.completion.completeError(const SocketException('offline'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(PoseHubCatalogImage),
          matching: find.byType(ColoredBox),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('verified replacement is displayed only after it has decoded', (
    tester,
  ) async {
    late _Cache cache;
    await tester.runAsync(() async {
      // Completion must be scheduled on the real zone we await below.
      cache = _Cache();
    });
    await tester.pumpWidget(_card(_Bundle(), cache));
    await tester.pump();
    late Directory temporary;
    late File file;
    late FileImage provider;
    await tester.runAsync(() async {
      temporary = await Directory.systemTemp.createTemp('posehub-card-test-');
      // Use the same normalized file path as the production Image.file helper.
      file = File.fromUri(File('${temporary.path}/cover.webp').uri);
      await file.writeAsBytes(_pixel);
      final target = cache.calls.single;
      final bytes = await file.readAsBytes();
      expect(bytes.length, target.bytes);
      expect(sha256.convert(bytes).toString(), target.sha256);

      final cached = cache.completion.future;
      cache.completion.complete(file.uri);
      expect(await cached.timeout(const Duration(seconds: 10)), file.uri);
      provider = FileImage(File.fromUri(file.uri));
      Object? decodeError;
      await precacheImage(
        provider,
        tester.element(find.byType(PoseHubCatalogImage)),
        onError: (error, _) => decodeError = error,
      ).timeout(const Duration(seconds: 10));
      expect(decodeError, isNull);
    });
    await tester.pump();
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    final rendered = tester.widget<Image>(find.byType(Image));
    expect(rendered.image, isA<FileImage>());
    expect(rendered.image, provider);
    expect(rendered.key, ValueKey('action/${_file('cover').sha256}'));
    expect((rendered.image as FileImage).file.uri, file.uri);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => temporary.delete(recursive: true));
  });

  testWidgets(
    'late completion from a previous action never replaces the new fallback',
    (tester) async {
      final bundle = _Bundle();
      final previous = _Cache();
      final current = _Cache();
      await tester.pumpWidget(_card(bundle, previous));
      await tester.pumpAndSettle();
      await tester.pumpWidget(_card(bundle, current, id: 'next-action'));
      await tester.pumpAndSettle();
      previous.completion.complete(Uri.parse('file:///retired-cover.webp'));
      await tester.pumpAndSettle();
      expect(current.calls.single.path, contains('/next-action/'));
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Image && widget.image is FileImage,
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
