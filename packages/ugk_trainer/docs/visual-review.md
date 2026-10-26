# 实色分层 UI 评审记录

`ugk_trainer 0.3.0` / `ugk_coach_ui 0.2.0`：三级不透明表面、主题 1px 低对比边线与轻固定阴影。旧玻璃依赖、实现、公开参数与旧演示资产已删除；完整位置与迁移见[审计清单](solid-layered-audit.md)。

基线：`e6dd32d90d0533aecf595f17f002701c0bec7d7a`。候选分支：`codex/solid-layered-ui`。两个包在同一已验证提交上打 tag；main 合入与推送须开哥批准。

| 检查 | 本轮结果 |
| --- | --- |
| 静态分析 | trainer、coach_ui、展示入口均无问题 |
| 全套测试 | trainer 257/257；coach_ui 33/33；展示 4/4；JS 播放协议 8/8 |
| 布局 | 8 组浅深/状态对照，106 个外框和 62 个缺席项一致，最大偏移 0dp |
| 防闪 / Morph Pulse | 原状态机、颜色交接、glyph/ripple 代码逐字保留；实底像素、中断反转、独立重绘测试通过 |
| 构建 | Web release、Android debug 成功 |
| 实际 Web 检查 | 暂停后由深切浅，35 秒和继续状态保留；标题显示 SDK 实色分层 |

浅深四状态共 8 张新图已查看。它们来自 Flutter test software renderer，非 Android/iOS 真机截图：430×932 逻辑视口，播放器裁切 430×883，pixelRatio=2，1000ms，开启阴影，中文字体 Microsoft YaHei 仅本机加载，未分发。源文件、截图和构建 SHA256 见 [capture-manifest.json](visuals/capture-manifest.json)，几何结果见 [layout-comparison.json](visuals/layout-comparison.json)。旧 before 图删除，after 图全部更新为本轮实色版本。

普通 UI 使用位移、缩放与淡入。训练布局与 Morph Pulse 依用户要求保持；径向进度 halo、点击 ripple、packed-alpha 视频合成 shader、coach 列表顶部功能遮罩保留。它们不采样背景实现玻璃。

[实时 Web 演示](http://127.0.0.1:7361/?v=solid-030#/showcase) · [浅深图库](visual-review.html) · [运行说明](../example/README.md)

本轮未启动模拟器、未安装设备、未做 iOS 构建或设备性能验收。Android debug 构建成功不代表设备视觉或媒体性能已获认可。
