# ugk_trainer 0.4.2

## 宿主媒体准备与 v3 逐文件素材

0.5.0 取消独立准备页与计时门禁。可选注入 `mediaPreparer`，实现 `PoseHubMediaPreparer.prepareAction(action)` 并返回 `PoseHubMediaProgress` / `PoseHubMediaReady(mediaBaseUri:)` / `PoseHubMediaFailed(reason:)` 事件流。宿主负责下载、缓存及 `file.bytes` / `file.sha256` 校验；SDK 编排最多两个并发准备任务、消费最终本地目录，不实现下载缓存。计时与播报照常开始，原始 alpha WebP 随包显示，失败保持静帧并静默重试；视频首帧可呈现后在原位淡入。不注入时保留本地 `mediaBaseUri` 播放。[接口与限制](../../docs/feedback-r1-part1.md)。

v3 的 657 个媒体文件共 163,351,529 bytes，以 Cloudflare R2 独立对象分发（media.uuugk.win/pack/r1-v3/），GitHub Release 仅保留 catalog 和整包 ZIP 备份；`file.downloadUri` 给出稳定 URL，原 `file.path` 供宿主按原目录落盘。根 catalog 不再用固定 v2 SHA 作准入门槛，而按自身版本、文件清单和语义字段校验。完整签名、事件/取消契约与 URL 规则见[v3 接入指南](../../docs/posehub-app-test-pack-r1-v3.md)。

## 219 动作素材包

`PoseHubActionLibrary.load()` 保留原始 219 动作元数据；`semanticCompleteActions` 为 211 个，`pendingActions` 为 8 个。AI 投影和用户动作库都排除待补动作。`PoseHubActionBrowser` 显示两列透明人物与中文名，中文名称/别名搜索和器械、部位、类型可组合筛选；点击卡片直接进入单动作训练。219 张原 cover WebP 按原 SHA 随包提供，离线可见，共 5,316,554 bytes；未改任何素材。187 张 cover 与视频首帧不同，其中 183 张属于用户库；[逐动作核对清单](../../docs/evidence/feedback-r1-part1/standing-first-frame-audit.md)记录差异与判定方法。

v3 媒体已压缩并按文件发布，不进入普通 Git 历史；原始媒体的完整 ZIP 仍保留在 v1/v2 Release。语义来源与旧整包安装见[v2 接入指南](../../docs/posehub-app-test-pack-r1-semantics-v2.md)，原有 Web 演示与平台范围见[v1 接入指南](../../docs/posehub-app-test-pack-r1.md)。已有扁平实色训练布局、防闪按钮与 Morph Pulse 保持不变。

## 实色分层与不兼容迁移

默认界面统一为三个不透明层级：`TrainerTheme.background` 页面、`surface` 内容面、`surfaceHigh` 抬升控件；配合主题 `border` 的 1px 低对比描边与 `shadow` 的轻固定阴影。浅深默认值及完整 `copyWith` 可直接使用，颜色只来自传入的主题 token。`TrainerSurface`、`TrainerIconButton` 取代旧材质组件，没有背景模糊、玻璃 shader、仿玻璃半透明面或兼容开关。

| 删除的 API | 0.3.x 迁移 |
| --- | --- |
| `TrainerGlassStyle`、`TrainerTheme.glassStyle` / `.glass` | 删除材质对象与赋值；向 `TrainerTheme` 注入实色角色 |
| `TrainerGlass` 及 `overMedia` / `control` / `pressed` | 使用 `TrainerSurface(level: TrainerSurfaceLevel.background/panel/control)` |
| `TrainerGlassButton` / `overMedia` | 使用 `TrainerIconButton`，原 callback/tooltip/size 保留 |
| `TrainerGlassField`、`TrainerHover` | 删除旧环境光或悬浮材质包装 |
| `TrainerTheme.scrim`、`TrainerStageFloor.fadeClipEdge` | 删除旧参数 |

直接构造主题还需提供 `border`、`shadow`、`ringKnob`、`accentSubtle`。从 `TrainerTheme.light` / `.dark` 的 `copyWith(...)` 起步可减少迁移代码；表面填色强制不透明，阴影允许低 alpha。

训练页现有位置、尺寸、交互和媒体布局保持。防闪颜色交接、Morph Pulse 形变/时序/呼吸/ripple 和径向进度 halo 保留；普通进入/退出与按压反馈使用位移、缩放、淡入。`packed_alpha.frag` 是透明视频合成，不属于玻璃，继续保留。更完整的删除清单与保留理由见[实色分层审计](docs/solid-layered-audit.md)。

