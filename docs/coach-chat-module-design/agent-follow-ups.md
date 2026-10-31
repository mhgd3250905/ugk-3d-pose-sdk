# Agent 后续项：推荐作用域修复与模型往返缩减

结论：SF five-3 第 2 轮是任务切换与动作来源作用域不一致，和执行时长回调无关；
应先修这项正确性问题。SF 五个 5 分钟最终轮的额外往返主要来自任务顺序、原话引用、
检索分批和“换一套”差异检查，不能把最多 9 次模型调用归因于配时或执行回调。

本文是设计附录，**没有实施以下修法，也没有新增模型运行**。设计基线为 SDK main
`3fbd179063e9b8433cadd5387295ac07b7b93800`；App 源码与 SDK pin 保持原状。
分析只使用已存公开工具请求、后续工具回执、最终状态和可读 SDK 源码，不使用私有
reasoning、system 消息正文、请求头或凭据。

## 1. 证据范围与结论边界

来源为 [已提交结果](../reports/fit-executed-duration-20261101/results.json)、
[中间失败证据](../reports/fit-executed-duration-20261101/recommendation-intermediate-failure.json)
以及原本地 `build/fit-executed-duration/live-smartfit-20261101-r1/five-1.json` 至
`five-5.json`。逐个原 case 的 SHA-256 与已提交 `rawCaseSha256` 一致，见文末。
这批真实运行的生产源码指纹为
`d0f5ede16d339c6931622b72f2c16156ba6fec41979030384e34a78e1fe10366`。

下文“轮”有两种口径：**用户第 3 轮**是“换一套，改成5分钟”；其中一次 HTTP 模型
调用可以返回多个工具调用，依次执行。表中的 `S1…Sn` 是该用户轮内 HTTP 序号，
`C14` 等是原 case 记录中跨三轮累计的 `call`，不是额外模型调用。

既有结论保持：HipLab/SF 的 **14 个最终计划双时长门禁通过**，完整三轮会话为
13/14 成功，42 个用户轮为 41 ok / 1 error。SF five-3 的第 2 轮推荐没有交付；
第 3 轮按预设输入继续，未重抽或人工补答。SF five-3 最终计划含手动阶段，310/315 秒
中的执行秒数明确为**估算**，依旧接受双数值门禁。

## 2. five-3 第 2 轮：根因与最小修法

### 可复核的失败过程

该轮原话是“推荐几个拉大腿内侧的动作”，共 5 次 HTTP / 10514ms。所有 HTTP 均为
200；没有抛异常，`errorType=null` 不能解释为成功。

| 原 call | 公开工具请求 | 可观察结果 |
| --- | --- | --- |
| C6 | `show_actions(s-butterfly, h-butterfly-active, h-adductor-rock)` | `unseen_actions`，`field=picks`，`candidateCount=0` |
| C7 | `search_actions`，大腿内侧、拉伸/灵活、居家、垫子 | 成功返回上述三个 ID 及 `s-frog` |
| C8 | 再次 `show_actions`，相同三个 ID | 再次 `unseen_actions` / 0 候选 |
| C9 | `check(node=actions, picks=上述三个ID)` | ok，但回执仍是旧的已完成 **plan** 六节点图，并非 recommend 图 |
| C10 | 第三次 `show_actions` | `unseen_actions`；超过默认 `maxResubmits=2` 后返回 `TurnStatus.error` |

三个拒绝回执全部能在 C11 的公开请求历史中找到；没有用模型解释补全未捕获回执。
`isPlanningFailure=false` 是推荐请求及原 plan 图已完成的状态结果，不能拿它跳过错误行。
展示层应使用 `status` 与既有 `issues`，而不是只测试 `error != null`。

根因在 [OutputGate](../../lib/src/agent/output_gate.dart)、
[AgentTask.start](../../lib/src/agent/agent_task.dart)、
[NodeGates](../../lib/src/agent/node_gates.dart) 与
[terminal 工具处理](../../lib/src/agent/terminal_tool_handler.dart) 的组合：
`show_actions` 会在临时状态中把旧 plan 切成 recommend；新任务按现有来源规则清空
`seenActionIds`，所以校验失败。失败返回原 task 的状态，合法任务切换没有提交。
中途 search/check 更新的仍是旧 plan；下一次 show 又临时切 recommend、再次清空。
这些相关分支与 main 700d010 相同，不是本次执行时长门禁引入的逻辑。

