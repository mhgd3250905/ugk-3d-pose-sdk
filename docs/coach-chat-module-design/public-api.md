# ugk_coach_chat 公开接口草案

这是设计提案，所有 `CoachChat*`、`CoachAppProfile` 和适配器签名均**尚未实现**。
代码块是评审用签名，不是已经可编译的示例或本次代码改动。主设计中的包划分、字段
命名与审批结论优先；此附录补齐所有权、失败和并发语义。

## 已存在的能力与新增层

当前设计基线为已合入 SDK main 的 `3fbd179063e9b8433cadd5387295ac07b7b93800`、SF
`3eb2a9e88ef4d28e02f4cf306c1716d61baa7f10`。
SDK 现有 `CoachConversationController` 已提供 `send`、`answerText`、
`answerChoices`、`answerForm`、`skipQuestion`、`cancel`、`newConversation`、
`focusExternalPlan`、`clearPlanFocus`、`exportSession`、`restoreSession`、
`restoreHistory` 和异步 `dispose`。`CoachPlanFocus`、`CoachSavedPlanRef`、
`ValidatedPlan`、`CoachSessionSnapshot`、`UserMemoryStore` 继续复用。

新模块承接 SF 的 `ChatHomePage`、`ChatController`、`AiChatEngine`、对话展示模型和
适配层中通用能力。一个 `CoachChatController` 私有持有**一个**长生命周期的
`CoachConversationController` 和其唯一 `CoachAgent`；App 不再维护另一套 Agent、
plans、activePlan/focus、问题回答状态或历史折叠逻辑。模块可保留 SF 原有问候、安全
对话、训练返回消息等本地展示行，并以 SDK 消息 ID 关联派生视图；它们不会反向成为
第二套模型事实，也不会自动进入模型历史。

已拍板的实施依赖为 `ugk_coach_chat → ugk_coach + ugk_coach_ui + ugk_trainer_runtime`。
`ugk_trainer_runtime` 是已批准拆分、尚未实现的无全量动作素材播放内核；旧 `ugk_trainer` 作为兼容外壳
转导出同一内核。`SessionResult`、`SessionBuilder` 与执行回调扩展必须是**相同 Dart
类型和同一份实现**，不复制一套 DTO。`ugk_coach_ui` 继续只收普通展示数据、不依赖
Coach；纯 Dart 核心不反向引用 Flutter/chat；新模块不 import 任何 App 路径或全局单例。

## 模块与宿主的责任

| 能力 | 模块自有 | 宿主提供 |
| --- | --- | --- |
| 整页与交互 | 原 SF 页面布局、星场/空态、输入栏、建议语、菜单、键盘与滚动、等待卡、出卡动效、错误行、问题表单 | App 壳插入一个 `CoachChatPage`，主题/图标/剪影来自配置档 |
| 计划与讨论 | 计划卡及详情视图、保存/更新/另存交互、focus 标签、训练返回消息、版本与出处展示 | 计划存储适配、开始训练回调；“我的计划”页面与 CRUD 仍由 App 持有 |
| 对话事实 | 单一 Agent/Controller、历史与快照格式、重建/取消/新对话、发到对话、来源校验 | 历史读写存储；旧 SF 数据的一次性读取适配 |
| 设置与安全 | SF 已有安全问答、承认/重新核对流程、开关对话语义和文案 | 设置/安全承认的持久化适配与宿主设置页面；不能移除 SDK 核心安全校验 |
| 动作 | 校验 ID 范围、生成名单内卡片与训练请求 | 配置档对应的目录数据、素材 resolver；宿主动作库/动作详情页 |
| 网关与记忆 | 构造一次 Agent、既有重试/预算/取消规则、记忆工具的逻辑 | `LlmConfig`、`AuthProvider` 或受测 `LlmClient` 工厂、现有 `UserMemoryStore` |
| 诊断 | 可选的无私有内容事件出口 | 原 SF 日志、开发菜单、性能实验室保留宿主；不复制诊断页面入 SDK |

“设置仍在 App”指页面和存储，不能让 App 再实现一套识别用户输入、改写消息或处理
表单的对话逻辑。“我的计划仍在 App”指计划库 CRUD/编辑/排序，聊天中的卡片、讨论、
更新原保存/另存交互与详情体验由同一个模块负责。

