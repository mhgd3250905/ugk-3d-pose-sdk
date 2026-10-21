# SmartFit 0.3.2 六条真实烟测：0.3.3 提速基线分析（2026-10-21）

六条共 **39 个逻辑步、43 次模型请求、867.891 秒、384,013 个已报告 token**。慢主要表现在多次模型往返：22 步用于读取资料、10 步用于 `check_plan`、1 步用于记忆操作、6 步用于最终交付。未发现同轮重复读取、失败文件读取或最终交付门禁重交；不能把十次自检计作十次门禁失败。臀桥步骤 3 的四次 `badResponse` 增加了 4.155 秒失败调用和 15.134 秒退避，但本轮日志省略了 `errorMessage` 和原始 HTTP 返回体，**无法从现存证据给出这四次错误的具体文本或判定网关/上游根因**。

本分析只读既有证据与已测 SDK 源码，没有发送真实请求，没有修改 App 或 SDK 核心实现。以下是 0.3.2 历史基线，不代表 0.3.3 已有真实提速结果。

## 证据与对齐口径

- App：`E:\AII-3D\3D-Sport-AI\Sport-Helper`；原报告：`docs/coach-032-smoke-2026-10-21.md`。
- 本轮目录：`.buildlog/skill-agent-smoke/2026-10-21T09-03-59.110231Z/`，主证据为 `results.json`、`requests.jsonl`、`events.jsonl`。
- 已测 App 源码 `b39304488e964b22a65501363a15140b5d0ca235`；SDK `b26e4fda807b6ef3db15a61ba30c67fb51dce5e1` / `ugk_coach 0.3.2`。分析源码行为使用该固定 SDK SHA，不把正在开发的 0.3.3 行为套回旧数据。
- 日志原时间为 UTC；本文显示的时刻为 Asia/Shanghai（UTC+08:00）。案例间配额等待不计入 867.891 秒。

`results.json[].calls` 是烟测从每条 `UsageRecord` 投影得到的记录：`step = record.attempt`，`retry = record.retry`，每次请求单列一行。`requests.jsonl` 的 43 行只有 `at`、`requestIndex`，没有请求正文、工具列表、`turnId`、step 或响应；因此表格用案例顺序、各案例 `httpRequests`/`calls` 数量及起止时间关联全局请求号，再用 `events` 的 step 补充已执行工具。全部记录 `httpAttempts=1`，与 App 客户端 `maxRetries=0` 一致。六组的 `events` 串接后与 `events.jsonl` 逐项相同；`calls` 用量逐项求和与案例 `usage` 相同。

**工具证据的限制：** `reading` 可确认为 `read(path)`，`checking` 可确认为 `check_plan`，`memory` 只记录 kind（`level`/`equipment`），不能仅凭该事件还原 `remember`/`forget` 的完整方法及参数。最终 `passed` 的原始 `show_*` 调用也没有落盘；本文只按结果的计划卡/文字标注终交类型。表格不是完整工具响应追踪，不能用它推断未记录的工具参数、`check_plan` 的 ok/errors、工具返回正文或其他无事件工具。