这里不能宣称“失败轮完全没有状态变化”：合法 search、check 可能更新 seen/picks。
保持不变的是旧的已交付计划内容与版本。C6 前和 C11 第 3 轮起点的末尾状态均为
`plan-1793467080343-2` **v1 / 卡片 625 秒**。随后第 3 轮自行提交 replace_all：
第一份替换草稿记为 v2、被 `replace_too_similar` 拦；修正后的 v3 才交付 310/315 秒。
第 2 轮没有提交新计划版本或替换这份编辑基线。

### 建议的最小实施边界

让显式 `start_task` 与现有 typed 输出工具的隐式切换走**同一个任务入口**。仅由
`recommend/plan` 工具类型决定切换，不在 App 或 SDK 再写用户文本意图解析器。
基本参数形状和有效类型通过后，先原子提交合法任务切换，再以该任务的有效作用域
执行 search/check/show；候选/输出校验不能每次重新创建另一份临时 task。

内部可称此对象为 `effectiveScope`：绑定任务身份/修订、当前有效参数、安全修订与
profile/catalog 范围，并承载**真实搜索回执**产生的 seen。这个名称是拟议内部结构，
不是已经存在的新公开 API。一次批处理内后续工具与下一次模型请求都必须读取同一
已提交 scope；显式、隐式开始不得各维护一套候选池。参数或安全范围变化时，沿用
现有失效与重新准入规则，不能把旧 scope 的 ID 集直接并进新 scope。
仅分钟、剂量或操作变化时，继续使用现有 `parametersChanged` 的合法动作复用路径；
不能因新增 scope 修订号而强迫所有旧候选重新搜索。显式复用仍须通过当前范围校验。

本次失败的最小恢复应为：C6 虽拒绝所选 ID，但合法 recommend 切换留下“待搜索”
状态；C7 在这个 scope 成功登记搜索来源；C8 即可通过同一 scope 的校验。若继续
支持“先 search、后显式开始”的兼容路径，pending 搜索也须绑定本轮同一有效约束；
只有严格一致时才能按现有来源语义接续。不要让它落在旧 completed task，或在 show
时靠放宽 seen 来挽救。无法合法接续时，应返回明确的任务修复指引。

原子性分成两个边界：**合法任务切换/合法搜索进度可以提交；无效 picks、草稿和输出
不能提交为已验证内容**。失败回执必须携带可继续的真实节点状态，不能返回“旧 plan
图 + 新 recommend 校验结果”的混合状态。非法 ID、越范围 ID、缺少真实搜索来源、
器械/伤痛不符仍按原规则拒绝；不能将用户、模型或任意工具参数中的 ID 直接写入 seen。

旧 plan 的 `plans` 历史、`lastDeliveredPlanId/version`、显式 `focusPlanId/savedRef`
须保留。新 recommend 的工作节点、候选和 picks 不得成为旧 plan 的新版本。下一次
`edit/replace_all` 仍解析到 focus 或此前已交付的确定版本；不能把临时候选、空 plan
占位或一次失败的推荐当成讨论计划。不要依赖保留一个旧 task 图来保住编辑目标。
版本继续由 SDK 追加，宿主不分配 ID/version，不重编号、不删除 v1 或失败草稿历史。

模型工具协议保持现有 `start_task → set_params → search_actions → draft_plan → show_*`
及 `set_params(operation=edit/replace_all)`，复用已有自检；不新增 get_plan/edit_plan。
回执如需补 scope/修复说明，只加可观察字段，不能通过重置重交计数、吞掉错误或
绕过来源检查让本例“成功”。有限重交与步数上限继续有效。

### 定向回归与真实验收建议（尚未执行）

| 用例 | 必须保持的断言 |
| --- | --- |
| 原 C6→C7→C8 最小重放 | 第一次拒绝后 recommend 工作状态一致；成功搜索后同 ID 可交付，不能再归零；任务事件只发布一次合法切换 |
| 显式 start 与隐式 show 两条入口 | 相同有效约束下 search/check/show 读同一 scope，含同一 HTTP 批与跨批两种情况 |
| 假 ID、只读目录或旧范围 ID | 不因切任务加入 seen；仍拒绝，参数/安全变化后旧准入不能借用 |
| 输出失败、取消、宿主安全更新并发 | 已验证的阶段提交与无效输出提交分离；不能残留混合节点，不能发布 stale 卡片 |
| 先有 A，再推荐成功/失败，再改计划 | A 内容/版本不变；明确修改仍指向 A，保持 focus/savedRef；新版本仅来自真实 draft/refit |
| 持续错误或重复反问 | 在原有限预算内终止；不交付近似/预设/未验证卡片，不以 `errorType=null` 当成功 |
| 新会话、恢复快照及跨 App | 原合法路径不回退；scope 不跨 controller/profile/catalog 或用户复用 |