## 页面与控制器

```dart
// 拟议签名；类型均为草案，现有 Core/Trainer 类型保留原身份。
class CoachChatPage extends StatefulWidget {
  const CoachChatPage({
    super.key,
    required CoachChatController controller,
    ScrollController? scrollController,
  });
}

class CoachChatPlanDetailsPage extends StatefulWidget {
  const CoachChatPlanDetailsPage({
    super.key,
    required CoachChatController controller,
    required CoachChatPlanReference plan,
  });
}

class CoachChatController extends ChangeNotifier {
  CoachChatController({
    required CoachAppProfile profile,
    required Catalog catalog,
    required CoachChatBindings bindings,
    CoachContext context = const CoachContext(),
    DateTime Function()? clock,
  });

  CoachChatState get state;                  // 不可变派生 UI 状态
  CoachPlanFocus? get focus;                 // Core 的当前 focus
  Stream<AgentEvent> get events;             // 同一 Agent 事件
  Future<CoachChatOperationResult> start();  // 复原/安全流程，幂等
  Future<CoachTurnResult?> send(String text);
  Future<CoachTurnResult?> answerText(String questionId, String text);
  Future<CoachTurnResult?> answerChoices(String questionId, List<String> values);
  Future<CoachTurnResult?> answerForm(
      String questionId, Map<String, List<String>> values);
  Future<CoachTurnResult?> skipQuestion(String questionId);
  void cancelRequest();
  Future<CoachChatOperationResult> newConversation();
  Future<CoachChatOperationResult> dispatch(CoachChatCommand command);
  CoachChatPlanDetailsPreparation prepareSavedPlanDetails(
      CoachSavedPlanSelection selection);
  Future<CoachChatFocusResult> sendPlanToConversation(
      CoachSavedPlanSelection selection);
  Future<CoachChatOperationResult> regenerateFromScopePreview(String previewId);
  Future<CoachChatFocusResult> adoptAndSaveScopePreview(String previewId);
  Future<CoachChatOperationResult> clearPlanFocus();
  Future<CoachChatOperationResult> savePlanCard(
      String messageId, {bool saveAsCopy = false});
  CoachChatSnapshot exportSnapshot();
  Future<CoachChatRestoreResult> restoreSnapshot(CoachChatSnapshot snapshot);
  Future<void> flushPersistence();
  Future<void> close();
  @override void dispose();
}
```

`CoachChatState` 暴露只读消息行、suggestions、waiting、当前表单/安全流程、保存状态、
focus、`actionScopeNotice` 和操作错误。消息行中的计划只引用 gate-admitted 的 `ValidatedPlan` 或明确的
不可用占位，不提供“任意 JSON 伪造已验证计划”的公开构造器。`CoachChatPlanReference`
包含计划 ID、版本与内容摘要，由模块签发而非任意公开构造，不能只以标题查找；来自
“我的计划”的入口须先准入。
`CoachChatPlanDetailsPage` 复用原 SF 详情体验，可供宿主“我的计划”薄壳使用；聊天不再
通过回调 push 一整页 SF `PlanPage`。

宿主“我的计划”使用 `prepareSavedPlanDetails(selection)` 取得模块签发的安全 reference。
它返回合法只读 reference、明确的 scope 修复 preview 或拒绝原因，验证当前 profile/
scope、结构与剂量；没有通过就不能靠构造 reference 打开可执行详情。该准备入口不改
Core plans、active/focus、messages，不导入外部计划，不发模型请求，查看详情不会成为
“已选中讨论”。reference 绑定具体内容摘要、scope 身份和其独立保存绑定，不能拿同 ID
不同内容替用。详情可读准入不授权开练；点击训练时仍 fresh 校验 scope、剂量、安全与
卡片/执行双时长，并使用同一个 builder。需要讨论时才显式走 sendPlanToConversation。

`CoachChatCommand` 使用枚举/有类型的 payload，区分 `newConversation`、`showHistory`、
`showLastPlan`、`recheckSafety` 与宿主导航。新对话由模块处理。`@drawer`、`@saved:*` 等
旧字符串只在迁移兼容器读取受信的原结构化操作时映射；用户随意输入同样字符串仍是
普通文本，模型工具也不能借此执行导航、设置或保存命令。

