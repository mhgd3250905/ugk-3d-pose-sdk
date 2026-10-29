# 外部保存计划与当前讨论计划

Coach 核心包是仓库根目录的 `ugk_coach`（纯 Dart）。宿主通过
`CoachConversationController` 选择自己保存的完整 `TrainingPlan`，SDK 将其导入
当前会话并绑定为讨论对象。选择本身不请求模型，也不自动添加可见聊天气泡，
现有对话计划卡的样式、展开与训练行为不变。

## 导入与监听

```dart
import 'package:ugk_coach/ugk_coach.dart';

// savedJson 来自宿主自己的计划存储。先严格解码，再提交完整计划。
final decoded = const PlanCodec().decodeStrict(savedJson);
if (!decoded.ok) {
  // 向用户呈现 decoded.issues；不要用宽容解码掩盖缺字段或坏剂量。
  return;
}
final result = controller.focusExternalPlan(
  externalId: savedId, // 宿主稳定且非空的保存记录 ID
  plan: decoded.plan!,
  title: displayTitle, // 可选；省略时使用 plan.title
);
if (!result.ok) {
  for (final error in result.errors) {
    print('${error.code}: ${error.message}');
  }
  return;
}
print('${result.planId} v${result.version}');

void onConversationChanged() {
  final focus = controller.focus; // 等同 controller.state.focus
  if (focus != null) {
    print('${focus.title}: ${focus.planId} v${focus.version}');
    print(focus.savedRef.toJson());
  }
}
controller.addListener(onConversationChanged);
// 页面销毁时 controller.removeListener(onConversationChanged)。
// 也可订阅 controller.states，每次状态中均包含当前 focus。
```

公开接口：

```dart
CoachPlanFocusResult focusExternalPlan({
  required String externalId,
  required TrainingPlan plan,
  String? title,
});
bool clearPlanFocus();
CoachPlanFocus? get focus;
```

`CoachPlanFocusResult` 提供 `ok`、不可变 `errors: List<PlanIssue>`、成功时的
`planId` 与 `version`。`CoachPlanFocus` 提供 `planId`、`title`、`version`、
`savedRef`，并支持 `toJson()`。导入、编辑交付、恢复和清除都会经过已有状态监听。

在控制器空闲时选择。请求中选择返回 `busy` 错误且不改变任何状态；关闭后的选择
返回 `disposed`。宿主可根据已有 `state.isWaiting` 禁用选择入口。
清除返回 `true`（控制器关闭后为 `false`）；若正有基于 focus 的请求，清除会立即
取消该轮，保留请求前的计划与历史并清掉绑定，迟到结果不会恢复旧 focus。

导入先复制并严格解码完整数据，再运行已有目录、结构、剂量、profile、场所、
器械、安全保护及宿主 `extraRules` 校验。未知动作（包含分段动作）、坏结构或
坏剂量会被拒绝；失败不更改会话、模型历史、展示消息或触发状态通知。
成功时的条件由选中计划提供，不借用之前计划的地点与动作；已有安全保护仍保留。

## 身份与版本

- `sessionState.plans` 以 `ext:<externalId>` 作为固定 `planId`，导入对象原有的
  `plan.id` 被替换为此 ID，其他计划及旧版本保留。
- 同 ID 首次导入为版本 1；与当前最新版本内容相同时复用版本，不同时追加版本。
  比较规范化后的完整内容，保留动作及步骤顺序，忽略 JSON 对象键和器械集合的顺序。
- 成功选择时 `activePlanId` 与 `focusPlanId` 都指向该计划。
- `savedRef` 是不可变 `CoachSavedPlanRef{externalId, baseVersion}`。
  `baseVersion` 表示本次从宿主选中内容对应的 **SDK 导入版本**，不是宿主数据库的
  乐观锁字段。后续编辑只增加 `version`，不会移动这个基准。
- 再次显式选择时，`savedRef.baseVersion` 更新为本次选中内容复用或新建的版本。
- `clearPlanFocus()` 仅清除 `focusPlanId` 与 `savedRef`；不删除计划、历史版本，
  也不清除当前 active draft。新建会话仍使用既有 `newConversation()`。

例如 A 已交付后选择保存计划 B：A 的数据保持原样，B 成为 active/focus。
对 B 的替换、插入、删除和缩时均在 B 的 ID 下追加版本，保留 B 原版。

## 模型可见的绑定

每次成功选择会在模型历史追加一条 `role=user` 消息，前缀固定为：

```text
用户从「我的计划」选中了计划（系统生成）：
```

