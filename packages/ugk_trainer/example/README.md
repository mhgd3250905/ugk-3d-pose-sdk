# 训练播放 UI 0.3.0 实色分层展示

## 0.4.0：219 动作库与自主单练

右上角动作库按钮进入全部 219 个原始 ID；支持名称/ID 搜索、142 个说明完整项和 77 个待补项筛选、详情与自主单练。待补项显示“训练说明待补”，不自动补次数、组数或时长。媒体来自另行安装的完整 R1 包，不随 Git 或 Web build 嵌入。打包与同源服务命令见[接入指南](../../../docs/posehub-app-test-pack-r1.md#sdk-acceptance-showcase)。默认训练展示与其四状态布局保持不变。

本入口直接运行 `TrainerPlayer`，通过公开的 `sessionBuilder`、`mediaBuilder` 和主题参数提供假数据。训练中、休息、换侧、结果均使用 SDK 的真实界面。右上角可选择浅色、深色或跟随系统；切换主题保留当前计时、暂停状态和结果。重播按钮重新开始所选状态。

`ugk_trainer 0.3.0` 使用不透明分层表面、1px 低对比描边和轻固定阴影，提示与控件统一使用 Cupertino 图标；配色来自 `TrainerTheme` 的浅深语义 token。原有控件位置、尺寸及操作保留。Web 可以直接展示当前实色 UI 和一般交互，静态前后对照见[视觉评审记录](../docs/visual-review.html)。

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

浏览器实色 UI 展示：

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

本轮还需检查下一个动作的占位符、不舒服提示与选项、指导语的可读性、静音图标切换和加时回调。分别观察浅深模式下页面、卡片和控件的层级、文字对比、描边及按压反馈；切换主题不应重建当前训练。真实媒体合成与设备性能仍需对应平台运行检查。

示例覆盖 UI 与交互，不替代真实透明视频、语音、后台、来电或原生媒体性能验收。

## 自动检查与成对截图

```powershell
flutter analyze --no-pub
flutter test test/showcase_test.dart
```

截图 harness 使用 Flutter test renderer，在同一 430×932 逻辑视口、同一时间点采集四状态浅深共 8 张 PNG；不包含展示工具栏。这些图片用于检查当前实色 UI 的构图、配色、文字和图标，属于软件测试渲染，不能标作 Android/iOS 真机截图或设备性能证据。

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