### 范围决策与只读告知

范围路径由 `profile.conversationPolicy` 的固定配置决定，模型不能自行关闭隔离或
选择不同处理方式。主设计定义字段与取值；API 层保证以下分支及优先级：

| 当前请求 | 模块必须执行的行为 |
| --- | --- |
| 伤痛/安全规则命中 | 先执行已有安全阻断与说明，不能为了满足请求、填满时长或提供替代而绕过 |
| 部分需求在范围外，其余需求可支持 | 在名单内检索语义最近、同时满足安全/器械/剂量规则的替代；没有合规替代时去掉该项。最终交付必须明确告知已替代/未纳入哪些要求 |
| 整个需求超出专长 | 不生成名单外计划；说明本 App 专长并给范围内建议 CTA，点击后才作为新的明确用户选择继续 |
| 用户坚持名单外动作 | 如实说明当前模块不提供该动作，拒绝编造可执行计划，不把其他动作改名充数 |

部分需求的替代/删除不等于接收非法草稿。原始 draft 若含名单外父 ID、segment 或
其他可执行引用，gate 仍拒收、保持已有计划不动，走已有的重出草稿链路。交付只接收
重新生成、通过白名单与全部既有校验的合法计划。替代后数量不足、合法剂量下无法
达到目标时长时继续原上下界/增删方向/重编流程，不截断、不扩大范围、不交付近似
计划。卡片与同时间线执行时长都须在 ±10% 内，手动计次仍标“估算”且无豁免。

拟议 `CoachChatState.actionScopeNotice` 是模块产生的只读结果，按 request/turn 与
最终 planId/version 关联，包含决策、受影响要求的原序号、用户原文或显式请求 ID、
最终替代 ID/删除状态及原因码。替代 ID 必须已通过 gate，不能把模型一句“已替换”
当成事实。模块从已确认的结构化请求与最终合法计划差异生成告知文案；无法证明
逐项语义对应时只能明确说明未纳入的要求，不冒称找到了等价替代。UI 固定展示该
告知，不由宿主额外拼接，也不允许成功出卡时漏掉。全部超范围/坚持外动作的回应
可无计划，仅给说明与允许的 CTA。此结果不开放任意 setter，也不新增模型工具。

`profile.conversationPolicy.outOfScopeGuidance` 可选、默认 disabled，默认回应不提其他 App。可选启用的说明
和跳转目标只能来自已审核配置；模型不能临时推荐/命名另一个 App 或生成外部动作
链接。启用带跳转的 guidance 时由宿主提供明确导航回调，只在用户点击时执行。
该开关不改变白名单、安全优先级或双时长门禁。

### 生命周期与所有权

1. 构造器不做 IO；首次 `start()` 校验配置/受限目录，读取适配器，构造唯一 Client、
   Agent 和 Core Controller，随后恢复快照或启动原 SF 安全/问候流程。重复 start 合并
   为同一 Future，不重复请求模型。页面调用 start 但不取得 Controller 所有权。
2. App 拥有注入的 Controller；页面自身仅释放内部 FocusNode、滚动状态和订阅。
   传入的 ScrollController 仍由调用方释放。离开页面但保留对话时不新造 Agent。
3. 取消、新对话、恢复、关闭递增 generation，原请求、进度和保存通知迟到时不能添加
   卡片、复活表单或覆盖新会话。用户双击发送不排队，沿用 Core 现有并发规则。
4. 新对话取消旧请求、清除 focus/模型和显示历史、保留同一个 Agent。已保存计划、
   训练记录、安全承认和用户记忆保持原 SF 语义，不能顺便删除宿主数据。
5. `close()` 先封存当前快照、取消请求/定时器，再串行 flush、销毁 Core、履行网关 lease。
   App 退出/切换账户时推荐 await close。ChangeNotifier 的 `dispose()` 保持同步，
   幂等启动同一 close 流程并停止通知；不能先 reset Agent 后才读取待写快照。
6. History 写入按捕获顺序串行，保留 SF 的 80ms 合并与显式生命周期 flush 行为；慢旧
   写入不能覆盖新 focus。保存错误显示原错误/重试交互，不能返回“已经保存”。
   关闭后的写失败只走明确诊断/关闭 Future，不向已销毁 notifier 发通知。

