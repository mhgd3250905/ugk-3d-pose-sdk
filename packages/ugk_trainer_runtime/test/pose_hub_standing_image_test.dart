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

Map<PoseHubMediaTheme, PoseHubPackMediaFiles> _themes(
  Set<PoseHubMediaTheme> enabled,
) => PoseHubPackMediaFiles.themesFromJson({
  for (final theme in enabled)
    theme.name: {
      'skin': switch (theme) {
        PoseHubMediaTheme.light => 'tech-white',
        PoseHubMediaTheme.dark => 'neon-night',
      },
      for (final kind in ['video', 'cover', 'thumbnail'])
        kind: _file(kind, revision: theme.name).raw,
    },
});

class _Bundle extends CachingAssetBundle {
  _Bundle({
    this.matches = false,
    this.hasImage = true,
    this.hasRecord = true,
    this.matchingThemes = const {},
  });
  final bool matches;
  final bool hasImage;
  final bool hasRecord;
  final Set<PoseHubMediaTheme> matchingThemes;
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
                    if (matchingThemes.isNotEmpty)
                      'themes': {
                        for (final theme in matchingThemes)
                          theme.name: {
                            'videoPath': _file(
                              'video',
                              revision: theme.name,
                            ).path,
                            'videoSha256': 'a' * 64,
                          },
                      },
                  },
              },
            }),
          ),
        ),
      );
    }
    if ((key.endsWith('/action.webp') ||
            matchingThemes.any(
              (theme) => key.endsWith('/action.${theme.name}.webp'),
            )) &&
        hasImage) {
      return ByteData.sublistView(_pixel);
    }
    throw FlutterError('No fixture asset: $key');
  }
}

class _Cache extends PoseHubImageCache {
  _Cache({this.load});

  final Future<Uri> Function(PoseHubPackFile)? load;
  final calls = <PoseHubPackFile>[];
  final completion = Completer<Uri>();
  @override
  Future<Uri> ensureFile(PoseHubPackFile file, {Uri? mediaBaseUri}) {
    calls.add(file);
    return load?.call(file) ?? completion.future;
  }
}

Widget _card(
  _Bundle bundle,
  _Cache cache, {
  bool thumbnail = false,
  bool preferCatalogArtwork = false,
  PoseHubPackFile? thumbnailFile,
  String id = 'action',
  ThemeMode themeMode = ThemeMode.light,
  Map<PoseHubMediaTheme, PoseHubPackMediaFiles> themedMedia = const {},
}) => MaterialApp(
  theme: ThemeData.light(),
  darkTheme: ThemeData.dark(),
  themeMode: themeMode,
  themeAnimationDuration: Duration.zero,
  home: DefaultAssetBundle(
    bundle: bundle,
    child: PoseHubCatalogImage(
      id: id,
      name: 'Action',
      video: _file('video', id: id),
      cover: _file('cover', id: id),
      thumbnailFile: thumbnailFile ?? _file('thumbnail', id: id),
      thumbnail: thumbnail,
      preferCatalogArtwork: preferCatalogArtwork,
      themedMedia: themedMedia,
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

  testWidgets(
    'brightness switch selects the new thumbnail and missing themes use the base video',
    (tester) async {
      final bundle = _Bundle(matches: true);
      final cache = _Cache();
      Future<void> show(ThemeMode mode, Set<PoseHubMediaTheme> variants) async {
        await tester.pumpWidget(
          _card(
            bundle,
            cache,
            thumbnail: true,
            themeMode: mode,
            themedMedia: _themes(variants),
          ),
        );
        await tester.pump();
      }

      await show(ThemeMode.light, PoseHubMediaTheme.values.toSet());
      expect(
        cache.calls.single.path,
        _file('thumbnail', revision: 'light').path,
      );
      await show(ThemeMode.dark, PoseHubMediaTheme.values.toSet());
      expect(cache.calls.map((file) => file.path), [
        _file('thumbnail', revision: 'light').path,
        _file('thumbnail', revision: 'dark').path,
      ]);
      await show(ThemeMode.dark, {PoseHubMediaTheme.light});
      expect(cache.calls, hasLength(2));
      expect(find.byKey(const ValueKey('standing-action')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'catalogue-first thumbnail changes SHA even when its path and video stay the same',
    (tester) async {
      final bundle = _Bundle(matches: true);
      final cache = _Cache();
      final original = _file('thumbnail');
      final revised = PoseHubPackFile.fromJson({
        ...original.raw,
        'sha256': 'c' * 64,
      });
      for (final thumbnail in [original, revised]) {
        await tester.pumpWidget(
          _card(
            bundle,
            cache,
            thumbnail: true,
            preferCatalogArtwork: true,
            thumbnailFile: thumbnail,
          ),
        );
        await tester.pump();
      }
      expect(cache.calls.map((file) => (file.path, file.sha256)), [
        (original.path, original.sha256),
        (revised.path, revised.sha256),
      ]);
      expect(find.byKey(const ValueKey('standing-action')), findsOneWidget);
    },
  );

  testWidgets(
    'catalogue-first thumbnail tries themed then ordinary before bundled artwork',
    (tester) async {
      final cache = _Cache(
        load: (_) async => throw const CatalogMediaException('sha256', 'bad'),
      );
      await tester.pumpWidget(
        _card(
          _Bundle(matches: true),
          cache,
          thumbnail: true,
          preferCatalogArtwork: true,
          themeMode: ThemeMode.dark,
          themedMedia: _themes({PoseHubMediaTheme.dark}),
        ),
      );
      await tester.pumpAndSettle();
      expect(cache.calls.map((file) => file.path), [
        _file('thumbnail', revision: 'dark').path,
        _file('thumbnail').path,
      ]);
      expect(find.byKey(const ValueKey('standing-action')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('matching bundled theme frames render with zero downloads', (
    tester,
  ) async {
    final bundle = _Bundle(matchingThemes: PoseHubMediaTheme.values.toSet());
    final cache = _Cache();
    final variants = _themes(PoseHubMediaTheme.values.toSet());
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      await tester.pumpWidget(
        _card(bundle, cache, themeMode: mode, themedMedia: variants),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('standing-action.${mode.name}')),
        findsOneWidget,
      );
      expect(cache.calls, isEmpty);
      expect(tester.takeException(), isNull);
    }
  });

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
