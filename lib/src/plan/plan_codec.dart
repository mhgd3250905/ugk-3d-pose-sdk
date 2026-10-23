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
import 'segment_rhythm.dart';
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
    // Legacy fields retain tolerant loading. New segments cannot be silently
    // dropped or repaired: doing so would change what constitutes a full set.
    if (r.plan == null || r.issues.any((i) => i.isError && (i.path?.contains('.segments') ?? false))) {
      throw FormatException('无法解析计划：${r.issues.map((i) => i.message).join('；')}');
    }
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
    void bad(String p, String msg, [String? expected, String? actual]) =>
        issues.add(PlanIssue(IssueCodes.schema, msg, path: p, expected: expected, actual: actual));
    String show(Object? v) => v == null ? '缺失' : jsonEncode(v);
    if (json is! Map) {
      bad(path, 'plan 必须是 JSON 对象');
      return PlanDecodeResult(null, issues);
    }
    final j = asMap(json);

    String str(String k, {String? or, bool required = true}) {
      final v = j[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
      if (v != null && v is! String) {
        bad('$path.$k', '$k 应为字符串', 'string', show(v));
      }
      if (or != null) return or;
      if (required && !lenient) bad('$path.$k', '缺少 $k', 'string', '缺失');
      return '';
    }

    int integer(Map<String, Object?> m, String p, String k, {int? or, bool required = true}) {
      final v = m[k];
      if (v is num && v.isFinite && v == v.roundToDouble()) return v.toInt();
      if (v != null) {
        bad('$p.$k', '$k 应为整数，实际 ${jsonEncode(v)}', 'integer', jsonEncode(v));
      } else if (or == null && required && !lenient) {
        bad('$p.$k', '缺少 $k', 'integer', '缺失');
      }
      return or ?? 0;
    }

    final sv = integer(j, path, 'schemaVersion', or: planSchemaVersion);
    final blocksRaw = j['blocks'];
    if (blocksRaw is! List) {
      bad('$path.blocks', 'blocks 必须是数组', 'array', show(blocksRaw));
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
      if (type == null) {
        bad(
          '$bp.type',
          'type 必须是 warmup / main / circuit / cooldown，实际 ${jsonEncode(b['type'])}',
          'warmup / main / circuit / cooldown',
          show(b['type']),
        );
      }
      final itemsRaw = b['items'];
      if (itemsRaw is! List) {
        bad('$bp.items', 'items 必须是数组', 'array', show(itemsRaw));
      }
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
        if (!it.containsKey('workSeconds') && it['seconds'] is num) {
          it['workSeconds'] = it['seconds'];
        }
        final exId = it['exerciseId'];
        if (exId is! String || exId.isEmpty) {
          bad('$ip.exerciseId', '缺少 exerciseId', '白名单动作 id', show(exId));
        }
        final mode = switch (it['mode']) {
          'reps' => DoseMode.reps,
          'time' => DoseMode.time,
          _ => null,
        };
        if (mode == null) {
          bad('$ip.mode', 'mode 必须是 reps 或 time，实际 ${jsonEncode(it['mode'])}', 'reps / time', show(it['mode']));
        }
        final perSide = it['perSide'];
        if (perSide is! bool && !(lenient && perSide == null)) {
          bad('$ip.perSide', 'perSide 必须是 true / false', 'boolean', show(perSide));
        }
        final sets = integer(it, ip, 'sets', or: lenient ? 1 : null);
        final segmentsRaw = it['segments'];
        final hasSegments = segmentsRaw is List && segmentsRaw.isNotEmpty;
        int? reps, work;
        if (mode == DoseMode.reps && (!hasSegments || it.containsKey('reps'))) {
          reps = integer(it, ip, 'reps', or: lenient ? 10 : null);
        } else if (mode == DoseMode.time && (!hasSegments || it.containsKey('workSeconds'))) {
          work = integer(it, ip, 'workSeconds', or: lenient ? 30 : null);
        }
        final rest = integer(it, ip, 'restSeconds', or: lenient ? 20 : null);
        final segments = <PlanSegment>[];
        if (it.containsKey('segments') && segmentsRaw is! List) {
          bad('$ip.segments', 'segments 必须是数组');
        }
        final segmentIds = <String>{};
        if (segmentsRaw is List) {
          for (var si = 0; si < segmentsRaw.length; si++) {
            final sp = '$ip.segments[$si]';
            final raw = segmentsRaw[si];
            if (raw is! Map) {
              bad(sp, '分段必须是对象');
              continue;
            }
            final s = asMap(raw);
            const keys = {'id', 'exerciseId', 'mode', 'reps', 'workSeconds', 'holdSeconds', 'label', 'rhythm'};
            for (final key in s.keys) {
              if (!keys.contains(key)) {
                bad('$sp.$key', '分段不支持 $key；组数、侧别和休息继承父计划项');
              }
            }
            final sid = s['id'];
            final sex = s['exerciseId'];
            if (sid is! String || sid.trim().isEmpty) {
              bad('$sp.id', '分段 id 必须是非空字符串');
            } else if (!segmentIds.add(sid.trim())) {
              bad('$sp.id', '同一计划项中的分段 id 不得重复');
            }
            if (sex is! String || sex.trim().isEmpty) {
              bad('$sp.exerciseId', '分段 exerciseId 必须是非空字符串');
            }
            final sm = switch (s['mode']) {
              'reps' => DoseMode.reps,
              'time' => DoseMode.time,
              _ => null,
            };
            if (sm == null) bad('$sp.mode', '分段 mode 必须是 reps 或 time');
            final sr = sm == DoseMode.reps ? integer(s, sp, 'reps') : null;
            final sw = sm == DoseMode.time ? integer(s, sp, 'workSeconds') : null;
            if (sr != null && sr <= 0) bad('$sp.reps', '分段 reps 必须大于 0');
            if (sw != null && sw <= 0) {
              bad('$sp.workSeconds', '分段 workSeconds 必须大于 0');
            }
            if (s.containsKey(sm == DoseMode.time ? 'reps' : 'workSeconds')) {
              bad(sp, '分段只能包含与 mode 对应的剂量');
            }
            final sh = s.containsKey('holdSeconds') ? integer(s, sp, 'holdSeconds') : null;
            if (sh != null && sh <= 0) {
              bad('$sp.holdSeconds', 'holdSeconds 必须大于 0');
            }
            if (s.containsKey('label') && (s['label'] is! String || (s['label'] as String).trim().isEmpty)) {
              bad('$sp.label', 'label 必须是非空字符串');
            }
            Map<String, dynamic>? rhythm;
            if (s.containsKey('rhythm')) {
              if (s['rhythm'] is! Map) {
                bad('$sp.rhythm', 'rhythm 必须是对象');
              } else {
                rhythm = Map<String, dynamic>.from(s['rhythm'] as Map);
                for (final e in segmentRhythmErrors(rhythm).entries) {
                  bad('$sp.rhythm${e.key}', e.value);
                }
              }
            }
            if (sid is String && sid.trim().isNotEmpty && sex is String && sex.trim().isNotEmpty && sm != null) {
              segments.add(
                PlanSegment(
                  id: sid.trim(),
                  exerciseId: sex.trim(),
                  mode: sm,
                  reps: sr,
                  workSeconds: sw,
                  holdSeconds: sh,
                  label: asString(s['label']),
                  rhythm: rhythm,
                ),
              );
            }
          }
        }
        if (exId is String && exId.isNotEmpty && mode != null) {
          items.add(
            PlanItem(
              exerciseId: exId,
              mode: mode,
              sets: sets,
              reps: reps,
              workSeconds: work,
              perSide: perSide == true,
              restSeconds: rest,
              note: asString(it['note']),
              replacedFrom: asString(it['replacedFrom']),
              segments: segments,
            ),
          );
        }
      }
      if (type != null) {
        blocks.add(
          PlanBlock(
            id: asString(b['id']) ?? 'b${bi + 1}',
            name: asString(b['name']) ?? type.zh,
            type: type,
            rounds: integer(b, bp, 'rounds', or: 1),
            restBetweenRoundsSeconds: integer(b, bp, 'restBetweenRoundsSeconds', or: 0),
            items: items,
          ),
        );
      }
    }

    // title / goal 的「缺失、为空、不在枚举」由 PlanValidator 判（与评测 validate.py 一样只报一次），这里只查类型。
    final title = str('title', or: lenient ? '训练计划' : null, required: false);
    final goal = str('goal', or: lenient ? 'mixed' : null, required: false);
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