## 宿主绑定与导航回调

```dart
class CoachChatBindings {
  const CoachChatBindings({
    required String storageNamespace,
    required CoachGatewayBinding gateway,
    required CoachPlanStorageAdapter plans,
    required CoachChatHistoryStore history,
    required CoachChatPreferenceStore preferences,
    required UserMemoryStore memory,
    required CoachChatHostActions actions,
    CoachChatObserver? observer,
  });
}

class CoachGatewayBinding {
  const CoachGatewayBinding({required LlmConfig config, required AuthProvider auth});
  factory CoachGatewayBinding.clientFactory(
      Future<CoachGatewayClientLease> Function() acquire);
}

class CoachGatewayClientLease {
  const CoachGatewayClientLease.owned({
    required LlmClient client,
    required FutureOr<void> Function() release,
  });
  const CoachGatewayClientLease.shared({required LlmClient client});
}

class CoachChatHostActions {
  const CoachChatHostActions({
    required Future<SessionResult?> Function(
        BuildContext context, CoachChatTrainingRequest request) onStartTraining,
    required Future<void> Function(
        BuildContext context, CoachChatActionOpenRequest request) onOpenAction,
    required Future<void> Function(BuildContext context,
        CoachChatLibraryOpenRequest request) onOpenLibrary,
    required Future<void> Function(BuildContext context) onOpenSavedPlans,
    required Future<void> Function(BuildContext context) onOpenCustomPlan,
    required Future<void> Function(BuildContext context) onOpenSettings,
    void Function(CoachSavedPlanSnapshot saved)? onSaved,
    Future<void> Function(BuildContext context,
        CoachOutOfScopeGuidanceTarget target)? onOpenOutOfScopeGuidance,
  });
}
```

网关工厂仅在创建会话依赖时运行一次，不能每次重建 Widget 就建 Agent。
`LlmClient` 本身**没有 close 接口**，模块不得对泛型 client 承诺或调用 client.close。
owned lease 的实际 release 回调由创建者提供，模块在关闭及初始化失败后的清理中
确保至多调用一次；shared lease 不释放共享资源，由宿主负责最终生命周期。内建
LlmConfig/AuthProvider 路径可创建具体 OpenAiCompatibleClient，并把该具体实现的
closer 注册进 owned lease。Core 销毁和 lease 释放通过 finally 衔接，不能因一个
释放步骤失败而漏掉另一个，也不能用 ownsClient 布尔值推断不存在的泛型方法。
`LlmConfig/AuthProvider` 沿用 SDK 现有接口，不把 key、headers、设备标识读取逻辑、
回调闭包或完整网络日志写进配置 JSON/会话。`storageNamespace` 是宿主给出的不透明
数据槽标识，与 appId 一起隔离账户/安装数据；切换数据槽关闭旧 Controller 后新建，
不拼接旧消息。

`onOpenAction` 只有通过白名单和可用性检查后才会调用，请求只包含该 ID、来源消息和
展示入口。回调打开宿主拥有的动作库详情。宿主导航均由宿主 push，模块负责原
SF 收菜单、关闭键盘以及返回后焦点行为；不要求宿主重写任何对话 Widget。

`CoachChatLibraryOpenRequest` 拟含 `initialCategoryId?` 和 sourceEntry，保留 SF
`@library:<category>` 的有类型参数（strength/core/cardio/mobility/stretch 等原类别由
当前 profile 映射和校验）；无参数 `@library` 则 initialCategoryId=null。
`onOpenCustomPlan` 对应原 `@custom`，打开宿主“我的计划”中的自定义编辑页，不把
编辑器复制进对话模块。原受信命令映射完整保留这两个分支；补齐接口不意味着新增
菜单按钮或改变旧显示条件，原布局、交互及深浅色仍按 SF 基线验收。

`onSaved` 只通知保存成功，可用于刷新宿主页面，**不能再保存一次**。用户要求的保存
回调通过 `plans.save(request)` 执行唯一写入；宿主可以用现有保存函数实现该方法，
不再同时暴露另一个有写入副作用的 `onSave`。

### 训练开始与返回

