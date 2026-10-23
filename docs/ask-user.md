# ask_user：App 接口（ugk_coach 0.4.0）

**升级兼容性：** 0.4.0 新增 `AgentEventKind.askUser`，对旧穷举 `switch` 是源码破坏性变更：没有此分支会编译失败。升级时补 `case AgentEventKind.askUser`（switch expression 则补 `AgentEventKind.askUser => ...`）；进度标签可返回 null，问题事件交由气泡处理。明确的 default / `_` 兜底也可解决穷举编译，但不会自动完成问题 UI 接入。

`CoachAgent` 可以先交付一个澄清问题，再用用户下一条消息继续排课。本次提供 SDK 的工具、事件、结果和门禁；问题气泡、选项按钮及输入框由 App 实现，`ugk_trainer` 版本仍为 0.1.7。`CoachSession` 降级入口不提供 `ask_user`。

## 问题结构

所有类型通过 `package:ugk_coach/ugk_coach.dart` 导出。App 接收通过门禁的 `AskUserQuestion`，无需解析模型原始工具参数；它的构造器不公开，`options` 是不可修改的列表。

| 字段 | Dart 类型 | 约定 |
|---|---|---|
| `question` | `String` | 去掉首尾空白后的非空问题，简短口语，一次问一件事 |
| `mode` | `AskUserMode` | `AskUserMode.text` 或 `AskUserMode.choice` |
| `options` | `List<String>` | text 时为空；choice 时 2–6 个去掉首尾空白后不重复的非空选项，每项最多 12 个 Unicode 码点 |
| `multiple` | `bool` | choice 是否允许多选，省略时为 false；text 的对象值为 false |

模型调用 text 模式时只能带 `question`、`mode`，不能带 `options` 或 `multiple`，即使它们是空数组、false 或 null 也拒绝。choice 必须提供 `options`，`multiple` 若提供必须是 bool。未知字段同样拒绝。`question.toJson()` 在 text 模式只输出 `question`、`mode`；choice 模式另输出 `options`、`multiple`。

```json
{
  "question": "你现在主要哪儿紧？",
  "mode": "choice",
  "options": ["肩颈", "胸背", "髋前侧", "臀腿", "不确定"],
  "multiple": true
}
```

## 事件、结果和回答

`agent.events` 新增 `AgentEventKind.askUser`，通过 `event.question` 携带问题，通过 `event.turnId` 标识本轮。正常顺序是：参数及整批工具门禁通过 → 本轮记账完成 → `askUser` 事件 → 提交问题历史和计数 → `done` 事件 → `agent.send()` 返回。SDK 发出问题后结束本轮，不继续调模型、不在工具循环中等待回答。

成功结果为 `CoachTurnResult(status: TurnStatus.ok)`，`result.question` 与事件中的问题一致，`result.text == result.question!.question`，`plan`、`actions` 为空。按同一个 `turnId` 更新同一个气泡；不要再把 `result.text` 追加成第二条问题。也可以只用结果渲染问题，事件用于进度。

事件发生时 `send` 尚未返回，`agent.isBusy` 仍可能为 true。App 可先显示禁用的问题气泡，必须等 `await agent.send(...)` 返回且 `result.question != null` 后再启用回答；不要在事件监听器中直接发送下一条消息。`done` 事件也不能替代等待 `send` 返回。

事件在提交历史之前同步发送。监听器若调用本轮的 `CancelToken.cancel()` 或 `agent.reset()`，本轮返回 `cancelled`，不提交问题历史、轮数或询问计数；App 应撤掉该 `turnId` 的临时气泡。reset 本身会清空已有会话及计数。其他取消路径没有可渲染的问题结果。

用户点击单选时发送选项文字；多选时用 `selected.join('、')`，例如“肩颈、髋屈肌”。用户直接输入文字时照常发送，不要求匹配选项，也不转换成选项序号或 JSON：

```dart
final next = await agent.send(answer, context: currentContext);
```

沿用同一个 `CoachAgent` 实例，不要在回答前 `reset()`。每次 `send` 都传入仍有效的 App 已知条件，特别是筛查得到的 `avoid`、场所、器械和时长；这些条件不会因为上一轮传过就自动成为下一轮的 `CoachContext`。用户口头回答保存在会话历史中，App 若另有结构化条件更新，应从现有 context 用 `copyWith` 更新，保留其他筛查条件。

## 可审阅的 Dart 接入示例

下面是与 UI 框架无关的绑定层，App 提供渲染回调。`upsertQuestion` 必须以 `turnId` 更新现有气泡；`showResult` 只处理非问题结果的文字、计划/动作卡和状态，不解析原始工具参数。绑定层保留同一任务的 context，发送期间禁用回答，并在取消结果时撤回临时气泡。

