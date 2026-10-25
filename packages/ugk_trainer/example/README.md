# 训练播放 UI 验收展示

本入口直接运行 `TrainerPlayer`，通过公开的 `sessionBuilder`、`mediaBuilder` 和主题参数提供假数据。训练中、休息、换侧、结果均使用 SDK 的真实界面。右上角可选择浅色、深色或跟随系统；切换主题保留当前计时、暂停状态和结果。重播按钮重新开始所选状态。

模拟人物由本示例原创矢量绘制，背景透明，不下载动作素材。结果页由三段短训练通过真实状态机完成后生成，统计时长较短是刻意的测试数据。保存仅在内存进行，没有账号、网络请求、持久化或外部 App 数据操作。语音使用 `TrainerVoice.silent`，后台保活关闭。

## 在设备上运行

在 SDK 仓库根目录执行：

```powershell
cd packages/ugk_trainer/example
flutter pub get
flutter devices
flutter run -d <设备ID>
```

Android 应用 ID 与 iOS bundle ID 均为 `com.ugk.trainer.showcase`，与宿主 App 分开。Android 可用 USB 真机或模拟器。iOS 需在 macOS 上使用 Xcode 配置该独立示例的开发签名后运行；Windows 上的测试不证明 iOS 构建通过。示例仅配置调试运行，未将 release 构建偷偷改为 debug 签名。

浏览器布局预览：

```powershell
flutter run -d chrome
```

也可只构建 Android 调试 APK，稍后由验收者自行安装：

```powershell
flutter build apk --debug
```

输出位于 `build/app/outputs/flutter-apk/app-debug.apk`。此制品用于展示，不是对外发布包。

## 建议检查

在同一设备依次选择训练中、休息、换侧、结果，分别切浅深主题。观察透明人物与背景、顶部信息层次、数字/环形进度、上一项/跳过、休息加时及结果统计。训练中可暂停后切主题，确认暂停未丢失；休息可点 `+15 秒`；点下一项观察真实阶段变化。选“跟随系统”后改变系统亮度，检查同一页面随之更新。

示例覆盖 UI 与交互，不替代真实透明视频、语音、后台、来电或原生媒体性能验收。

## 自动检查与成对截图

```powershell
flutter analyze --no-pub
flutter test test/showcase_test.dart
```

截图 harness 使用 Flutter test renderer，在同一 430×932 逻辑视口、同一时间点采集四状态浅深共 8 张 PNG；不包含展示工具栏。它们是 Flutter 软件测试渲染证据，不能标作 Android/iOS 真机截图或 GPU/折射性能证据。

```powershell
$env:SHOWCASE_CAPTURE_DIR = Join-Path (Get-Location) '.review-artifacts/screenshots'
$env:SHOWCASE_FONT = 'C:\Windows\Fonts\msyh.ttc'
flutter test test/showcase_test.dart --plain-name 'capture four states'
Remove-Item Env:SHOWCASE_CAPTURE_DIR
Remove-Item Env:SHOWCASE_FONT
```

`SHOWCASE_FONT` 仅供本机加载有使用权的中文 TTF/TTC。字体文件不会被复制或随仓库分发。其他平台可传自己的字体路径；未设置时普通测试照常运行，但 Flutter 默认测试字体不适合视觉评审。截图目录可指定为仓库内的其他位置，便于同一 harness 对比基线与候选。
