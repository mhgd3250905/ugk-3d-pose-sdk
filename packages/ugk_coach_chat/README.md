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

完整接口/接入边界见 [SDK 接入文档](../../docs/coach-chat-module.md)，关键状态帧复现见
[采集环境](../../docs/coach-chat-module-design/capture-environment.md)。
