# ugk_coach_chat

SF `3eb2a9e` 的完整教练对话模块：页面、输入/菜单、等待与出卡、计划详情、问题表单、
安全确认、保存与讨论、历史快照、新对话、训练往返。宿主保留壳、动作库、我的计划、
设置、品牌和实际存储/网关/媒体实现。

依赖方向为 `ugk_coach_chat → ugk_coach + ugk_coach_ui + ugk_trainer_runtime`。
不依赖带全量动作素材的旧 `ugk_trainer`，不声明动作素材或复制训练引擎。
计划使用 `ugk_coach.TrainingPlan`，完成回执使用 runtime 的同一个 `SessionResult`。

```dart
final chat = CoachChatController(
  profile: CoachAppProfile(
    appId: coachProfile.id,
    scopeManifest: manifest,
    coachProfile: coachProfile,
    conversationPolicy: policy,
    executionTiming: playerBuilder.executionTiming,
    visual: brandVisuals,
    strings: brandStrings,
  ),
  catalog: catalog,
  bindings: CoachChatBindings(
    storageNamespace: userChatNamespace,
    gateway: CoachGatewayBinding.configured(config: config, auth: auth),
    plans: planStore,
    history: chatHistory,
    preferences: preferences,
    actions: hostActions,
    memory: userMemory,
  ),
);
await chat.start();
// App 壳挂载 CoachChatPage(controller: chat)。
```

`start()` 幂等、恢复本地状态且不请求模型。页面不拥有 controller；宿主关闭时优先
`await chat.close()`，Widget 的同步销毁入口为 `chat.dispose()`。

宿主页面的“去排一套”在 pop 后调用 `chat.requestCompose()`，SDK 会聚焦原输入框；
普通返回不自动弹键盘。`bindings.observer` 的 `chat.user` 事件提供
`CoachChatUserInput.rawText/sentText`，可按 `messageId` 避免与显示监听重复记录。
可选 `bindings.beforeNewConversation(snapshot)` 在重置前同步发起并等待归档；等待期间
新输入排队，归档异常只报 `chat.archive.error` 后继续重置。

每次 Agent 轮结束会发出 `observer('chat.turn.result', detail)`；`detail` 是可 JSON
编码的 Map，包含 `turnId/status/errorType/failureKind/contextRequests`。每步上下文
诊断含 `beforeBytes/afterBytes/tailStateBytes/completedTurnsFolded/fitsHardLimit` 等
数值；没有对话原文、工具正文或异常消息。宿主可将该事件直接写入运行日志。
失败提示区分网络、鉴权、上下文、计划门禁及服务/超时；只有网络错误使用网络文案。
文案可通过 `CoachChatStrings` 的 `networkFailure/authenticationFailure/contextFailure/`
`planGateFailure/timeoutFailure/serviceFailure/generationFailure` 覆盖；旧空失败记录显示
通用失败文案，原存档结构不变。
既有轮数/历史策略的 `limitReached` 单独使用 `conversationLimitReached`，提示开启
新对话；它与可压缩的 64KB 上下文预算错误分开，不更改原有轮数策略。实际网关为
`OpenAiCompatibleClient` 时，字节日志沿用其 `buildBody` 精确序列化结果。

`CoachAppProfile` 负责显式动作范围、剂量投影/单位、对话文案、安全文案、主题/图标/
剪影和同播放器的执行时长回调；`CoachChatBindings` 负责有生命周期的宿主服务。
SF 名单为 219 授权/211 可规划，HipLab 45、托马斯 51 仍是候选，不是签核 manifest。

`CoachChatVisuals` 支持浅深 palette/font、`iconBuilder`、`exerciseFor`、共享
`assetResolverFor`、`mediaBuilder`、`cutoutBuilder/cutoutFor` 和 `preloadPoster`。
宿主传原 CustomPainter/剪影绘制，尺寸/颜色/布局仍由模块提供。可见推荐海报预热与
计划首张海报预热都调用宿主端口，预热的 bundle 与训练路由一致。

详情预览使用 `previewBuilder`；`retirePreview(context, actionId)` 必须等待该 context
对应的实际 surface 退役，串行切换后才创建下一个播放器。`previewStatusFor` 可透传原
播放器的 loading/failed/revealed/progress；模块不另写缓存或解码器。

`plans.save` 的 update 模式必须原子比较 `expectedStorageRevision`。SDK 的
`savedRef.baseVersion` 是会话编辑基准，不是宿主存储版本，不能代替 CAS token。
`storageRevision` 使用宿主可 JSON 编码的普通值，按卡保留；冲突不会静默覆盖。
`onSaved` 只是通知，不再写一次计划。

宿主“发到对话”调用 `sendPlanToConversation(selection)`；查看详情先调用
`prepareSavedPlanDetails(selection)`，把成功的 reference 交给
`CoachChatPlanDetailsPage(controller: chat, plan: reference)`。看详情不设置 focus，
合法 focus 不发模型请求；非法导入不改当前会话或宿主原记录。

训练回调在 `hostActions.onStartTraining`：先 `request.holdTransition()` 冻结来源页，
准备同一海报，再执行 `if (!await request.onStarting()) return null;`，仅放行后才 push
已有 `TrainerSlideRoute`；取消或异常时须释放 hold。
把其 control 的 startGate/beginExit/beforeExitPop 接到原 TrainerPlayer；入口完成、出口
媒体退役或保存失败时释放相应短期 hold，不把整场训练冻结。回调只返回原播放器已保存的
receipt，模块按 sessionId 添加一次返回消息，不再次保存训练结果。

旧 SF 的 `chat`、`coachDisplay`、`coachSessionJson` 可从
`CoachChatHistoryStore.loadLegacy` 提供；模块解码并保留原 request/context，再写独立
Chat envelope，旧数据不删除。没有 profile/目录哈希绑定或消息鉴真机制。
原非 AI 模板按原剂量/目标恢复为只读历史；开练和保存重新校验。启动恢复失败时关闭仅
释放资源，不写入空 envelope 遮盖旧档。

完整接口/接入边界见 [SDK 接入文档](../../docs/coach-chat-module.md)，关键状态帧复现见
[采集环境](../../docs/coach-chat-module-design/capture-environment.md)。
