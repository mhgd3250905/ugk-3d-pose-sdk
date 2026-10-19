/// dart:io 实现（Flutter 移动端 / 桌面 / 命令行可用；Web 不可用，所以单独一个入口 `ugk_coach_io.dart`）。
library;

import 'dart:convert';
import 'dart:io';

import '../catalog/catalog_source.dart';
import '../usage/usage.dart';

/// 目录缓存到一个文件（写临时文件再 rename，避免写一半）。
class FileCatalogCache implements CatalogCache {
  FileCatalogCache(this.file);
  final File file;

  @override
  Future<CatalogPayload?> read() async {
    if (!await file.exists()) return null;
    final text = await file.readAsString();
    return CatalogPayload(text: text, origin: 'cache', sha256: sha256Hex(utf8.encode(text)));
  }

  @override
  Future<void> write(CatalogPayload payload) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(payload.text, flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }
}

/// 追加写 JSONL（一行一条记录），便于导出核算。
class JsonlUsageSink implements UsageSink {
  JsonlUsageSink(this.file);
  final File file;

  @override
  Future<void> record(UsageRecord r) async {
    await file.parent.create(recursive: true);
    await file.writeAsString('${jsonEncode(r.toJson())}\n', mode: FileMode.append, flush: true);
  }

  /// 读回全部记录（坏行跳过）。
  Future<List<UsageRecord>> readAll() async {
    if (!await file.exists()) return const [];
    final out = <UsageRecord>[];
    for (final line in await file.readAsLines()) {
      if (line.trim().isEmpty) continue;
      try {
        out.add(UsageRecord.fromJson((jsonDecode(line) as Map).cast<String, Object?>()));
      } on Object {
        // 跳过坏行。
      }
    }
    return out;
  }
}