实施后先离线重放固定回执，再在相同 SF 配置与三轮原话下运行事先约定的独立会话。
目标是推荐与后续计划同时成功、旧编辑基线与双时长门禁均保持。失败样本原样保留；
“最终计划通过”和“每轮成功”继续分别计数。本文没有启动这轮真实复验。

## 3. 五个 5 分钟最终轮：逐次 HTTP 与回执归因

| 样本 | HTTP / 工具数 | 用户第 3 轮总 ms | 卡片/执行秒 | 可见主要修复来源 |
| --- | ---: | ---: | ---: | --- |
| five-1 | 9 / 10 | 23122 | 329/330 | `wrong_node`，随后 `replace_too_similar` |
| five-2 | 5 / 5 | 15876 | 313/315 | `quote_not_found` |
| five-3 | 4 / 5 | 15103 | 310/315，估算 | `replace_too_similar`；第 2 轮推荐失败单列 |
| five-4 | 7 / 11 | 21019 | 311/313 | 6 个不同检索请求，1 次重复技能正文读取；没有拒绝码 |
| five-5 | 8 / 11 | 29001 | 312/316 | `wrong_node`，随后 `replace_too_similar` |

**9 次 / 23.122 秒是 five-1；最长 29.001 秒是另一个样本 five-5，只有 8 次。**
以下只记录公开工具与回执要点；一行内 `+` 表示同一次 HTTP 返回的多个有序工具。

### five-1：9 次 HTTP

| S / 原 call | 工具 | 回执与归因 |
| --- | --- | --- |
| 1 / C14 | `set_params(minutes,operation)` → `start_task(plan)` | 两者 ok；但 start 回执 `reused=false`、当前节点 parameters |
| 2 / C15 | `search_actions`，拉伸、内侧/髋屈/髋外展、居家、垫子、level1 | 4 项，合法检索 |
| 3 / C16 | `draft_plan` | `wrong_node`；没有版本/配时回执，尚未进入剂量配时 |
| 4 / C17 | `check(parameters)` | ok，修复刚才的新任务节点顺序 |
| 5 / C18 | `search_actions`，髋外展拉伸 | 返回 `o-stand-crossreach`，不是完全相同查询 |
| 6 / C19 | `draft_plan` | v2，执行 314 秒、已在时长窗口；10 条剂量调整日志，但被 `replace_too_similar` 拒绝 |
| 7 / C20 | `search_actions`，扩大到臀大肌等目标 | 返回 6 项，补替换候选 |
| 8 / C21 | `draft_plan` | v3，执行 330 秒，自动 check ok；本次 fitLog 空 |
| 9 / C22 | `show_plan` | 最终 ValidatedPlan 与保存版仍为 v3，329/330 秒 |

额外模型重编的直接触发是节点顺序和“换一套”的动作差异门禁，**没有
`duration_fit_failed` 回执**。v2 虽已经过本地配时，其拒绝原因仍是替换相似度。

### five-2：5 次 HTTP

| S / 原 call | 工具 | 回执与归因 |
| --- | --- | --- |
| 1 / C10 | `start_task(plan)` | `reused=true`，当前 planning，合法复用前轮候选 |
| 2 / C11 | `set_params` | `quote_not_found`：minutes.quote 写成“换成5分钟” |
| 3 / C12 | `set_params` | 改用原话“改成5分钟”，通过；来源校验不能省略 |
| 4 / C13 | `draft_plan` | v2，执行 315 秒，32 条剂量调整日志，自动 check ok |
| 5 / C14 | `show_plan` | 保存版仍 v2，313/315 秒 |

本轮没有新 search、重复 draft 或配时拒绝；额外一次参数修复不是执行回调错误。

### five-3：4 次 HTTP

| S / 原 call | 工具 | 回执与归因 |
| --- | --- | --- |
| 1 / C11 | `set_params` + `search_actions` | 均 ok；仍以原已交付 plan v1 为基线 |
| 2 / C12 | `draft_plan` | v2，执行 326 秒、时长合格，fitLog 空；被 `replace_too_similar` 拒绝 |
| 3 / C13 | `draft_plan` | 换主体项后 v3，执行估算 315 秒，7 条剂量调整日志，自动 check ok |
| 4 / C14 | `show_plan` | 保存版仍 v3，310/315 秒，含手动计次 |

