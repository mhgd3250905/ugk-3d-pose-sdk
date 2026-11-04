# iOS packed alpha 原生后端 · 2026-11-04

分支 `codex/ios-packed-alpha`，基线 `9dd93163e9f355665e5c923f374c64f03bf65a86`。
仅修改 `packages/ugk_trainer_runtime` 和本目录。Flare 宿主使用本机
`/Users/shengkai/3D-Flare/app`、`codex/sdk-pin-v0.7.0`、1.0.12+18，
验收时通过忽略的 `pubspec_overrides.yaml` 引用本地五包。

## 实现与要求

- iOS 15.0 起，Flutter ≥3.44.0、Dart ^3.12.0，需支持 shader filter 的 Impeller/Metal。
  本轮固定 Flutter 3.44.7 / Dart 3.12.2，Xcode 26.6 / iOS SDK 26.5。
- SPM 和 CocoaPods 共享 Swift 源码，仅注册既有 packed alpha 两个通道。
  AVPlayer 静音、不设置 AVAudioSession、不自行常亮，不注册 iOS `training_session`。
- AVPlayerItemVideoOutput 输出 BGRA/Metal/IOSurface 像素缓冲；CADisplayLink 拉帧，
  首次在 raster 线程交出真实缓冲后才发 `first-frame`。锁保护缓冲和销毁状态。
  循环 seek 保留末帧；不可见、暂停、销毁时停止拉帧。position 仅应请求读取。
- 校验旋转后 `width > 0 && height == 2*width`，保留 Dart 和原生来源限制。
  创建/解码失败沿用“视频暂不可用，训练继续 · 重试”，不影响训练时钟。
  shader、Android、缓存校验、动作和 QA 数据未改。
- 随包资源、缓存文件和 HTTPS 不需新增 Info.plist 权限；HTTP 仍受宿主 ATS 约束。
  未启用 iOS 后台模式，锁屏/后台计时行为不据静态代码认定实测通过。

## 验证

| 检查 | 结果 |
| --- | --- |
| 修改前 runtime | analyze 0，71 项测试通过 |
| 修改前 Flare iOS | `flutter build ios --debug --no-codesign` 通过 |
| runtime 修改后 | analyze 0，80 项通过；`--enable-impeller` 平台测试 7 项通过 |
| 根包 | analyze 0，1,557 项通过 |
| ugk_coach_chat | analyze 0，73 项通过，文件未修改 |
| ugk_coach_ui | analyze 0，179 项通过、4 项 golden 差异；原始 SHA 同四项复现，未更新 golden |
| ugk_trainer | 首次并发运行有 2 项时序失败；单独复测及最终 `flutter test --concurrency=1` 全量 581 项通过。analyze 有 3 条既有 unawaited_futures info，原始 SHA 同样复现 |
| Flare SPM / CocoaPods | 两种 `flutter clean → pub get → build ios --debug --no-codesign` 均通过；SPM 设置已恢复开启 |
| iOS 原生 XCTest | iOS 26.5 模拟器 4/4 通过，详见下文 |
| Swift 编译检查 | iOS device/simulator Swift 源码 `-typecheck -warnings-as-errors` 通过；XCTest 源码检查通过 |
| Android APK | 已尝试，Gradle 因本机缺 Java Runtime 失败；Android SDK 存在，未安装新 JDK |

原生 XCTest 使用 AVAssetWriter 生成测试用 H.264，不依赖动作素材或网络。覆盖来源边界、
无效尺寸、ready 元数据、真实首帧只发一次、BGRA 平面/通道和 alpha 接近 0/1、
暂停/继续、visible、active=false 清除播放意图、currentTime 循环、无空缓冲、
正常/提前/重复销毁与销毁后无事件。RGB 使用有损编码容差，灰度 alpha 端点独立校验。
运行方式：

```bash
cd packages/ugk_trainer_runtime
ruby tool/run_ios_packed_alpha_tests.rb /Users/shengkai/3D-Flare/app <simulator-UDID>
```

## 真机待验与证据

用户本轮明确“暂时无法连接，先完成实现和编译”，未执行 iPhone 验收，未生成真机录屏/截图。
真实公共 MP4、随包/缓存、飞行模式、损坏重下、镜像/切动作/返回、锁屏/后台恢复、
训练语音、浅深主题下 Metal 上下方向/平面对齐/边缘/封面衔接均仍待真机验收。
模拟器合成视频和 widget 测试不等同于上述项目通过。

原始日志和最终 XCTest 结果保留于本机
`/Users/shengkai/3D-Pose-SDK/ugk-3d-pose-sdk/build/ios-packed-alpha/`，不入库。
真机证据预留 `docs/ios-packed-alpha-20261104/evidence.local/`，该目录被忽略。
两次模拟器测试曾因磁盘满中断；按用户追加授权清理了其他项目的可再生编译/模块缓存后继续，
路径记录在 `build/ios-packed-alpha/cleanup.log`，历史 xcarchive/IPA/证据保留。

交付为 Draft PR，不合并、不打 tag、不修改 App 远端、不上传 TestFlight/App Store。
