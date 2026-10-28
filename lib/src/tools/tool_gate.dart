/// 工具门禁：保留目录、伤痛、器械、场景与来源底线；可确定修正的
/// 协议/呈现偏差由代码规范化并写入回执。Agent v2 的配时交给共享配时器，
/// 专业编排建议作为 warning；宿主 extraRules 保持原有执行方式。
///
/// 卡片只接受本门禁产出的 [ValidatedPlan] / [ValidatedActions]（私有构造，App 无法自己造）。
library;

import 'dart:convert';

import '../agent/output_gate.dart';
import '../agent/session_state.dart';
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
  ValidatedPlan._(this.plan, List<PlanIssue> warnings)
    : warnings = List.unmodifiable(warnings);
  final TrainingPlan plan;
  final List<PlanIssue> warnings;
}

class ValidatedAction {
  const ValidatedAction._(this.drill, this.note);
  final Drill drill;
  final String? note;
  String get id => drill.id;
}

/// 通过门禁的动作展示（非空、不重复、都在白名单）。只能由 [ToolGate] 构造。
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
        ? {
            'ok': true,
            'shown': true,
            if (warnings.isNotEmpty)
              'notes': [for (final warning in warnings) warning.message],
          }
        : {
            ...(errors.isEmpty
                ? <String, Object?>{
                    'ok': false,
                    'code': 'prompt_leak',
                    'field': 'content',
                    'expected': '不含内部提示或标记的用户回复',
                    'actual': '检测到内部标记',
                    'fix': '停止本次交付，重新生成不含内部资料的回复。',
                  }
                : ToolGate.issueJson(errors.first)),
            'remainingAttempts': ?remaining,
            'errors': [for (final e in errors) ToolGate.issueJson(e)],
            'instruction': '逐条改完后重新调用同一个工具，提交完整参数；不要向用户解释这些错误。',
          },
  );
}

/// A validated card and the state transition to commit only on delivery.
class AgentOutputResult {
  const AgentOutputResult({
    required this.state,
    this.card,
    this.changes = const [],
    this.noteTruncated = false,
    this.notices = const [],
    this.unavailable = false,
    this.unavailableMessage,
    this.needsUserChoice = false,
    this.feasibility,
    this.error,
  });
  final CoachSessionState state;
  final GateResult? card;
  final List<CoachNodeState> changes;
  final bool noteTruncated;
  final List<String> notices;
  final bool unavailable;
  final String? unavailableMessage;
  final bool needsUserChoice;
  final Map<String, Object?>? feasibility;
  final Map<String, Object?>? error;
  bool get ok => error == null;
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

  late final Set<String> _whitelist = CoachTools.whitelist(
    profile,
    catalog,
  ).toSet();

  PlanValidator get _validator => PlanValidator(
    catalog: catalog,
    profile: profile,
    extraRules: extraRules,
    enforceDrillDoseRange: enforceDrillDoseRange,
  );