这次最终轮没有节点/原话错误；一次模型重编由主体动作差异不足触发。第 2 用户轮的
五次推荐调用不计入这里的四次，但保留在完整会话耗时和成功率中。

### five-4：7 次 HTTP

| S / 原 call | 工具 | 回执与归因 |
| --- | --- | --- |
| 1 / C9 | `start_task(plan,reuse=true)` | ok，当前 planning |
| 2 / C10 | `set_params` | ok |
| 3 / C11 | `read(plan-training/SKILL.md)` + 内侧拉伸/垫子 search | read 返回正文；search 返回 3 项，均未被挡 |
| 4 / C12 | 髋屈拉伸 search + 髋外展拉伸 search + 垫上灵活 search | 同批分别返回 5 / 1 / 12 项 |
| 5 / C13 | 去掉垫子标签的内侧拉伸 search + 臀大肌拉伸 search | 同批返回 6 / 4 项；前者为扩大查询，并非完全重复参数 |
| 6 / C14 | `draft_plan` | v2，执行 313 秒，21 条剂量调整日志，自动 check ok |
| 7 / C15 | `show_plan` | 保存版仍 v2，311/313 秒 |

这 6 个 search 均合法、没有 search 拒绝码。内侧两次查询有重叠，也确实扩展了候选，
不能一概删成“重复搜索”。可以研究合并同类 OR 目标与批量查询，但仍需遵守场景、
器械、level、上限和已搜索来源，不能以减少 HTTP 为由吞掉新增候选。

该 read 的 2682 字符正文与请求历史已披露的 plan-training 正文 SHA 相同：
`f5591c626dea613faca051d927ab287b5389a94af9a5825db1c2906a68bbe63c`；本轮 start
回执也已有披露引用。它是可去除的重复正文读取，**不是被挡 read**，且与 search 同批，
不能声称去掉它就必然省一次 HTTP。

### five-5：8 次 HTTP、耗时最长

| S / 原 call | 工具 | 回执与归因 |
| --- | --- | --- |
| 1 / C13 | `set_params` → `start_task(plan)` | 均 ok；`reused=false`、当前 parameters |
| 2 / C14 | 内侧拉伸/垫子/level1 search | 返回 2 项 |
| 3 / C15 | 内侧灵活 search + 髋屈拉伸 search + 臀大肌灵活 search | 同批返回 2 / 3 / 7 项 |
| 4 / C16 | `draft_plan` | `wrong_node`；这次 HTTP 本身耗时 7147ms，不是一次已测得的本地 fit 耗时 |
| 5 / C17 | `check(parameters)` | ok，补节点顺序 |
| 6 / C18 | `draft_plan` | v2，执行 315 秒，4 条剂量调整日志；被 `replace_too_similar` 拒绝 |
| 7 / C19 | `draft_plan` | 更换主体组合后 v3，执行 316 秒，自动 check ok；fitLog 空 |
| 8 / C20 | `show_plan` | 保存版仍 v3，312/316 秒 |

### 必须分开的四种过程

这五个最终轮的可观察拒绝码合计为 `wrong_node` 2 次、`quote_not_found` 1 次、
`replace_too_similar` 3 次；**没有 `duration_fit_failed` 或执行回调异常**。
其中 five-1/5 在已完成的 recommend 上先 set_params，使其完成态失效，再 start_task(plan)，
回执因而变成未复用的 parameters 节点；five-2/4 先 start 再写参数，复用后直接处于
planning。两种协议顺序不能混写成“配时又要求一次 check”。

1. **一次 draft 内的本地 fit**：按合法剂量搜索，可能有多条 fitLog；不是多次模型调用。
   fitLog 空只说明没有剂量改动，不能推出没有调用 fitter/执行测量。
2. **模型重出 draft**：本例因 wrong_node 或 replace_too_similar 后再次调用 draft_plan；
   后者在剂量已合格后仍须满足原主体差异门禁。不能放宽差异要求来省调用。
3. **自动 check/review**：成功 draft 的同一回执已有 `check.ok=true`，不是另一轮模型
   check_plan。这五轮没有额外的模型 planning/review 复核往返；两次 check(parameters)
   是当前错误路径的必要修复，不是可以连同参数校验一起取消的重复 review。
