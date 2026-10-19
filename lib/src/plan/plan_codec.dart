/// TrainingPlan v1 的编解码。
///
/// - [decodeStrict]：模型输出用。结构问题（缺字段、类型错、枚举外的值）逐条记为 [PlanIssue]，
///   而不是悄悄补默认值；只对无歧义的小偏差做规范化（缺 id/source、`seconds`→`workSeconds`）。
/// - [decode]：已存计划用，宽容（与 SmartFit `TrainingPlan.fromJson` 同口径）。
library;

import 'dart:convert';

import '../catalog/catalog.dart';
import '../util/json.dart';
import 'plan_issue.dart';
import 'training_plan.dart';

class PlanDecodeResult {
  const PlanDecodeResult(this.plan, this.issues);
  final TrainingPlan? plan;
  final List<PlanIssue> issues;
  bool get ok => plan != null && !issues.any((i) => i.isError);
}

class PlanCodec {
  const PlanCodec();

  String encode(TrainingPlan p) => jsonEncode(p.toJson());

  /// 宽容解码（读已存计划）。结构坏到无法恢复时抛 [FormatException]。
  TrainingPlan decode(Object? json) {
    final r = decodeStrict(json is String ? jsonDecode(json) : json, lenient: true);
    if (r.plan == null) throw FormatException('无法解析计划：${r.issues.map((i) => i.message).join('；')}');
    return r.plan!;
  }

  /// [defaults] 补模型没写的 id / scene / level / targetMinutes（来自本轮条件）。
  PlanDecodeResult decodeStrict(
    Object? json, {
    String path = 'plan',
    bool lenient = false,
    String? id,
    String source = 'ai',
    String? scene,
    int? level,
    int? minutes,
  }) {
    final issues = <PlanIssue>[];
    void bad(String p, String msg) => issues.add(PlanIssue(IssueCodes.schema, msg, path: p));
    if (json is! Map) {
      bad(path, 'plan 必须是 JSON 对象');
      return PlanDecodeResult(null, issues);
    }
    final j = asMap(json);

    String str(String k, {String? or, bool required = true}) {
      final v = j[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
      if (v != null && v is! String) bad('$path.$k', '$k 应为字符串');
      if (or != null) return or;
      if (required && !lenient) bad('$path.$k', '缺少 $k');
      return '';
    }

    int integer(Map<String, Object?> m, String p, String k, {int? or, bool required = true}) {
      final v = m[k];
      if (v is num && v == v.roundToDouble()) return v.toInt();
      if (v != null) {
        bad('$p.$k', '$k 应为整数，实际 ${jsonEncode(v)}');
      } else if (or == null && required && !lenient) {
        bad('$p.$k', '缺少 $k');
      }
      return or ?? 0;
    }

    final sv = integer(j, path, 'schemaVersion', or: planSchemaVersion);
    final blocksRaw = j['blocks'];
    if (blocksRaw is! List) {
      bad('$path.blocks', 'blocks 必须是数组');
      return PlanDecodeResult(null, issues);
    }
    final blocks = <PlanBlock>[];
    for (var bi = 0; bi < blocksRaw.length; bi++) {
      final bp = '$path.blocks[$bi]';
      final braw = blocksRaw[bi];
      if (braw is! Map) {
        bad(bp, '训练块必须是对象');
        continue;
      }
      final b = asMap(braw);
      final type = BlockType.tryParse(b['type']);
      if (type == null) bad('$bp.type', 'type 必须是 warmup / main / circuit / cooldown，实际 ${jsonEncode(b['type'])}');
      final itemsRaw = b['items'];
      if (itemsRaw is! List) bad('$bp.items', 'items 必须是数组');
      final items = <PlanItem>[];
      for (var ii = 0; ii < (itemsRaw is List ? itemsRaw.length : 0); ii++) {
        final ip = '$bp.items[$ii]';
        final iraw = (itemsRaw! as List)[ii];
        if (iraw is! Map) {
          bad(ip, '动作项必须是对象');
          continue;
        }
        final it = asMap(iraw);
        // 规范化：模型常把目录里的 seconds 抄过来。
        if (!it.containsKey('workSeconds') && it['seconds'] is num) it['workSeconds'] = it['seconds'];
        final exId = it['exerciseId'];
        if (exId is! String || exId.isEmpty) bad('$ip.exerciseId', '缺少 exerciseId');
        final mode = switch (it['mode']) { 'reps' => DoseMode.reps, 'time' => DoseMode.time, _ => null };
        if (mode == null) bad('$ip.mode', 'mode 必须是 reps 或 time，实际 ${jsonEncode(it['mode'])}');
        final perSide = it['perSide'];
        if (perSide is! bool && !(lenient && perSide == null)) bad('$ip.perSide', 'perSide 必须是 true / false');
        final sets = integer(it, ip, 'sets', or: lenient ? 1 : null);
        int? reps, work;
        if (mode == DoseMode.reps) {
          reps = integer(it, ip, 'reps', or: lenient ? 10 : null);
        } else if (mode == DoseMode.time) {
          work = integer(it, ip, 'workSeconds', or: lenient ? 30 : null);
        }
        final rest = integer(it, ip, 'restSeconds', or: lenient ? 20 : null);
        if (exId is String && exId.isNotEmpty && mode != null) {
          items.add(PlanItem(
            exerciseId: exId,
            mode: mode,
            sets: sets,
            reps: reps,
            workSeconds: work,
            perSide: perSide == true,
            restSeconds: rest,
            note: asString(it['note']),
            replacedFrom: asString(it['replacedFrom']),
          ));
        }
      }
      if (type != null) {
        blocks.add(PlanBlock(
          id: asString(b['id']) ?? 'b${bi + 1}',
          name: asString(b['name']) ?? type.zh,
          type: type,
          rounds: integer(b, bp, 'rounds', or: 1),
          restBetweenRoundsSeconds: integer(b, bp, 'restBetweenRoundsSeconds', or: 0),
          items: items,
        ));
      }
    }

    final title = str('title', or: lenient ? '训练计划' : null);
    final goal = str('goal', or: lenient ? 'mixed' : null);
    final plan = TrainingPlan(
      schemaVersion: sv,
      id: asString(j['id']) ?? id ?? 'plan-${DateTime.now().millisecondsSinceEpoch}',
      source: asString(j['source']) ?? source,
      templateId: asString(j['templateId']),
      title: title,
      summary: asString(j['summary']) ?? '',
      goal: goal,
      scene: asString(j['scene']) ?? scene ?? 'home',
      equipment: asStringList(j['equipment']),
      level: asInt(j['level']) ?? level ?? 1,
      targetMinutes: asInt(j['targetMinutes']) ?? minutes ?? 10,
      blocks: blocks,
      avoid: asStringList(j['avoid']).toSet(),
      notes: asStringList(j['notes']),
      safetyNotes: asStringList(j['safetyNotes']),
    );
    return PlanDecodeResult(plan, issues);
  }
}
