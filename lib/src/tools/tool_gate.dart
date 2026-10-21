/// 工具门禁：判定模型一次回复（文字 + 工具调用）能否渲染。**只判不修**——不修 JSON、不补字段、不改剂量。
///
/// 必须改（错误，打回让模型自己修）：
/// - `invalid_json` 参数不是合法 JSON；`schema` 缺字段 / 类型错；`unexpected_field` 多余字段（如看动作带剂量）
/// - `items_count` show_actions 不是 1–6 个；`multiple_tools` 一次调了两个及以上工具；`unknown_tool`；`empty_reply`
/// - `unknown_exercise` id 不在目录；`out_of_profile` 不在本 App 白名单
/// - `mode_mismatch` 剂量单位与动作不符；`avoid` 撞用户保护部位；`duplicate_action` 同一动作重复
/// - `context_conflict` 计划 level / targetMinutes 与本轮 [CoachContext] 明确值不一致
/// - 沿用 0.1 的其余计划规则（硬限、单侧、器械、场所、热身在放松后……）
///
/// 只警告放行：剂量超出动作推荐范围、估算时长偏差、块顺序不理想（沿用 0.1 口径）。
///
/// 卡片只接受本门禁产出的 [ValidatedPlan] / [ValidatedActions]（私有构造，App 无法自己造）。
library;

import 'dart:convert';

import '../catalog/catalog.dart';
import '../llm/llm_types.dart';
import '../plan/coach_context.dart';
import '../plan/plan_codec.dart';
import '../plan/plan_issue.dart';
import '../plan/plan_validator.dart';
import '../plan/training_plan.dart';
import '../profile/coach_profile.dart';
import 'coach_tools.dart';

/// 通过门禁的计划。只能由 [ToolGate] 构造。
final class ValidatedPlan {
  ValidatedPlan._(this.plan, List<PlanIssue> warnings) : warnings = List.unmodifiable(warnings);
  final TrainingPlan plan;
  final List<PlanIssue> warnings;
}

class ValidatedAction {
  const ValidatedAction._(this.drill, this.note);
  final Drill drill;
  final String? note;
  String get id => drill.id;
}

/// 通过门禁的动作展示（1–6 个、不重复、都在白名单）。只能由 [ToolGate] 构造。
final class ValidatedActions {
  ValidatedActions._(List<ValidatedAction> items, List<PlanIssue> warnings)
    : items = List.unmodifiable(items),
      warnings = List.unmodifiable(warnings);
  final List<ValidatedAction> items;
  final List<PlanIssue> warnings;
}

class GateResult {
  GateResult._({
    required this.text,
    this.plan,
    this.actions,
    this.toolName,
    List<PlanIssue> errors = const [],
    List<PlanIssue> warnings = const [],
    this.leaked = false,
  }) : errors = List.unmodifiable(errors),
       warnings = List.unmodifiable(warnings);

  /// 给用户的文字（可为空：只有卡片）。
  final String text;
  final ValidatedPlan? plan;
  final ValidatedActions? actions;
  final String? toolName;
  final List<PlanIssue> errors;
  final List<PlanIssue> warnings;

  /// 回复里出现了提示词暗号：整轮丢弃、不重交、直接回落。
  final bool leaked;

  bool get ok => !leaked && errors.isEmpty;

  /// 回给模型的工具结果（JSON 字符串）：一次列出全部错误，每条 位置 / 错误码 / 期望 / 实际 / 改法。
  String feedback({int? remaining}) => jsonEncode(
    ok
        ? {'ok': true, 'shown': true}
        : {
            'ok': false,
            'remainingAttempts': ?remaining,
            'errors': [for (final e in errors) ToolGate.issueJson(e)],
            'instruction': '逐条改完后重新调用同一个工具，提交完整参数；不要向用户解释这些错误。',
          },
  );
}

class ToolGate {
  ToolGate({
    required this.catalog,
    required this.profile,
    this.canary,
    this.extraRules = const [],
    this.enforceDrillDoseRange = false,
  });

  final Catalog catalog;
  final CoachProfile profile;

  /// 提示词暗号；null = 不检测。
  final String? canary;
  final List<PlanRule> extraRules;
  final bool enforceDrillDoseRange;

  late final Set<String> _whitelist = CoachTools.whitelist(profile, catalog).toSet();

  PlanValidator get _validator => PlanValidator(
    catalog: catalog,
    profile: profile,
    extraRules: extraRules,
    enforceDrillDoseRange: enforceDrillDoseRange,
  );