4. **show 时自动 refit**：现有 OutputGate 只在目标/已确认剂量不符或双时长不合格时
   进入 refit，随后仍会重新量测最终候选。五例 show 前与最终保存版本均为
   `3/2/3/2/3`，时长及日志匹配，未出现该追加版本路径。最终 show 没有下一次请求
   回传其 tool receipt，本文以最终 ValidatedPlan/保存版核对，**不杜撰 shown/refit 回执**。

## 4. 耗时只能按现有计时点定量

| 样本 | 用户轮 elapsedMs | 各 HTTP elapsedMs 合计 | 未分项差额 |
| --- | ---: | ---: | ---: |
| five-1 | 23122 | 22934 | 188 |
| five-2 | 15876 | 15635 | 241 |
| five-3 | 15103 | 14961 | 142 |
| five-4 | 21019 | 20872 | 147 |
| five-5 | 29001 | 28859 | 142 |

`EvaluationWireClient.send` 的计时从交给底层 HTTP client 前开始，到完整响应体读完
结束：包含网络、服务端排队/模型生成及传输，**不能拆成已测得的“网络秒数”和
“模型思考秒数”**。用户轮计时包住 conversation.send；其与串行 HTTP 合计的差额是
未分项综合开销，包含本地工具、fit、回调、序列化、SDK 状态处理与调度等，不能全部
命名为 fit，也不能从它推断单次 callback 成本、候选数或某个优化能省几秒。
最终验收 helper 的 phase 重放发生在用户轮计时停止后，也不能混进该差额归因。

现有记录支持先减少无效模型往返。它们没有 fit/callback 独立 span、服务端排队、
TTFT 或 token 流时点；本批 harness 的 taskAtRequest/caseElapsedMs 等可选 provider
也未接齐。缺失字段应保持未知，不能凭工具名称或响应长短填成“模型慢/配时慢”。

## 5. 降低往返的优先级与调用预算目标

以下都是**待实施、待验证目标**，不是从这批运行测出的改进成绩。正确性优先，不能
改 fit 的搜索顺序、合法剂量范围、双时长/安全/来源/差异门禁，不能换模型、重抽、
加 fallback plan、删动作截断时长或将非法 ID 加入 seen。

| 优先级 | 建议 | 预期作用与约束 |
| --- | --- | --- |
| P0 | 统一 task/scope，合法切换先提交，输出原子准入 | 修复第 2 节循环；保留旧计划与版本；不把错误“记成成功” |
| P1 | 固定 typed 批处理顺序；已知条件用既有 NodeGates 自动推进 | 使用 start→set→search→draft；不要先 set 再新建任务使参数节点失效。自动推进仍调用同一参数门禁，不能跳过参数/来源检查 |
| P1 | 原话引用与自检回执作为下一步的明确依据 | 引用用户实际子串，避免“换成/改成”改写；成功 draft 已自动 check/review 就直接 show。失败修正是同轮合法重交，不能改成截断输出 |
| P2 | 复用已有 inline 技能索引、start_task 披露与当前 scoped candidates | 不再为已可见技能增加 read；候选确实不足时再搜索，且仍须由真实 search 登记来源。不能凭索引/目录存在就自动准入未搜 ID |
| P2 | 同类检索目标合并、独立检索同批返回 | 利用现有同类标签 OR 语义和工具批处理，减少五-4那样多批探索；保留过滤、结果上限、必要的扩大查询和新增候选，不以“去重”删除有效选择 |
| P2 | 在模型可见的既有替换反馈中明确旧主体与合规差异候选 | 使下一份 draft 一次满足原 replace_all 阈值；不降低阈值、不改为 edit、不给模型传任意剂量。若考虑结构预检前移，需另审版本/拒绝草稿历史语义，不能悄悄把现有 v3 重编号成 v2 |
| P3 | 先补最小本地 span，再决定是否优化测量开销 | 目前没有证据表明 callback 是秒级瓶颈。不先做跨轮测量缓存；show 必须按实际最终候选与当时宿主配置复检 |

对于约束已知、候选可获得且组合可行的替换计划，目标为 **3–4 次 HTTP**：
一批处理 start/params/必要 search，一次 draft，最后 show；确有新增检索时再加一批。
出现一次真实结构重建时目标 **不超过 6 次**。这是后续协议效率的观测预算，不替代
现有 maxSteps/maxResubmits，也不能为了达成数字提前交付或掩盖失败。

