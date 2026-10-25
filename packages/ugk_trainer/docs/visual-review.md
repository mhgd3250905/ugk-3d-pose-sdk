# 训练播放页视觉评审 R2

本轮只打磨按钮、提示与文字的材质、配色和字重，保留 `ugk_trainer-v0.2.9` 的位置、尺寸、排列和交互。首版的布局调整已撤回；本次是待开哥评审的修订候选，未合 main、未发 tag。

基线 SHA：`953be22414f23128af879dc62686db200db34265`。分支：`codex/trainer-liquid-glass`。本记录与代码、截图一同提交。

[四状态浅深前后对照](visual-review.html) · [材质与依赖说明](liquid-glass-design.md) · [展示页运行说明](../example/README.md)

## 实际改动

- HUD 与提示撤掉厚白/厚灰覆盖，使用清薄底色、细边缘和较轻阴影；主要按钮改为染色透光效果，文字保持明确主次。
- 恢复 34dp 关闭按钮、32dp 倒计时字号、原 prev/skip 圆钮与原休息控件；结果恢复顶部完成卡、中间两张统计卡及底部完成按钮。
- 结果的静态卡片使用技能首选库的 clear 材质；视频和高频控件没有新增实时背景采样。主按钮只在颜色转换期间使用一个圆盘范围的局部离屏层。

## 运行

在本分支工作树中执行：

```powershell
cd packages/ugk_trainer/example
flutter pub get
flutter run -d <设备ID>
```

独立应用 ID：`com.ugk.trainer.showcase`。顶部工具栏可选择训练中、休息、换侧、结果，以及浅色／深色／跟随系统。展示入口使用真实播放器和状态机、假数据及原创透明矢量人物。保存只在内存；没有业务账号、真实媒体下载或外部 App 数据操作。

## 当轮验证

- SDK 全部 **249 项测试通过**；包及示例静态分析通过。
- 示例 **4 项测试通过**，覆盖四状态与结果回调、切换主题保留暂停状态、系统主题优先级，以及配对截图。
- 同一视口、字体、数据与时间下，四状态 × 浅深共 **106 个组件外框与基线完全一致，最大偏移 0dp**；62 个应缺席锚点也一致。见 [布局比较](visuals/layout-comparison.json)。
- 重绘探针确认视频、按钮呼吸与环更新继续隔离；倒计时及 prev/skip 不随这些独立更新重绘。原有键盘操作、大字号、交互与动画测试通过。
- Android debug APK 构建通过，48.1 秒；未安装到用户设备。路径：`example/build/app/outputs/flutter-apk/app-debug.apk`，**191832030 bytes**，SHA-256：`F3BC89ACBC53A8C36B6502692C8F0EF1DA40484040EFC7C49C7DF4395DAC4FA1`。

初次接入曾因库全局预热在测试环境选择错误 shader 路径而失败。已移除 SDK 内的全库初始化，改用公共组件自身按需加载；上述 249 + 4 项是修正后的本轮结果，没有忽略该异常。

## 截图范围

16 张前后图片为 Flutter 软件测试渲染：430×932 逻辑视口，排除工具栏后 430×883，2× PNG，1000ms，使用本机中文及 Material Icons 字体，启用软阴影。字体未复制分发。源文件与图片摘要见 [capture-manifest.json](visuals/capture-manifest.json)。

训练 HUD 可据此检查配色、文字和半透明绘制；**结果页截图是库的轻量降级路径，不能证明 Android/iOS Impeller 折射效果**。浅深均已人工查看，但用户满意度尚待评审。连续边缘光学、真实透明视频合成与设备帧率仍待验。

| 状态 | 浅色 | 深色 |
| --- | --- | --- |
| 训练中 | ![训练中浅色](visuals/after-training-light.png) | ![训练中深色](visuals/after-training-dark.png) |
| 休息 | ![休息浅色](visuals/after-rest-light.png) | ![休息深色](visuals/after-rest-dark.png) |
| 换侧 | ![换侧浅色](visuals/after-transition-light.png) | ![换侧深色](visuals/after-transition-dark.png) |
| 结果 | ![结果浅色](visuals/after-result-light.png) | ![结果深色](visuals/after-result-dark.png) |

## 兼容性与未验证项

本候选的 `liquid_glass_widgets 1.15.0` 原生辅助插件要求 **iOS 15+**。这会提高仍支持 iOS 13/14 的宿主的最低构建要求，不能视为零集成成本；合入前需要按宿主支持范围裁决。Android 使用同一 Flutter 材质路径。

Android 真机安装、原生视觉／透明视频／profile 帧率和 iOS 构建运行均未执行。旧 tag 的性能结果不是本轮证据。计次、语音、状态机、后台处理和公开调用签名没有修改。