  /// 判定一次模型回复。
  GateResult check(
    String text,
    List<LlmToolCall> calls, {
    CoachContext context = const CoachContext(),
    String? planId,
  }) {
    if (_leaks(text, calls)) return GateResult._(text: '', leaked: true);
    final errors = <PlanIssue>[];
    final warnings = <PlanIssue>[];
    if (calls.isEmpty) {
      if (text.trim().isEmpty) {
        errors.add(_issue(IssueCodes.emptyReply, '回复为空', 'content', '一句文字，或文字 + 一个工具', '空'));
      }
      return GateResult._(text: text.trim(), errors: errors);
    }
    if (calls.length > 1) {
      errors.add(
        _issue(
          IssueCodes.multipleTools,
          '一次回复只能调用一个工具',
          'tool_calls',
          '0 或 1 个工具调用',
          '${calls.length} 个：${calls.map((t) => t.name).join(', ')}',
        ),
      );
    }
    ValidatedPlan? plan;
    ValidatedActions? actions;
    for (var k = 0; k < calls.length; k++) {
      final call = calls[k];
      final prefix = calls.length > 1 ? 'tool_calls[$k].' : '';
      final errs = <PlanIssue>[];
      final warns = <PlanIssue>[];
      if (!CoachTools.names.contains(call.name)) {
        errs.add(
          _issue(
            IssueCodes.unknownTool,
            '没有工具「${call.name}」',
            'tool_calls[$k].name',
            'show_actions / show_plan',
            call.name,
          ),
        );
      } else {
        Object? args;
        try {
          args = jsonDecode(call.arguments);
        } on FormatException catch (e) {
          errs.add(
            _issue(
              IssueCodes.invalidJson,
              '参数不是合法 JSON：${e.message}',
              'arguments',
              '合法 JSON 对象',
              _clip(call.arguments),
            ),
          );
        }
        if (errs.isEmpty && args is! Map) {
          errs.add(_issue(IssueCodes.schema, '参数必须是 JSON 对象', 'arguments', 'object', _typeOf(args)));
        } else if (errs.isEmpty) {
          final m = (args! as Map).cast<String, Object?>();
          if (call.name == CoachTools.showActions) {
            actions = _checkActions(m, context, errs, warns);
          } else {
            plan = _checkPlan(m, context, errs, warns, planId);
          }
        }
      }
      errors.addAll(prefix.isEmpty ? errs : errs.map((e) => e.copyWith(path: '$prefix${e.path ?? 'arguments'}')));
      warnings.addAll(warns);
    }
    if (errors.isNotEmpty) {
      return GateResult._(text: text.trim(), errors: errors, warnings: warnings, toolName: calls.first.name);
    }
    return GateResult._(
      text: text.trim(),
      plan: plan,
      actions: actions,
      warnings: warnings,
      toolName: calls.single.name,
    );
  }

  /// 暗号检测：原文 + 参数 JSON 解码后的全部字符串（键和值），防 `\u0055GK-…` 这类转义绕过。
  bool _leaks(String text, List<LlmToolCall> calls) {
    final c = canary;
    if (c == null || c.isEmpty) return false;
    if (text.contains(c)) return true;
    for (final t in calls) {
      if (t.name.contains(c) || t.arguments.contains(c)) return true;
      Object? args;
      try {
        args = jsonDecode(t.arguments);
      } on FormatException {
        continue;
      }
      if (_anyString(args, (s) => s.contains(c))) return true;
    }
    return false;
  }

  static bool _anyString(Object? v, bool Function(String) test) => switch (v) {
    String() => test(v),
    List() => v.any((x) => _anyString(x, test)),
    Map() => v.entries.any((e) => _anyString(e.key, test) || _anyString(e.value, test)),
    _ => false,
  };

  /// App 自己的模板计划（回落用）也只能经门禁变成 [ValidatedPlan]；不合格返回 null。
  ValidatedPlan? admitTemplate(TrainingPlan plan, [CoachContext context = const CoachContext()]) {
    final r = _validator.validate(plan, context);
    return r.ok ? ValidatedPlan._(plan, r.warnings) : null;
  }

