import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_coach/ugk_coach_io.dart';

import 'support.dart';

String withVersion(String v, {String? drop}) {
  final raw = jsonDecode(catalogText()) as Map<String, Object?>;
  raw['version'] = v;
  if (drop != null) (raw['drills']! as List).removeWhere((d) => (d as Map)['id'] == drop);
  return jsonEncode(raw);
}

void main() {
  final manifestUrl = Uri.parse('https://cdn.example.com/catalog/manifest.json');
  final bundled = BundledCatalogSource(() async => catalogText());

  /// 远端：清单 + 目录。可篡改 sha / 版本 / 目录内容。
  http.Client remote({required String catalog, String? sha, String? version, int? bytes, int status = 200}) {
    final body = utf8.encode(catalog);
    return MockClient((req) async {
      if (status != 200) return http.Response('down', status);
      if (req.url.path.endsWith('manifest.json')) {
        return http.Response(jsonEncode({
          'format': 'pose-hub-catalog-manifest',
          'formatVersion': 1,
          'version': version ?? (jsonDecode(catalog) as Map)['version'],
          'url': 'catalog-next.json',
          'sha256': sha ?? sha256Hex(body),
          'bytes': ?bytes,
        }), 200);
      }
      expect(req.url.toString(), 'https://cdn.example.com/catalog/catalog-next.json', reason: 'url 相对清单解析');
      return http.Response.bytes(body, 200);
    });
  }

  test('load：只有内置', () async {
    final repo = CatalogRepository(bundled: bundled);
    expect((await repo.load()).version, '0.1.0');
    expect(repo.origin, 'bundled');
  });

  test('refresh：新版本下载、校验、写缓存、切换并通知', () async {
    final cache = MemoryCatalogCache();
    final next = withVersion('0.2.0', drop: 's-butterfly');
    final repo = CatalogRepository(bundled: bundled, cache: cache, remote: RemoteCatalogSource(manifestUrl: manifestUrl, httpClient: remote(catalog: next)));
    await repo.load();
    final updates = <String>[];
    repo.updates.listen((c) => updates.add(c.version));
    final r = await repo.refresh();
    expect(r.status, CatalogRefreshStatus.updated);
    expect(repo.current.version, '0.2.0');
    expect(repo.current.contains('s-butterfly'), isFalse);
    expect((await cache.read())!.parse().version, '0.2.0');
    await Future<void>.delayed(Duration.zero);
    expect(updates, ['0.2.0']);

    // 下次启动：缓存比内置新，直接用缓存。
    final again = CatalogRepository(bundled: bundled, cache: cache);
    await again.load();
    expect(again.current.version, '0.2.0');
    expect(again.origin, 'cache');
  });

  test('sha256 不符：拒绝，不切换、不写缓存', () async {
    final cache = MemoryCatalogCache();
    final repo = CatalogRepository(
      bundled: bundled,
      cache: cache,
      remote: RemoteCatalogSource(manifestUrl: manifestUrl, httpClient: remote(catalog: withVersion('0.2.0'), sha: 'ab' * 32)),
    );
    await repo.load();
    final r = await repo.refresh();
    expect(r.status, CatalogRefreshStatus.rejected);
    expect(r.error, isA<CatalogIntegrityException>());
    expect(repo.current.version, '0.1.0');
    expect(await cache.read(), isNull);
  });

  test('大小不符：拒绝', () async {
    final repo = CatalogRepository(
      bundled: bundled,
      remote: RemoteCatalogSource(manifestUrl: manifestUrl, httpClient: remote(catalog: withVersion('0.2.0'), bytes: 10)),
    );
    await repo.load();
    expect((await repo.refresh()).status, CatalogRefreshStatus.rejected);
  });

  test('清单版本与目录内版本不符：拒绝', () async {
    final repo = CatalogRepository(
      bundled: bundled,
      remote: RemoteCatalogSource(manifestUrl: manifestUrl, httpClient: remote(catalog: withVersion('0.2.0'), version: '0.3.0')),
    );
    await repo.load();
    final r = await repo.refresh();
    expect(r.status, CatalogRefreshStatus.rejected);
    expect('${r.error}', contains('版本不符'));
  });

  test('远端不比当前新：upToDate，不下载目录', () async {
    var downloads = 0;
    final client = MockClient((req) async {
      if (req.url.path.endsWith('manifest.json')) {
        return http.Response(jsonEncode({'format': 'pose-hub-catalog-manifest', 'version': '0.1.0', 'url': 'c.json', 'sha256': 'x'}), 200);
      }
      downloads++;
      return http.Response('', 404);
    });
    final repo = CatalogRepository(bundled: bundled, remote: RemoteCatalogSource(manifestUrl: manifestUrl, httpClient: client));
    await repo.load();
    expect((await repo.refresh()).status, CatalogRefreshStatus.upToDate);
    expect(downloads, 0);
  });

  test('网络失败：failed，保持原目录', () async {
    final repo = CatalogRepository(
      bundled: bundled,
      remote: RemoteCatalogSource(manifestUrl: manifestUrl, httpClient: MockClient((_) => throw http.ClientException('offline'))),
    );
    await repo.load();
    expect((await repo.refresh()).status, CatalogRefreshStatus.failed);
    expect(repo.current.version, '0.1.0');
  });

  test('没配远端：noRemote', () async {
    final repo = CatalogRepository(bundled: bundled);
    await repo.load();
    expect((await repo.refresh()).status, CatalogRefreshStatus.noRemote);
  });

  test('缓存损坏：丢弃并回到内置', () async {
    final cache = MemoryCatalogCache();
    await cache.write(const CatalogPayload(text: '{坏的', origin: 'cache'));
    final repo = CatalogRepository(bundled: bundled, cache: cache);
    await repo.load();
    expect(repo.origin, 'bundled');
    expect(await cache.read(), isNull);
  });

  test('缓存比内置旧（App 升级带了新目录）：用内置', () async {
    final cache = MemoryCatalogCache();
    await cache.write(CatalogPayload(text: withVersion('0.0.9'), origin: 'cache'));
    final repo = CatalogRepository(bundled: bundled, cache: cache);
    await repo.load();
    expect(repo.current.version, '0.1.0');
  });

  test('FileCatalogCache 读写', () async {
    final dir = await Directory.systemTemp.createTemp('ugk');
    final cache = FileCatalogCache(File('${dir.path}/sub/catalog.json'));
    expect(await cache.read(), isNull);
    await cache.write(CatalogPayload(text: withVersion('0.5.0'), origin: 'remote'));
    expect((await cache.read())!.parse().version, '0.5.0');
    await cache.clear();
    expect(await cache.read(), isNull);
    await dir.delete(recursive: true);
  });

  test('compareVersions', () {
    expect(compareVersions('0.10.0', '0.9.9'), 1);
    expect(compareVersions('2026.10.19-2', '2026.10.19-1'), 1);
    expect(compareVersions('1.0.0', '1.0.0'), 0);
    expect(compareVersions('1.0', '1.0.1'), -1);
  });
}