仓内[验收展示](example/README.md)支持四训练状态、浅/深/跟随系统；[基线图与检查](docs/visual-review.md)保留 `c4d251d` 证据，[0.3.1 收尾记录](docs/flat-closeout-2026-10-26.md)记录当时复核。开哥已确认扁平版真机流畅，`c6e261e` 已合入并推送 main。219 素材包的 Web 检查不替代新一轮原生性能验收；本轮不启动模拟器。

## 0.2.9：拼接 alpha 视频（随 0.2.10 纳入主线）

下方设备数据保留为 0.2.8 / 0.2.9 当时渲染路径的历史证据，不作为当前 0.3.0 实色版本的设备性能证明。

推荐通过 `DrillMediaView` 接入，资源审核与测试构建开关由 App 管理：

```dart
// Owned by the App's State; dispose it when that State is disposed.
final playback = DrillMediaPlaybackHandle();

DrillMediaView(
  media: const DrillMedia(
    id: 'example-action',
    videoAsset: 'assets/example/opaque.mp4',       // ordinary MP4 fallback
    posterAsset: 'assets/example/opaque-frame0.webp',
    duration: 4,
    packedAlphaVideoAsset: 'assets/example/packed.mp4',
    packedAlphaPosterAsset: 'assets/example/alpha-frame0.webp',
    bundledOnly: true,                           // App-verified local assets
  ),
  playing: previewStarted,
  paused: paused,
  playbackHandle: playback,
)
```

拼接视频为 720×1440 H.264：上半为完整 720×720 RGB，下半为同帧、同尺寸的灰度 alpha，黑色透明、白色不透明。`packedAlphaPosterAsset` **必须是该视频第 0 帧的透明 PNG/WebP**，不能换成挑选姿态的 cover；cover/thumbnail 可供列表单独使用。两项 packed asset 都存在才尝试透明路径；`bundledOnly: true` 表示这些资源及回退资源已由 App 验证并打包，不从继承的其他版本媒体 repository 解析或下载，也不显示下载中的提示。

当前透明路径限定 Android＋Impeller，运行时可检查 `UgkPackedAlphaVideo.isSupported`；本轮实机环境为 Impeller Vulkan。iOS、Web、Skia、不支持的后端或 packed 解码/着色失败会使用既有普通 MP4 路径；没有普通视频时保留静帧。App 应提供适配主题的普通 `videoAsset/posterAsset`，必要时同时提供 `lightVideoAsset/lightPosterAsset`。SDK 不会通过 CSS 混合把普通 MP4 伪装成透明视频。

底层 `UgkPackedAlphaVideo(asset: ..., controller: ...)` 使用 MediaPlayer＋SurfaceProducer，并以 `MEDIA_INFO_VIDEO_RENDERING_START` 区分真实首帧与初始化元数据；直接使用底层组件时，调用方需处理 controller 的失败状态及回退。完整 2h Texture 先经过 `ImageFilter.shader` 合成，再由外层 matrix image filter 压到 h，避免先压缩 packed 输入而丢失一半垂直细节。没有逐帧 Dart `toImage`、像素回读或 canvas capture；只有缺目标 poster 的既有切换协议可显式请求一次快照。参见 [GPU 路径与来源说明](lib/src/media/packed_alpha_sources.md)。

`playing: false` 仅展示静帧、不创建解码器；`playing: true, paused: true` 暂停已有解码器并保留画面。`TrainerPlayer` 中既有 150ms 最后目标合并、首帧门禁和 120ms 视频/透明首帧封面交接继续生效；自定义 media builder 仍须使用稳定 key。

点击问题标记时可按需读取真实视频时间：

```dart
final snapshot = await playback.capture();
// snapshot?.mediaId, videoSeconds (nullable), ready, capturedAt (UTC)
// Join the App-owned asset revision and issue metadata in the App.
```

`capture()` 是只读元数据快照，不是截图；它只在调用时查询一次解码器位置，不创建周期计时器、不改变播放或训练时钟。等待中、静帧、已销毁或查询失败时 `videoSeconds` 可以为 null，不能用训练经过时间或猜测的 0 秒替代。快速切换时保留调用瞬间的媒体 ID，不把旧视频时间配到新动作。动作审核/可见性、资源 revision、问题存储与导航继续由 App 负责。