先验收 wrong_node/无效 quote/重复披露是否消失，再比较调用数。耗时另报全部样本、
HTTP 与本地 span 及分布，不把少 2 次调用换算成固定秒数承诺。新正常路径应保留
known-condition 的零反问行为、全部双时长门禁和每轮成功率；有限预算内仍失败就
如实失败，不能补抽一个样本替换它。

## 6. 最小观测 schema 建议

不需要新模型工具。实施时可扩展现有安全诊断出口；下面字段是**建议**，当前数据
没有的应写 null/unknown，而非反向补造。时间用单调时钟，嵌套 span 不重复求和。

| 范围 | 建议字段 |
| --- | --- |
| 不可变来源 | schemaVersion、run/case/host、sdkCommit、profile/catalog digest、宿主提供的 builder 配置身份；不含配置正文或密钥 |
| 每用户轮 | turn、输入/消息引用、status、已有 issues/errorCode、planId/version 前后、finalDelivered、手动估算标记、总 elapsed |
| 每 HTTP | call、toolCallId 对应关系、HTTP elapsed、status、request/response byte 数与 SHA、模型标签、公开 usage；如服务端未提供排队/TTFT，保持未知 |
| 每工具 | task type/scope revision 前后、工具名、结果码、有效 seen 数变化、是否切任务；公开引用可追到已捕获 receipt |
| draft 与配时 | draftOrdinal、触发的上游错误/toolCallId、fitElapsedMicros、rangeElapsedMicros、候选测量次数、callbackTotalMicros、card/executed 秒；fitLog 条数另列，不能代替耗时/次数 |
| 输出 | needsRefit/refitReason、refitElapsedMicros、最终 fresh measurement、自动 check/review 是否执行、计划版本与最终 gate 结果 |

新的 span 只计时和计数，不改变搜索顺序、剂量或调用结果。错误显示可直接保留现有
`CoachTurnResult.issues`；不必为了这项分析另加一个会参与模型决策的错误状态系统。
观测不能保存 reasoning、system 正文、授权头或认证值，也不能引入第二套训练时间估算。

## 7. 后续门禁与来源索引

先用固定公开回执验证任务作用域、失败原子性和旧版保留；再以同目录/profile/实际
builder 核对现有固定时长回归、上下限、异常、手动计次和自然 timeline。协议优化
不能改既有 fit 搜索方法或把回调替换成常数预算。三包全量、analyze 0、默认 golden
零差异仍是实施分支门禁；本设计文档没有运行或声称这些检查的新成绩。

真实复验须预先固定独立样本与输入，沿用原模型/配置，记录每轮成功和最终计划门禁、
总调用/耗时及本地 span。对 SF 原三轮尤其保留推荐中间状态；HipLab/SF 均应传各自
播放器实际 builder。预算超出作为性能结果报告，不改为近似计划/隐式豁免，不重抽。
真机/音频/交互性能需要另有宿主验收，本例离线时间线与模型记录不能代替它们。

| 原本地 case | SHA-256（与已提交 results 一致） |
| --- | --- |
| five-1.json | `ab73c63785dae3c8bbb67e99938fb01a36de600fb2b8317604e44b0cedab14a2` |
| five-2.json | `08111ec81e9901fcb7648c75bb44c4a4fdc1f969f070f74a5b024cc4b7ad23ec` |
| five-3.json | `ffe472247656aecbccfeb77d743464377e46a5c6040d6e2849fc3018ad69c3f0` |
| five-4.json | `8bcec593730c01dff2dbb34e375412bfc8905efd20e497afd27ccc2b5cc4daa7` |
| five-5.json | `1fc5ad189a657a240134006a5e85b036c2a6dd76bb29b871cf4b0cc8008507d2` |

原 SF timeline SHA 为
`64d142e37f2998dc3e7d02e881a021ce399d851bcd67895df03b458ccbf46964`。
可读证据入口为 [真实报告](../reports/fit-executed-duration-20261101/README.md)、
[已提交计划/状态](../reports/fit-executed-duration-20261101/results.json) 和
[来源失败回执](../reports/fit-executed-duration-20261101/recommendation-intermediate-failure.json)。
源码复核点为 `output_gate.dart`、`agent_task.dart`、`node_gates.dart`、
`draft_tool_handler.dart`、`task_tool_handler.dart`、`plan_builder.dart`、
`tool/eval_coach_agent_v2.dart` 与 `tool/executed_duration_host_timing.dart`。
