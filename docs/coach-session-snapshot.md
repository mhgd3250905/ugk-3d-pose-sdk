# 通用会话快照与推荐动作卡接入

基于 main `adbc908`；新分支 `codex/coach-session-snapshot`。新存档使用会话快照，不依赖计划卡；旧存档继续走 `restoreHistory`。SDK 默认模型配置与上下文预算未改，本轮不调用真实模型。

## 公开接口

```dart
// package:ugk_coach/ugk_coach.dart
CoachSessionSnapshot controller.exportSession();
void controller.restoreSession(
  CoachSessionSnapshot snapshot,
  List<CoachConversationMessage> messages,
);

Map<String, Object?> snapshot.toJson();
CoachSessionSnapshot.fromJson(Object? json);
```

`CoachSessionSnapshot.currentSchemaVersion == 1`。快照含 sourced `sessionState`（参数、source/quote/basedOn、任务/节点、picks、seen IDs、计划版本与交付版本）、`ContextTurnLedger`、待答问题及消息 ID、已加载技能名、当前候选、推荐交付的 `messageId/actionIds/note`。候选和技能名序列化在 sessionState 下，快照还提供对应 getters；不改变旧 `CoachSessionState` 构造合同。`agentState` 是 SDK 自身的续跑标记，App 不应编辑。

集合不可变，toJson 返回独立 JSON 副本；不包含模型密钥、传输配置、原始 reasoning、旧工具调用或工具回执。无需把 widget、图片、目录或素材地址写入快照。

## SmartFit 保存与恢复

```dart
import 'dart:convert';
import 'package:ugk_coach/ugk_coach.dart';

// App 持久化自己的显示消息；和快照一起原子保存。
final savedSnapshotJson = jsonEncode(controller.exportSession().toJson());
final savedMessages = controller.state.messages; // App 原有显示消息序列化
await appStore.saveConversation(savedSnapshotJson, encodeDisplayMessages(savedMessages));

// 重新构造同一 profile/catalog 配置的 Agent 和 Controller 后：
Object? decoded;
try {
  decoded = jsonDecode(await appStore.readSnapshot());
} on FormatException {
  decoded = null;
}
final snapshot = CoachSessionSnapshot.fromJson(decoded);
controller.restoreSession(snapshot, decodeDisplayMessages(await appStore.readMessages()));

// 后续照常走原接口，不要自行重放旧工具或补造任务。
await controller.send('再短点');
```

上面的 appStore、encode/decodeDisplayMessages 代表 SmartFit 已有存储层。显示消息只用于 UI；即使其文字被替换、删掉 planState 或推荐动作对象，也不能改变恢复后的参数、账本、任务和模型上下文。已交付推荐通过快照中的消息 ID 重新解析当前目录并构造 message.actions，note 取原交付值。

没有快照的旧存档仍使用：

```dart
controller.restoreHistory(savedDisplayMessages, planState: oldPlanState);
```

未知 schemaVersion 或损坏 JSON 对象不会从 fromJson/restoreSession 抛出异常；`snapshot.isValid == false`，restoreSession 自动退回 restoreHistory。App 可观察：

```dart
controller.events.listen((event) {
  if (event.kind == AgentEventKind.snapshotRestoreFallback) {
    recordRestoreFallback(event.path); // unsupported_schema / invalid_snapshot
  }
});
```

快照无需训练计划即可恢复推荐或问答。恢复本身不发请求；下一条新输入的请求顺序是 system/tools → 同一 `ContextTurnLedger.summaryMessage()` 生成的 role=user 摘要 → 本次用户原话 → 本次当前状态。没有旧 assistant/tool 或 reasoning，之后的工具循环重新追加真实结果。

## 进行中任务、询问和隐私

导出是同步的时间点快照。进行中的用户轮记录为 `interrupted`，保留已生效的参数、已完成节点、候选和当前计划版本；不会自动重跑模型或工具。取消已结束后再导出，也保留独立捕获的中断进度，原有 live cancel 回滚语义不变。新用户输入后模型基于这些事实继续。

