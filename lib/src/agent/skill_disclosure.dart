/// Tracks full skill delivery in model-visible history, without inspecting prose.
library;

import 'dart:convert';

import '../llm/llm_types.dart';
import 'skill_files.dart';

enum SkillSource { read, startTask }

/// Internal metadata only; inherited toJson sends the ordinary tool protocol.
/// Replacing a result during compression also removes its full-text metadata.
class SkillDisclosureMessage extends LlmMessage {
  SkillDisclosureMessage(
    super.toolCallId,
    super.content, {
    this.fullRead = false,
    this.fullSkills = const {},
    this.requiredSkills = const {},
  }) : super.tool();

  final bool fullRead;
  final Set<String> fullSkills;
  final Set<String> requiredSkills;
}

class SkillDisclosures {
  SkillDisclosures._(this.sources);
  final Map<String, SkillSource> sources;

  static const readReference = '[已在前文 read 中]';
  static const startReference = '[已在 start_task 结果中]';
  static const unrelatedArchive = '[已归档：与当前任务无关的技能 read]';

  static Set<String> requiredFor(String type) => {
    '${SkillFiles.ask}/SKILL.md',
    '${SkillFiles.actionLibrary}/SKILL.md',
    if (type == 'recommend') '${SkillFiles.actionCoaching}/SKILL.md',
    if (type == 'plan') '${SkillFiles.planTraining}/SKILL.md',
  };

  static String? readPath(LlmToolCall call) {
    if (call.name != 'read') return null;
    try {
      final args = jsonDecode(call.arguments);
      return args is Map && args['path'] is String
          ? SkillFiles.normalize(args['path'] as String)
          : null;
    } on FormatException {
      return null;
    }
  }

  factory SkillDisclosures.fromMessages(Iterable<LlmMessage> messages) {
    final sources = <String, SkillSource>{};
    final pending = <LlmToolCall>[];
    for (final message in messages) {
      if (message.role == LlmRole.assistant) {
        pending
          ..clear()
          ..addAll(message.toolCalls);
      } else if (message.role == LlmRole.tool) {
        final index = pending.indexWhere((c) => c.id == message.toolCallId);
        if (index < 0) continue;
        final call = pending.removeAt(index);
        if (message is! SkillDisclosureMessage) continue;
        if (call.name == 'read' && message.fullRead) {
          final path = readPath(call);
          if (path != null && path.endsWith('/SKILL.md')) {
            sources[path] = SkillSource.read;
          }
        } else if (call.name == 'start_task') {
          for (final path in message.fullSkills) {
            sources[path] = SkillSource.startTask;
          }
        }
      }
    }
    return SkillDisclosures._(Map.unmodifiable(sources));
  }
}