后接 JSON，字段为 `plan_id`、`version`、`title`、`estimateSec`、`equipment`、
`items`。每轮末尾的“当前状态（系统生成）”还会带同结构 `focus_plan`。
它从会话中的最新版本即时生成，历史折叠或 export/restore 后仍完整携带，
没有 focus 时不输出该字段。

`items` 按 `blocks`、块内 `items` 的原顺序展平，`index` 从 1 连续编号。
每项包含 `actionId`、当前目录本地化 `name` 和结构化 `dose`。`dose` 保留
`mode`、`sets`、`reps/workSeconds`、`perSide`、`restSeconds`、可选备注与
`segments`，另带 `blockId`、`blockType`、`rounds`、`restBetweenRoundsSeconds`，
避免把循环轮数、分段与单侧剂量丢成一段文字。`estimateSec` 按既有 `PlanDuration`
计算，器械使用计划中的目录 ID。

系统提示约定：“这个计划”指 `focus_plan`；“第 N 个动作”指 `index=N`。
编辑沿用已有条件，不重新问地点，使用现有 `set_params(operation=edit)`、
`draft_plan`、检查及 `show_plan` 链路；未新增 `get_plan` 或 `edit_plan` 工具。
这些系统说明与下面的可选草稿字段只在 focus 存在时启用；无 focus 的既有
提示及工具 schema 保持原样，沿用原有请求字节预算。
现有 `draft_plan` 的动作项可选 `sourceIndex` 指向本轮 focus 的原始 index，
使重复 actionId 的不同剂量项也可精确保留、替换或删除；新动作不填写此字段。
一份草稿中只要使用了 `sourceIndex`，所有保留项均应显式引用，未引用项按新动作
处理；全部省略时兼容按相同 actionId 的出现顺序匹配。重复引用、越界或 ID 不匹配
会拒绝该草稿。
保留的旧项沿用完整原剂量与分段，明确缩时或改剂量时才从当前版本重新配时。

## 接收编辑后的卡片

既有 `CoachTurnResult.plan` 与 `CoachConversationMessage.plan` 仍是门禁构造的
`ValidatedPlan`。新增两个可选字段，不改变既有卡片渲染：

```dart
final turn = await controller.send('把第3个动作换一个，缩到5分钟');
final card = turn?.plan;
if (card != null) {
  final dataToPersist = card.plan.toJson(); // 完整新版 TrainingPlan
  final version = card.version;
  final savedRef = card.savedRef;
  if (savedRef != null) {
    // 由宿主决定何时保存/确认覆盖，SDK 不直接写宿主存储。
    // 用 savedRef.externalId 找原保存记录，baseVersion 识别本次导入基准。
    print('${savedRef.externalId}: ${savedRef.baseVersion} -> $version');
    print(dataToPersist);
  }
}
```

普通历史/模板 admission 可以没有 `version` 或 `savedRef`，宿主按可选字段处理。
focus 编辑交付时二者齐全，且 `controller.focus.version` 同步指向最新版本。
视觉组件仍使用宿主既有的数据映射；这些字段用于保存来源与版本识别。

## 会话持久化

```dart
final snapshotJson = controller.exportSession().toJson();
// 将 snapshotJson 与既有展示消息一起持久化；重启后：
final snapshot = CoachSessionSnapshot.fromJson(snapshotJson);
controller.restoreSession(snapshot, restoredDisplayMessages);
```

`sessionState` 包含 `focusPlanId`、`savedRef` 及全部计划版本。快照校验引用的
计划、外部 ID 和基准版本；坏引用走既有恢复回落，旧快照缺少这两个字段仍兼容。
恢复后继续编辑会基于 focus 最新版，`savedRef` 保留。旧的 `restoreHistory`
无 `sessionState` 路径也会从最后一张已准入计划卡补齐 `activePlanId`。

## 本次验证

| 包 | 全量测试 | 静态分析 |
| --- | --- | --- |
| Coach（仓库根目录） | `dart test --concurrency 1`：1278 通过 | `dart analyze --fatal-infos`：无问题 |
| Coach UI | `flutter test --no-pub`：111 通过 | `dart analyze --fatal-infos`：无问题 |
| Trainer | `flutter test --no-pub`：365 通过 | `dart analyze --fatal-infos`：无问题 |

新增 68 项回归覆盖导入拒绝的原子性、监听、重复选择版本、四类编辑、原剂量与
分段保留、重复动作的 sourceIndex、savedRef、预设回退、历史折叠、导出恢复、
损坏快照、请求中清除及迟到结果隔离。既有无 focus 的 schema 与请求字节预算
断言未放宽。Coach UI 和 Trainer 源码保持不变。