已测烟测源码中，[请求日志只保存时间和序号](https://github.com/mhgd3250905/Sport-Helper/blob/b39304488e964b22a65501363a15140b5d0ca235/tools/coach/worker_agent_smoke.dart#L68)；[calls 投影仅保存 errorKind](https://github.com/mhgd3250905/Sport-Helper/blob/b39304488e964b22a65501363a15140b5d0ca235/tools/coach/worker_agent_smoke.dart#L294)。本地文件与上述固定 commit 的源码为证据，链接不代表仓库可公开访问。

## 汇总

P/C 为 `promptTokens/completionTokens`；reasoning 已计入 completion，cached 已计入 prompt，二者均不再相加。失败行的 0/0 表示 SDK 未取得用量，不证明服务端没有消耗 token。

| case | 逻辑步 / 请求 | 秒 | P / C | 文件 read | check_plan | 最终门禁重交 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `core` | 9 / 9 | 213.908 | 79,226 / 5,284 | 13 | 3 | 0 |
| `actions` | 7 / 11 | 132.244 | 41,841 / 1,552 | 8 | 0 | 0 |
| `back-protection` | 7 / 7 | 166.198 | 86,098 / 6,613 | 21 | 2 | 0 |
| `remember` | 3 / 3 | 60.845 | 11,320 / 360 | 1 | 0 | 0 |
| `memory-on-plan` | 5 / 5 | 110.305 | 47,094 / 4,754 | 5 | 2 | 0 |
| `memory-off-plan` | 8 / 8 | 184.391 | 92,570 / 7,301 | 14 | 3 | 0 |
| 合计 | 39 / 43 | 867.891 | 358,149 / 25,864 | 62 | 10 | 0 |

累计调用 `latencyMs` 为 851.804 秒，占整轮合计的 98.15%；它包含网络、网关、上游生成及 SDK 解析，不能直接等同于纯模型计算时间。退避 15.134 秒；两者以外的差值仅 0.953 秒，包含本地工具、记忆落盘、门禁、日志与计时边界。现有数据不支持把数分钟等待主要归因于本机 `read` 执行耗时。

累计 prompt 358,149，占已报告 token 的 93.26%；其中 cached 299,520，占 prompt 的 83.63%。最大单次 prompt 为 `back-protection` step 7 的 19,580，未出现 `contextTooLong` retry 事件。日志没有压缩明细，不能据此还原每步估算预算或证明从未压缩。

## 逐次请求

全局请求号对应 `requests.jsonl` 的同号行；step/retry 来自 `calls`。`toolStep` 表示中间工具步骤被执行，不能据此认定该工具自身返回了 `ok:true`。工具列只列事件确证项，多个路径表示同一响应内已执行的多次读取。

### 1. `core` — 在家 15 分钟练核心，徒手

记忆关；submissions=1；结果为有效计划：15 分钟，level=1。

| 请求 # | step | retry | outcome | P / C | latency 秒 | 事件确证工具 / 终交 |
| ---: | ---: | ---: | --- | ---: | ---: | --- |
| 1 | 1 | 0 | toolStep | 2,852 / 108 | 25.944 | `read(plan-training/SKILL.md)`<br>`read(action-library/SKILL.md)` |
| 2 | 2 | 0 | toolStep | 4,924 / 123 | 18.997 | `read(action-library/index/category/core.md)`<br>`read(action-library/index/muscle/abs.md)` |
| 3 | 3 | 0 | toolStep | 5,753 / 259 | 22.396 | `read(action-library/index/category/mobility.md)`<br>`read(action-library/index/category/stretch.md)` |
| 4 | 4 | 0 | toolStep | 8,302 / 713 | 24.004 | `read(action-library/details/w-dead-bug.md)`<br>`read(action-library/details/h-forearm-plank.md)`<br>`read(action-library/details/w-bird-dog.md)`<br>`read(action-library/details/h-catcow-quad.md)`<br>`read(action-library/details/h-supine-twist.md)`<br>`read(action-library/details/h-knee-hug.md)` |
| 5 | 5 | 0 | toolStep | 9,797 / 765 | 25.842 | `read(action-library/details/n-pelvis-circle.md)` |
| 6 | 6 | 0 | toolStep | 10,710 / 710 | 24.564 | `check_plan`（参数/结果未保存） |
| 7 | 7 | 0 | toolStep | 11,383 / 743 | 23.697 | `check_plan`（参数/结果未保存） |
| 8 | 8 | 0 | toolStep | 12,185 / 1,076 | 24.952 | `check_plan`（参数/结果未保存） |
| 9 | 9 | 0 | passed | 13,320 / 787 | 23.338 | 计划终交（原始最终工具未保存） |

读取占 step 1–5；step 6–8 连续三次 `check_plan` 共 73.213 秒，然后 step 9 终交。三次检查的参数、通过状态和时长差未保留，不能判断是剂量修订、时长调整还是重复自检。

### 2. `actions` — 臀桥怎么做

记忆关；submissions=1；结果为接纳文字，`actions=null`、`planTitle=null`。

| 请求 # | step | retry | outcome | P / C | latency 秒 | 事件确证工具 / 终交 |
| ---: | ---: | ---: | --- | ---: | ---: | --- |
| 10 | 1 | 0 | toolStep | 2,826 / 81 | 21.722 | `read(action-coaching/SKILL.md)` |
| 11 | 2 | 0 | toolStep | 3,185 / 43 | 13.468 | `read(action-library/SKILL.md)` |
| 12 | 3 | 0 | error | 0 / 0 | 0.759 | `badResponse`；无工具执行事件 |
| 13 | 3 | 1 | error | 0 / 0 | 1.200 | `badResponse`；无工具执行事件 |
| 14 | 3 | 2 | error | 0 / 0 | 0.934 | `badResponse`；无工具执行事件 |
| 15 | 3 | 3 | error | 0 / 0 | 1.262 | `badResponse`；无工具执行事件 |
| 16 | 3 | 4 | toolStep | 4,218 / 59 | 9.821 | `read(action-library/index/muscle/glute-max.md)` |
| 17 | 4 | 0 | toolStep | 5,588 / 173 | 10.054 | `read(action-library/index/position/supine.md)`<br>`read(action-library/index/muscle/hamstrings.md)` |
| 18 | 5 | 0 | toolStep | 7,142 / 133 | 8.795 | `read(action-library/index/equipment/mat.md)` |
| 19 | 6 | 0 | toolStep | 9,121 / 327 | 23.161 | `read(action-library/details/h-bridge-march.md)`<br>`read(action-library/details/w-feet-on-chair-bridge.md)` |
| 20 | 7 | 0 | passed | 9,761 / 736 | 25.876 | 文字终交（由结果确认，原始响应未保存） |

step 3 前四次请求失败，第五次（retry=4）成功后才执行 glute-max 索引读取。七个成功逻辑步中六步都是读取；原脚本因强制要求动作卡而 exit 1，但这一条是合法 how-to 文字交付，不把该断言失败算作 SDK 门禁失败。

### 3. `back-protection` — 我腰不太舒服，想练腿 20 分钟

记忆关；submissions=1；结果为有效计划：20 分钟，level=1。

| 请求 # | step | retry | outcome | P / C | latency 秒 | 事件确证工具 / 终交 |
| ---: | ---: | ---: | --- | ---: | ---: | --- |
| 21 | 1 | 0 | toolStep | 2,846 / 172 | 16.776 | `read(action-library/SKILL.md)`<br>`read(plan-training/SKILL.md)` |
| 22 | 2 | 0 | toolStep | 4,981 / 367 | 19.069 | `read(action-library/index/caution/lower-back.md)`<br>`read(action-library/index/muscle/quadriceps.md)`<br>`read(action-library/index/muscle/hamstrings.md)`<br>`read(action-library/index/muscle/glute-max.md)`<br>`read(action-library/index/category/strength.md)`<br>`read(action-library/index/muscle/calves.md)` |
| 23 | 3 | 0 | toolStep | 10,426 / 844 | 26.531 | `read(action-library/index/category/mobility.md)`<br>`read(action-library/index/category/stretch.md)` |
| 24 | 4 | 0 | toolStep | 13,560 / 1,468 | 26.728 | `read(action-library/details/h-squat.md)`<br>`read(action-library/details/w-feet-on-chair-bridge.md)`<br>`read(action-library/details/h-side-leg-raise.md)`<br>`read(action-library/details/h-calf-raise.md)`<br>`read(action-library/details/h-tib-raise.md)`<br>`read(action-library/details/n-pelvis-circle.md)`<br>`read(action-library/details/h-hip-gate.md)`<br>`read(action-library/details/h-butterfly-active.md)`<br>`read(action-library/details/o-stand-quad.md)`<br>`read(action-library/details/h-wall-calf.md)`<br>`read(action-library/details/s-figure4.md)` |
| 25 | 5 | 0 | toolStep | 16,581 / 1,485 | 26.372 | `check_plan`（参数/结果未保存） |
| 26 | 6 | 0 | toolStep | 18,124 / 1,397 | 26.869 | `check_plan`（参数/结果未保存） |
| 27 | 7 | 0 | passed | 19,580 / 880 | 23.698 | 计划终交（原始最终工具未保存） |

四个读取步合计读取 21 个不同文件，step 4 一次读取 11 个详情；这证明模型已能在一轮并列调用多个 read。step 5–6 自检共 53.241 秒；没有最终门禁拒绝记录。

### 4. `remember` — 我是新手，家里有哑铃

记忆开；submissions=1；结果为接纳文字，`actions=null`、`planTitle=null`。

| 请求 # | step | retry | outcome | P / C | latency 秒 | 事件确证工具 / 终交 |
| ---: | ---: | ---: | --- | ---: | ---: | --- |
| 28 | 1 | 0 | toolStep | 3,372 / 193 | 26.319 | `read(user-memory/SKILL.md)` |
| 29 | 2 | 0 | toolStep | 3,893 / 100 | 21.615 | `memory` 事件，kind=`level`（方法名未记录）<br>`memory` 事件，kind=`equipment`（方法名未记录） |
| 30 | 3 | 0 | passed | 4,055 / 67 | 12.526 | 文字终交（由结果确认，原始响应未保存） |

step 2 有 level/equipment 两个 memory 事件；结果与本地持久化快照确认存入“新手”“家里有哑铃”。具体工具调用/参数/单次 save 时长没有保存，不能用总耗时差估算存储 I/O。

### 5. `memory-on-plan` — 请给我排一个15分钟的居家力量训练计划

记忆开；submissions=1；结果为有效计划：15 分钟，level=1。

| 请求 # | step | retry | outcome | P / C | latency 秒 | 事件确证工具 / 终交 |
| ---: | ---: | ---: | --- | ---: | ---: | --- |
| 31 | 1 | 0 | toolStep | 3,403 / 147 | 8.180 | `read(plan-training/SKILL.md)`<br>`read(action-library/SKILL.md)` |
| 32 | 2 | 0 | toolStep | 5,514 / 245 | 22.281 | `read(action-library/index/category/strength.md)`<br>`read(action-library/index/equipment/dumbbell.md)`<br>`read(action-library/index/level/1.md)` |
| 33 | 3 | 0 | toolStep | 10,789 / 2,019 | 28.672 | `check_plan`（参数/结果未保存） |
| 34 | 4 | 0 | toolStep | 12,880 / 1,488 | 26.890 | `check_plan`（参数/结果未保存） |
| 35 | 5 | 0 | passed | 14,508 / 855 | 24.267 | 计划终交（原始最终工具未保存） |

只用两个读取步、未读取详情文件，之后两次自检共 55.562 秒并终交。它比 memory-off 案例少三步，但输入记忆条件不同，单次样本不能证明“开记忆”本身导致固定速度提升。

### 6. `memory-off-plan` — 请给我排一个15分钟的居家力量训练计划

记忆关；submissions=1；结果为有效计划：15 分钟，level=1。

| 请求 # | step | retry | outcome | P / C | latency 秒 | 事件确证工具 / 终交 |
| ---: | ---: | ---: | --- | ---: | ---: | --- |
| 36 | 1 | 0 | toolStep | 2,845 / 148 | 17.668 | `read(plan-training/SKILL.md)`<br>`read(action-library/SKILL.md)` |
| 37 | 2 | 0 | toolStep | 4,957 / 112 | 11.997 | `read(action-library/index/category/strength.md)`<br>`read(action-library/index/level/1.md)` |
| 38 | 3 | 0 | toolStep | 9,723 / 2,290 | 32.142 | `read(action-library/details/h-squat.md)`<br>`read(action-library/details/h-incline-pushup.md)`<br>`read(action-library/details/w-feet-on-chair-bridge.md)`<br>`read(action-library/details/w-prone-swimmer.md)`<br>`read(action-library/details/h-catcow-quad.md)` |
| 39 | 4 | 0 | toolStep | 12,721 / 256 | 21.887 | `read(action-library/details/h-wall-angel.md)`<br>`read(action-library/details/h-step-jack.md)`<br>`read(action-library/details/s-figure4.md)`<br>`read(action-library/details/h-knee-hug.md)`<br>`read(action-library/details/h-chair-lat.md)` |
| 40 | 5 | 0 | toolStep | 13,680 / 1,039 | 24.425 | `check_plan`（参数/结果未保存） |
| 41 | 6 | 0 | toolStep | 14,777 / 1,760 | 28.494 | `check_plan`（参数/结果未保存） |
| 42 | 7 | 0 | toolStep | 16,507 / 795 | 23.647 | `check_plan`（参数/结果未保存） |
| 43 | 8 | 0 | passed | 17,360 / 901 | 23.965 | 计划终交（原始最终工具未保存） |

step 3 的 32.142 秒触发本轮唯一 slow；该步 completion=2,290，其中 reasoning=2,102，属于成功响应。step 5–7 自检共 76.566 秒；没有 badResponse 或最终门禁重交。

## 重复读取、无效读取与门禁重交

这里“重复读取”限定为同一案例同一规范化路径再次发出 `reading`；“无效读取”限定为文件不存在、目录误当文件或已读占位，不能把“未进入最终计划”的查阅自动判作无效。

| case | reading 次数 / 不同路径 | 同轮重复 | 未匹配成功 reads 的 reading | check_plan | submissions / rejected / rewritten |
| --- | ---: | ---: | ---: | ---: | --- |
| `core` | 13 / 13 | 0 | 0 | 3 | 1 / 0 / 0 |
| `actions` | 8 / 8 | 0 | 0 | 0 | 1 / 0 / 0 |
| `back-protection` | 21 / 21 | 0 | 0 | 2 | 1 / 0 / 0 |
| `remember` | 1 / 1 | 0 | 0 | 0 | 1 / 0 / 0 |
| `memory-on-plan` | 5 / 5 | 0 | 0 | 2 | 1 / 0 / 0 |
| `memory-off-plan` | 14 / 14 | 0 | 0 | 3 | 1 / 0 / 0 |

62 个 `reading` 事件按顺序与各案例的 `reads` 完全相同，且同一案例没有重复路径。结合 0.3.2 `_read` 仅在实际首次文件读取时追加 `reads` 的实现，**本轮已记录读取中的重复/失败/目录误读均为 0**。未发现 `listing` 事件。因为完整原始工具响应未落盘，无法评估查阅内容是否必要，也不能把已有成功文件读取归成“无效工具响应”。

跨六个独立新对话有 41 个不同路径、62 次读取，即跨案例重复 21 次；其中 `action-library/SKILL.md` 5 次、`plan-training/SKILL.md` 4 次。这是每条隔离对话重新加载资料，不能与同轮空转混算；可作为预加载/紧凑索引方案的候选减少往返点。

十次 `checking` 都是 `toolStep`，不是 `rejected`。六条均 `submissions=1`、最终 `passed`，没有 `rewritten` 或任何 `issueCodes`，因此**最终 show 门禁重交为 0**。自检内部是否发现并修复错误没有字段证据；十次自检累计 258.582 秒（整轮合计的 29.79%），但不能宣称删除它们可无损节省全部时间。

## 臀桥 step 3：四次 badResponse 的已知事实与根因边界

| 请求 # | 上海发起时刻 | step / retry | latency 秒 | 随后 retrying | delay 秒 | 具体 errorMessage / 原始响应 |
| ---: | --- | --- | ---: | --- | ---: | --- |
| 12 | 17:08:09.000834 | 3 / 0 | 0.759 | attempt=1/4, reason=badResponse | 1.015 | 未保存 / 未保存 |
| 13 | 17:08:10.779478 | 3 / 1 | 1.200 | attempt=2/4, reason=badResponse | 1.898 | 未保存 / 未保存 |
| 14 | 17:08:13.880520 | 3 / 2 | 0.934 | attempt=3/4, reason=badResponse | 4.067 | 未保存 / 未保存 |
| 15 | 17:08:18.888630 | 3 / 3 | 1.262 | attempt=4/4, reason=badResponse | 8.154 | 未保存 / 未保存 |
| 16 | 17:08:28.307988 | 3 / 4 | 9.821 | 成功，执行 glute-max read | 0 | 成功协议仅记录 reasoning 存在/长度 |

四次失败 latency 共 4.155 秒，四次退避共 15.134 秒，合计 19.289 秒，占这条 132.244 秒的 14.59%。这是已发生的失败及退避成本，不是跳过失败后仍必然成功的反事实收益。

本轮 `results.calls` 缺少 `errorMessage`、`statusCode`、content-type、响应片段和响应 hash；`results.error=null` 是因为最终恢复成功，不意味着前面没有错误。`responseProtocol` 仅在 `inner.complete` 成功后追加，因此编号 12–15 整体缺失，不能从该数组恢复错误体。`requests.jsonl` 没有 body，`events.jsonl` 只有错误分类。App 的 UsageSink 为进程内 `MemoryUsageSink`；本轮 local-state 文件没有 UsageRecord 持久化集合，`coach-032-live.log` 的 SMOKE_RESULT 也只是相同投影，无法补回这些消息。

按 [固定 0.3.2 transport 的解析实现](https://github.com/mhgd3250905/ugk-3d-pose-sdk/blob/b26e4fda807b6ef3db15a61ba30c67fb51dce5e1/lib/src/llm/openai_compatible_client.dart#L161)，标准客户端在 HTTP 200 分支有三种 badResponse：

| SDK 分支 | 该分支会生成的错误消息 | 此次是否能确定命中 |
| --- | --- | --- |
| JSON 解码失败（L175–177） | `返回体不是 JSON：<截断片段>` | 不能；具体消息未保存 |
| JSON 中没有 choices（L180–182） | `没有 choices：<截断片段>` | 不能；具体消息未保存 |
| content 为空且无 tool_calls（L194–196） | `正文为空` | 不能；具体消息未保存 |

因此可以定位 **SDK 把服务返回分类为 badResponse，并按单步失败重试恢复**。按该版标准 transport 代码推导，这些错误来自 200 分支的结构/内容解析，HTTP 状态本身没有作为实测字段保存。不能在三者中选一个，更不能把它们写成“网关返回 5xx”“解析失败已证明是 SDK bug”“一定是内容审查”或“reasoning 字段缺失导致”。在实际失败前成功的请求 #11，`responseProtocol.reasoningPresent=false`，而发往 #12–16 的 `assistantProtocol` 已记录 `reasoningPresent=true, reasoningLength=0`；至少没有“回传历史 assistant 缺整个 reasoning_content 字段”的直接证据。长度标记仍无法证明其他请求字段或上游协议完全正确。

网关 `api.uuugk.win`、其上游路由、HTTP content-type 以及未经 SDK 解析的返回体均未追踪到本轮四次请求；故 **gateway vs upstream vs SDK 协议兼容问题仍待带关联编号的原始响应诊断**。SDK 解析/重试路径明确，远端根因不明确。

另外只在旧运行 `.buildlog/skill-agent-smoke/2026-10-21T06-21-53.751672Z/results.json` 的 `actions.error` 看到了 `LlmException(badResponse 200)`，片段以 `data: {"error":...}` 开头，包含 `content_check_error` / `content_check_rejected`；该片段确证旧 run 曾收到 SSE 格式错误，而当时客户端要求单个 JSON 响应。**它不是本轮 #12–15 的原始 body，也不是完整 HTTP 抓包，不能移植成这四次的具体 errorMessage 或根因。** 它只提供下次诊断可验证的假设。

## 对 0.3.3 验证的直接约束

优先比较每条的实际请求/逻辑步与 P/C，而不是只比较最终 status 或设置更短 timeout。已有证据更支持减少可避免的资料披露往返和连续自检，而不是优化不存在的同轮重复 read。保留最终交付门禁与记忆持久化确认；独立新对话、记忆开关和相同问题继续分别记录，记忆开/关两个样本不视为严格等条件性能对照。

下一轮日志至少保留每次 record 的 `errorKind`、经过脱敏的 `errorMessage`、step/retry、请求关联号及 HTTP status/content-type；逐步记录工具名/路径与结果状态（尤其 check_plan ok/错误 code、read 是否命中、压缩是否发生），才能判断自检是否必要并定位 badResponse。原始 body 若需保留应是受控、脱敏的诊断附件，不能把密钥、请求头、设备标识、用户记忆或完整 reasoning 写入可提交报告。本分析文档没有这些敏感字段。

本轮仅 6 个不同场景、每场景 1 次；43 次调用共享一次网关时段，不能据此报告 P95、稳定 SLA 或保证的提速百分比。原六条 verdict 的动作卡误报保持原样；独立补卡运行不计入本基线。

## 证据完整性校验

| 文件 | SHA-256 |
| --- | --- |
| `results.json` | `3c0e26226ade06b0a0bf7f6edfed9e6b1c88fde46653ae3ea6891153cacd6d87` |
| `requests.jsonl` | `51581f4ea7076559cb5c191dce7a636c0518e75c7140e75b84eaed131ce4f0cc` |
| `events.jsonl` | `a5e495e6a3b127b88bb1ddb1c88ec8d8523ccd24bf2c350e54ddb753f3ab1cd5` |

校验方式：只读解析三份 JSON/JSONL；检查请求号 1–43 连续、每案例 calls 数等于 httpRequests、所有 httpAttempts=1、事件逐项一致、各用量字段逐记录求和等于案例汇总、读取事件等于成功 reads 列表。每个请求的时刻均位于对应 step 的 thinking 起点与下一 step 起点（末步为 done）之间；成功请求号与 responseProtocol 完全一致，失败 #12–15 缺席。未改写任何原始证据。
