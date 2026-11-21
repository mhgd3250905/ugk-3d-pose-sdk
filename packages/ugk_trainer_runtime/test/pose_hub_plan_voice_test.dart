import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_trainer_runtime/src/pose_hub/pose_hub_catalog_io_types.dart';
import 'package:ugk_trainer_runtime/src/pose_hub/pose_hub_plan_voice.dart';

final _manifestUri = Uri.parse(
  'https://updates.example/plans/voice/manifest.json',
);

Map<String, Object> _file(String path, List<int> bytes) => {
  'path': path,
  'bytes': bytes.length,
  'sha256': sha256.convert(bytes).toString(),
};

PoseHubPlanVoiceManifest _manifest(
  List<Map<String, Object>> files, {
  Map<String, List<String>>? plans,
}) => PoseHubPlanVoiceManifest.fromBytes(
  utf8.encode(jsonEncode({'schema': 1, 'files': files, 'plans': ?plans})),
  manifestUri: _manifestUri,
);

final class _Http implements PoseHubCatalogHttpClient {
  final requests = <Uri>[];
  final responses = <Uri, List<int>>{};

  @override
  Future<PoseHubCatalogHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    int maxBytes = 64 * 1024 * 1024,
  }) async {
    requests.add(uri);
    final response = responses[uri];
    return response == null
        ? PoseHubCatalogHttpResponse(404, Uint8List(0))
        : PoseHubCatalogHttpResponse(200, Uint8List.fromList(response));
  }
}

void main() {
  test(
    'same-name plan audio with a different digest gets a fresh file',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'posehub-plan-voice-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final oldBytes = [10, 20, 30];
      final newBytes = [30, 20, 10];
      const path = 'zh/intro.m4a';
      final original = _manifest([_file(path, oldBytes)]);
      final updated = _manifest([_file(path, newBytes)]);
      final url = _manifestUri.resolve(path);
      final http = _Http()..responses[url] = oldBytes;
      final cache = PoseHubPlanVoiceCache.files(directory.path, http: http);

      final oldUri = await cache.ensureFile(original, path);
      expect(File.fromUri(oldUri!).readAsBytesSync(), oldBytes);

      http.responses[url] = newBytes;
      final newUri = await cache.ensureFile(updated, path);
      expect(File.fromUri(newUri!).readAsBytesSync(), newBytes);
      expect(newUri, isNot(oldUri));
      expect(http.requests, [url, url]);

      // A resumed session still resolves the original snapshot, not the newly
      // installed plan's clip under the same display path.
      final offline = _Http();
      final reopened = PoseHubPlanVoiceCache.files(
        directory.path,
        http: offline,
      );
      expect(await reopened.ensureFile(original, path), oldUri);
      expect(await reopened.ensureFile(updated, path), newUri);
      expect(offline.requests, isEmpty);
    },
  );

  test(
    'prefetch uses matching bundled bytes and only visits one plan',
    () async {
      const firstPath = 'zh/first.m4a';
      const nextPath = 'zh/next.m4a';
      final first = [1, 2, 3];
      final next = [4, 5, 6];
      final shared = _manifest(
        [_file(firstPath, first), _file(nextPath, next)],
        plans: {
          'first-plan': [firstPath],
          'next-plan': [nextPath],
        },
      );
      final wanted = shared.files[firstPath]!.sha256;
      final reads = <String>[];
      final http = _Http();
      final store = MemoryPoseHubCatalogStore();
      final cache = PoseHubPlanVoiceCache(
        store: store,
        uriOf: (name) => Uri.file('/plans/$name'),
        http: http,
        loadBundled: (digest) async {
          reads.add(digest);
          return digest == wanted ? first : null;
        },
      );

      final result = await cache.prefetchPlan(shared, 'first-plan');

      expect(result.keys, [firstPath]);
      expect(result[firstPath], isNotNull);
      expect(store.values.values.single, first);
      expect(reads, [wanted]);
      expect(http.requests, isEmpty);
    },
  );

  test('wrong bundled and network bytes never become playable', () async {
    const path = 'cooldown.m4a';
    final manifest = _manifest([
      _file(path, [1, 2, 3]),
    ]);
    final uri = _manifestUri.resolve(path);
    final http = _Http()..responses[uri] = [1, 2, 0];
    final store = MemoryPoseHubCatalogStore();
    final cache = PoseHubPlanVoiceCache(
      store: store,
      uriOf: (name) => Uri.file('/plans/$name'),
      http: http,
      loadBundled: (_) async => [0, 1, 2],
    );

    expect(await cache.prefetchFiles(manifest, [path]), {path: null});
    expect(http.requests, [uri]);
    expect(store.values, isEmpty);
  });

  test('a voice group cannot refer to an unlisted file', () {
    expect(
      () => _manifest(
        [],
        plans: {
          'first-plan': ['unlisted.m4a'],
        },
      ),
      throwsFormatException,
    );
  });
}