  ValidatedActions? _checkActions(
    Map<String, Object?> m,
    CoachContext ctx,
    List<PlanIssue> errs,
    List<PlanIssue> warns,
  ) {
    for (final k in m.keys) {
      if (k != 'items') errs.add(_issue(IssueCodes.unexpectedField, '多余字段 $k', k, '只有 items', k));
    }
    final raw = m['items'];
    if (raw is! List) {
      errs.add(_issue(IssueCodes.schema, raw == null ? '缺少 items' : 'items 必须是数组', 'items', 'array', _typeOf(raw)));
      return null;
    }
    if (raw.isEmpty || raw.length > CoachTools.maxActions) {
      errs.add(_issue(IssueCodes.itemsCount, 'items 数量不对', 'items', '1–${CoachTools.maxActions} 个', '${raw.length} 个'));
    }
    final out = <ValidatedAction>[];
    final firstAt = <String, int>{};
    for (var i = 0; i < raw.length; i++) {
      final p = 'items[$i]';
      final it = raw[i];
      if (it is! Map) {
        errs.add(_issue(IssueCodes.schema, '动作项必须是对象', p, 'object', _typeOf(it)));
        continue;
      }
      for (final k in it.keys) {
        if (k != 'actionId' && k != 'note') {
          errs.add(_issue(IssueCodes.unexpectedField, '看动作不带剂量或其他字段：$k', '$p.$k', 'actionId 与可选 note', '$k'));
        }
      }
      final note = it['note'];
      if (note != null && note is! String) {
        errs.add(_issue(IssueCodes.schema, 'note 必须是字符串', '$p.note', 'string', _typeOf(note)));
      }
      final id = it['actionId'];
      if (id is! String || id.isEmpty) {
        errs.add(
          _issue(
            IssueCodes.schema,
            id == null ? '缺少 actionId' : 'actionId 必须是字符串',
            '$p.actionId',
            '白名单动作 id',
            _typeOf(id),
          ),
        );
        continue;
      }
      final d = catalog[id];
      if (d == null) {
        errs.add(_issue(IssueCodes.unknownExercise, '未知动作 ID：$id', '$p.actionId', '本 App 动作目录里的 id', id));
        continue;
      }
      if (!_whitelist.contains(id)) {
        errs.add(
          _issue(
            IssueCodes.outOfProfile,
            '${d.name.of(ctx.language)}（$id）不在本 App 的动作范围',
            '$p.actionId',
            '本 App 动作目录里的 id',
            id,
          ),
        );
      }
      final prev = firstAt[id];
      if (prev != null) {
        errs.add(_issue(IssueCodes.duplicateAction, '动作重复', '$p.actionId', '每个 id 只出现一次', '$id（与 items[$prev] 重复）'));
      } else {
        firstAt[id] = i;
      }
      for (final c in d.cautions) {
        if (ctx.avoid.contains(c)) {
          errs.add(
            _issue(
              IssueCodes.avoid,
              '${d.name.of(ctx.language)}（$id）会加重$c部负担（用户要保护）',
              '$p.actionId',
              '注意列不含「$c」的动作',
              id,
            ),
          );
        }
      }
      out.add(ValidatedAction._(d, note is String && note.trim().isNotEmpty ? note.trim() : null));
    }
    return errs.isEmpty ? ValidatedActions._(out, warns) : null;
  }

  ValidatedPlan? _checkPlan(
    Map<String, Object?> m,
    CoachContext ctx,
    List<PlanIssue> errs,
    List<PlanIssue> warns,
    String? planId,
  ) {
    if (m.length == 1 && m['plan'] is Map) {
      errs.add(
        _issue(
          IssueCodes.unexpectedField,
          '参数多包了一层 plan',
          'plan',
          '顶层直接是 TrainingPlan 字段（schemaVersion、title、blocks…）',
          '{"plan": {...}}',
        ),
      );
      return null;
    }
    final decoded = const PlanCodec().decodeStrict(
      m,
      id: planId,
      scene: ctx.scene,
      level: ctx.level,
      minutes: ctx.minutes,
    );
    errs.addAll(decoded.issues.where((i) => i.isError).map(_strip));
    // 只判不修：本轮已知的水平 / 时长为准，冲突打回重交（旧入口会覆盖，这里不改值）。
    final lv = m['level'];
    if (ctx.level != null && lv is int && lv != ctx.level) {
      errs.add(_issue(IssueCodes.contextConflict, '计划水平与本轮条件不符', 'level', '${ctx.level}（本轮条件）', '$lv'));
    }
    final tm = m['targetMinutes'];
    if (ctx.minutes != null && tm is int && tm != ctx.minutes) {
      errs.add(_issue(IssueCodes.contextConflict, '计划时长与本轮条件不符', 'targetMinutes', '${ctx.minutes}（本轮条件）', '$tm'));
    }
    final raw = decoded.plan;
    if (raw == null) return null;
    // 只判不修：不改场所 / 等级 / 时长；只标 source=ai 并带上本轮保护部位（随计划保存）。
    final plan = raw.copyWith(source: 'ai', avoid: {...raw.avoid, ...ctx.avoid});
    final report = _validator.validate(plan, ctx);
    for (final i in report.issues) {
      if (i.code == IssueCodes.duplicateExercise) continue; // 由下面的全计划重复判定（错误）取代
      (i.isError ? errs : warns).add(_strip(i));
    }
    final firstAt = <String, String>{};
    for (var b = 0; b < plan.blocks.length; b++) {
      for (var k = 0; k < plan.blocks[b].items.length; k++) {
        final id = plan.blocks[b].items[k].exerciseId;
        final here = 'blocks[$b].items[$k]';
        final prev = firstAt[id];
        if (prev != null) {
          errs.add(
            _issue(
              IssueCodes.duplicateAction,
              '同一动作在计划里重复出现',
              '$here.exerciseId',
              '每个动作只出现一次（多做请加 sets）',
              '$id（与 $prev 重复）',
            ),
          );
        } else {
          firstAt[id] = here;
        }
      }
    }
    return errs.isEmpty ? ValidatedPlan._(plan, warns) : null;
  }