未答 ask_user 恢复后保持可答；使用原 `answerChoices/answerText/answerForm`，或通过普通 send 输入回答。已答或已提交的旧问题只读。进行中无关消息不会把仍未答的问题丢掉。快照 pending 状态优先于 App 显示消息的 questionAnswered 值。

记忆存储不进入快照；clearMemory、禁用记忆、newConversation 的原有存储语义保留。成功 forget 后，导出副本去除删除的记忆文本及可追溯的原 remember 用户原话；live 显示历史不改写。remember 来源只以哈希和用户轮号保存，不写原记忆缓存，跨恢复后 forget 也能追溯。App 应用最新快照覆盖已保存版本；旧快照文件、备份与原显示消息仍由 App 的数据删除策略处理。

## 推荐卡

```dart
// package:ugk_coach_ui/ugk_coach_ui.dart as ui
ui.CoachRecommendCard(
  actionIds: message.actions!.items.map((action) => action.id).toList(),
  note: message.text,
  library: localizedExerciseLibrary,
  onOpenAction: (id) => openSingleActionTraining(id),
  onPlanFromActions: (ids) async {
    await controller.send('请把刚才推荐的动作排成计划。');
  },
);
```

`onPlanFromActions` 省略或为 null 时不显示按钮。library 沿用动作库的可信素材与当前语言映射，提供 `CoachExercise.name/levelLabel/equipmentLabel/stillCutout`；卡片不把内部 ID/编码显示给用户，不解析 note 猜测器材或剂量。支持 `CoachUiTheme`、`CoachUiBuilders.media` 覆盖，浅色风格与既有套路卡一致；未修改训练页或套路卡。

完整组件签名、取图路径和媒体 builder 示例见 [推荐卡接入](../packages/ugk_coach_ui/docs/recommend-card.md)。截图由真实 Flutter widget 渲染，不冒充原生设备验收。

## 参考设计

实施前对照了维护中的 [pi SessionManager](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/session-manager.ts)（[MIT](https://github.com/earendil-works/pi/blob/main/LICENSE)）：可持久化事实和模型上下文的投影分开。本项目继续复用已有 Dart 账本，不引入其 TypeScript/Node 存储依赖。

也对照了 [LangGraph persistence](https://github.com/langchain-ai/docs/blob/main/src/oss/langgraph/persistence.mdx) 与 [interrupts](https://github.com/langchain-ai/docs/blob/main/src/oss/langgraph/interrupts.mdx)（[MIT](https://github.com/langchain-ai/langgraph/blob/main/LICENSE)）。其恢复可能从节点开头重新执行，存在重复副作用；本项目按本次合同仅保存状态/中断标记、等待新用户输入，不采用自动重跑节点方案。只借鉴状态与暂停数据分离的设计，没有复制外部实现或添加依赖。

## 本轮验证记录

Coach 1206、UI 89、Trainer 332，共1627项全量通过；三包 `dart analyze --fatal-infos` 均无问题。快照模型/恢复专门31项通过，推荐卡新增10项。旧存档 `restoreHistory`、清空/取消/禁记忆/forget 原有测试继续通过。真实模型调用0次。

以下为固定本地恢复样本，经生产 OpenAI-compatible 请求序列化器测得 UTF-8 字节；不是网络或真实模型评测。首包均校验 system/tools → 确定性 user 摘要 → 新用户原话 → 当前状态，且没有 assistant/tool/reasoning。

|恢复样本|off B|on B|
|---|---:|---:|
|问答（含首尾空白/换行的新原话）|11,644|11,643|
|推荐|12,944|12,943|
|计划及后续缩短|14,143|14,142|
|待答 choice / answerText / 普通 send|12,418|12,417|
|进行中或取消结束后保存|13,589|13,588|
|仅外层独立账本、旧 state 内副本缺失|11,523|11,522|

全部低于 off 40,960 B / on 51,200 B 软阈值与65,536 B硬限。没有为了预算删原话、quote或交付文本。空会话和旧存档12KB检查继续通过。

Trainer首次执行因C盘临时目录空间不足未能完成；保留失败日志，仅把验证进程TEMP/TMP指向E盘后完成全量。Flutter工具自动添加的分析排除项已保存并恢复原配置，再执行严格分析；提交没有更改分析配置、SDK默认模型配置或上下文预算。
