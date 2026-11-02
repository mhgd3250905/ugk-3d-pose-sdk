# 第 2 批：公共动作资源（2026-11-02）

**状态：SDK 已实现，整批部分完成；HipLab 包体尚未验收。** 分支 `codex/media-on-demand`，代码提交 `0b8d63f31a7611f0f982776cf0c0e4b303b3b2b5`；从 `9719e96` / 文档检查点 `333e015` 继续。基准 HipLab `0f507a3`、SF `52d30ae`。

## 已交付

`CoachAppProfile.mediaPolicy` 可选，null 保持原接线。公共清单按动作 ID 映射实际文件，默认源为 `https://media.uuugk.win/pack/r1-v3/`；SF 的 300 MB LRU、跨版本缓存、进度、校验、清理与正播保护下沉到 runtime。公共 packed alpha 视频、透明 frame-zero poster、浅深主题背景与播放就绪遮罩由 SDK 处理；仅打包 poster，计划视频异步预取，失败/断网保留 poster 并可重试，训练计时不中断。正播 pin 等原生 dispose 确认后释放。配置方式见 `docs/public-training-media.md`。

HipLab 隔离副本临时接线覆盖普通/快捷/AI 训练及中央 `HipDrillArt`（列表、详情、自测等使用方），46 个主动作全部使用公共 ID 和原字节 poster。未提交 App 或 pin。

## 验证

| 项目 | 结果 |
| --- | --- |
| SDK 相关回归 | **79/79**：缓存/LRU 21、launcher 7、公共媒体 widget 7、旧媒体 33、chat 11；含命中/未命中/失败/断网/重试、计时继续、LRU/正播保护 |
| 真实 Worker 下载与冷缓存 | **1/1**：h-squat 1,002,257 B，bytes/SHA 校验通过；下载 9.362 s，重开仓库且不配下载源后磁盘命中 11 ms；仅本机单样本 |
| analyze | runtime、chat 两包均 0 问题；HipLab 临时接线/测试 8 文件 0 问题 |
| SF 兼容 | **2/2**；浅深主题 **32/32 关键帧 0 像素差**，生产接线不改 |
| HipLab 训练截图 | 两主题共 440 张，414 张训练状态帧 poster 均已解码；36 张入口 gate 帧只显示 poster。仅静图 widget 证据，不是原生播放验收 |
| 瘦身中间产物 | release flutter_assets：**0 MP4、46 公共 poster / 1,198,922 B、0 旧 drill_media**；576 语音和 1 字体与历史包逐文件 SHA 一致 |
| HipLab 实测包体 ≤45 MB | **未完成**，未生成候选 APK；不能用资源减少量代替包体实测 |

## 缺口与停止项

- `supine-cross-demo`（HipLab 自测别名 `n-leg-circles#supine-cross-demo`）不在公共包：没有公共视频或 poster，显示暂无公共示范，业务流程继续；未上传、未替换为其他动作，原业务比较图保留。
- 本地 release 两轮失败后停止：首轮 Kotlin 增量缓存跨 E/F 盘报 `different roots`；次轮临时关闭增量后，Batch 1 遗留的 `integration_test` 注册使 Java 编译找不到 `IntegrationTestPlugin`。临时签名文件已移除，Gradle 配置已恢复，未做第三次构建。
- HipLab 额外采集测试为 0/2，通过训练序列后因详情返回控件定位失败，两轮停止；自测截图未采，light 首次首页/列表部分图片尚在解码。另一个额外 profile 专用集成测试两轮未收敛，原型移到本地 build，未计入通过数；原两条 adapter 测试保留且通过。

原始日志、截图、Worker 回执及 HipLab 临时接线归档均在本地 `build/media-on-demand/`，不入库。真实模型不适用。本批只普通推送分支，不合 main、不打 tag、不提交 App/pin、不改 Flare、不交付 APK、不改托管、未启动模拟器或设备。