```dart
import 'dart:async';
import 'package:ugk_coach/ugk_coach.dart';

typedef UpsertQuestion = void Function(
  String turnId,
  AskUserQuestion question,
  bool canAnswer,
);

class AskUserChatBinding {
  AskUserChatBinding({
    required this.agent,
    required CoachContext context,
    required this.upsertQuestion,
    required this.removeQuestion,
    required this.showResult,
    required this.setInputEnabled,
  }) : _context = context {
    _subscription = agent.events.listen(_onEvent);
  }

  final CoachAgent agent;
  final UpsertQuestion upsertQuestion;
  final void Function(String turnId) removeQuestion;
  final void Function(CoachTurnResult result) showResult;
  final void Function(bool enabled) setInputEnabled;
  late final StreamSubscription<AgentEvent> _subscription;
  final _unconfirmed = <String>{};
  CoachContext _context;
  CancelToken? _cancel;
  String? _pendingTurnId;
  AskUserQuestion? _pending;
  bool _sending = false;
  bool _disposed = false;

  void _onEvent(AgentEvent event) {
    if (_disposed || event.kind != AgentEventKind.askUser) return;
    final question = event.question;
    if (question == null) return;
    _unconfirmed.add(event.turnId);
    upsertQuestion(event.turnId, question, false);
    // 不在监听器中调用 send，也不在 done 事件中启用回答。
  }

  // 初始请求、自由输入的回答和“直接出”都走这里。
  Future<CoachTurnResult> sendText(
    String text, {
    CoachContext? context,
  }) async {
    if (_disposed || _sending || agent.isBusy) {
      throw StateError('当前不能发送');
    }
    if (text.trim().isEmpty) throw ArgumentError('回答不能为空');
    if (context != null) _context = context;
    final previousId = _pendingTurnId;
    final previousQuestion = _pending;
    if (previousId != null && previousQuestion != null) {
      upsertQuestion(previousId, previousQuestion, false);
    }
    _sending = true;
    setInputEnabled(false);
    final token = CancelToken();
    _cancel = token;
    late final CoachTurnResult result;
    try {
      result = await agent.send(text, context: _context, cancel: token);
    } finally {
      _sending = false;
      _cancel = null;
    }
    if (_disposed) return result;

    final hadTemporaryBubble = _unconfirmed.remove(result.turnId);
    final question = result.question;
    _pendingTurnId = null;
    _pending = null;
    if (result.status == TurnStatus.ok && question != null) {
      _pendingTurnId = result.turnId;
      _pending = question;
      upsertQuestion(result.turnId, question, true);
      // result.text 就是同一个问题，不再追加文字气泡。
    } else {
      if (hadTemporaryBubble) removeQuestion(result.turnId);
      showResult(result); // App 处理 cancelled、limitReached 等状态。
    }
    setInputEnabled(true); // 此时 SDK 的 send 已返回，isBusy 已释放。
    return result;
  }

  Future<CoachTurnResult> sendChoices(List<String> selected) {
    final question = _pending;
    if (question == null || question.mode != AskUserMode.choice ||
        selected.isEmpty || selected.toSet().length != selected.length ||
        (!question.multiple && selected.length != 1) ||
        selected.any((value) => !question.options.contains(value))) {
      throw ArgumentError('请选择当前问题的有效选项');
    }
    return sendText(selected.join('、'));
  }

  void cancelCurrent() => _cancel?.cancel();

  Future<void> dispose() async {
    _disposed = true;
    cancelCurrent();
    await _subscription.cancel();
    // agent 的所有者在不再使用整个会话时调用 agent.dispose()。
  }
}
```

创建绑定时把筛查结果作为 `context` 传入，之后 `sendText('肩颈、髋屈肌')` 与按钮触发的 `sendChoices(...)` 都是下一次普通 `send`。只有用户明确开始新会话时才重建绑定或调用 `agent.reset()`，不要为每个问题重置。

## 门禁和任务计数

同一模型响应含 `ask_user` 时，只允许该响应有一个工具调用。与第二个 `ask_user`、`show_plan`、`show_actions`、`read`、`ls`、`remember` 等任何其他工具同批出现都会整批拒绝，不先执行旁边的读取或副作用。参数、互斥或计数错误按现有工具反馈机制回给模型修正，沿用 `maxResubmits`，App 不应自行修补不合格参数或展示被拒问题。

`CoachAgent.maxQuestionsPerTask == 3`；`agent.questionsAsked` 是 SDK 已成功提交的澄清问题数，跨 `send` 保留。在事件监听器中计数可能尚未增加，以 `send` 返回后的 getter 为准。非法调用及提交前被取消的问题不增加计数。

| 情况 | 计数变化 |
|---|---|
| 成功交付合法问题 | 加 1 |
| 已问 3 次后再次调用 `ask_user` | 拒绝，反馈 `ask_limit`，要求模型用已有回答及合理默认值出方案 |
| 成功交付合法 `show_plan` / `show_actions` | 清零 |
| fallback 交付通过门禁的模板计划 | 清零 |
| 普通文字回复、无合法计划的 fallback、参数拒绝或取消 | 不因该结果清零 |
| `reset()` | 清零，同时清空会话历史 |

SDK 会把当前询问计数带入模型上下文。提问轮数仍属于会话轮数，原有 `maxTurns` / 历史长度限制继续生效。任务计数不会在每次 `send` 开始时清零，也不由 App 自报。

## 何时问

`plan-training` 只补会改变方案的时长、地点和器械、重点/紧绷部位、水平或不适部位，一次问影响最大的一件事，优先 choice；用户已说过、筛查及上下文已有的信息不重问。询问轮直接 `ask_user`，不先读动作库、编排动作或长篇思考。需要保存的稳定事实先留在会话，答复后交付方案前再按记忆规则保存。

“bboy、程序员、日常久坐肌肉紧张，练托马斯前要放松”应先问紧绷重点；“在家 20 分钟练核心”信息已经足够，直接出方案。最终计划要采用前面的回答。到 3 次上限或用户说“直接出”就停止追问，按合理默认值出方案，用一句话说明假设。以上为 SDK 行为及接口约定，不代表本仓库已经实现各 App 的问题气泡 UI。

本次验证范围与评测证据见 [0.4.0 ask_user 评测记录](coach-040-ask-user-eval-2026-10-23.md)；离线协议验证与真实模型结果分别记录。
