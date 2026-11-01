# 第 3 批：教练对话模块提取（2026-11-01）

分支 `codex/coach-chat-extract`，实现提交 **`10a0089ee884fe3256ef37a36041f3a4c6fc590f`**。
第 2 批已快进、推送并核对远端 main：`67c9747b8e29955d2be21c020c5ef3881b4966e6`。
本批基于该 main，SF 来源为只读 `3eb2a9e88ef4d28e02f4cf306c1716d61baa7f10`。

新增 `ugk_coach_chat`，复用现有 Coach、UI、asset-free runtime；页面、输入/菜单、
等待/出卡、详情、安全确认、保存/focus、历史/新对话、训练往返由模块持有。
`CoachAppProfile` 配范围/剂量/文案/主题/同时间线回调，`CoachChatBindings` 接存储、网关、
媒体和导航。旧包运行代码与 API 未改。CAS storageRevision 与 savedRef.baseVersion 分离。

实现 diff 为 **58 文件，+12,299 / −4 行**：新包 48 文件 +10,714（含测试/说明），
采集与真实评测脚本 6 文件 +1,414；README/接入/环境/台账 4 文件 +171/−4。
收尾另增本报告并链接到 README/台账；完整文件清单可直接查看分支 diff。

全量测试：**Coach 1540/1540、UI 178/178、Trainer 578/578、runtime 15/15、chat 34/34**。
五包 `dart analyze --fatal-infos` 均 0（root 为 `lib test tool`，外部采集副本留在 build）。
默认 16 张 golden 通过、0 差异；SF 浅/深各 11 个关键状态帧 **22/22 零像素差**，
两边使用相同完整 Flutter 3.44.7 工具链、字体/素材/视口，未更新源基线或放宽阈值。
像素对比修复了历史 request/context 丢失及 mat 标签映射，并保留可见海报的原预热调度。

真实模型仅收尾运行一次、同一新 `CoachChatController` 会话，DeepSeek Flash，thinking on。
SF 219 授权/211 可规划；执行回调与原 SF builder 的逐阶段时间线一致，无重抽、无截断。

| 对话轮 | HTTP | 耗时 | 卡片/执行秒 | 双时长偏差 | 最大请求 B | total/cache token |
| --- | ---: | ---: | --- | --- | ---: | ---: |
| 5 分钟计划 | 3 | 12.492s | 312 / 314 | +4.00% / +4.67% | 43,876 | 29,678 / 20,864 |
| 推荐大腿内侧动作 | 2 | 5.381s | 4 个动作 | 不适用 | 37,395 | 17,393 / 11,264 |
| 换一套、缩到 3 分钟 | 3 | 11.834s | 187 / 189 | +3.89% / +5.00% | 49,911 | 37,041 / 26,368 |

三轮均通过，无重编错误码；计划非空，所有计划/推荐 ID 均在范围内；两张计划均过 ±10%。
没有手动计次阶段。缩短目标使用 SF 原 profile 合法范围 3–60 分钟；HTTP 目标均达到。
第 2 批已接受的三轮调用目标偏差未额外修复。

未通过项：无。本批未验收 App 迁移、iOS、真机媒体/性能及实际数据库接线。
本分支不合 main、不打 tag、不改 App/pin；HipLab 45、托马斯 51 名单仍为候选。

接入：[公开接口与边界](../coach-chat-module.md)、[包示例](../../packages/ugk_coach_chat/README.md)。
复现：[帧清单/环境](../coach-chat-module-design/capture-environment.md)。原始 JSON、日志、PNG
仅本地 `build/chat-extract*`：像素 `candidate-final`、模型 `live-final-20261101`，不入库。
