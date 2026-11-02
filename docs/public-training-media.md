# 公共动作包接入

HipLab、SF 和后续 App 使用相同的 `r1-v3` 动作 ID 与原始文件，下载基址为 `https://media.uuugk.win/pack/r1-v3/`。清单决定文件路径、bytes 和 SHA；不按 App 名或动作 ID 猜视频文件名，也不把视频循环时长当训练剂量。

App 依赖无动作资产的 `ugk_trainer_runtime`。随 App 打包公共 `catalog.json` 和所需动作的 `standing/<id>.webp`，不要包含 MP4。源文件在 SDK 的 `packages/ugk_trainer/assets/pose_hub/app-test-pack-r1/`；standing 索引记录其对应视频 frame 0，区别于清单里的 cover/thumbnail。图片保持原字节，不重新编码；可把选中的 standing 原文件放到 App 的 `assets/public_posters/`。

```dart
final policy = await TrainingMediaPolicy.load(
  manifestAsset: 'assets/public_media/catalog.json',
  posterAssetRoot: 'assets/public_posters/',
);

// 将 policy 赋给 CoachAppProfile.mediaPolicy，或包住普通入口。
TrainingMediaPolicyScope(policy: policy, child: app);

await TrainerLauncher.open<void>(
  context,
  mediaPolicy: profile.mediaPolicy,
  planActionIds: plan.exerciseIds,
  firstPosterAsset: policy.posterAssetFor(firstActionId),
  builder: (_) => player,
);
```

`CoachChatTrainingAdapter` 自动透传 profile 的 policy 和计划动作。默认 `TrainerPlayer` 读取 scope；动作 ID 与业务 drill ID 不同时，在 `DrillMedia.actionId` 声明公共动作 ID。`DrillMedia.videoAvailable == false` 可显式关闭该示范播放。自定义 `mediaBuilder` 保持优先，由宿主选择使用 `TrainingActionMedia`。

列表静图、详情或自测入口也使用同一个控件与 policy：

```dart
TrainingActionMedia(
  actionId: actionId,
  playing: animate, // false 时仅显示本地公共 poster，不请求视频
  paused: paused,
  mirrored: leftSide,
  stage: theme.mediaStage,
);
```

公共 packed alpha 视频与透明 poster 在浅深主题中复用；SDK 负责解码、square/contain、镜像、就绪前遮罩和主题背景。平台不支持 packed alpha 时保留 poster。断网或下载失败保留 poster 并显示重试入口；开练前预取只准备本次计划的视频，异步下载不阻断路由、计时和语音。可以在计划已确定时提前调用 `policy.prefetchActions(plan.exerciseIds)`。

缓存默认 300,000,000 B，可在 `load` / `TrainingMediaRepository.fromCatalog` 指定更小预算。后者返回 `CatalogMediaRepository`，提供 `watchFile` / `watchAction`、`cachedVideo`、`videoCacheBytes`、`clearVideoCache`。LRU、内容复用、进度、失败重试和正播保护来自 SF `52d30ae`；同一 App 的不同清单版本共享预算。缓存清理保留正在使用的视频和静图。新控件在原生 dispose 确认后释放该代 pin；若原生释放失败，保守保留保护。

policy 不拥有独立缓存生命周期：App 服务持有 repository，在相关播放器卸载后调用 `policy.repository.dispose()`。路由退出不会销毁 App 缓存服务。`mediaPolicy == null` 且无配置 scope 时维持原接线，不自动创建仓库或改写宿主素材。

公共清单没有的动作不请求近似文件，也不替换动作。SDK 显示“此动作暂无公共示范”，训练流程继续。HipLab 的 `supine-cross-demo` 属于此缺口；原自测流程及业务比较图可保留，但该演示无公共视频或 poster。本批未向托管上传或修改文件。
