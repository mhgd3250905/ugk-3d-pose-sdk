/// Local skill file/list handlers. The caller emits events and owns cancellation.
library;

import 'dart:convert';

import 'agent_resilience.dart';
import 'agent_task.dart';
import 'skill_files.dart';

class SkillToolResult {
  const SkillToolResult(
    this.response, {
    this.failed = false,
    this.fresh = false,
    this.compressible,
  });
  final String response;
  final bool failed;
  final bool fresh;
  final CompressibleResult? compressible;
}

class SkillToolHandler {
  SkillToolHandler(this.files, this.readSet, this.reads, this.listed);
  final SkillFiles files;
  final Set<String> readSet;
  final List<String> reads;
  final Set<String> listed;

  bool blocked(String path, {required bool read, required bool hasTask}) =>
      hasTask &&
      (read
          ? path.startsWith('${SkillFiles.actionLibrary}/') &&
                path != '${SkillFiles.actionLibrary}/SKILL.md'
          : path == SkillFiles.actionLibrary ||
                path.startsWith('${SkillFiles.actionLibrary}/'));

  SkillToolResult execute(
    String callId,
    String path, {
    required bool read,
    required bool hasTask,
  }) {
    if (blocked(path, read: read, hasTask: hasTask)) {
      return SkillToolResult(
        jsonEncode(
          nodeError(
            'use_action_search',
            read ? 'path' : 'dir',
            read
                ? 'search_actions 或 get_action'
                : 'search_actions 或 get_action',
            path,
            read ? '通过动作工具读取按当前条件过滤的数据。' : '通过动作工具检索按当前条件过滤的数据。',
          ),
        ),
        failed: true,
      );
    }
    if (!read) {
      final children = files.ls(path);
      if (children == null) {
        return SkillToolResult(
          jsonEncode(
            nodeError('not_found', 'dir', '现有技能目录', path, '提供现有目录路径。'),
          ),
          failed: true,
        );
      }
      return SkillToolResult(
        children.join('\n'),
        fresh: listed.add(path),
        compressible: CompressibleResult(callId, '已列目录 $path（略，需要可再 ls）'),
      );
    }
    final text = files.read(path);
    if (text != null) {
      if (!readSet.add(path)) return SkillToolResult('（已读过 $path，见前文）');
      reads.add(path);
      return SkillToolResult(
        text,
        fresh: true,
        compressible: CompressibleResult(
          callId,
          '已读 $path（内容已省略以节省上下文，需要可再 read）',
          path: path,
        ),
      );
    }
    final children = files.ls(path);
    if (children == null) {
      return SkillToolResult(
        jsonEncode(
          nodeError(
            'not_found',
            'path',
            '现有技能文件或目录',
            path,
            '使用技能索引里的完整文件路径调用 read。',
          ),
        ),
        failed: true,
      );
    }
    return SkillToolResult(
      '$path 是目录，包含：\n${children.join('\n')}',
      fresh: listed.add(path),
      compressible: CompressibleResult(callId, '已列目录 $path（略，需要可再 ls）'),
    );
  }
}
