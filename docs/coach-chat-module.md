# 统一教练对话模块接入

`packages/ugk_coach_chat` 从 SF `3eb2a9e88ef4d28e02f4cf306c1716d61baa7f10` 提取，
基于 SDK main `67c9747b8e29955d2be21c020c5ef3881b4966e6`。本批只交 SDK 包，App/pin 不变。
完整例子见[新包 README](../packages/ugk_coach_chat/README.md)。

聊天页已支持可选的 [QA 问答 Agent](coach-qa-agent-v3.md)（当前为 v3，兼容配置名保留）：App 在 profile 中设置
`agentMode: CoachChatAgentMode.qaV2` 并提供 `aiTags` 即可启用；默认旧版保持兼容。

## 所有权与公开入口

模块持有一个 `CoachConversationController` 和同一个 `CoachAgent`，复用原工具循环、
配时、安全、scope 与卡片/执行双时长规则。没有第二份计划模型或播放引擎。

| 入口 | 用途 |
| --- | --- |
| `CoachAppProfile` | appId、manifest、CoachProfile、范围策略、执行回调、文案、视觉、剂量覆盖 |
| `CoachChatBindings` | namespace、网关 lease、计划/历史/偏好存储、宿主导航/训练、记忆、观察者 |
| `CoachChatController` | 发送/问题回答、取消/新对话、安全流程、保存、focus、恢复和训练返回 |
| `CoachChatPage` | 原页、输入/菜单、键盘、等待/交付、卡片、标签、星场及滚动 |
| `CoachChatPlanDetailsPage` | 共用训练图文详情；通过 `CoachChatPlanReference` 打开 |
| `CoachChatSnapshot` / `CoachChatLegacyData` | 新 envelope 与原 SF 三字段的读取迁移 |
| `CoachChatVisuals` / `CoachChatPalette` | 浅深主题、字体、原品牌图标/剪影及媒体端口 |
| `CoachPlanStorageAdapter` 及 `CoachPlanWrite*` | create/copy/update 与显式 CAS 结果 |

控制器构造参数：`profile`、`catalog`、`bindings` 必填；可选 `context`、`replyDelay`
（原 450ms）、`prepareReply`、`turnTimeout`（原 390s）、`clock`。
页面参数为 `controller`，可选 `scrollController` 和 UI `clock`；宿主拥有传入对象。
UI clock 默认为系统时间，采集时可固定，原动画数值没有更改。

控制器主要方法沿用同一个会话：`start/send/answerText/answerChoices/answerForm/skipQuestion`、
`cancelRequest/newConversation/dispatch`、`savePlanCard`、`sendPlanToConversation/clearPlanFocus`、
`prepareSavedPlanDetails`、`exportSnapshot/restoreSnapshot/importLegacy`、
`startTraining/completeTraining`、`flushPersistence/close/dispose`。
兼容源页面的 message 参数方法也保留，不要求 App 再实现一套问答/保存逻辑。

SF 接入反馈修复新增三个可选端口：

```dart
// “我的计划”空态：返回后聚焦同一个 SDK 输入框。
onCompose: () { Navigator.of(context).pop(); chat.requestCompose(); }
// CoachChatBindings：归档旧完整快照，完成后 SDK 才 reset，并放行排队输入。
beforeNewConversation: (snapshot) => archive(snapshot.session.toJson()),
// observer 的 chat.user 详情为 CoachChatUserInput；显示与模型仍使用 trimmed 文本。
```

原话使用 `rawText`，模型输入使用 `sentText`，`displayLabel` 单独保留。监听端应按
`messageId` 防止与原显示监听重复记日志；使用新归档钩子后移除 reset 后猜测归档的旧适配。
归档失败发 `chat.archive.error`，仍继续新对话，不把诊断错误写入聊天正文。

## 配置与实际边界

显式名单与素材闭包沿用[Scope 接口](coach-scope-manifest.md)及
[runtime 资产工具](trainer-runtime-split.md)。只有目录/工具暴露、实际计划准入和
素材打包三处检查；跨 App 历史、外部 focus 和开练也是计划准入入口。
主题、普通显示消息及既有回执不做鉴真、深层引用遍历或多重版本/目录绑定。

