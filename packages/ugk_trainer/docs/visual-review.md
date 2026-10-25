# 训练播放页候选与布局记录 R4

用户否决 R3 的扁平磨砂效果后，本轮直接采用技能 UGK Water 案例中已调过的 accessory / control 光学配置，保留 `ugk_trainer-v0.2.9` 的位置、尺寸、排列和交互。本次是待开哥视觉评审的修订候选，未合 main、未发 tag；原生效果尚未运行，不能宣称视觉通过。

基线 SHA：`953be22414f23128af879dc62686db200db34265`。分支：`codex/trainer-liquid-glass`。本记录与代码、截图一同提交。

[布局对照（软件降级，非通透效果预览）](visual-review.html) · [材质与依赖说明](liquid-glass-design.md) · [展示页运行说明](../example/README.md)

## 实际改动

- 默认 HUD、提示框与次级圆钮使用 `liquid_glass_widgets 1.15.0` 公共 `GlassContainer`，请求 premium / clear 与库对应浅深 tint。accessory 采用 thickness 30 / blur 2 / lightIntensity 0.18，control 采用 24 / 3 / 0.2；高对比以 minimal / blur 0 降级。R3 的 standard / blur 0 无采样交付路径已撤下。
- 顶部使用 16px 连续超椭圆；原 34dp 关闭按钮、32dp 倒计时字号、prev/skip 圆钮及休息控件外框保持。结果保留顶部完成卡、中间两张统计卡及底部完成按钮。
- 关闭、不舒服、换侧、加时、静音等统一为 Cupertino 图标。下一个动作没有海报或加载失败时，在原 28px 圆槽内显示下一项符号；提示 w500、指导语 w400。
- 单一承载面内的控件由库使用 vibrancy，不嵌套折射；去掉默认表面外重复的手绘阴影，自定义 `glassStyle` 保留旧绘制合约。结果卡片沿用 accessory 材质；主按钮保持原变形、径向 halo 与重绘边界，只在颜色转换期间使用一个圆盘范围的局部离屏层。

## 运行

在本分支工作树中执行：

```powershell
cd packages/ugk_trainer/example
flutter pub get
flutter run -d <设备ID>
```

独立应用 ID：`com.ugk.trainer.showcase`。顶部工具栏可选择训练中、休息、换侧、结果，以及浅色／深色／跟随系统。展示入口使用真实播放器和状态机、假数据及原创透明矢量人物。保存只在内存；没有业务账号、真实媒体下载或外部 App 数据操作。

## 当轮检查与待验

- SDK **253 项测试通过**（并发 2），包与示例静态分析通过；示例 **4 项测试通过**，覆盖四状态/结果回调、切主题保留暂停、系统主题优先级和配对布局图。
- 四状态 × 浅深共 **106 个控件外框与旧版完全一致，最大偏移 0dp**；62 个缺席锚点也一致。见 [布局比较](visuals/layout-comparison.json)。普通模式检查采样范围局限于控件，高对比检查无采样层；软件重绘探针仍保持呼吸、媒体与进度更新隔离。
- Android debug APK 构建通过（Gradle 17.6 秒），**191833191 bytes**，SHA-256：`E92ADB0453505E23EB2DC542A24457031E822C98F5FA652D9BC1DFFAEB322DE4`。路径：`example/build/app/outputs/flutter-apk/app-debug.apk`。未安装到用户设备。

以上测试及布局结果均重新运行于 R4。首次全套曾在未改动的 `explicit theme handover drops the old frame while the next video resolves` 用例中，100ms 等待窗口内未观察到本地 HTTP 请求；该用例定向重跑通过，随后并发 2 的完整 253 项重跑通过。未改媒体生产逻辑、该测试或等待时限。SDK 使用公共组件自身按需加载，没有恢复曾在测试环境选错 shader 路径的全库初始化。

本轮曾启动专用 Android 模拟器；收到用户禁止启动模拟器的指令后立即停止，并确认对应进程为 0。该启动不计作 R4 原生验证。遵照用户的禁止模拟器指令及内存限制，本轮没有继续原生视觉与性能运行。

## 布局截图范围

保留基线 8 张 before 图片，R4 重新采集四状态浅深共 8 张 after 布局图。图片来自 Flutter 软件测试渲染：430×932 逻辑视口，排除工具栏后 430×883，2× PNG，1000ms，启用软阴影。基线加载 Material Icons，候选同时加载 Cupertino Icons；中文使用本机字体且未复制分发。源文件与图片摘要见 [capture-manifest.json](visuals/capture-manifest.json)。

**这些图片只检查布局、文字和图标，属于软件降级，非通透效果预览。** 库的 Web 路径同样降级；软件图和网页都不能证明 Android/iOS premium 材质、主体透出或边缘折射。R3 的 Web 休息截图已退出本记录；R4 视觉仍需原生 APK 后续评审。

| 状态 | 浅色 | 深色 |
| --- | --- | --- |
| 训练中 | ![训练中浅色](visuals/after-training-light.png) | ![训练中深色](visuals/after-training-dark.png) |
| 休息 | ![休息浅色](visuals/after-rest-light.png) | ![休息深色](visuals/after-rest-dark.png) |
| 换侧 | ![换侧浅色](visuals/after-transition-light.png) | ![换侧深色](visuals/after-transition-dark.png) |
| 结果 | ![结果浅色](visuals/after-result-light.png) | ![结果深色](visuals/after-result-dark.png) |

## 兼容性与未验证项

本候选的 `liquid_glass_widgets 1.15.0` 原生辅助插件要求 **iOS 15+**。这会提高仍支持 iOS 13/14 的宿主的最低构建要求，不能视为零集成成本；合入前需要按宿主支持范围裁决。Android 使用同一 Flutter 材质路径。

Android 真机安装、R4 原生视觉／透明视频／profile 帧率和 iOS 构建运行均未执行。用户尚未认可 R4；其他项目的材质反馈、旧 tag 或 R3 的测试都不是本轮视觉与性能证据。计次、语音、状态机、后台处理和公开调用签名没有修改。