2026-10-25，同一 Android 真机 Impeller Vulkan 的 Profile 复测：浅色稳态/切换 Raster P99 为 **8.427/8.312ms**，深色为 **8.059/7.086ms**，四个窗口均无 Raster 超过 16.67ms 的帧。稳态各 20 秒，切换各 14 秒（上一/下一各 5 次）；只复测受影响场景，没有跑全量测试。数据来自引擎 FrameTiming，不等同于硬件呈现帧率。

0.2.8 当时的分支性能修复将信息卡和相邻按钮改为无采样绘制，并隔离倒计时/按钮重绘、将环头柔光改为径向渐变。0.2.10 当时保留重绘边界与 halo，并采用局部光学采样；当前 0.3.0 已删除该材质。原定向 SDK 22/22、SmartFit 9/9 及以下设备记录属于旧版本，不代替新材质的 release 复测。

重连真机后的 `candidateResumeFull` profile 五场景记录如下。首次进入取有效 3 秒，UI 最慢帧为 13.246ms、Raster 最慢帧为 21.407ms，满足入口不超过 33ms 的本轮门槛。

| 场景 | 有效帧数 | Raster P99 | Raster 最慢帧 | 超过 16.67ms |
|---|---:|---:|---:|---:|
| 首次进入（3 秒） | 187 | — | 21.407ms | — |
| 无操作播放 | 907 | 9.054ms | 10.258ms | 0 |
| 播放/暂停按钮 | 1231 | 6.965ms | 10.200ms | 0 |
| 上一项/下一项 | 988 | 8.286ms | 19.573ms | 1 |
| 临时关闭按钮波纹与光晕的对照 | 1248 | 7.297ms | 14.185ms | 0 |

按钮 20 次单点/快连点的保守 `tap + 600ms` 窗口内，Raster 超过 16.67ms 的帧均为 0。播放、按钮、切换的 Raster P99 均不超过 16.67ms；切换的单次最慢帧如表保留，该场景验收要求是 P99，零超预算要求针对按钮动画窗口。这批采样满足本轮数值门槛；关闭波纹与光晕未显示明确收益，因此保留完整效果。

此前按钮 24.895ms 的候选样本仍保留在原报告，不能据当前采样宣称永远零慢帧或硬件始终按 60fps 呈现。本轮已逐帧审阅原始 VM full trace，DevTools UI 导入审阅尚未完成。采集已从每秒双次 VM timeline 查询改为窗口结束后拉取，以减少采集本身引入的 UI 尖峰；此类干扰的消除不直接计为代码优化收益。

0.2.7 把训练页中央播放/暂停按钮封装为 `UgkPlayPauseButton`。保持 76px 按钮、96px 进度环与主题配色：用 CustomPainter 将三角两块逐点形变成双条；颜色从中心漫开，按压松手弹回，暂停时缓慢呼吸，播放时亮起环头柔光。快速反向保留当前动画进度；真实播放状态始终负责确认或纠正本地点击。

`TrainerPlayer` 已自动接入，无需宿主重复管理动画。需要单独使用时：

```dart
UgkPlayPauseButton(
  isPlaying: isPlaying,          // App/player authoritative state
  progress: progressNotifier,   // ValueListenable<double>, 0..1
  onTap: togglePlayback,
  theme: trainerTheme,          // accent/onAccent, pausedColor/onPaused
  strings: trainerStrings,      // localized pause/resume semantics
)
```

可选 `progressColor`、`trackColor`、`knobColor`，以及 `size`（默认 76，至少 48）、`ringSize`（96）、`iconSize`（38）。进度仍直接驱动原环 painter，不触发页面重建。外部状态变化只切图标/颜色与状态氛围，按压、波纹和触感仅来自用户激活；系统减少动态时只保留 150ms 图标交叉淡入和颜色过渡。组件提供键盘、Semantics 与独立重绘边界。

0.2.6 修复训练中快速上一项/下一项切换时的播放器闪现。`TrainerPlayer` 内自动使用 `DrillMediaHandoff`：目标静帧立即显示，连续切换默认合并 150ms 后只加载最后目标；WebView/iframe 到首个已合成视频帧才短淡入。目标没有静帧时，切换前暂停旧视频并抓取当前解码帧，截图回复等待最多 60ms，图片预解码最多 40ms，随后销毁旧播放器；浅深主题的截图不混用。播放器始终关闭原生 controls，页面自己的手动播放按钮由宿主负责。

