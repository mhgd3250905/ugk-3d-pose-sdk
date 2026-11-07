# ugk_trainer_runtime

训练播放的唯一实现：`SessionBuilder`、`SessionEngine`、`SessionResult`、voice/media、
训练 UI、`TrainerSlideRoute` 和 Android/iOS 插件。包内仅含公共网页播放器、静音音轨与
alpha shader，**不含动作目录、封面、视频、action-kit 或动作命名语音**。

依赖方向为 `ugk_trainer → ugk_trainer_runtime → ugk_coach`。旧包保留历史全量资源，
转导出这里的类型；同时导入新旧入口得到的是同一个类型、静态状态和插件，不需要转换 DTO。
`ugk_coach_ui` 继续不依赖 Coach/Trainer；本批没有创建 `ugk_coach_chat`。

## 接入

```yaml
dependencies:
  ugk_trainer_runtime:
    git:
      url: https://github.com/mhgd3250905/ugk-3d-pose-sdk.git
      path: packages/ugk_trainer_runtime
      ref: <审核后的完整提交 SHA>
```

```dart
import 'package:ugk_trainer_runtime/ugk_trainer_runtime.dart';
// 纯 Dart 的执行时间线、Result、节奏和语音调度：
// import 'package:ugk_trainer_runtime/engine.dart';
```

SDK 内部使用相对路径指向同一 Git 树的兄弟包；宿主仍固定完整 Git SHA，不跟踪可变分支。
若宿主还直接依赖 `ugk_coach`，应固定到同一 SDK 提交。

训练器的构造参数、生命周期、计时、语音和路由语义沿用旧包。`startGate`、
`chromeAnimation`、`beforeExitPop`、`onExitStarted` 无需重新实现。
入口详见[旧训练器接入文档](../ugk_trainer/README.md)。

示范视频的 HUD、宿主下载状态、`onTiming` 运行日志及当前动作优先队列见
[下载进度与提速接入说明](../../docs/media-progress-r1.md)。
`TrainerPlayer.showMediaDownloadIndicator` 默认 `true`；宿主自行下载时可提供
`mediaDownloadState`（`ValueListenable<CatalogMediaDownloadState>`）和 `onMediaDownloadRetry`，
自定义媒体视图还须绑定 `request.playbackHandle`：下载 ready 和当前视频首帧均到达后 HUD 才完成。
`TrainingActionMedia.prefetchWhenIdle` 默认 `false`，SDK 仅为播放器当前动作开启；
列表、详情和其它未播放预览不提前下载。`onTiming` 由宿主接入既有日志存储，SF 接入另单处理。

### iOS 透明示范视频

iOS 15.0 起提供与 Android 相同的 packed alpha 通道；要求 Flutter ≥3.44.0、
Dart ^3.12.0 和支持 `ImageFilter.shader` 的 Impeller（iOS 使用 Metal）。
SPM 与 CocoaPods 共用 `ios/ugk_trainer_runtime/Sources/ugk_trainer_runtime` 下的 Swift。
RGB 位于视频上半、alpha 位于下半；视频尺寸必须是 `width × 2*width`。

随包资源、已校验缓存文件和 HTTPS MP4 不需要新增 Info.plist 权限。HTTP 仍受宿主
现有 ATS 策略约束；插件不自动放宽网络限制。播放器静音、不设置 AVAudioSession、
不自行常亮；iOS 不注册 Android 的 `training_session` 服务，也不启用后台训练模式。
解码失败由训练页下载 HUD 的重试状态承接，不影响训练计时。

原生测试在 Flutter 宿主完成 `flutter pub get` 后运行（需要 Ruby `xcodeproj`，
CocoaPods 已包含此 gem）：

```bash
ruby tool/run_ios_packed_alpha_tests.rb /absolute/path/to/Flare/app <simulator-UDID>
```

测试临时把原生源文件加入宿主 `RunnerTests`，结束后恢复原 Xcode 工程文件；
测试生成自己的 H.264 视频，不打包动作素材。真机 Metal 方向、边缘、主题、语音及
前后台验收须另做，不能由模拟器或 widget 测试替代。见
[首次验证记录](../../docs/ios-packed-alpha-20261104/verification.md)；
新基线迁移、测试期望变更、App 接入及后台差距见
[r2 迁移记录](../../docs/ios-packed-alpha-r2-20261107/verification.md)。

## 动作资源由宿主明确提供

用[白名单闭包生成工具](../../docs/trainer-assets-closure.md)把获批 manifest 生成到
宿主自己的资产目录，在 pubspec 中加入生成的逐文件清单，并用对应根路径加载目录、
海报和 `DrillMedia`。可运行的最小构建模板见
[trainer_runtime_minimal](../../examples/trainer_runtime_minimal/README.md)。

runtime 没有默认动作库。`PoseHubActionLibrary.load()` 和 `PoseHubStandingImage`
保留的历史默认 URI 属于旧包兼容契约；runtime-only 宿主必须传自己的目录和海报。
动作资源缺失时返回原有加载错误，不补全库、不自动下载、不把空名单解释成全量。
本批只提供素材生成与物理打包门禁，检索/工具/计划白名单守卫属于第 2 批。

## 公共资源与兼容键

`TrainerRuntimeAssets` 提供公共资源常量：`playerPrefix`、`poseHubPlayer`、`silence`、
`shader`。`resolveAsset(String key, {AssetBundle? bundle})` 只解析已知公共资源的旧键：

| 入口 | 兼容行为 |
| --- | --- |
| 依赖旧 `ugk_trainer` | 继续加载实际存在的 `packages/ugk_trainer/...` 字节；默认海报保留 |
| 仅依赖 runtime | 内部公共资源加载转到 `packages/ugk_trainer_runtime/...` |
| 动作专属或任意未知路径 | 不改写，不尝试全库兜底 |

旧公开常量值保持不变。为维持 rootBundle 兼容，旧包也保留少量公共文件原字节；
这不产生第二份 Dart/Kotlin 实现，也不会再注册一次插件。

本包没有发布 tag。拆包、测试、产物审计和接入边界见
[第 1 批交付记录](../../docs/trainer-runtime-split.md)及
[构建门禁](../../docs/runtime-split-build-gate.md)。