`CoachChatTrainingRequest` 拟包含 `ValidatedPlan plan`、`sourceEntry`、来源消息 ID 和
幂等的 `Future<bool> onStarting()`。onStarting 由模块封装安全检查、确认当前版本、
记录“上次那个”和必要的计划 touch；宿主沿用 SF `openTraining` 的调用顺序：先冻结
来源视口，再清键盘，再 await onStarting；false 时不开练，返回 null。

模块拦重复启动。宿主复用 `TrainerSlideRoute` 与播放器的 startGate/beforeExitPop/
onExitStarted、海报和既有保存错误处理。路由进入完成前不起计时或语音，不在此处
另造训练计时器。App 的动作库及“我的计划”入口也可使用同一训练打开适配。

`onStartTraining` 只在真正 pop 成功后返回播放器已保存的**同一个 SessionResult receipt**。
Trainer 的 onFinished/onCompleted、保存重试和 completeReceipt 责任保持原样；模块
不会再写一次训练结果。返回 null 不伪造完成消息。模块按 `sessionId` 幂等增加原 SF
训练返回消息/保存提示与滚动动画，同一 receipt 重复通知不重复出行。

## 计划存储与保存版本

```dart
abstract interface class CoachPlanStorageAdapter {
  Future<List<CoachSavedPlanSnapshot>> load();
  Stream<CoachSavedPlansChanged> get changes;
  Future<CoachSavedPlanSnapshot?> read(String externalId);
  Future<CoachPlanWriteResult> save(CoachPlanWriteRequest request);
}

// 请求模式：create / copy / update；update 必须带期望 revision。
class CoachPlanWriteRequest {
  // admittedPlan、sdkVersion、savedRef、mode、name、idempotencyKey
  // externalId、saveBindingId、expectedStorageRevision（仅 update）
}
class CoachSavedPlanSnapshot {
  // externalId、title、完整 TrainingPlan、sdkVersion?
  // storageRevision（宿主不透明 CAS token）、更新时间
}
class CoachPlanSaveBinding {
  // 不可变、模块签发的 saveBindingId
  // externalId、sdkBaseVersion、sourceContentDigest
  // sourceMessageId 或 importId、originalStorageRevision
}
```

所有读写适配都属于宿主存储域，不由 SDK 新建另一个计划库。“我的计划”与聊天使用
同一适配数据源。保存前重新准入动作 ID/剂量/版本；`ValidatedPlan` 也不能绕过运行中
配置身份检查。update 原子比较 `expectedStorageRevision`；结果显式区分成功、冲突、
已删除、不可写和失败。对已删除或冲突的记录，保留卡片并显示原更新/另存选择，不
静默覆盖、自动创建同名替代记录或把失败 toast 写成成功。

**两个版本分离已拍板，不能混用**：

- 现有 `savedRef.baseVersion` 是导入外部计划时的 **SDK 会话计划版本**。同 ext ID 的
  后续编辑追加 SDK version，baseVersion 保持导入基准，不能改变既有协议含义。
- `storageRevision` 是宿主计划库的并发更新凭据。模块在选择已保存计划时记住它，
  更新用该值 CAS；它不能用 savedRef.baseVersion、计划名或内容哈希代替。

保存授权必须绑定**这一张卡的来源**，不能维护 `externalId → 最新 storageRevision`
全局映射后让旧卡读取。每次明确的导入/选择创建不可变 `saveBindingId`，绑定
`(externalId, SDK baseVersion, sourceContentDigest, sourceMessageId 或 importId)`
与当时的 `originalStorageRevision`。卡片及其编辑后消息引用对应 binding；SDK 相同
内容复用同一计划版本，也不能合并两次导入的 binding 或覆盖旧卡的 CAS token。
宿主 store 的 changes/read 最新记录只刷新存在性/展示信息，不会自动授予旧卡新 token。

