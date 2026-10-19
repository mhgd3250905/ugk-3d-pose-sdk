/// 会话历史（App 负责持久化：toJson / fromJson）与送给模型时的裁剪策略。
library;

import 'dart:convert';

import '../catalog/catalog.dart';
import '../envelope/coach_reply.dart';
import '../llm/llm_types.dart';
import '../plan/training_plan.dart';
import '../util/json.dart';

class CoachTurn {
  const CoachTurn.user(this.text, this.at) : reply = null;
  const CoachTurn.assistant(CoachReply this.reply, this.at) : text = '';

  final String text;
  final CoachReply? reply;
  final DateTime at;
  bool get isUser => reply == null;

  Map<String, Object?> toJson() => {
    'role': isUser ? 'user' : 'assistant',
    if (isUser) 'text': text,
    if (!isUser) 'reply': reply!.toJson(),
    'at': at.toIso8601String(),
  };

  factory CoachTurn.fromJson(Map<String, Object?> j) {
    final at = DateTime.tryParse(asString(j['at']) ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
    return j['role'] == 'assistant'
        ? CoachTurn.assistant(CoachReply.fromJson(asMap(j['reply'])), at)
        : CoachTurn.user(asString(j['text']) ?? '', at);
  }
}

class CoachConversation {
  CoachConversation([List<CoachTurn>? turns]) : turns = turns ?? [];
  final List<CoachTurn> turns;

  void addUser(String text, DateTime at) => turns.add(CoachTurn.user(text, at));
  void addAssistant(CoachReply r, DateTime at) => turns.add(CoachTurn.assistant(r, at));

  /// 最近一份计划（「再短一点」「换掉第 2 个」的对象）。
  TrainingPlan? get lastPlan {
    for (final t in turns.reversed) {
      if (t.reply?.plan != null) return t.reply!.plan;
    }
    return null;
  }

  void clear() => turns.clear();

  Map<String, Object?> toJson() => {'turns': [for (final t in turns) t.toJson()]};
  factory CoachConversation.fromJson(Map<String, Object?> j) =>
      CoachConversation([for (final t in asList(j['turns'])) CoachTurn.fromJson(asMap(t))]);
}

/// 送给模型的历史裁剪：最近 [maxTurns] 条、总字数 ≤ [maxChars]；
/// 只有最近一份计划保留完整 JSON，更早的计划压成一行摘要（id×剂量）。
class HistoryPolicy {
  const HistoryPolicy({this.maxTurns = 10, this.maxChars = 6000});
  final int maxTurns;
  final int maxChars;

  List<LlmMessage> select(CoachConversation c) {
    final out = <LlmMessage>[];
    var chars = 0;
    var planKept = false;
    for (final t in c.turns.reversed.take(maxTurns)) {
      final String content;
      if (t.isUser) {
        content = t.text;
      } else {
        final r = t.reply!;
        if (r.plan != null && !planKept) {
          content = jsonEncode(r.toJson());
          planKept = true;
        } else if (r.plan != null) {
          content = jsonEncode({'kind': 'plan', 'text': r.text, 'planSummary': summarize(r.plan!)});
        } else {
          content = jsonEncode(r.toJson());
        }
      }
      if (chars + content.length > maxChars && out.isNotEmpty) break;
      chars += content.length;
      out.add(t.isUser ? LlmMessage.user(content) : LlmMessage.assistant(content));
    }
    // 从用户消息开始，避免以孤立的助理消息开头。
    while (out.isNotEmpty && out.last.role == LlmRole.assistant) {
      out.removeLast();
    }
    return out.reversed.toList();
  }

  static String summarize(TrainingPlan p) {
    String dose(PlanItem i) =>
        '${i.exerciseId} ${i.sets}×${i.mode == DoseMode.reps ? '${i.reps}次' : '${i.workSeconds}秒'}';
    return '${p.title}（${p.targetMinutes}分钟）：${p.blocks.map((b) => '${b.type.name}[${b.items.map(dose).join(', ')}]').join(' ')}';
  }
}
