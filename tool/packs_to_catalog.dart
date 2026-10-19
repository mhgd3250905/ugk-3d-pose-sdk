// 把 SmartFit drill-pack 目录（assets/packs）转成 pose-hub-catalog（统一目录落地前、或只带小包的 App 用）。
// 用法：dart run tool/packs_to_catalog.dart <packs 目录> <version> > catalog.json
import 'dart:convert';
import 'dart:io';

import 'package:ugk_coach/ugk_coach.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('用法：dart run tool/packs_to_catalog.dart <packs 目录> <version>');
    exit(64);
  }
  final dir = Directory(args[0]);
  final packs = <String, Object?>{
    for (final d in dir.listSync().whereType<Directory>())
      if (File('${d.path}/pack.json').existsSync())
        d.uri.pathSegments.where((s) => s.isNotEmpty).last: jsonDecode(File('${d.path}/pack.json').readAsStringSync()),
  };
  final c = const DrillPackAdapter().build(version: args[1], packs: packs);
  stderr.writeln('${c.length} 个动作${c.problems.isEmpty ? '' : '；问题：\n${c.problems.join('\n')}'}');
  stdout.writeln(const JsonEncoder.withIndent(' ').convert(c.toJson()));
}