两个消息同时修改同一保存记录时，只有符合原 revision 的一项成功；另一项明确冲突。
重复点击或重试使用稳定 idempotencyKey（namespace/消息 ID/SDK version/binding/操作），
适配器返回同一次写结果。用户选择“另存”才创建新 externalId；不会改动旧保存。
成功后由适配器返回新 storageRevision，回执只关联该次 idempotencyKey、原卡片、
提交版本和 binding，不全局给同 externalId 的旧卡或其他消息授信，也不覆写旧 binding。
卡片保存状态可以根据该回执更新；该次已授权的成功结果可以派生**新的继任 binding**，
绑定刚保存的确切内容/版本与新 token，仅供这个成功结果之后产生的编辑继承。已存在
旧卡、并行编辑分支及其 binding 仍保留原 token，不因某次写成功而获新授权。
因此“更新→继续编辑→再次更新”无需无谓增加确认弹窗，而旧卡仍不能覆盖外部或其他
分支的新内容。外部 changes/read 后想刷新旧卡目标，必须用户明确选择并生成对应新
binding；不能更新 Agent 的 SDK 编辑基准去假装模型重新选中过保存计划。

必须补并发回归：S 在 r1 导入为 SDK base v1，旧编辑卡 v2 引用 B1/r1；宿主把 S 改成
r2，再显式导入为 SDK base v3，产生 B2/r2。旧卡更新仍携带 B1/r1，必须 CAS 冲突，
不能借 B2 或最新索引覆盖 r2。export→restore 后也必须如此；同 externalId/同内容的
SDK 版本复用也不得改写 B1，成功写入的幂等回执不能改变其他旧卡授权。
再补同一成功保存结果的后续编辑能持继任 binding 正常更新，同时旧分支仍冲突的用例。

### 发到对话

宿主“我的计划”选择一条记录后调用 `sendPlanToConversation(selection)`，selection
包含外部 ID、完整有序计划、标题和 storageRevision。模块先进行 scope/schema/dose
准入，再复用现有 `focusExternalPlan`，计划 ID 仍为 `ext:<externalId>`，版本复用与
追加规则保持原协议。导入失败时不增加会话消息、不改 active/focus/保存来源、不发模型
请求。`CoachChatFocusResult` 返回原 Core 错误列表，可另带只读 `scopePreview`，由模块
提供的预览/CTA 组件呈现；不能把预览伪装成成功的计划卡或“已选中讨论”。busy 时明确
拒绝，不暗中取消用户正在等待的轮次后导入，也不排队偷偷执行。

已有保存计划不采用普通新请求的自动替代/删除后直接导入路径。范围不合法时，先拒绝
这一导入事务，原保存、原消息与讨论绑定保持不动；预览只列明范围内可能的替代/
删除方案、受影响项和是否仍需生成，不写数据库，不调用 Core focus。预览身份绑定
当前 profile/scope、源计划内容摘要及原 storageRevision，过期后重新校验。

两个 CTA 的语义明确分开：

- **推荐“按范围内方案重新生成”**：调用 `regenerateFromScopePreview`，用户明示接受
  后才进入普通新 plan task，必要时调用模型。它是一轮新的生成请求，不是 focus
  导入的一部分。沿既有 activePlanId/版本编辑链处理新计划和后续调整；不借用原保存
  的 externalId/savedRef，也不要求显示外部保存 focus 标签。原保存不修改、不自动另存。
- **可选“采用并另存为新计划”**：调用 `adoptAndSaveScopePreview`，先把候选做完整
  白名单、结构、剂量、安全和双时长校验，再以明确的 create/copy 意图交给 adapter。
  只有新 externalId/storageRevision 创建成功后，才对这份完整合法的新保存计划调用
  原 `focusExternalPlan`；原保存记录不覆盖。候选尚不完整或需模型重新生成时不能
  先保存，先走前一条明确生成路径。创建失败不设置 focus；创建成功但后续 focus
  失败则准确报告新保存已存在及导入失败，重试只用同一新记录，不能重复创建。

上述行为不新增本地未保存 focus 域、focus 类型或 Core 入口。未保存的新生成计划按
原普通计划行为展示；“未保存候选直接 focus”属于以后单独评估的需求，不是本次
抽取的实施前提。任何 CTA 都不能暗中改宿主库，也不能宣称原非法计划已成功导入。