`doseOverrides` 按 ID 投影实际 catalog 剂量/范围/节奏，不能只换显示文字掩盖执行差异。
可选 `unitLabel` 同时用于普通项和分段的卡片/详情剂量。`executionTiming` 必须是
播放器实际同一 builder 的同步纯函数，无 IO；卡片与执行均须 ±10%，异常不静默回退。

`visual.iconBuilder` 拿到 glyph、size、color、filled、strokeWidth，可原样用宿主
CustomPainter。剪影 renderer 继续处在现有任务卡 RepaintBoundary 中。
媒体资源由宿主白名单资产包提供；包本身只依赖 asset-free runtime，不包含动作素材。
源 App 的品牌图标、实际素材解析、网关凭据和原数据库实现保留宿主。

## 保存、恢复和训练

计划保存唯一写路径是 `plans.save`。update 带这张卡自己的 `expectedStorageRevision`，
冲突/删除/只读/失败明确返回；另存成功才采用新的 externalId。`savedRef.baseVersion`
仍是 SDK 会话版本，两个版本不混用。每张卡及后续编辑保留自身宿主 revision，旧卡不会
因为另一张卡更新成功而悄悄获得新凭据。

历史适配器读取 `loadLegacy` 提供的 SF `chat/coachDisplay/coachSessionJson`；
真实计划按原 request/context 重新准入（包括已有瑜伽垫等条件），不丢失条件后误拒绝。
Chat envelope 与 Core snapshot 独立版本化，恢复/关闭不删除宿主数据。
旧非 AI 模板只读恢复保留 target/dose/context，显示不套当前训练门禁；训练和保存仍
重新准入。启动恢复失败时，SDK 先调用 `history.preserveUnreadable`（默认空实现）及已配置的
`beforeNewConversation` 归档钩子，再降级为可发送的新对话并显示提示；宿主要实现备份端口
才会保留副本，不能把“提供了钩子”当作“备份已成功”。close 仍正常清理网关 lease。
80ms 合并写入按快照捕获顺序串行 flush，取消/新对话后的迟到回复和保存不覆盖新会话。
owned gateway 通过具体 lease release 关闭一次，shared client 由宿主释放。

宿主训练回调使用原 runtime `TrainerSlideRoute`，先执行
`if (!await request.onStarting()) return null;`，未放行时不 push，取消或异常时释放 hold。
接好 startGate、onExitStarted、beforeExitPop。用 `request.holdTransition()` 与路由 control
联动：来源页在入场/退场短窗口保留上一帧，输入与后台更新随后一次发布；保存失败解除
退场冻结。完成只返回原 receipt，模块按 sessionId 幂等追加消息，结果存储由原播放器负责。
详情单预览沿用串行退役，离屏低于 20% 停止；开练先 await 宿主退役，再放行原 gate，
返回保持文章 ScrollController 和位置。

## 复现与验收

```powershell
# Root 是纯 Dart Coach，采集用的外部 App 副本不是 SDK 源目录。
dart test
dart analyze --fatal-infos lib test tool
# 在每个 Flutter 包目录分别执行：
flutter test --no-pub
dart analyze --fatal-infos
```

本批包含新包及 Coach/UI/Trainer/runtime 全量测试；不改原三包测试断言或 lint 门槛。
SF 关键帧使用[同源采集脚本和固定环境](coach-chat-module-design/capture-environment.md)，
浅深共 22 张、完整视口、默认零差 comparator，不做时刻/刷新率矩阵。

收尾真实模型仅通过新 controller 跑一次同会话：5 分钟拉伸计划 → 推荐动作 → 换一套
缩到 3 分钟（SF 原 profile 合法范围 3–60）。运行器为
`tool/chat_extract_live.ps1`，默认 Prepare，Dry 为 0 HTTP；Live 明示后才读取既有网关配置。
卡片和执行按每轮目标各过 ±10%，HTTP 次数是优化目标，原始 JSON/日志仅本地 build。

本批不代表 App 已迁移，也不替代 iOS、真机播放/性能或实际数据库接线验收。