使用默认 `TrainerPlayer` 媒体构建器无需额外配置。自定义 `mediaBuilder` 返回 `DrillMediaView` 或其包装 Widget 时，请给这层使用稳定 key（例如 `const ValueKey('trainer-media')`），不要按 `drill.id` 更换 key，才能保留切换边界并抓取当前画面。独立的 `DrillMediaView` 默认仍立即响应手动播放；需要同样合并时可显式包 `DrillMediaHandoff(child: ..., settleDelay: const Duration(milliseconds: 150))`。媒体加载和导航语音合并只影响呈现，训练引擎和计时继续运行；150ms 内的中间目标不会起播或播报开头。

0.2.5 为 SmartFit 真机反馈的分支修复，待真机确认后合 main：训练中的“下一个动作”位于顶部信息条下面的左侧，与右侧“不舒服”按钮共用一行，动作名在有限宽度内换行。暂停后保留下一动作预告，去掉重复的“已暂停”标签；中央继续按钮以暂停态颜色表达状态，继续后恢复运行色，计时、语音和安全操作逻辑不变。

宿主可在 `TrainerTheme` 构造或 `copyWith` 中传入 `pausedColor` 与 `onPaused`，分别控制暂停时继续按钮的底色和图标色。省略时沿用该主题的 `danger` 和 `onAccent`，不依赖某个 App 的品牌颜色。按钮无障碍标签仍使用宿主的 `TrainerStrings.pause` / `resume`。

0.2.0 已获开哥批准合入 main（验收提交 `64a5487`）：修复组/侧/分段统计与浮点推进，补充无节奏动作自动报数、`PlanItem.segments` 和 App 可选操作。新行为、语音清单、后台/中断策略与 SmartFit 回归边界见 [0.2.0 接入契约](../../docs/trainer-020-integration.md)及[验证记录](../../docs/trainer-020-verification-2026-10-23.md)。

FlareLab 使用交付回执的 main 完整 SHA 固定依赖；接入后做锁屏、来电中断和原生播放真机验收，发现 SDK 问题再出补丁。SmartFit、HipLab 暂不升级；临时副本回归不能替代原 App 升级验收。

三 App（托马斯 3D-Body / 开胯 HipLab / SmartFit）共用的跟练模块。方案见仓库根目录 `docs/trainer-plan.md`。

当前包版本以 [pubspec.yaml](pubspec.yaml) 为准，版本历史见 [CHANGELOG.md](CHANGELOG.md)，合并与验证记录见[项目维护台账](../../docs/project-ledger.md)。本包与根包 `ugk_coach` 0.5.0 独立管理版本；`publish_to: none`，版本归档不表示 pub.dev 发布。

| 层 | 内容 | 来源 |
|---|---|---|
| `engine/`（纯 Dart） | `SessionBuilder`（TrainingPlan v1 + 每动作 `Rhythm` → 固定长度相位：准备/组/换边/组间/轮间/结束）、`SessionEngine`（绝对活动时间；自主计次 `completeSet`；`restartWith` 换动作；相位访问日志） | SmartFit `session.dart` |
| `rhythm/` | `ActionKind`（6 种）+ `KitPhase` + `RepPlan`；`Rhythm.fromJson`（目录 `rhythm` 字段）/ `fromActionKitJson` / `fromRepSeconds` / `forDose`；`rhythmsFromCatalog` | HipLab `action_kit.dart` |
| `voice/` | `VoiceQueue` / `VoiceLineController` / `JustAudioVoiceOutput`（10-19 安卓修复版）；`SessionScript`（SmartFit 组/轮 + HipLab 节奏计数、换边余量）；`VoiceSource` 接口 + `ManifestVoiceSource` / `DrillPackVoiceSource`；`SessionRunner` | HipLab / SmartFit |
| `platform/` | `TrainingKeepAlive` / `TrainingHold`（安卓前台服务 + 唤醒锁，本包 Android 插件）、`ScreenAwake`（wakelock_plus） | HipLab |
| `media/` | `DrillMedia`、`DrillMediaView`（封面 → WebView/iframe 循环示范）、本地资源服务 | SmartFit + 3D-Body web |
| `ui/` | `TrainerPlayer`、`TrainerTheme`、`TrainerStrings`、倒计时环/数字、`TrainerSurface`、`TrainerIconButton`、`TrainerStageFloor` | SmartFit 播放页与 PR #6 舞台 UI |
| `result/` | `SessionResult`（开始即定 `sessionId`）、`SessionRecorder`、`ResultSaver` | 新 |

`package:ugk_trainer/engine.dart` 只导出纯 Dart 部分（可在 `dart test` / 工具里用）；`package:ugk_trainer/ugk_trainer.dart` 导出全部。