  static PlanIssue _strip(PlanIssue i) {
    final p = i.path;
    final np = p == null || p == 'plan' ? 'arguments' : (p.startsWith('plan.') ? p.substring(5) : p);
    return i.copyWith(path: np);
  }

  static PlanIssue _issue(String code, String msg, String path, String expected, String actual) =>
      PlanIssue(code, msg, path: path, expected: expected, actual: actual);

  static String _typeOf(Object? v) => switch (v) {
    null => '缺失',
    String() => 'string',
    bool() => 'boolean',
    num() => 'number',
    List() => 'array',
    Map() => 'object',
    _ => v.runtimeType.toString(),
  };

  static String _clip(String s) => s.length <= 80 ? s : '${s.substring(0, 80)}…';

  /// 一条错误回给模型的样子。
  static Map<String, Object?> issueJson(PlanIssue e) => {
    'path': e.path ?? 'arguments',
    'code': e.code,
    'expected': e.expected ?? '见 message',
    'actual': e.actual ?? '见 message',
    'fix': e.fix ?? fixFor(e.code),
    'message': e.message,
  };

  /// 每个错误码一句改法。
  static String fixFor(String code) => switch (code) {
    IssueCodes.invalidJson => '参数必须是合法 JSON（检查引号、逗号、括号是否成对），重新提交完整参数',
    IssueCodes.schema || IssueCodes.schemaVersion || IssueCodes.goal => '按工具参数 schema 补齐该字段或改成正确类型 / 取值',
    IssueCodes.unexpectedField => '删掉这个字段（看动作只写 actionId 和可选 note；show_plan 参数不要包在 plan 里）',
    IssueCodes.itemsCount => 'show_actions 只放 1–6 个动作',
    IssueCodes.multipleTools => '只保留一个工具调用：看动作用 show_actions，开练用 show_plan',
    IssueCodes.unknownTool => '只能用 show_actions 或 show_plan',
    IssueCodes.emptyReply => '至少写一句给用户的文字',
    IssueCodes.unknownExercise || IssueCodes.outOfProfile => '换成参数 enum 白名单里的动作 id，逐字拷贝',
    IssueCodes.modeMismatch => '按目录「默认」列单位：次 → mode=reps 并填 reps；秒 → mode=time 并填 workSeconds',
    IssueCodes.repsRange ||
    IssueCodes.workSecondsRange ||
    IssueCodes.setsRange ||
    IssueCodes.restRange ||
    IssueCodes.roundsRange ||
    IssueCodes.restBetweenRoundsRange ||
    IssueCodes.minutesRange => '把数值调到期望范围内',
    IssueCodes.perSide => '单侧动作 perSide=true，其余 false',
    IssueCodes.avoid => '换成「注意」列不含该部位的动作，或删掉这一项',
    IssueCodes.duplicateAction => '删掉重复项；同一动作要多做就加 sets',
    IssueCodes.equipment => '换成用户已有器械或徒手的动作',
    IssueCodes.scene || IssueCodes.position || IssueCodes.sceneUnsupported => '换成适合该场所的动作，scene 填用户场所',
    IssueCodes.blockOrder => '热身块放在最前，放松块放在最后',
    IssueCodes.contextConflict => 'level / targetMinutes 改成本轮条件给出的值（expected），并按新时长调整动作与组数',
    IssueCodes.emptyPlan || IssueCodes.emptyBlock => '每个块至少放一个动作',
    IssueCodes.tooManyItems => '减少动作条目，多做用 sets / rounds',
    _ => '按期望改正',
  };
}
