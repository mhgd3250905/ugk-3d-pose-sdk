// 把 lib/src/qa_v2/coach_qa_sop.md 生成成 Dart 常量（SDK 是纯 Dart，不读资源文件）。
// 改 SOP 只改 .md，然后：dart run tool/gen_qa_sop.dart
// test/qa_v2/coach_qa_agent_test.dart 会检查两边一致。
import 'dart:io';

void main() {
  final md = File('lib/src/qa_v2/coach_qa_sop.md').readAsStringSync();
  if (md.contains("'''")) throw StateError('SOP 里不能有三个连续单引号');
  File('lib/src/qa_v2/coach_qa_sop.g.dart').writeAsStringSync(
    '// 生成文件，不要手改。来源 coach_qa_sop.md，命令 dart run tool/gen_qa_sop.dart。\n'
    '// ignore_for_file: lines_longer_than_80_chars\n\n'
    "/// 给模型的问答 SOP（整份放进系统提示词）。\nconst String coachQaSop = r'''\n$md''';\n",
  );
}