成功时模块按原 SF 展示外部计划与讨论标签，并把显示历史、Core session、导入的
不可变 saveBinding 作为同一个持久化操作提交；展示卡引用本次导入的 saveBindingId，
不能按 externalId 动态查“最新令牌”。`CoachChatFocusResult` 包装现有
`CoachPlanFocusResult`，另列 persisted/persistenceError 和可选 scopePreview：合法 focus 已提交但磁盘写入
失败时，不能谎报“导入被拒且状态未变”，也不再次导入增版本；保留当前 focus，显示
保存失败并只重试同一份持久化快照。非法计划/busy 则 Core 结果明确失败、persisted=false，
所有会话状态保持原样。合法选择/focus 本身不调用模型，预览 CTA 的新生成请求单独
计为用户操作与模型轮次。随后“这个计划”
与“第 N 个动作”仍由 Core focus 的完整有序 items 解释；不新增 get_plan/edit_plan
模型工具。宿主只负责导航回聊天；无需手工追加用户气泡或拼一段 JSON 到模型。

## 历史、设置与快照

```dart
abstract interface class CoachChatHistoryStore {
  Future<CoachChatSnapshot?> load(String namespace);
  Future<void> write(String namespace, CoachChatSnapshot snapshot);
  Future<CoachChatHistoryContext> readTrainingContext();
  Future<void> rememberStartedPlan(
      TrainingPlan plan, {String? savedExternalId});
}

abstract interface class CoachChatPreferenceStore {
  Future<CoachChatPreferences> load();
  Stream<CoachChatPreferences> get changes;
  Future<void> update(CoachChatPreferenceChange change);
}

class CoachChatSnapshot {
  // 独立 envelopeSchemaVersion；appId、storageNamespace、profileRevision
  // catalogVersion/catalogSha256、allowlistSha256、dosePolicyRevision
  // 现有 CoachSessionSnapshot + 对话显示消息/本地展示行
  // saveBindings：按 saveBindingId 保存全部仍被旧卡/操作引用的不可变来源绑定
  // 每条含 externalId、SDKbaseVersion、sourceContentDigest、消息/importId、原始storageRevision
  // 卡片 -> saveBindingId 引用，以及按 idempotencyKey 关联原卡/提交版本的写入回执
}
```

Preferences 包括原安全承认及版本、重新核对答案、训练许可、外观与声音开关等持久
事实。模块拥有问答和控制行为，宿主设置页面通过同一 store 修改；安全许可不能仅
由普通输入文字或模型建议置 true。`UserMemoryStore` 原接口直接注入，不重复设计一套
记忆库；新对话不顺便清记忆，用户显式关/清记忆仍走原 Core 规则。

`readTrainingContext` 读取宿主已有的“上次计划”和训练历史，只为原 `@last/@history`
对话功能提供输入；`CoachChatHistoryContext` 是 SF 现有 WorkoutLog 的只读展示投影
（标题、时间、分钟、完成数/总数），可带已有 SessionResult 的引用，不是新的结果
保存格式。模块处理呈现与命令语义，宿主仍只适配数据读取。`rememberStartedPlan`
映射原 SF store.rememberPlan/touchPlan，由幂等 onStarting 调用，更新上次计划与使用
时间；它不开始 Recorder、不保存完成结果、不再记一次训练。返回 receipt 后历史
仍读取 Trainer 宿主已经写入的同一数据源。

新 envelope 与现有 `CoachSessionSnapshot.currentSchemaVersion=1` **分别版本化**，
不能修改旧 schemaVersion 来冒充完成迁移。历史显示与模型状态一同保存，但职责
分离：模型只恢复受检的 Core snapshot，显示消息不能补造已确认参数、版本或工具
回执。动画中间进度、FocusNode、Widget、闭包、网关配置和私有 reasoning 均不序列化；
恢复时原历史不重复播放进场。

恢复先比较 appId、namespace、profile/剂量策略与目录/白名单身份，并校验所有计划
版本、segment、推荐、focus、活动计划和 ledger 中的动作引用。范围变化、跨 App、
缺失语义或无法证明安全的旧快照，不能直接交给 Core 的 legacy fallback 路径继续
模型请求。返回有类型的恢复问题，保留原存储用于回滚；可显示明确的只读不可用占位，
不能带出名单外缩略图、剂量/动作卡或删掉几项后假称原计划合法。模型会话从已验证
迁移结果开始，迁移无法完成时新建空会话并如实说明。

