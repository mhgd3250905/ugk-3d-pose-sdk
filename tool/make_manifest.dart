// 为一份目录生成远端清单（manifest.json），发布时与目录文件一起上传。
// 用法：dart run tool/make_manifest.dart <catalog.json> [发布文件名，默认 catalog-<version>.json] > manifest.json
import 'dart:convert';
import 'dart:io';

import 'package:ugk_coach/ugk_coach.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法：dart run tool/make_manifest.dart <catalog.json> [发布文件名]');
    exit(64);
  }
  final bytes = File(args[0]).readAsBytesSync();
  final catalog = Catalog.fromJson(jsonDecode(utf8.decode(bytes))); // 解析失败直接报错，坏目录不发布
  if (catalog.problems.isNotEmpty) {
    stderr.writeln('目录有问题：\n${catalog.problems.join('\n')}');
    exit(1);
  }
  final manifest = {
    'format': CatalogManifest.format,
    'formatVersion': 1,
    'catalogFormatVersion': catalog.formatVersion,
    'version': catalog.version,
    'url': args.length > 1 ? args[1] : 'catalog-${catalog.version}.json',
    'sha256': sha256Hex(bytes),
    'bytes': bytes.length,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
  };
  stdout.writeln(const JsonEncoder.withIndent(' ').convert(manifest));
}
