# 第 2 批：瘦身与按需媒体（2026-11-02）

**状态：托管前置检查暂停，尚未实现或验收。** 分支 `codex/media-on-demand` 从 `9719e96d33c077464d756063862d6ec85466d060` 创建。本检查点仅文档；遵守用户“视频托管沿用 SF 的方式；如需新增托管或费用，停下来报告”。

## 核对结果

基准：HipLab `0f507a3124436d29e8e3fbb7e2769a1d7d3c9018`；SF `52d30aecc74c177c438f2b7e4d7c9970d5ea591a`；SF `codex/slim-assets`（+46）为 `6ef6bf773590a758a17c5ab79d95f8fb96241dc8`。

| 检查 | 实际结果 |
| --- | --- |
| HipLab 内置 MP4 | 94 项，61,041,462 B；47 个动作各含浅、深主题；全部与 `assets/hip/action-media.json` 的 bytes/SHA 一致 |
| SF 现有清单可复用性 | SF 旧清单 378 个视频描述、v3 的 219 个动作视频，与 HipLab 原视频精确 SHA 匹配均为 0 |
| SF v3 动作覆盖 | 46/47 个媒体动作 ID 对应，但视频为 720×1440 packed alpha，非 HipLab 原 1080×1080 主题视频；缺 `supine-cross-demo` |
| 已有托管 | SF `assets/posehub/media-delivery.json` 配置 `https://media.uuugk.win/pack/r1-v3/`；现有 h-squat 视频 HEAD 为 200，1,002,257 B |
| HipLab 历史包 | 106,781,267 B，release / arm64-v8a；其中 94 个 MP4 均未压缩存储，内容与上述清单完全一致 |
| 新包体积 | 未构建。仅扣视频的算术残余为 45,739,805 B（45.74 MB / 43.62 MiB），不能作为 ≤45 MB 的实测验收 |

SF 的已配置清单无法提供 HipLab 这 94 个原视频的正式下载映射。保留原画面并沿用 SF 托管，需要先确认同素材已有地址，或允许在该托管中补充资源及映射；本批未上传、开通托管或产生经确认的新费用。HipLab 公开 GitHub 固定提交的原文件抽样可读，可作为备选方案，但未擅自改用 GitHub Raw 替代指定托管。也未把 SF 的另一套视频直接替换进 HipLab。

## 已明确的后续实现边界

SDK `TrainingMediaRepository` 已有下载、bytes/SHA 校验、磁盘缓存、进度、并发限制与清理，可复用；其旧索引写死 `v<version>/<skin>/<theme>/<id>.mp4`，需增加实际文件映射入口。SF 的完整 LRU / 正播保护仍在 App，不能视为 SDK 已具备。

待托管前提确定后，增加可选 `CoachAppProfile.mediaPolicy`（null 保持现状），经 adapter / launcher 传入路由；预取与播放统一使用实际主题和文件。下载不挡 poster 入口、训练计时或语音；失败保持 poster，提供进度及显式重试。HipLab 除训练入口外，详情与自测的 `HipDrillArt` 也须接入，不能只删资源声明。原日常目录已有签名配置，隔离副本缺失；恢复构建时可临时接线，当前未读取或复制密钥。

## 验证与交付范围

本批只有清单、SHA、历史包与已有地址的只读检查；原始清单结果留在本地 `build/media-on-demand/inventory.json`。新增测试 0，未运行 analyze、新包构建或 SF 关键帧复验；第 1 批结果不充作本批验收。真实模型不适用。

本检查点只普通推送文档分支；不合 main、不打 tag、不提交 App / pin、不交付 APK，未启动模拟器。继续前需要确定 HipLab 原视频在 SF 托管中的地址或补充资源的授权；SDK 代码、命中/未命中/断网/失败测试、SF 零像素差和 HipLab 包体实测均待完成。
