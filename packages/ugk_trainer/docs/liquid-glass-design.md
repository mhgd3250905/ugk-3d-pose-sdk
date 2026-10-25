# 训练播放页材质说明

本候选按旧版 `ugk_trainer-v0.2.9` 的控件位置、尺寸和交互打磨美学。按钮、提示、文字和背景配色同时覆盖浅深主题。首版改变了 prev/skip 和结果页布局且材质偏厚，用户未认可；本轮恢复旧版布局后重新调整，仍待用户视觉评审。

## 材质与边界

训练 HUD、倒计时、上一项/跳过保留绘制材质，不采样人物视频。撤掉原来约 85% 覆盖的浅色底和 78% 覆盖的深色底，以低覆盖染色、细边缘和局部反光显露环境；不把这些绘制面宣称为物理折射。主题仍支持已有 `glassStyle` 覆盖，复杂不透明视频可由宿主提供更强的正文承载色。

主播放按钮保留 76/96px 圆盘/环、原图标变形和颜色波纹。稳定及呼吸时直接绘制；颜色切换期间仅在圆盘矩形内使用一个局部 `saveLayer`，使多层颜色先合成再施加材质 alpha，避免动画收尾跳色。倒计时与 prev/skip 的重绘边界、径向光环保留，route 不加整页 Opacity/Clip。

人物媒体下方提供不透明舞台底与静态环境光，透明人物不会被背景光叠加染色。休息和换侧沿用同一材质体系，不改变控件摆放。

结果页恢复原来的顶部完成卡、中段两张统计卡和底部完成按钮。只有此静态区域使用 `liquid_glass_widgets: 1.15.0` 公共 `GlassContainer`，采用 clear 材质与库的浅深 tint，从技能案例的 thickness 30 / blur 2 / lightIntensity 0.18 起点适配。内部文字和完成图标不嵌套折射层。宿主无需新增初始化或全局 Theme 包装，现有 API 与业务逻辑不变。

## 技能与参考

依据 `flutter-ios-liquid-glass` 技能的 UGK Water R4 记录：用户认可的是材质改善，不能扩张为整页已验收。检查重点是主体透出、薄而清晰的边缘、文字对比和浅深一致性，不以 shader 加载或测试通过代替视觉判断。

技能原句：“由库负责光学与交互，不另写仿玻璃渐变、发光边缘或拟物表面。”用户更具体的要求是视频与高频区域保持绘制、不用 BackdropFilter；本候选在这些区域遵从用户要求，静态结果页使用标准库。旧版布局保留的要求优先于技能中的通用布局建议。

- [liquid_glass_widgets 1.15.0](https://pub.dev/packages/liquid_glass_widgets/versions/1.15.0) 与 [上游 MIT 许可证](https://github.com/sdegenaar/liquid_glass_widgets/blob/main/LICENSE)：使用发布包公共 API，不复制私有引擎。该版本包含 iOS 原生辅助插件，要求 iOS 15；Android 使用同一 Flutter 材质路径。
- [技能所对照的官方 Podcasts 示例](https://github.com/sdegenaar/liquid_glass_widgets/blob/57dc25a4ff49e553e137fc9eda3c4bb83d82f0ee/example/lib/apple_podcasts/apple_podcasts_demo.dart)：参考材质角色，保留训练页自己的旧布局。
- [Apple 材质指南](https://developer.apple.com/design/human-interface-guidelines/materials) 与 [Flutter 性能建议](https://docs.flutter.dev/perf/best-practices)：控制层与内容层有区别，避免视频区域的大面积采样和不必要的离屏层。

曾核查 `liquid_glass_easy` 5.0.0 的缓存背景方案。它能不实时采样，但不透明静态快照会在镜片内替换人物画面，因此没有把该方案扩散到 HUD。当前依赖已改为技能首选库。

## 验证

当轮截图、布局坐标对照、测试和制品记录统一见 [视觉评审记录](visual-review.md)。软件渲染截图只支持构图、配色和可读性检查；原生折射、真实透明视频与 profile 性能需要对应设备证据，不沿用旧 tag 的性能数字。
