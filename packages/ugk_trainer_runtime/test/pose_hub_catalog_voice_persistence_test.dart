import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';

class _Http implements PoseHubCatalogHttpClient {
  _Http(this.bytesByPath);

  final Map<String, List<int>> bytesByPath;
  final requested = <String>[];

  @override
  Future<PoseHubCatalogHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    int maxBytes = 64 * 1024 * 1024,
  }) async {
    final path = uri.pathSegments.skip(2).join('/');
    requested.add(path);
    final bytes = bytesByPath[path];
    return PoseHubCatalogHttpResponse(
      bytes == null ? HttpStatus.notFound : HttpStatus.ok,
      Uint8List.fromList(bytes ?? const []),
    );
  }
}

Map<String, Object?> _clip(
  String path,
  List<int> data, {
  String idField = 'clipId',
  String id = 'name',
  int? declaredBytes,
}) => {
  idField: id,
  'language': 'zh',
  'path': path,
  'bytes': declaredBytes ?? data.length,
  'sha256': sha256.convert(data).toString(),
};

PoseHubAppTestCatalog _catalog(
  String version,
  List<Map<String, Object?>> clips, {
  List<Map<String, Object?>> common = const [],
}) {
  final raw =
      jsonDecode(
            File(
              'test/fixtures/pose_hub/r2-v1/catalog.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final actions = (raw['actions'] as List<Object?>)
      .cast<Map<String, dynamic>>();
  for (final action in actions) {
    action.remove('voice');
  }
  actions.first['voice'] = {'files': clips};
  raw['pack'] = version;
  raw['voiceCommon'] = {'format': 'pose-hub-voice-common@1', 'files': common};
  return PoseHubAppTestCatalog.fromJson(raw);
}

Future<LayeredVoiceSource> _open(
  PoseHubAppTestCatalog catalog,
  String support,
) async =>
    await withPoseHubCatalogVoice(
          ManifestVoiceSource.empty,
          catalog: catalog,
          assetRootDirectory: support,
        )
        as LayeredVoiceSource;

void main() {
  late Directory root;
  late String support;
  const shared = [1, 2];
  const retired = [3, 4];
  const changed = [5, 6];
  const common = [7, 8];
  const oldName = 'voice/old/zh/name.m4a';
  const oldCue = 'voice/old/zh/cue.m4a';
  const newName = 'voice/new/zh/name.m4a';
  const newCue = 'voice/new/zh/cue.m4a';
  const commonAlias = 'voice/common/zh/alias.m4a';
  const commonOnly = 'voice/common/zh/alone.m4a';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('posehub_voice_');
    support = '${root.path}/support';
    addTearDown(() => root.delete(recursive: true));
  });

  test(
    'upgrade and player restart reuse verified voice objects by SHA',
    () async {
      final old = _catalog('r2-v16', [
        _clip(oldName, shared),
        _clip(oldCue, retired, id: 'primaryCue'),
      ]);
      final first = _Http({oldName: shared, oldCue: retired});
      await preparePoseHubCatalogVoice(
        old,
        assetRootDirectory: support,
        http: first,
      );
      expect(first.requested, unorderedEquals([oldName, oldCue]));
      final playing = await _open(old, support);
      final oldClip = playing.catalog.allClips.firstWhere(
        (clip) => clip.path == oldCue,
      );
      final oldFile = File(playing.cache.path(oldClip));
      expect(await oldFile.readAsBytes(), retired);

      final next = _catalog(
        'r2-v18',
        [_clip(newName, shared), _clip(newCue, changed, id: 'primaryCue')],
        common: [
          _clip(commonAlias, changed, idField: 'key', id: 'alias'),
          _clip(commonOnly, common, idField: 'key', id: 'alone'),
        ],
      );
      final upgrade = _Http({
        newCue: changed,
        commonAlias: changed,
        commonOnly: common,
      });
      await preparePoseHubCatalogVoice(
        next,
        assetRootDirectory: support,
        http: upgrade,
      );
      expect(upgrade.requested, hasLength(2));
      expect(upgrade.requested, contains(commonOnly));
      expect(upgrade.requested, isNot(contains(newName)));
      expect(
        upgrade.requested.where(
          (path) => path == newCue || path == commonAlias,
        ),
        hasLength(1),
      );
      expect(await oldFile.exists(), isTrue);

      final orphanSha = sha256.convert([9, 10]).toString();
      final orphan = File(
        '$support/ugk_catalog_voice/catalog-voice/${orphanSha.substring(0, 2)}/$orphanSha.m4a',
      );
      await orphan.parent.create(recursive: true);
      await orphan.writeAsBytes([9, 10]);
      await prunePoseHubCatalogVoice([next], assetRootDirectory: support);
      expect(await orphan.exists(), isFalse);
      expect(await File(playing.cache.path(oldClip)).readAsBytes(), retired);

      final systemCache = await Directory('${root.path}/cache').create();
      await systemCache.delete();
      final offline = _Http({});
      await preparePoseHubCatalogVoice(
        next,
        assetRootDirectory: support,
        http: offline,
      );
      expect(offline.requested, isEmpty);
      final afterStart = await _open(next, support);
      for (final clip in afterStart.catalog.allClips) {
        expect(await afterStart.cache.ensure(clip), isTrue);
        expect(await File(afterStart.cache.path(clip)).exists(), isTrue);
      }
    },
  );

  test('invalid next voice size leaves verified old bytes in place', () async {
    final old = _catalog('r2-v16', [_clip(oldName, shared)]);
    await preparePoseHubCatalogVoice(
      old,
      assetRootDirectory: support,
      http: _Http({oldName: shared}),
    );
    final layer = await _open(old, support);
    final oldFile = File(layer.cache.path(layer.catalog.allClips.single));

    final next = _catalog('r2-v18', [
      _clip(newName, shared, declaredBytes: shared.length + 1),
    ]);
    final offline = _Http({});
    await expectLater(
      preparePoseHubCatalogVoice(
        next,
        assetRootDirectory: support,
        http: offline,
      ),
      throwsStateError,
    );
    expect(offline.requested, isEmpty);
    expect(await oldFile.readAsBytes(), shared);
  });
}