  /// Agent v2 output path; all model-facing fields are checked before either
  /// a private card constructor or an output transition is made available.
  AgentOutputResult checkAgentOutput(
    CoachSessionState state,
    String tool,
    Object? arguments, {
    String language = 'zh',
  }) {
    final prepared = OutputGate(
      profile,
      catalog,
      extraRules: extraRules,
      enforceDrillDoseRange: enforceDrillDoseRange,
    ).prepare(state, tool, arguments, language: language);
    if (!prepared.ok) {
      return AgentOutputResult(
        state: prepared.nodeResult?.state ?? state,
        notices: prepared.notices,
        error: prepared.error,
      );
    }
    if (prepared.unavailable || prepared.needsUserChoice) {
      return AgentOutputResult(
        state: prepared.nodeResult!.state,
        unavailable: prepared.unavailable,
        needsUserChoice: prepared.needsUserChoice,
        feasibility: prepared.feasibility,
        changes: prepared.nodeResult!.changes,
        unavailableMessage: prepared.unavailableMessage,
        notices: prepared.notices,
      );
    }
    final warnings = [
      for (final text in prepared.warnings)
        PlanIssue.warning(
          prepared.warningDetails
                      .where((detail) => detail['message'] == text)
                      .firstOrNull?['code']
                  as String? ??
              'unverified_limit',
          text,
        ),
    ];
    final plan = prepared.plan == null
        ? null
        : ValidatedPlan._(prepared.plan!, warnings);
    final actions = prepared.actions == null
        ? null
        : ValidatedActions._([
            for (final drill in prepared.actions!)
              ValidatedAction._(drill, null),
          ], warnings);
    return AgentOutputResult(
      state: prepared.nodeResult!.state,
      changes: prepared.nodeResult!.changes,
      noteTruncated: prepared.noteTruncated,
      notices: prepared.notices,
      card: GateResult._(
        text: prepared.note,
        plan: plan,
        actions: actions,
        warnings: warnings,
        toolName: tool,
      ),
    );
  }

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
        errors.add(
          _issue(
            IssueCodes.emptyReply,
            '回复为空',
            'content',
            '一句文字，或文字 + 一个工具',
            '空',
          ),
        );
      }
      return GateResult._(text: text.trim(), errors: errors);
    }
    if (calls.length > 1) {
      warnings.add(
        const PlanIssue.warning('normalized_batch', '已按顺序处理输出工具批次。'),
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
          errs.add(
            _issue(
              IssueCodes.schema,
              '参数必须是 JSON 对象',
              'arguments',
              'object',
              _typeOf(args),
            ),
          );
        } else if (errs.isEmpty) {
          final m = (args! as Map).cast<String, Object?>();
          if (call.name == CoachTools.showActions) {
            actions = _checkActions(m, context, errs, warns);
          } else {
            plan = _checkPlan(m, context, errs, warns, planId);
          }
        }
      }
      errors.addAll(
        prefix.isEmpty
            ? errs
            : errs.map(
                (e) => e.copyWith(path: '$prefix${e.path ?? 'arguments'}'),
              ),
      );
      warnings.addAll(warns);
    }
    if (errors.isNotEmpty) {
      return GateResult._(
        text: text.trim(),
        errors: errors,
        warnings: warnings,
        toolName: calls.first.name,
      );
    }
    return GateResult._(
      text: text.trim(),
      plan: plan,
      actions: actions,
      warnings: warnings,
      toolName: calls.last.name,
    );
  }

  /// 暗号检测（公开给 Agent 的中间工具轮复用）。
  bool leaks(String text, List<LlmToolCall> calls) => _leaks(text, calls);

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
    Map() => v.entries.any(
      (e) => _anyString(e.key, test) || _anyString(e.value, test),
    ),
    _ => false,
  };

  /// App 自己的模板计划（回落用）也只能经门禁变成 [ValidatedPlan]；不合格返回 null。
  ValidatedPlan? admitTemplate(
    TrainingPlan plan, [
    CoachContext context = const CoachContext(),
  ]) {
    final r = _validator.validate(plan, context);
    return r.ok ? ValidatedPlan._(plan, r.warnings) : null;
  }

  ValidatedActions? _checkActions(
    Map<String, Object?> m,
    CoachContext ctx,
    List<PlanIssue> errs,
    List<PlanIssue> warns,
  ) {
    if (m.keys.any((key) => key != 'items')) {
      warns.add(const PlanIssue.warning('normalized_fields', '已忽略推荐卡额外字段。'));
    }
    final raw = m['items'];
    if (raw is! List) {
      errs.add(
        _issue(
          IssueCodes.schema,
          raw == null ? '缺少 items' : 'items 必须是数组',
          'items',
          'array',
          _typeOf(raw),
        ),
      );
      return null;
    }
    if (raw.isEmpty) {
      errs.add(
        _issue(
          IssueCodes.itemsCount,
          'items 数量不对',
          'items',
          '1–${CoachTools.maxActions} 个',
          '${raw.length} 个',
        ),
      );
    }
    final out = <ValidatedAction>[];
    final firstAt = <String, int>{};
    for (var i = 0; i < raw.length; i++) {
      final p = 'items[$i]';
      final it = raw[i];
      if (it is! Map) {
        errs.add(
          _issue(IssueCodes.schema, '动作项必须是对象', p, 'object', _typeOf(it)),
        );
        continue;
      }
      if (it.keys.any((key) => key != 'actionId' && key != 'note')) {
        warns.add(PlanIssue.warning('normalized_fields', '已忽略动作项 $i 的额外字段。'));
      }
      final note = it['note'];
      if (note != null && note is! String) {
        warns.add(PlanIssue.warning('normalized_note', '动作项 $i 的非文本说明已忽略。'));
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
        errs.add(
          _issue(
            IssueCodes.unknownExercise,
            '未知动作 ID：$id',
            '$p.actionId',
            '本 App 动作目录里的 id',
            id,
          ),
        );
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
      if (firstAt.containsKey(id)) {
        warns.add(PlanIssue.warning('normalized_duplicate', '重复推荐动作 $id 已合并。'));
        continue;
      }
      firstAt[id] = i;
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
      out.add(
        ValidatedAction._(
          d,
          note is String && note.trim().isNotEmpty ? note.trim() : null,
        ),
      );
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
    if (m['plan'] is Map) {
      m = (m['plan'] as Map).cast<String, Object?>();
      warns.add(const PlanIssue.warning('normalized_wrapper', '已解包计划对象。'));
    }
    final decoded = const PlanCodec().decodeStrict(
      m,
      id: planId,
      scene: ctx.scene,
      level: ctx.level,
      minutes: ctx.minutes,
    );
    errs.addAll(decoded.issues.where((i) => i.isError).map(_strip));
    final raw = decoded.plan;
    if (raw == null) return null;
    if ((ctx.scene != null && raw.scene != ctx.scene) ||
        (ctx.level != null && raw.level != ctx.level) ||
        (ctx.minutes != null && raw.targetMinutes != ctx.minutes)) {
      warns.add(
        const PlanIssue.warning(
          'normalized_card_conditions',
          '已按本轮确认条件同步卡片字段。',
        ),
      );
    }
    // 只判不修：不改场所 / 等级 / 时长；只标 source=ai 并带上本轮保护部位（随计划保存）。
    final plan = raw.copyWith(
      source: 'ai',
      scene: ctx.scene,
      level: ctx.level,
      targetMinutes: ctx.minutes,
      avoid: {...raw.avoid, ...ctx.avoid},
    );
    final report = _validator.validate(plan, ctx);
    for (final i in report.issues) {
      (i.isError ? errs : warns).add(_strip(i));
    }
    return errs.isEmpty ? ValidatedPlan._(plan, warns) : null;
  }

  static PlanIssue _strip(PlanIssue i) {
    final p = i.path;
    final np = p == null || p == 'plan'
        ? 'arguments'
        : (p.startsWith('plan.') ? p.substring(5) : p);
    return i.copyWith(path: np);
  }

  static PlanIssue _issue(
    String code,
    String msg,
    String path,
    String expected,
    String actual,
  ) => PlanIssue(code, msg, path: path, expected: expected, actual: actual);

  static String _typeOf(Object? v) => switch (v) {
    null => '缺失',
    String() => 'string',
    bool() => 'boolean',
    num() => 'number',
    List() => 'array',
    Map() => 'object',
    _ => v.runtimeType.toString(),
  };

  static String _clip(String s) =>
      s.length <= 80 ? s : '${s.substring(0, 80)}…';

  /// 一条错误回给模型的样子。
  static Map<String, Object?> issueJson(PlanIssue e) => {
    'ok': false,
    'field': e.path ?? 'arguments',
    'path': e.path ?? 'arguments',
    'code': e.code,
    'expected': e.expected ?? (e.fix ?? fixFor(e.code)),
    'actual': e.actual ?? e.message,
    'fix': e.fix ?? fixFor(e.code),
    'message': e.message,
  };

  /// 每个错误码一句改法。
  static String fixFor(String code) => switch (code) {
    IssueCodes.invalidJson => '参数必须是合法 JSON（检查引号、逗号、括号是否成对），重新提交完整参数',
    IssueCodes.schema ||
    IssueCodes.schemaVersion ||
    IssueCodes.goal => '按工具参数 schema 补齐该字段或改成正确类型 / 取值',
    IssueCodes.unexpectedField =>
      '删掉这个字段（看动作只写 actionId 和可选 note；show_plan 参数不要包在 plan 里）',
    IssueCodes.itemsCount => 'show_actions 只放 1–6 个动作',
    IssueCodes.multipleTools => '只保留一个工具调用：看动作用 show_actions，开练用 show_plan',
    IssueCodes.unknownTool => '只能用 show_actions 或 show_plan',
    IssueCodes.emptyReply => '至少写一句给用户的文字',
    IssueCodes.unknownExercise ||
    IssueCodes.outOfProfile => '调用 search_actions，使用本任务已返回且符合条件的动作 id',
    IssueCodes.modeMismatch =>
      '按目录「默认」列单位：次 → mode=reps 并填 reps；秒 → mode=time 并填 workSeconds',
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
    IssueCodes.scene ||
    IssueCodes.position ||
    IssueCodes.sceneUnsupported => '换成适合该场所的动作，scene 填用户场所',
    IssueCodes.blockOrder => '热身块放在最前，放松块放在最后',
    IssueCodes.contextConflict =>
      'level / targetMinutes 改成本轮条件给出的值（expected），并按新时长调整动作与组数',
    IssueCodes.emptyPlan || IssueCodes.emptyBlock => '每个块至少放一个动作',
    IssueCodes.tooManyItems => '减少动作条目，多做用 sets / rounds',
    _ => '修复 actual 描述的字段错误，按当前工具 schema 重新提交完整参数。',
  };
}
