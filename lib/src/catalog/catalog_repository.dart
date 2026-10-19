/// 目录仓库：启动时取「缓存 vs 内置」里较新的一份；[refresh] 检查远端并热更新。
/// 助理每次 ask 读 [current]，所以提示词、校验随目录版本自动走。
library;

import 'dart:async';

import '../util/version.dart';
import 'catalog.dart';
import 'catalog_source.dart';

enum CatalogRefreshStatus {
  /// 已是最新。
  upToDate,

  /// 下载、校验通过并已切换。
  updated,

  /// 没配远端。
  noRemote,

  /// 校验失败（sha / 大小 / 版本 / 格式），保持原目录。
  rejected,

  /// 网络等错误，保持原目录。
  failed,
}

class CatalogRefreshResult {
  const CatalogRefreshResult(this.status, {this.from, this.to, this.error});
  final CatalogRefreshStatus status;
  final String? from;
  final String? to;
  final Object? error;
  @override
  String toString() => 'CatalogRefreshResult(${status.name} $from → $to${error == null ? '' : ', $error'})';
}

class CatalogRepository {
  CatalogRepository({required this.bundled, this.remote, CatalogCache? cache}) : cache = cache ?? MemoryCatalogCache();

  final BundledCatalogSource bundled;
  final RemoteCatalogSource? remote;
  final CatalogCache cache;

  Catalog? _current;
  String _origin = 'none';
  final _updates = StreamController<Catalog>.broadcast();

  /// 当前目录；须先 [load]。
  Catalog get current => _current ?? (throw StateError('CatalogRepository.load() 尚未完成'));
  bool get isLoaded => _current != null;

  /// bundled / cache / remote
  String get origin => _origin;

  /// 每次切换目录时发出新目录（UI 刷新、已存计划复核）。
  Stream<Catalog> get updates => _updates.stream;

  /// 读内置 + 缓存，取版本较新且能解析的一份。缓存坏了就丢掉。
  Future<Catalog> load() async {
    final b = (await bundled.load()).parse();
    var pick = b;
    var origin = 'bundled';
    try {
      final cached = await cache.read();
      if (cached != null) {
        final c = cached.parse();
        if (compareVersions(c.version, b.version) > 0) {
          pick = c;
          origin = 'cache';
        }
      }
    } on Object {
      await cache.clear();
    }
    _set(pick, origin);
    return pick;
  }

  /// 检查远端：清单版本比当前新才下载；校验全过才写缓存并切换。
  Future<CatalogRefreshResult> refresh() async {
    final r = remote;
    if (r == null) return const CatalogRefreshResult(CatalogRefreshStatus.noRemote);
    final from = _current?.version;
    try {
      final m = await r.fetchManifest();
      if (m.formatVersion != supportedCatalogFormatVersion) {
        return CatalogRefreshResult(CatalogRefreshStatus.rejected, from: from, to: m.version,
            error: CatalogFormatException('远端 formatVersion ${m.formatVersion} 不受支持'));
      }
      if (from != null && compareVersions(m.version, from) <= 0) {
        return CatalogRefreshResult(CatalogRefreshStatus.upToDate, from: from, to: m.version);
      }
      final payload = await r.download(m);
      final c = payload.parse();
      await cache.write(payload);
      _set(c, 'remote');
      return CatalogRefreshResult(CatalogRefreshStatus.updated, from: from, to: c.version);
    } on CatalogIntegrityException catch (e) {
      return CatalogRefreshResult(CatalogRefreshStatus.rejected, from: from, error: e);
    } on CatalogFormatException catch (e) {
      return CatalogRefreshResult(CatalogRefreshStatus.rejected, from: from, error: e);
    } on Object catch (e) {
      return CatalogRefreshResult(CatalogRefreshStatus.failed, from: from, error: e);
    }
  }

  /// 测试 / 手动注入（例如 App 从别处拿到并已校验的目录）。
  void replace(Catalog c, {String origin = 'manual'}) => _set(c, origin);

  void _set(Catalog c, String origin) {
    final changed = _current?.version != c.version || _origin != origin;
    _current = c;
    _origin = origin;
    if (changed) _updates.add(c);
  }

  Future<void> dispose() => _updates.close();
}
