/// 一轮对话的结果类型与回落约定（[CoachAgent] 使用）。
///
/// 0.2 的 `CoachSession` 工具版会话已删除（2026-11-04）：入口为 [CoachAgent] / [CoachConversationController]
/// 与问答 Agent（`package:ugk_coach/ugk_coach_qa_v2.dart`）。
library;

import 'dart:async';

import '../assistant/fallback.dart';
import '../llm/llm_types.dart';
import '../plan/coach_context.dart';
import '../plan/plan_issue.dart';
import '../plan/training_plan.dart';
import '../usage/usage.dart';
import 'ask_user.dart';
import 'tool_gate.dart';

enum TurnStatus {
  /// 模型回复通过门禁（可能经过重交）。
  ok,

  /// 用了 App 模板（模型不可用、重交用尽、或暗号泄露）。
  fallback,

  /// 会话到达硬上限，没有调用模型：App 提示用户重置。
  limitReached,

  /// 用户输入过长，没有调用模型。
  inputTooLong,

  /// 被取消；或在返回前会话已重置（旧轮作废）。历史与轮数不变。
  cancelled,

  /// 上一轮还在进行：本次被拒绝，没有调用模型（同一会话一次只处理一轮）。
  busy,

  /// 需要回落但没有配置回落（或回落本身出错）。
  error,
}

/// 回落请求：App 用自己的模板 / 规则生成回复。
class SessionFallbackRequest {
  const SessionFallbackRequest({
    required this.userText,
    required this.context,
    required this.reason,
    this.issues = const [],
    this.error,
  });
  final String userText;
  final CoachContext context;
  final FallbackReason reason;

  /// 最后一次提交的门禁错误（invalidOutput 时）。
  final List<PlanIssue> issues;
  final Object? error;
}

/// 回落回复。[plan] 也要过门禁（[ToolGate.admitTemplate]）。
/// CoachAgent 拒绝不合格计划并返回失败；纯文字回落保持可用。
class SessionFallbackReply {
  const SessionFallbackReply(this.text, {this.plan});
  final String text;
  final TrainingPlan? plan;
}

typedef SessionFallback =
    FutureOr<SessionFallbackReply> Function(SessionFallbackRequest request);

class CoachTurnResult {
  const CoachTurnResult({
    required this.turnId,
    required this.status,
    this.text = '',
    this.plan,
    this.actions,
    this.question,
    this.warnings = const [],
    this.issues = const [],
    this.submissions = 0,
    this.fallbackReason,
    this.leaked = false,
    this.error,
    this.records = const [],
    this.steps = 0,
    this.reads = const [],
    this.isPlanningFailure = false,
  });

  final String turnId;
  final TurnStatus status;

  /// 给用户的文字。
  final String text;

  /// 只有通过门禁的计划 / 动作卡。
  final ValidatedPlan? plan;
  final ValidatedActions? actions;

  /// Agent question, validated before delivery; mutually exclusive with plan/actions.
  final AskUserQuestion? question;
  final List<PlanIssue> warnings;

  /// 回落时：最后一次提交的错误。
  final List<PlanIssue> issues;

  /// 模型提交次数（1 = 首次即过；0 = 没调模型）。
  final int submissions;
  int get resubmits => submissions > 1 ? submissions - 1 : 0;
  final FallbackReason? fallbackReason;

  /// 回复里出现提示词暗号（已丢弃）。
  final bool leaked;
  final Object? error;

  /// True only for a failed planning turn, never ordinary chat or safety.
  final bool isPlanningFailure;
  final List<UsageRecord> records;

  /// Agent 版：本轮调模型的步数（0.2 会话为 0）。
  final int steps;

  /// Agent 版：本轮读过的文件路径（按顺序）。
  final List<String> reads;

  TokenUsage get usage => records.fold(TokenUsage.zero, (a, r) => a + r.usage);
}
