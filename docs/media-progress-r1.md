# 训练示范视频：下载进度与当前动作优先

`TrainerPlayer` 的下载 HUD 位于“不舒服”按钮右边缘下方，独立于视频镜像。
它不改变训练倒计时、播放、语音或结果记录。默认显示；没有 policy 或宿主下载状态时隐藏。

## 使用 SDK 下载仓库

把 `TrainingMediaPolicyScope` 放在播放器外层。默认媒体视图会在动作成为当前动作时请求视频，
包括准备阶段和预览；`canPlay` 继续只控制播放。后台和被其它路由遮盖时仍退回静帧、释放播放器。
当前视频准备完成后才预取下一个不同动作，不预取整套计划。

兼容宿主已有 `poseHubMediaPreparer` 的队列：未传入新下载状态时沿用旧调度；
显式提供 `mediaDownloadState` 后，桥接队列才启用“当前 ready 后仅预取下一条”。
这不改变 SDK policy 仓库本身的当前/下一条调度，也不会自动改造 SF 自有仓库。

`TrainingActionMedia.prefetchWhenIdle` 是可选参数，默认 `false`：单独使用组件时，
`playing: false` 仍只展示静帧，不下载或创建解码器。SDK 仅在 `TrainerPlayer` 的当前动作视图中传入
`prefetchWhenIdle: true`，使倒计时期间先下载，播放仍等待 `canPlay`。
动作列表、详情和其它未播放预览不传此开关，继续等待用户明确播放。

```dart
final repository = await CatalogMediaRepository.create(
  catalog: catalog,
  catalogRevision: catalogSha256,
  mediaBaseUrls: mediaBaseUrls,
  onTiming: (timing) {
    // 接到宿主已有的运行日志存储；不要仅依赖 debugPrint。
    runtimeLog.record(CatalogMediaTiming.event, fields: timing.toFields());
    // 纯文本通道也可逐行保存 timing.toLogLine()，前缀为 media.timing。
  },
);
final policy = TrainingMediaPolicy(repository: repository);

TrainingMediaPolicyScope(
  policy: policy,
  child: TrainerPlayer(
    plan: plan,
    drillOf: drillOf,
    strings: TrainerStrings.zh(),
    onFinished: saveResult,
    showMediaDownloadIndicator: true, // 默认值；false 只关闭 HUD。
  ),
);
```

`TrainingMediaPolicy.load`、`TrainingMediaRepository.fromCatalog` 也接受可选的 `onTiming`。
记录含动作 ID、文件种类、字节数、入队/取槽/请求/首字节/下载完成/校验完成时间、
base 序号（从 1 开始）、回退次数和安全错误码；不记录 URL、签名或请求头。
缓存命中等不经过网络的阶段为 null。每个去重后的文件任务输出一条终态记录。
宿主日志若有字段白名单，需要接纳 `toFields()` 的字段，才能保留完整计时。

队列默认最多同时处理 2 个文件。当前请求优先于排队预取，已排队同文件会提升优先级并复用 Future；
运行中的预取不中断。原 `ensureFile(file)` 签名保持不变，默认作为当前请求；预取调用
`ensureFileWithPriority(file, priority: CatalogMediaPriority.prefetch)`。
宿主自行实现旧仓库接口时仍能使用，优先级能力为可选接口。
每个 base 只尝试一次，失败马上试下一个；连接、首字节及流空闲超时仍为 15 秒。

## 宿主自行下载或自定义媒体视图

宿主可给 `TrainerPlayer.mediaDownloadState` 传入
`ValueListenable<CatalogMediaDownloadState>`；它优先于 policy 的视频状态。
未传时回落到 `policy.repository.watchFile(action.video)`。
切换动作时，宿主须同步提供新动作的状态，不能沿用上一个动作的 ready 状态。

