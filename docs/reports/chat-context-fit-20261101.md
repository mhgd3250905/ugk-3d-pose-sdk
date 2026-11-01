# 长会话上下文预算修复 · 2026-11-01

分支 `codex/chat-context-fit`，基于 main `a13e3b674359c93c941f7f59d1edf09a6d609487`；实现提交 `9f36d6ff26d672f31c6ef50dfe7d6300522338aa`。代码及原有文档 17 文件 +947/−29，本报告另计。

**证据边界：** 微信原文件与诊断副本相同，450,795 B / 1,500 条 runtime events，没有请求正文、工具参数/回执、ledger、seed、snapshot 或 result.error。手机第 17–25 轮实际组成字节和具体错误类型无法精确重建。可确认 17/18/20/21 轮 step 1 请求成功、step 2 本地终止；22–25 轮 step 1 未请求，19 轮成功。没有把 `AgentContextBudgetExceeded` 写成手机已捕获事实。

**代码根因：** 旧折叠把所有完整 ledger 再塞回请求，逐轮重复 task/params/candidates/seenActionIds；已恢复但不在 ledger 中的 seed 又不参与折叠。摘要持续增长，超过 65,536 B 后每轮在请求前失败，并继续增长。聊天层还把这些失败统一显示为网络不稳。

以下为全新中性文本和真实目录形状的离线结构回放，按 `OpenAiCompatibleClient.buildBody` UTF-8 精确量测，**不是原手机逐请求实测**。旧算法下第 17 轮和 legacy seed 回归失败，新算法全部通过。

| 结构回放 | 旧 after B | 新 after B |
|---|---:|---:|
| 第 17 轮 | 67,165 | 21,710 |
| 第 22 轮 | 84,370 | 19,155 |
| 第 25 轮 | 94,693 | 32,256 |
| 长恢复 seed | 141,544 | 22,469 |

第 17 轮旧 after 组成：system 2,101 / tools 9,625 / history 80 / ledger 55,055 / tail 198 / envelope 106 B，receipt 与 seed 均为 0。17–25 轮 before/after 和完整组成在本地 `build/chat-context-fit/structural-{baseline,fixed}.json`；手机缺失值在 `phone-observations.json` 保留 null。

**改动：** 软阈值折叠已结束轮及旧恢复工具链，预算不足时继续缩减请求 ledger 的重复状态、旧交付正文及旧轮；完整历史、原话、ledger、计划和快照不改。当前轮输入/推理/未消费回执不截断，64KB 不放宽。失败区分网络、鉴权、上下文、计划门禁、服务/超时；原轮数/历史策略单独提示新对话。每轮 `chat.turn.result` 只发 error 类型和 before/after/tail/折叠数/fitsHardLimit 等数值，宿主接入 observer 写日志；取消包装透传真实编码器，计数与 Mock HTTP body 完全一致。详见[上下文契约](../coach-agent-context-append-fold.md)与 chat README。

**门禁：** Coach **1543**、UI **178**、Trainer **578**、runtime **15**、chat **52**，全量通过；五包 `dart analyze --fatal-infos` **0 问题**，原分析配置未变；默认 golden 通过。新增 3 条长会话/seed/恢复回归及 9 条失败分类/日志/真实编码计数测试；4 条旧请求视图断言改为紧凑视图，同时保留完整存档断言。

| 唯一真实长测 | 成功轮数 / 调用 | 总耗时 | 最大发送 B | 折叠 / 硬限错误 |
|---|---|---|---:|---|
| SF 3eb2a9e 只读配置、thinking on、同播放器 builder | 30/30，47 次 | 214.627 s | 55,917 | 17 次 / 0 |

四份计划卡片/执行秒数：目标 300→296/300；600→624/627；300→295/295；300→289/290，均在 ±10%，非手动计次。第 7 轮推荐为同一轮 5 个模型步骤，超过正常 ≤4 的优化目标；未记录逐工具 span，不能进一步归因，不重抽、不另修。长测显式用既有 `maxTurns=100/maxHistoryChars=200000`，SDK 默认轮数策略不改。

**未解决项：** 缺原手机 snapshot/request/error，不能追认其具体异常或实际字节；本次验证为结构回归与一次新长对话，不等同真机复验。原导出仅留用户本地目录；回放脚本、JSON、模型指标和日志仅留本地 `build/chat-context-fit/`，未入 Git。分支待审，不合 main、不打 tag、不动 App/pin。
