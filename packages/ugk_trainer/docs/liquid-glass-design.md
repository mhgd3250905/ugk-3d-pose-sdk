# 训练播放页材质说明 R4

本候选按旧版 `ugk_trainer-v0.2.9` 的控件位置、尺寸和交互打磨美学。用户否决 R3 的扁平磨砂表现后，R4 直接采用技能 UGK Water 案例中已调过的 accessory / control 光学配置。此处复用配置，不迁移其他项目的验收结论；本项目原生视觉尚未运行，也未获用户认可。没有合入 main 或发布 tag。

## 材质与边界

默认训练 HUD、提示与次级圆钮使用 `liquid_glass_widgets: 1.15.0` 的公共 `GlassContainer`，请求 `premium` 光学路径。共享 `TrainerControlSurface` 按角色采用 `GlassBodyMode.clear` 与库内置对应浅深 tint，不增加不透明 backer 或内容覆盖。库负责材质，不另叠手绘 rim、光边或 `TrainerHover` 阴影。R3 的 standard / blur 0 无采样路径已撤下，不再作为交付目标。

| 角色 | thickness / blur / lightIntensity | 配置 |
| --- | --- | --- |
| 顶部、提示等 accessory | 30 / 2 / 0.18 | premium、clear、库对应浅深 tint |
| 次级按钮等 control | 24 / 3 / 0.2 | 同上 |
| 高对比降级 | 对应角色厚度 / 0 / 对应角色光强 | minimal、主题内容底色 |

顶部卡片使用 16px 连续超椭圆，保留原高度、padding 和子控件外框。小提示沿用胶囊，指导语沿用 16px 圆角；原按压缩放与回调保留。单一承载面内的关闭等控件交给库的 vibrancy 路径，不嵌套另一层折射。高对比模式的 `minimal` / blur 0 是可读性降级，不能代表通常模式的光学目标。

宿主显式传入 `glassStyle` 时，保留已有自定义绘制、阴影与非媒体静态面 blur 合约，不强制替换宿主材质。主题参数和公开调用方式没有变化。

主播放按钮保留 76/96px 圆盘/环、原图标变形和颜色波纹。稳定及呼吸时直接绘制；颜色切换期间仅在圆盘矩形内使用一个局部 `saveLayer`，使多层颜色先合成再施加材质 alpha，避免动画收尾跳色。倒计时与 prev/skip 的重绘边界、径向光环保留，route 不加整页 Opacity/Clip。

人物媒体下方提供不透明舞台底与静态环境光，透明人物不会被背景光叠加染色。休息和换侧沿用同一材质体系，不改变控件摆放。

结果页保留原来的顶部完成卡、中段两张统计卡和底部完成按钮，使用同一 accessory 配置；内部文字和完成图标不嵌套折射层。Web 与软件测试使用库的降级路径，不能据此证明原生 premium 效果。宿主无需新增初始化或全局 Theme 包装，现有 API 与业务逻辑不变。

## 提示与图标

关闭、换侧、不舒服、上一项/跳过、加时、完成及声音状态采用 `cupertino_icons: 1.0.8` 的标准符号。提示文字使用 w500，动作名保持 w600，指导语明确为 w400；字号、padding、位置、触控与语义保持原来安排。下一个动作没有海报或加载失败时，在原 28px 圆槽内显示下一项符号，避免空圆。

## 技能与参考

依据 `flutter-ios-liquid-glass` 技能的 UGK Water R4 记录：用户认可的是材质改善，不能扩张为整页已验收。检查重点是主体透出、薄而清晰的边缘、文字对比和浅深一致性，不以 shader 加载或测试通过代替视觉判断。

技能原句：“由库负责光学与交互，不另写仿玻璃渐变、发光边缘或拟物表面。”本轮按用户最新要求采用技能已经调过的光学配置，撤回 R3 为避免采样而交付的扁平路径。旧版布局与业务边界保持；原生媒体合成和性能需要对应运行证据，不能由参数或软件测试推定通过。

- [liquid_glass_widgets 1.15.0](https://pub.dev/packages/liquid_glass_widgets/versions/1.15.0) 与 [上游 MIT 许可证](https://github.com/sdegenaar/liquid_glass_widgets/blob/main/LICENSE)：使用发布包公共 API，不复制私有引擎。该版本包含 iOS 原生辅助插件，要求 iOS 15；Android 使用同一 Flutter 材质路径。
- [技能所对照的官方 Podcasts 示例](https://github.com/sdegenaar/liquid_glass_widgets/blob/57dc25a4ff49e553e137fc9eda3c4bb83d82f0ee/example/lib/apple_podcasts/apple_podcasts_demo.dart)：参考材质角色，保留训练页自己的旧布局。
- [Apple 材质指南](https://developer.apple.com/design/human-interface-guidelines/materials) 与 [Flutter 性能建议](https://docs.flutter.dev/perf/best-practices)：控制层与内容层有区别，避免视频区域的大面积采样和不必要的离屏层。

曾核查 `liquid_glass_easy` 5.0.0 的缓存背景方案。它能不实时采样，但不透明静态快照会在镜片内替换人物画面，因此没有把该方案扩散到 HUD。当前依赖已改为技能首选库。

## 验证

当轮布局截图、坐标对照、测试和制品记录统一见 [视觉评审记录](visual-review.md)。R4 已重新执行分析、253 项 SDK 测试、4 项示例测试、布局采集与 APK 构建；证据绑定本轮源文件和制品摘要。

本轮曾启动专用 Android 模拟器；收到用户禁止启动模拟器的指令后立即停止，并确认对应进程为 0。此次启动不计作原生验证，后续遵照禁止模拟器及内存限制。R4 原生视觉、连续边缘光学、真实透明视频与 profile 性能均未运行；布局软件图和库的 Web 降级画面都不是通透效果预览。原生 APK 仅供后续有条件时评审，用户满意度仍待确认。
