/// 目录从哪来：内置资源 / 远端（带版本与 sha256 校验）/ 本地缓存。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import '../util/json.dart';
import 'catalog.dart';

String sha256Hex(List<int> bytes) => crypto.sha256.convert(bytes).toString();

/// 读取到的一份目录原文。
class CatalogPayload {
  const CatalogPayload({required this.text, required this.origin, this.sha256});
  final String text;

  /// bundled / remote / cache
  final String origin;
  final String? sha256;

  Catalog parse() => Catalog.fromJson(jsonDecode(text));
}

/// 内置目录（随安装包发布的那份）。Flutter：`BundledCatalogSource(() => rootBundle.loadString('assets/catalog.json'))`。
class BundledCatalogSource {
  const BundledCatalogSource(this.read);
  final Future<String> Function() read;

  Future<CatalogPayload> load() async => CatalogPayload(text: await read(), origin: 'bundled');
}

/// 远端清单 `manifest.json`：
/// ```json
/// {"format": "pose-hub-catalog-manifest", "formatVersion": 1,
///  "version": "0.2.0", "url": "catalog-0.2.0.json", "sha256": "…", "bytes": 123456}
/// ```
/// `url` 可相对清单地址。清单本身很小，每次检查只拉它；版本更新才下载目录。
class CatalogManifest {
  const CatalogManifest({required this.version, required this.url, required this.sha256, this.bytes, this.formatVersion = 1});
  final String version;
  final Uri url;
  final String sha256;
  final int? bytes;
  final int formatVersion;

  static const format = 'pose-hub-catalog-manifest';

  factory CatalogManifest.fromJson(Object? raw, Uri base) {
    final j = asMap(raw);
    if (j['format'] != format) throw CatalogFormatException('清单 format 应为 $format');
    final v = asString(j['version']), u = asString(j['url']), s = asString(j['sha256']);
    if (v == null || u == null || s == null) throw const CatalogFormatException('清单缺 version / url / sha256');
    return CatalogManifest(
      version: v,
      url: base.resolve(u),
      sha256: s.toLowerCase(),
      bytes: asInt(j['bytes']),
      formatVersion: asInt(j['catalogFormatVersion']) ?? asInt(j['formatVersion']) ?? 1,
    );
  }
}

class CatalogIntegrityException implements Exception {
  const CatalogIntegrityException(this.message);
  final String message;
  @override
  String toString() => 'CatalogIntegrityException: $message';
}

/// 远端目录。先拉清单比对版本，再下载目录并校验 sha256、版本号一致、可解析。
class RemoteCatalogSource {
  RemoteCatalogSource({required this.manifestUrl, http.Client? httpClient, this.timeout = const Duration(seconds: 20)})
    : _http = httpClient ?? http.Client();

  final Uri manifestUrl;
  final Duration timeout;
  final http.Client _http;

  Future<CatalogManifest> fetchManifest() async {
    final res = await _http.get(manifestUrl).timeout(timeout);
    if (res.statusCode != 200) throw http.ClientException('清单 HTTP ${res.statusCode}', manifestUrl);
    return CatalogManifest.fromJson(jsonDecode(utf8.decode(res.bodyBytes)), manifestUrl);
  }

  /// 下载并校验。不通过抛 [CatalogIntegrityException]（绝不把未校验的内容交出去）。
  Future<CatalogPayload> download(CatalogManifest m) async {
    final res = await _http.get(m.url).timeout(timeout);
    if (res.statusCode != 200) throw http.ClientException('目录 HTTP ${res.statusCode}', m.url);
    final bytes = res.bodyBytes;
    if (m.bytes != null && bytes.length != m.bytes) {
      throw CatalogIntegrityException('大小不符：清单 ${m.bytes}，实际 ${bytes.length}');
    }
    final sha = sha256Hex(bytes);
    if (sha != m.sha256) throw CatalogIntegrityException('sha256 不符：清单 ${m.sha256}，实际 $sha');
    final payload = CatalogPayload(text: utf8.decode(bytes), origin: 'remote', sha256: sha);
    final c = payload.parse();
    if (c.version != m.version) {
      throw CatalogIntegrityException('版本不符：清单 ${m.version}，目录内 ${c.version}');
    }
    return payload;
  }
}

/// 本地缓存（存最近一次校验通过的远端目录原文）。
abstract interface class CatalogCache {
  Future<CatalogPayload?> read();
  Future<void> write(CatalogPayload payload);
  Future<void> clear();
}

class MemoryCatalogCache implements CatalogCache {
  CatalogPayload? _p;
  @override
  Future<CatalogPayload?> read() async => _p;
  @override
  Future<void> write(CatalogPayload payload) async => _p = payload;
  @override
  Future<void> clear() async => _p = null;
}
