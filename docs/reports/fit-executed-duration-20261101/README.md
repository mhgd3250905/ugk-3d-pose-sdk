# 执行时长双门禁：真实模型报告

2026-11-01，SDK `codex/fit-executed-duration`，基线 main
`700d0100f1cb42ef122e774a6ee0076d1916b5e5`。HipLab 与 SF 各七次独立三轮会话，
最终计划双数值门禁均 **7/7**。没有重抽、补答、截断、容差豁免或传输重试。

**一次中间推荐失败也保留在报告中**：SF five-3 第 2 轮返回 error，第 3 轮原定用户输入
继续交付合格计划。完整 42 轮有 41 轮成功；“14/14”只指最终第三轮的计划双时长门禁。

## 验证方式与范围

每次新建 Agent/Controller，thinking on，返回模型全部为 `deepseek-flash`。
HipLab 三轮原话为“在家开胯10分钟入门”→“推荐几个拉大腿内侧的动作”→
“换一套，缩短到5分钟”（10/20 分钟用对应目标的“换一套，改成N分钟”）。
SF 第一轮明确在家、10 分钟、入门、徒手和瑜伽垫、大腿内侧和髋部、无不适，随后同样
推荐和替换。每个宿主最终目标固定为 5 分钟五次、10 分钟一次、20 分钟一次。

这次运行通过 SDK harness 为 Coach 注入宿主真实播放器配置的 builder；宿主源码与
SDK pin 均只读，未操作设备或播放音频。HipLab 使用原生验收 helper 的无损计划映射与
完整时间线断言；SF 直接复用 AppTestContent 和宿主 SessionBuilder，逐 phase 对照。
每次均断言回调与实际播放器 phase 总和一致。两批源文件/素材哈希全程不变。

纯计时样本自然遍历 SessionEngine 并核对累计 visit 秒数。SF five-3 和 ten-1 含
`h-quadruped-rockback` 的手动阶段，执行时长归为**估算**，依旧通过两个数字门禁，
不能解释为手动动作在真机上的实测耗时。其余 12 项为完整计时时间线。

| 只读宿主参考 | HEAD |
| --- | --- |
| HipLab coach-v2 | `58e2e8117dc89b57a4a2a3660439fd11f3fc3fe6` |
| SF 验收 worktree Sport-Helper-coach-ui-kit | `3eb2a9e88ef4d28e02f4cf306c1716d61baa7f10` |
| SF 当前 main 对照，区别于上项验证源 | `731c6671f8f7f12a13454ad7b8fb03a08c5b2693` |

SDK 生产 Dart 文件指纹（按绝对路径排序、以相对路径与文件 SHA 拼接计算）两批均为：
`d0f5ede16d339c6931622b72f2c16156ba6fec41979030384e34a78e1fe10366`。
该指纹覆盖 root lib 与 ugk_trainer/lib，不把运行时未提交的基线 HEAD 当成最终代码身份。
对应宿主源码、profile、catalog、kit、voice 等文件逐项 SHA 在
[results.json](results.json) 的 provenance 中。

## 每次结果

卡片/执行单位均为秒。表中“最终”是第三轮，另列完整三轮调用与耗时；耗时是模型门禁
会话耗时，包含 SDK 配时，不是训练过程的实际钟表计时。全部最终计划的两个时钟均在
目标 ±10% 内，边界含等号。

| 宿主 | 目标/编号 | 卡片/执行秒 | 分类 | 最终调用/ms | 三轮调用/ms |
| --- | --- | ---: | --- | ---: | ---: |
| HipLab | 5m-1 | 279/287 | 计时 | 6/18667 | 13/33755 |
| HipLab | 5m-2 | 279/287 | 计时 | 5/11405 | 12/29058 |
| HipLab | 5m-3 | 279/287 | 计时 | 4/11106 | 12/28634 |
| HipLab | 5m-4 | 271/280 | 计时 | 6/18466 | 14/37184 |
| HipLab | 5m-5 | 302/311 | 计时 | 6/14279 | 13/30779 |
| HipLab | 10m | 595/607 | 计时 | 4/14430 | 12/35714 |
| HipLab | 20m | 1200/1224 | 计时 | 5/13855 | 14/31834 |
| SF | 5m-1 | 329/330 | 计时 | 9/23122 | 22/52868 |
| SF | 5m-2 | 313/315 | 计时 | 5/15876 | 14/38077 |
| SF | 5m-3 | 310/315 | **估算** | 4/15103 | 14/39457 |
| SF | 5m-4 | 311/313 | 计时 | 7/21019 | 15/42352 |
| SF | 5m-5 | 312/316 | 计时 | 8/29001 | 20/67130 |
| SF | 10m | 625/629 | **估算** | 5/15601 | 16/39692 |
| SF | 20m | 1243/1256 | 计时 | 8/28592 | 15/46942 |

HipLab 共 90 调用 / 228046ms；SF 共 116 调用 / 328361ms。两批并行运行，
不要把两个批次耗时相加解释为实际墙钟耗时。

## 中间推荐失败

SF five-3 第 2 轮“推荐几个拉大腿内侧的动作”没有正确建立 recommend 任务，
三次 `show_actions` 被 `unseen_actions` 拦截，达到既有 `maxResubmits=2` 上限后返回
`TurnStatus.error`，没有抛异常，所以 errorType 为 null。失败轮中搜索命中不能修正
旧 plan 任务与临时 recommend 状态之间的来源问题。本分支的执行回调只用于计划，
该推荐链路没有改动。

第 3 轮开始时仍以第 1 轮 `plan-1793467080343-2` v1、卡片 625 秒为编辑基线，
没有第 2 轮推荐卡或新计划覆盖它。之后按预设“换一套，改成5分钟”调用原编辑链路，
最终同 ID v3 交付 310/315 秒。此处没有人工补答、重置会话或失败重抽。
原三轮状态均保留在 results.json，失败工具回执另见
[recommendation-intermediate-failure.json](recommendation-intermediate-failure.json)。

## 测试与证据

| 包 | 全量测试 | dart analyze --fatal-infos |
| --- | ---: | --- |
| ugk_coach | 1432 | 0 问题 |
| ugk_coach_ui | 178 | 0 问题 |
| ugk_trainer | 564 | 0 问题 |

默认浅/深色 golden 为 4 项 / 16 图，0 像素差异，没有更新任何基线。既有测试没有修改。
固定 326/335 秒回归改为 302/311 秒；边界、异常、手动计次、circuit 分支和恢复门禁均
见 [接入与测试说明](../../fit-executed-duration.md)。

[results.json](results.json) 保留每次最终计划、实际 phase、保存版本/fitLog、每轮状态、
调用/耗时、原 case/journal SHA 和源码来源；不包含私有 reasoning、headers 或密钥。
[HipLab 摘要](hiplab-summary.md)、[SF 摘要](smartfit-summary.md) 是原批表格副本，
Pass 列的定义同样仅是最终计划双门禁。

原完整公开记录、桥与包配置在仓库忽略的本地 `build/fit-executed-duration/`
`live-hiplab-20261101-r1` 和 `live-smartfit-20261101-r1`，没有覆盖旧工件。
两份原 summary.json 的 SHA-256 分别为：

- HipLab：`f9a0cb7620a4e682fc78390c5def2708605a7ce3e3e83b8353260395fe89e9e4`
- SF：`818a7c25ef8c4a2d24bc25c73523ff6aa372edf2bb549f68990c5bed229046ba`
