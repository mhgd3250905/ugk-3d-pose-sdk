# 训练播放页材质与验收说明

本轮是 `ugk_trainer` 的 UI 评审候选，同时交付浅色、深色和可运行展示入口。设计目标是让人物、训练状态和主操作清楚分层；代码与测试完成不代表开哥已接受视觉效果。成对截图及当轮制品身份见 [视觉评审记录](visual-review.md)。

## 实现边界

训练 HUD、倒计时、上一项/跳过使用半透明渐变、方向性描边和局部阴影，不对人物视频或每帧更新区域做背景采样。倒计时及 prev/skip 的 `RepaintBoundary`、倒计时径向光环继续保留，route 没有新增全页 `Opacity` 或裁剪包装。

`TrainerPlayer` 提供不透明的 `mediaStage` 底色，静态 `TrainerStageFloor` 放在人物媒体下面；透明人物显露背景，背景不叠在人物上染色。浅深主题分别调整底色、文字和材质，而非整屏提亮或加厚白雾。休息与切换沿用这条低成本路径。

只有结果页使用真实折射：`TrainerResultStage` 承载静态背景，`TrainerResultSurface` 是一块 `LiquidGlassLens`，内部保持普通文本与统计内容，不叠套玻璃。精确固定 `liquid_glass_easy: 5.0.0`；镜片自行异步加载 shader，现有宿主无需新增 `main()` 初始化、全局主题包装或平台分支。该依赖没有 native plugin，不额外提高 Android/iOS 最低系统版本。

结果背景的 `realTimeCapture: false` 复用 Skia/Web 快照，主题或尺寸变化时只调用一次 `captureOnce()`；Impeller 在绘制结果镜片时读取背景。未启用 `touch` 或自适应亮度采样。镜片采用 32 圆角、1.02 折射率和 24 宽度的折射带，保留清透低 alpha 底色，不加实时模糊；这些是本轮页面参数，不是通用设计标准。高对比度时改用稳定实底。结果区域局部关闭 Android stretch overscroll 装饰，避免上游已知的隔离合成层使镜片变黑，正常滚动仍保留。

计次、语音、状态机、原生媒体和公开调用契约不变。主题保持原构造方式；展示页通过已有 `sessionBuilder`、`mediaBuilder` 等入口提供假数据，不在生产逻辑增加演示状态。

## 技能适配与依据

使用的技能是 `C:\Users\29485\.codex\skills\flutter-ios-liquid-glass\SKILL.md`，其中原句为：“由库负责光学与交互，不另写仿玻璃渐变、发光边缘或拟物表面”。本次用户明确要求视频上层及高频区域不用实时模糊，并指定使用绘制材质；该明确要求优先于技能的一般指导。用户随后强调最终视觉质量，因此静止结果区域采用兼容的真实光学库，训练控制仍保持性能隔离。

[Apple 材质指南](https://developer.apple.com/design/human-interface-guidelines/materials) 将玻璃用于浮动控制层，强调内容与控制的层次。这里借鉴其布局和材质角色，不宣称 Flutter 实现等同系统原生效果。[Flutter 重绘边界说明](https://api.flutter.dev/flutter/widgets/RepaintBoundary-class.html) 和 [性能建议](https://docs.flutter.dev/perf/best-practices) 支持隔离不同更新频率的子树，并减少额外 opacity/saveLayer 与裁剪。

| 核查对象 | 结论 |
| --- | --- |
| [`liquid_glass_easy` 5.0.0](https://pub.dev/packages/liquid_glass_easy/versions/5.0.0) | 2026-10-10 发布，GitHub 最近推送为 2026-10-15；[MIT](https://github.com/AhmeedGamil/liquid_glass_easy/blob/main/LICENSE)。已核查发布包源码：仅 Flutter SDK 与 `meta` 依赖、shader 懒加载、无原生 plugin。采用其公开 Lens/View API，不复制第三方实现。 |
| [`liquid_glass_widgets` 1.15.0](https://pub.dev/packages/liquid_glass_widgets/versions/1.15.0) | 活跃维护、MIT，但发布包 iOS plugin 的 podspec/SPM 要求 iOS 15；单纯 UI 改造不应因此提升宿主系统底线。 |
| [`liquid_glass_widgets` 1.10.0](https://pub.dev/packages/liquid_glass_widgets/versions/1.10.0) | 最后一个无原生 plugin 的版本，但后续版本才补 shader 生命周期、曲面抗锯齿与边缘修复，未选用旧版来绕开系统要求。参见其 [变更记录](https://pub.dev/packages/liquid_glass_widgets/changelog)。 |

同库参考可直接查看 [官方互动镜片展示](https://ahmeedgamil.github.io/liquid_glass_easy/demos/index.html?d=lens-plain&v=-4b98f3de7)、[Lens/Style API](https://ahmeedgamil.github.io/liquid_glass_easy/en/api-lens.html)、[静态快照与加载 API](https://ahmeedgamil.github.io/liquid_glass_easy/en/api-view.html)。官方展示是实现参考，不是本 SDK 的渲染验收证据。

## 验证记录

| 检查 | 本轮记录 |
| --- | --- |
| `ugk_trainer` 测试 | 249 项通过；包含原有行为、媒体及重绘隔离回归。 |
| 原有焦点断言 | `stage_r9_test.dart` 的旧定位键 `glass-button-focus` 已不对应独立播放按钮，更新为 `play-pause-focus`；保留焦点行为断言，没有删除或放宽断言。 |
| 展示页测试 | 4 项通过，覆盖四状态、主题切换时保留暂停状态、跟随系统与显式主题优先级、成对截图 harness。 |
| 静态分析 | 包与展示入口分析通过。 |
| Android 调试 APK | 已构建；制品大小与 SHA-256 见 [视觉评审记录](visual-review.md)。未安装设备。 |
| Android 真机 / iOS / 性能 | 未验证。软件测试截图不证明目标 GPU 折射、真实透明视频合成或设备帧率通过。 |

从 SDK 仓库根目录运行：

```powershell
cd packages/ugk_trainer/example
flutter pub get
flutter run -d <设备ID>
```

展示页可切训练中、休息、换侧、结果及浅色/深色/跟随系统。Android 与 iOS 使用同一套界面；iOS 真机运行仍需 macOS/Xcode 和示例开发签名。完整命令、独立应用 ID、假数据边界及截图方式见 [展示页 README](../example/README.md)。本轮交付待审分支，不包含合 main、发 tag 或应用发布。
