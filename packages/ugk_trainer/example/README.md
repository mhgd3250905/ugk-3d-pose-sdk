# 训练播放 UI 验收展示

本入口直接运行 `TrainerPlayer`，通过公开的 `sessionBuilder`、`mediaBuilder` 和主题参数提供假数据。训练中、休息、换侧、结果均使用 SDK 的真实界面。右上角可选择浅色、深色或跟随系统；切换主题保留当前计时、暂停状态和结果。重播按钮重新开始所选状态。

R4 将默认 HUD、提示及次级按钮接到技能已经调过的 premium 光学配置，并使用 Cupertino 图标；旧版控件位置和操作保留。静态图片见[布局对照（软件降级，非通透效果预览）](../docs/visual-review.html)。Web 与软件测试只用于布局、文字、图标和一般交互检查，不能预览原生透镜效果；后续视觉评审应使用本轮原生 APK。

模拟人物由本示例原创矢量绘制，背景透明，不下载动作素材。结果页由三段短训练通过真实状态机完成后生成，统计时长较短是刻意的测试数据。保存仅在内存进行，没有账号、网络请求、持久化或外部 App 数据操作。语音使用 `TrainerVoice.silent`，后台保活关闭。

## 在设备上运行

在 SDK 仓库根目录执行：

```powershell
cd packages/ugk_trainer/example
flutter pub get
flutter devices
flutter run -d <设备ID>
```

Android 应用 ID 与 iOS bundle ID 均为 `com.ugk.trainer.showcase`，与宿主 App 分开。原生视觉可在验收者后续有条件时使用指定设备与本轮 APK 检查；本轮遵照用户指令不启动模拟器。iOS 需在 macOS 上使用 Xcode 配置该独立示例的开发签名后运行；Windows 上的测试不证明 iOS 构建通过。示例仅配置调试运行，未将 release 构建偷偷改为 debug 签名。

`liquid_glass_widgets 1.15.0` 的原生辅助插件要求 iOS 15+；接入仍支持 iOS 13/14 的宿主前，需要先裁决其最低系统版本。

浏览器布局演示（库的降级路径，非通透效果预览）：

```powershell
flutter run -d chrome
```

也可只构建 Android 调试 APK，稍后由验收者自行安装：

```powershell
flutter build apk --debug
```

输出位于 `build/app/outputs/flutter-apk/app-debug.apk`。此制品供后续原生视觉评审使用，不是对外发布包；构建通过不等于已经安装、运行或获得视觉认可。

## 建议检查

在同一设备依次选择训练中、休息、换侧、结果，分别切浅深主题。观察透明人物与背景、顶部信息层次、数字/环形进度、上一项/跳过、休息加时及结果统计。训练中可暂停后切主题，确认暂停未丢失；休息可点 `+15 秒`；点下一项观察真实阶段变化。选“跟随系统”后改变系统亮度，检查同一页面随之更新。

本轮还需检查下一个动作的占位符、不舒服提示与选项、指导语的可读性、静音图标切换和加时回调。默认 accessory 采用 30 / 2 / 0.18，control 采用 24 / 3 / 0.2（thickness / blur / lightIntensity），均请求 premium / clear 与库对应浅深 tint；高对比采用 minimal / blur 0。原生主体透出、边缘折射、媒体合成与性能需要对应平台运行，不能由参数或 Web 降级推定通过。

示例覆盖 UI 与交互，不替代真实透明视频、语音、后台、来电或原生媒体性能验收。

## 自动检查与成对截图

```powershell
flutter analyze --no-pub
flutter test test/showcase_test.dart
```

截图 harness 使用 Flutter test renderer，在同一 430×932 逻辑视口、同一时间点采集四状态浅深共 8 张 PNG；不包含展示工具栏。它们只作布局对照，软件降级的磨砂表现不能作为真实玻璃交付效果，也不能标作 Android/iOS 真机截图或 GPU/折射性能证据。

harness 显式加载 Flutter Material Icons 与依赖包的 Cupertino Icons 字体。新增图标后须先运行 `flutter pub get`；仅引入 `CupertinoIcons` 而没有字体资产会造成截图缺字形。中文字体仍通过下面的本机参数加载。

如果新增字体依赖后仍报资产不存在，先检查 `build/unit_test_assets/FontManifest.json`。Flutter 3.47.8 的测试缓存可能遗漏时间戳较旧的新依赖资产；更新示例 `pubspec.yaml` 的修改时间后重跑会重新生成资产，无需清理工作树或复制字体。

```powershell
$env:SHOWCASE_CAPTURE_DIR = Join-Path (Get-Location) '.review-artifacts/screenshots'
$env:SHOWCASE_FONT = 'C:\Windows\Fonts\msyh.ttc'
flutter test test/showcase_test.dart --plain-name 'capture four states'
Remove-Item Env:SHOWCASE_CAPTURE_DIR
Remove-Item Env:SHOWCASE_FONT
```

`SHOWCASE_FONT` 仅供本机加载有使用权的中文 TTF/TTC。字体文件不会被复制或随仓库分发。其他平台可传自己的字体路径；未设置时普通测试照常运行，但 Flutter 默认测试字体不适合视觉评审。截图目录可指定为仓库内的其他位置，便于同一 harness 对比基线与候选。
