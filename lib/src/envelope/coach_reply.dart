/// 助理回复信封：模型每轮只输出一个 JSON 对象。
///
/// ```json
/// {"kind": "plan",  "text": "给你排了一套 10 分钟的…", "plan": { TrainingPlan v1 }}
/// {"kind": "ask",   "text": "在家还是办公室？", "options": ["在家", "办公室"]}
/// {"kind": "reply", "text": "这个问题建议咨询医生…"}
/// ```
library;

import '../plan/plan_codec.dart';
import '../plan/plan_issue.dart';
import '../plan/training_plan.dart';
import '../util/json.dart';
import 'json_extract.dart';

enum ReplyKind { reply, ask, plan }

class CoachReply {
  const CoachReply({required this.kind, required this.text, this.options = const [], this.plan});
  const CoachReply.text(this.text) : kind = ReplyKind.reply, options = const [], plan = null;
  const CoachReply.ask(this.text, [this.options = const []]) : kind = ReplyKind.ask, plan = null;
  const CoachReply.plan(this.text, TrainingPlan this.plan) : kind = ReplyKind.plan, options = const [];

  final ReplyKind kind;

  /// 给用户看的一两句话（字幕；语音只用目录内的台词）。
  final String text;

  /// 追问时的快捷选项（≤ 4 个）。
  final List<String> options;
  final TrainingPlan? plan;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'text': text,
    if (options.isNotEmpty) 'options': options,
    if (plan != null) 'plan': plan!.toJson(),
  };

  factory CoachReply.fromJson(Map<String, Object?> j) {
    final kind = ReplyKind.values.where((k) => k.name == j['kind']).firstOrNull ?? ReplyKind.reply;
    return CoachReply(
      kind: kind,
      text: asString(j['text']) ?? '',
      options: asStringList(j['options']),
      plan: j['plan'] == null ? null : const PlanCodec().decode(j['plan']),
    );
  }
}

class EnvelopeParseResult {
  const EnvelopeParseResult({this.reply, this.issues = const [], this.repairs = const []});
  final CoachReply? reply;
  final List<PlanIssue> issues;
  final List<String> repairs;
  bool get ok => reply != null && !issues.any((i) => i.isError);
}

class EnvelopeParser {
  const EnvelopeParser({this.maxOptions = 4, this.maxTextChars = 400, this.codec = const PlanCodec()});
  final int maxOptions;
  final int maxTextChars;
  final PlanCodec codec;

  /// [planDefaults] 交给 [PlanCodec.decodeStrict] 补 id / scene 等。
  EnvelopeParseResult parse(
    String content, {
    String? planId,
    String? scene,
    int? level,
    int? minutes,
  }) {
    final x = extractJsonObject(content);
    if (!x.ok) {
      return EnvelopeParseResult(issues: [PlanIssue(IssueCodes.notJson, x.error ?? '不是 JSON')], repairs: x.repairs);
    }
    var j = x.value!;
    final repairs = [...x.repairs];
    // 宽容：直接给了计划本体（有 blocks 没 kind）。
    if (!j.containsKey('kind') && j['blocks'] is List) {
      j = {'kind': 'plan', 'text': asString(j['summary']) ?? asString(j['title']) ?? '', 'plan': j};
      repairs.add('bare_plan');
    }
    final issues = <PlanIssue>[];
    void bad(String path, String msg) => issues.add(PlanIssue(IssueCodes.envelope, msg, path: path));

    final kind = ReplyKind.values.where((k) => k.name == j['kind']).firstOrNull;
    if (kind == null) bad('kind', 'kind 必须是 reply / ask / plan，实际 ${j['kind']}');
    final text = j['text'];
    if (text is! String || text.trim().isEmpty) bad('text', 'text 必须是非空字符串');
    if (text is String && text.length > maxTextChars) {
      issues.add(PlanIssue.warning(IssueCodes.envelope, 'text 超过 $maxTextChars 字', path: 'text'));
    }
    final options = j['options'];
    if (options != null && (options is! List || options.any((o) => o is! String))) {
      bad('options', 'options 必须是字符串数组');
    } else if (options is List && options.length > maxOptions) {
      bad('options', 'options 最多 $maxOptions 个');
    }

    TrainingPlan? plan;
    if (kind == ReplyKind.plan) {
      if (j['plan'] is! Map) {
        bad('plan', 'kind=plan 时必须带 plan 对象');
      } else {
        final r = codec.decodeStrict(j['plan'], id: planId, scene: scene, level: level, minutes: minutes);
        issues.addAll(r.issues);
        plan = r.plan;
      }
    } else if (j['plan'] != null) {
      issues.add(PlanIssue.warning(IssueCodes.envelope, 'kind=${kind?.name} 不应带 plan，已忽略', path: 'plan'));
    }
    if (kind == null || text is! String || text.trim().isEmpty) {
      return EnvelopeParseResult(issues: issues, repairs: repairs);
    }
    return EnvelopeParseResult(
      reply: CoachReply(
        kind: kind,
        text: text.trim(),
        options: options is List ? [for (final o in options) if (o is String) o] : const [],
        plan: plan,
      ),
      issues: issues,
      repairs: repairs,
    );
  }
}