```dart
TrainerPlayer(
  plan: plan,
  drillOf: drillOf,
  strings: TrainerStrings.zh(),
  onFinished: saveResult,
  mediaDownloadState: currentDemoDownload,
  onMediaDownloadRetry: retryCurrentDemo, // 也须恢复失败的宿主解码器。
  showMediaDownloadIndicator: true,
  mediaBuilder: (context, request) => DrillMediaView(
    media: request.drill.media!,
    paused: request.paused || !request.canPlay,
    mirrored: request.mirrored,
    playbackHandle: request.playbackHandle,
  ),
);
```

自定义解码视图应将 `request.playbackHandle` 绑定到自己的 `DrillMediaController`，
动作 ID 使用 `request.drill.media?.actionId ?? request.drill.id`，离开时解除绑定。
SDK 的 `DrillMediaView` 和 `TrainingActionMedia` 已支持该参数；HUD 同时兼容
`DrillMediaView` 已有的宿主 `media.id` 与目录动作 ID，不改变原来的播放位置检查身份。
HUD 同时监听下载状态和解码器：只有 ready 且当前视频已出帧，才显示对勾并在停留 400ms 后淡出 200ms；
两个信号的先后顺序均可。下载 ready 本身不能代替首帧，解码失败也会进入可重试状态。
自定义 `mediaBuilder` 没有绑定首帧句柄时，HUD 不会仅凭下载 ready 提前完成。
关闭 HUD 不会停止下载；平台不支持视频时不显示 HUD。

SF +29 当前仍使用 App 自己的下载仓库，没有接入 SDK policy。本提交不会自动加快该仓库或接入 SF 运行日志。
SF 的状态、首帧、重试和日志桥接，以及自身慢下载诊断，留给单独的 App 接入卡；本单不出 SF 包。

## 验证边界

受控组件计时使用固定 200ms 下载和 100ms 模拟解码，可比较调度变化，不能当作真机网络或原生解码测速。
下表数值均为进入组件后的毫秒；“首帧”是模拟解码器发出的事件，不等于视频已在倒计时结束前可见。

| 受控场景 | 改前请求 / 首帧 | 改后请求 / 首帧 | 画面实际可见 |
| --- | --- | --- | --- |
| `TrainerLauncher`，18 秒准备，关闭额外预取 | 400 / 700 | 0 / 300 | 改前未测；改后 450 |
| 直接 `TrainingActionMedia(playing: false)`，18 秒后允许播放；改后显式开启 `prefetchWhenIdle` | 18000 / 18300 | 0 / 300 | 改前未测；改后 18050 |

对应的 `before/after-launcher-prep18.json` 和 `before/after-playing-false18.json` 位于根目录
`build/media-progress-r1/`。这组计时证明当前动作提前准备，不证明 SF 真机的网络下载耗时。

按本单新行为调整的三个旧测试如下；保留原有行为断言，完整测试结果以本轮检查记录为准。

| 旧测试 | 原检查方式 | 本次调整及保留断言 |
| --- | --- | --- |
| runtime：`offline failure retains poster and retries only on one tap` | `public-action-retry` 位于媒体组件内 | 改查外层 `media-download-retry` 并绑定播放句柄；保留点击前 1 次请求、点击后 2 次及封面仍显示 |
| runtime：`a failed download does not pause the running training clock` | 检查 `public-action-retry` | 改查 `media-download-retry`；保留失败时训练时钟前进和封面显示 |
| trainer：`player reuses same-host queue across callback rebuilds and waits when provider changes` | 起始并发准备两个动作 | 夹具显式接入下载状态，先准备当前一个，ready 后才取下一个；保留同宿主重建复用队列、换宿主等待取消完成 |

`training_library_test.dart` 的 8 条现有用例不修改，继续检查列表不下载、详情点击后才下载、
受限动作不能开始等原有约束。此前提前下载越过这些约束的问题由 `prefetchWhenIdle` 的默认值和调用位置修正。

仓库队列测试另外用本地 HTTP 验证两个活动预取占槽时，当前视频先于其它等待预取取得第一个空槽。
安全的逐文件计时和请求动作顺序写入 runtime 包的 `build/media-progress/queue-timing.json`。
原始日志、计时 JSON 和四张本机字体截图放在忽略的 `build/` 中，不随提交发布。
