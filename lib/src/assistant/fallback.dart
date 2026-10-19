/// 回落：模型不可用或两次都没给出合格输出时，交给 App 自己的离线生成器（如 SmartFit 的模板 + 规则对话）。
library;

import 'dart:async';

import '../envelope/coach_reply.dart';
import '../plan/coach_context.dart';
import '../plan/plan_issue.dart';
import 'conversation.dart';

enum FallbackReason {
  /// 断网 / 连不上。
  offline,
  timeout,
  rateLimited,

  /// key / 中转令牌无效。
  auth,

  /// 服务端错误或返回体异常。
  server,

  /// 输出被 max_tokens 截断。
  truncated,

  /// 输出不合格（重写后仍不合格）。
  invalidOutput,
}

class FallbackRequest {
  const FallbackRequest({
    required this.userText,
    required this.context,
    required this.conversation,
    required this.reason,
    this.issues = const [],
    this.error,
  });

  final String userText;
  final CoachContext context;
  final CoachConversation conversation;
  final FallbackReason reason;

  /// invalidOutput 时，最后一次的校验问题。
  final List<PlanIssue> issues;
  final Object? error;
}

/// App 实现：返回一条回复（通常带模板计划）。
abstract interface class FallbackPlanner {
  Future<CoachReply> reply(FallbackRequest request);
}

/// 用函数实现 [FallbackPlanner]。
class FallbackFn implements FallbackPlanner {
  FallbackFn(this.fn);
  final FutureOr<CoachReply> Function(FallbackRequest request) fn;
  @override
  Future<CoachReply> reply(FallbackRequest request) async => fn(request);
}