保存绑定必须完整往返，不能恢复时折叠成每 externalId 一条最新绑定。旧历史若缺少
可证明对应关系的 CAS binding，只读展示仍可按准入结果处理，更新原保存须先请用户
显式确认目标并新建绑定；不能从最新计划库补一个 token 假装原卡已有授权。

SF `chat`、`coachDisplay`、`coachSessionJson` 的一次性适配归模块 migration 层，宿主
只读取原存储。先读取原始资料、decode/重新准入、写入新 envelope、回读校验并登记
迁移标记；原字段不清理。中途失败不写完成标记，下次可幂等重试。现有历史上限、
pending question 恢复、focus/savedRef 与已取消请求状态必须有对应回归，再谈替换。

## 配置档与执行回调绑定

拟议 `CoachAppProfile` 字段统一为：`appId`、`revision`、`scopeManifest`、`coachProfile`、
`doseOverrides`、`conversationPolicy`、`strings`、`visual`、`executionTiming`。
`conversationPolicy.outOfScopeGuidance` 可选、默认 disabled；可提供顶层只读 getter，
但不能再存第二份值。范围处理字段的具体命名与默认值以主设计中的
配置档表为准；本附录不另设互相矛盾的开关。
`allowedActionIds` 是 `scopeManifest.allowedActionIds` 的只读访问，不再存一份可能
不一致的名单。manifest/文案/策略可以版本化配置；运行时主题实例、图标 Widget/
Painter、剪影 renderer 与执行闭包由宿主装配，不存入会话 JSON。

新模块要求 `executionTiming` **非空**，沿用已合入 main
`3fbd179063e9b8433cadd5387295ac07b7b93800` 的
`PlanExecutionTimingCallback = PlanExecutionTiming Function(TrainingPlan)`。
输出是 totalSeconds、各 block 明细和 containsManualCounting，必须同步、纯函数、无
IO，并来自播放器实际同一个 SessionBuilder/同一个无 IO 配置工厂；素材与语音配置
在绑定前加载。旧 Core Agent/旧接入仍允许 null、行为保持旧版。

draft/refit/范围/交付门禁都使用同一回调，卡片与执行都须 ±10%。回调非法或抛错阻止
交付并返回明确错误，不回落卡片估时。手动计次显示“估算”且不免除数字门禁。宿主
接入测试须断言 callback 总和等于其播放器实际 phases 总和；每个 App 分别验证，
不能把 SF 的准备/节奏/语音配置拿来代替 HipLab 或托马斯。

## 已定约束与其余接口建议

| 问题 | 推荐 |
| --- | --- |
| 一个 onSave 回调与计划 adapter 双写 | 只保留 adapter.save 为写路径，onSaved 为无写入通知；App 旧保存函数放进 adapter |
| 保存的 SDK baseVersion 与 CAS | 已拍板：独立宿主 storageRevision，旧 savedRef 语义不改 |
| 播放 runtime 与旧完整资产包 | 已拍板：拆 asset-free runtime、旧 wrapper 转导出同一实现；迁移后的 Chat 不依赖旧全资产包 |
| 页面是否可替换任意消息/输入栏 builder | 首次迁移不开放整页行为替换；仅主题、图标、剪影等已定插槽，保证三 App 同一模块 |
| 计划详情归哪个 App | 模块提供统一详情页/视图，宿主我的计划只保留入口和 CRUD 薄壳 |
| Controller 怎样异步销毁 | close 负责顺序 flush/异步释放，dispose 同步幂等封口；不能要求 Widget.dispose await |
| 旧快照范围不匹配时删动作后恢复 | 保留原资料、明确拒绝活跃恢复或经受测迁移；禁止删项改变原序号和用户选择 |
| 宿主当前缺少原子 CAS/写入幂等 | 适配器先补合同测试再启用“更新原保存”；不把无条件覆盖当等效适配 |
| 新 API 的执行时长依赖 | 依赖已合 main 的 3fbd179；实施统一使用同一 builder 合同，设计分支只记录方案，不重复搬运行代码 |

以上签名的源依据是 SF 的控制器/页面行为和 SDK 已有接口；实际提取时以原版交互及
逐帧验收裁决。没有因为 API 草案而授权新的字体、色值、间距、动效或第三方状态管理
依赖，也没有声称这些新接口已实现或已通过 App 门禁。