## 播放器接入（沿用 0.1.7 的业务与布局）

[PR #6](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/6) 已于 2026-10-23（Asia/Shanghai）合入 main，合入提交为 `eb29c749a52c1b226841726a3fba8e9f62e9e6be`。当前播放器保留方形示范画面与舞台地面、动作序号和分段进度；控件使用主题实色表面，倒计时环放在暂停按钮外侧。

自主计次时，“完成本组”与顶部目标剂量同时可见，工作、暂停和下一组均保留目标；宿主 `doseLabel` 继续生效。顶卡、字幕和数字槽随系统 `TextScaler` 调整，倒计时有 `scaleDown` 兜底；已覆盖 1 / 1.5 / 2 倍字号及 390×844 / 844×390 横竖屏。关闭、上一项、暂停/继续、跳过按钮支持 Tab 聚焦及 Enter / Space 激活，并显示焦点环。

原有 `TrainerPlayer` 业务接入参数继续可用。`TrainerTheme` 提供浅深默认 token 和完整 `copyWith`；表面与图标按钮分别使用 `TrainerSurface`、`TrainerIconButton`，并导出 `TrainerStageFloor`、`TrainerResultStage` 和 `TrainerCountdownDigits`。旧材质 API 的不兼容迁移见本页顶部。默认媒体以圆角 0 铺入舞台；宿主 `mediaBuilder` 收到的 `TrainerMediaRequest.theme.radius` 同样为 0，可据此保持画面边缘一致。

0.1.5 / 0.1.6 的媒体缓存与内测预览策略沿用。测试和 Web 预览不能证明真机帧率、原生媒体播放或整节训练体验已验收，这些仍由宿主 App 验证。

## 接入

```yaml
dependencies:
  ugk_trainer:
    git:
      url: https://github.com/mhgd3250905/ugk-3d-pose-sdk
      path: packages/ugk_trainer
      ref: ugk_trainer-v0.3.1
```

```dart
final result = await Navigator.of(context).push<SessionResult>(
  MaterialPageRoute(
    builder: (_) => TrainerPlayer(
      plan: plan,                                   // ugk_coach TrainingPlan v1
      rhythms: rhythmsFromCatalog(catalog),         // 见下「动作节奏」
      drillOf: (id) => TrainerDrill(id: id, name: …, cue: …, media: DrillMedia(…)),
      strings: myStrings,                           // TrainerStrings
      theme: myTheme,                               // TrainerTheme
      voice: TrainerVoice(source: voiceSource, output: voiceOutput, settings: settings),
      onFinished: (r) => store.upsertSession(r.sessionId, r.toJson()),
      onDiscomfort: …, feedbackBuilder: …, mediaBuilder: …, // 可选插槽
      notificationIcon: 'mipmap/ic_launcher_monochrome',
    ),
  ),
);
```

### 各 App 要提供什么

1. **VoiceSource**（语音素材）
   - HipLab：`ManifestVoiceSource.load(rootBundle.loadString, kitVoices: {id: KitVoice.fromActionKitJson(kit)})`，读 `assets/voice/manifest.json`。
   - SmartFit：`DrillPackVoiceSource.load(rootBundle.loadString)`，读 `assets/packs/index.json` + 各包 `pack.json`。
   - 托马斯：复用其中一种（中/英）；`VoiceSettings.language` 填语音语言代码。素材里没有该语言时（其余 10 种）自动降级为只有提示音 + 屏幕倒数，不会说半句话（决定 B）。
   - 输出用一个 App 级 `JustAudioVoiceOutput()`（App 退出时 `dispose()`）。iOS 锁屏保活靠它循环本包的静音片段，Info.plist 需有 `UIBackgroundModes: audio`。
2. **动作节奏 Rhythm**：`rhythmsFromCatalog(catalog, overrides: …, defaults: …)`。优先级为 App overrides（含 HipLab action kit）> 目录 rhythm > defaultDose.holdSeconds > 明确的 repSeconds > `RhythmDefaults`。无节奏 reps 默认自动按 3 秒/次报数、完成；time 仍计时。自主完成仅显式 self_paced；视频循环长度不作为单次时长。rep_hold 的停留秒数用 `rhythm.withHold(n)`，详细覆盖规则见 0.2.0 接入契约。
3. **TrainerStrings**：播放页全部文案（含安卓常驻通知文字）。`TrainerStrings.zh()` / `.en()` 是 SmartFit 文案的起点，托马斯 12 语言自己传。
4. **TrainerTheme**：颜色/字体 token；`TrainerTheme.dark` / `.light` 为 SmartFit 值。
5. **drillOf**：动作名（App 语言）、休息时显示的要点、示范 `DrillMedia`（`videoAsset` / `posterAsset` 为 App 资源键，可带浅色版）。返回 null 的动作不进训练。
6. **mediaBuilder**（可选）：默认 `DrillMediaView`——安卓/iOS 用 WebView + 本机回环资源服务，web 用 iframe，播放页 `packages/ugk_trainer/assets/media_player/player.html` 随包带。默认只放行 `assets/` 下的 mp4/jpg/png/webp。
7. **onFinished**：训练结束（完成、提前结束、关闭）时调用一次，传一个 `SessionResult`。**按 `sessionId` 覆盖保存**：保存失败时完成页出现「重试」，重试传的是同一个结果（同一 id），不会产生第二条记录。保存成功前「完成」不可点；关闭和系统返回也等待保存，失败时保留完成页供重试。
8. **onDiscomfort**（可选）：返回 `DiscomfortDecision(continueEasier | skip | end | substitute, substituteId:, note:)`；HipLab 疼痛阶梯留在 App，在这里弹自己的页面。缺省是内置三选项底部弹层。事件记入结果。
9. **feedbackBuilder**（可选）：完成页上方的插槽（HipLab 感受反馈），拿到 `SessionResult`。
10. **sessionBuilder**（可选）：传入 `SessionBuilder` 子类，覆写 `phases` 保留 App 的左右侧剂量和组数编排；相位必须保留原计划的 `itemIndex`、`blockIndex`、`itemInBlock`，并以 `done` 结尾。计时、跳过、语音队列和保存仍由播放器管理。
11. **restFeedbackBuilder**（可选）：动作间休息的感受插槽，拿到当前 `phase`、刚结束的 `completedPhase` 和 `reportDiscomfort()`。普通反馈不暂停计时；报告疼痛时，`onDiscomfort` 的 `phase` 指刚结束的动作，`resumePhase` 指实际休息相位，`afterExercise` 为 true。完成页反馈发生在自动保存之后；要持久化完成页的新回答，App 应按同一 `sessionId` 更新补充数据。
12. **DiscomfortDecision.replacementPhases**（可选）：App 的疼痛策略可重建后续相位（减量、替换、方向过滤），`restartItemIndex` 选择开始位置，`withRest` 保留该位置前的休息；全部被过滤时进入 `done`。`voiceClips` 在重排后排入语音队列，用于 App 的疼痛提示。未提供相位时沿用默认动作；`continueEasier` 只表示减小幅度，具体减量由 App 决定。
13. **replayBuilder**（可选）：保存成功后显示再练入口，拿到 `SessionResult` 和 `replay()`。App 先重置自己的疼痛/感受状态，再调用 replay；同一播放器 State 开新会话和新结果 ID，保留共享语音输出，不建立第二个路由。
14. **doseLabel**（可选）：以 `SessionPhase` 按 occurrence 返回 App 的剂量文案，同时用于当前动作和下一动作预览；返回 null 则使用默认剂量文字。
15. **announceDiscomfortPause**（缺省 true）：false 时疼痛对话进出静默暂停/恢复，仍重新激活音频与续期保活；普通暂停按钮的播报不受影响。`DiscomfortDecision.subtitle` 可给出 App 的可见响应，即使没有语音素材也显示。

`SessionResult.completedExercises` 只统计实际完成全部所需侧别/组的动作，跳过不计为完成。引擎的 `completedExercises` 保留播放位置语义；读取实际完成数使用 `fullyCompletedExercises`。
`ItemResult.plannedSideSets` / `completedSideSets` 用 `right`、`left` 表示各侧实际组数，支持不对称编排；原 `plannedSets` / `completedSets` 继续表示成对组。旧结果没有这些字段时按空映射读取。

### Android

- 本包是 Flutter 插件：`com.ugk.trainer.TrainingSessionService`（`mediaPlayback` 前台服务 + 部分唤醒锁）和 `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_MEDIA_PLAYBACK` / `WAKE_LOCK` 权限由包内 manifest 合并进 App，通道 `ugk_trainer/training_session`。
- `JustAudioVoiceOutput` 在训练期间循环包内静音音频，填补两句口令之间的播放空隙：HipLab 真机观察到小米 Greeze 在音频空闲时仍会冻结前台服务并禁用唤醒锁。Android 使用正常播放器音量播放采样值全零的包内音源；设为零音量会被系统标记为客户端静音，不计入有效音频活动（0.1.2 已在真机复现此失败）。iOS 保持零音量。静音播放器不持续申请 Android 音频焦点；口令仍按句申请和释放焦点。来电等中断和耳机断开会暂停保活，训练结束后释放，单会话上限两小时。完成页留屏及快速再练也要验证释放/交接。实际兼容性必须由宿主真机复测确认。
- 0.1.3修正音轨静音标记后，HipLab同一设备仍在约五分钟关屏后被冻结。0.1.4在既有唯一服务内加入framework MediaSession及MediaStyle token，训练页明确启用媒体身份，暂停/中断与恢复同步真实状态；自测等普通TrainingHold默认不创建媒体会话。结束、销毁、任务移除及安全上限释放媒体身份和锁，不增加持续音频焦点或第二服务。该方案仍须宿主整节锁屏验收，不能由API或单测推定小米免冻。
- **Play Console 需补「媒体播放」前台服务声明**（应用内容 → 前台服务权限），每个 App 各自做。
- HipLab 切换时删掉 App 自己的 `TrainingSessionService.kt`、MainActivity 里的 `hiplab/training_session` 通道和 manifest 里的 service 声明，避免两份服务。
- 通知小图标用 `notificationIcon`（`mipmap/…` 或 `drawable/…`），不填用应用图标。

## 静帧、主题与播放选择（0.2.4）

宿主按实际素材清单设置 `DrillMedia.videoAvailable`。设为 `false` 时，`DrillMediaView` 保留主题匹配的 poster，并可显示宿主传入的 `unavailableLabel`；不会创建播放器、下载资源或显示网络故障提示。已有视频请求失败仍使用 `errorLabel`，两种情况分别处理。

使用 repository 时，宿主把当前主题明确传给 `DrillMedia.theme`（`light` / `dark`），同时提供对应的 poster 与视频路径；不要用深色素材代替缺失的浅色素材。纯 assets 模式仍支持原有 `lightVideoAsset` / `lightPosterAsset`。主题与资源更换时先清掉旧 frame，再展示新主题静帧并加载视频。

卡片流由宿主统一选择一个 `playing: true`，其余传 `false`，SDK 会释放非活跃播放器。进入训练前应先关闭详情预览并等待一帧，避免旧路由退场时与新训练同时播放。SmartFit 当前把已有浅深视频随包带上以支持离线；内置读取仍先于缓存和网络，SDK 不要求所有宿主都采用同一种打包策略。

## 内置精简与按需素材

`TrainingMediaRepository` 位于共用 trainer 包，三个 App 可接入同一套清单、下载、缓存与播放器。宿主选择动作及保存 Wi-Fi/开发开关偏好，仓库负责素材完整性与网络策略。原来的 `DrillMedia` / `DrillMediaView` 不传仓库时继续读取宿主 assets。

```dart
final media = await TrainingMediaRepository.create(
  manifestAsset: 'assets/training_media/v0.3.0-app/app-manifest.json',
  baseUrls: [
    Uri.parse('http://192.168.1.10:8765/v0.3.0-app/'),
    // 正式部署时依次配置国内、海外的同版本目录。
  ],
  wifiOnly: savedWifiOnly, // 缺省 true
  allowPending: savedDeveloperSwitch, // 还受下方编译策略限制，缺省 false
);
// 在应用根部或训练路由上包 TrainingMediaScope(repository: media, child: ...)。
// DrillMedia.actionId 可把 App 自己的 drill id 映射为清单动作 id。
unawaited(media.prefetchActions(planActionIds));
// 设置页：media.manifest.packages['realistic-dark']!.totalBytes 显示包大小；
// media.stateFor('realistic-dark') 显示进度；调用前保存 media.wifiOnly。
await media.downloadPackage();
final usedBytes = await media.cacheBytes();
await media.clearCache();
```

主清单打进 assets；只带 `packages/builtin.json`、`packages/realistic-dark.json` 两份子清单，`common-lossy/covers/` 和缩略图，以及 builtin 所列 32 段 realistic/dark 视频。保持 `v0.3.0-app/` 与 `v0.3.0/` 相邻，仓库按清单相对路径解析。主清单可信于 APK，子清单按主清单的 SHA-256 和长度验证；额外皮肤的子清单随包从相同镜像下载。`skin` / `theme` 是预留接口，宿主无需提供额外皮肤界面。

读取顺序是内置、已校验本地缓存、下载。原生下载写入 `<app-cache>/training-media/<version>/<sha256>.<sequence>.part`，以流方式写盘，检查长度和 SHA-256 后重命名为 `<sha256>` 才可用；现有缓存每次读取也复校验，损坏即删除。`availableActionIds()` / `readyActionIds` 只包含当前允许动作的默认深色写实视频，离线计划可优先选这些 ID。`isOffline` 是当前连接探测结果，HTTP 不可达仍可能发生；`canDownload()` 可主动刷新，真实连接变更由插件监听。

默认只允许 Wi-Fi；移动网络、其他网络、无网络不会开启新请求，下载期间网络策略变更会取消临时文件。策略受阻动作和包在 Wi-Fi 恢复或用户取消 Wi-Fi 限制时自动续试；HTTP/完整性失败停在失败状态，由用户显式重试。连接、响应及数据空闲各默认 15 秒超时，可在 `create(downloadTimeout: ...)` 调整。镜像按配置顺序尝试，关闭自动重定向。后台最多并发 3 个媒体文件，同一哈希的请求合并。

`DrillMediaView` 等待时保留封面和加载状态，失败保留封面与说明；不等待下载再启动训练引擎或语音。清缓存先取消并等待已有下载，推进 generation 撤销旧能力，再删文件；并发清理共享同一个 Future，旧任务不能重新写入。空间统计与清理覆盖 `training-media/` 下所有版本，目录遍历和逐文件计数容忍并发删除；不访问其他 App 缓存。包内资源始终保留。缓存视频只通过本机回环固定 `/verified-media/clip.mp4` 读取，路径不能选取其他文件，支持 GET/HEAD、单区间 Range，非法/多区间返回 416。

`releaseEligible` 为 false 的动作缺省不可见、不可下载。`allowPending: true` 还必须通过共用编译策略 `TrainingMediaPreviewPolicy.enabled`：debug 维持开发预览；release/profile 只有 `FLUTTER_APP_FLAVOR=internal` **同时** `UGK_INTERNAL_MEDIA_PREVIEW=true` 才能预览。普通 production 构建、缺少 flavor 或仅一个开关都不放行。内测构建缺省 `allowPending: false` 仍隐藏待审核动作；该开关不能在运行时打开生产门禁。

宿主可复用此 const 判断是否启用内测设置及局域网下载地址。Flutter 内测命令采用 `flutter build apk --release --flavor internal --dart-define=UGK_INTERNAL_MEDIA_PREVIEW=true`，并由宿主另设“允许待审核”的开关。宿主需要先定义独立 `internal` flavor，隔离应用标识、显示名称及 Android 网络安全配置；生产 flavor 不配置内测 opt-in。此策略不自行修改平台网络权限，不保证 HTTP 自动可用。Web 暂仅支持内置素材，缺失素材降级到封面，不播放未经校验的远端 URL。本包不创建云资源或上传素材。

## 测试

当前 0.2.0 验收源码 `64a54874307449c8685577f8eeb913296b207a7c` 的 `flutter test --no-pub --reporter expanded` 为 207 项通过，静态分析无问题；根包 456 项、共享 Schema 样例 12 个通过，SmartFit 临时副本 41 项定向回归通过。完整命令与边界见[0.2.0 验证记录](../../docs/trainer-020-verification-2026-10-23.md)。后续批准状态与本次收束仅改文档，复用已验源码证据。

**0.1.7 历史复审：** `flutter test --no-pub` 为 170 项通过，`flutter analyze --no-pub` 为 0 问题，source 为 `b84881f58c035b1fce2ff929cdb207e465821c92`；其与合入提交 `eb29c749a52c1b226841726a3fba8e9f62e9e6be` 整树一致。0.1.7 收束仅调整版本与文档，验证命令和适用性见[维护台账](../../docs/project-ledger.md)。

覆盖引擎、自主计次与换边、节奏与语音队列、保活、结果幂等保存、App 插槽、完成页音频释放及再练、媒体仓库下载/缓存/策略故障注入，以及舞台切换稳定性。`stage_r9_test.dart` 的 17 项回归覆盖剂量持续显示、宿主剂量文案、大字号横竖屏和键盘操作。夹具在 `test/fixtures`；真机帧率和宿主完整训练不在这 170 项离线测试的证明范围内。

## 未带过来（留在各 App）

- HipLab：开场念课程名（`routine.*`）、按剂量文字找的台词（`textKey`）、紧侧多做一组（D-01）、自测流程。
- SmartFit：星空背景、自绘图标、完成页动画。
