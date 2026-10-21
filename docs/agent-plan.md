# 0.3 Agent 版：紧凑索引与按需详情

入口 `CoachAgent`（`lib/src/agent/`）。0.2 的 `CoachSession` 保留作降级，门禁、回落、记账口径不变。

## 三层披露

| 层 | 内容 | 何时进上下文 |
|---|---|---|
| 1 系统提示词 `prompts/agent_kernel.md` | 身份、安全、回答风格、三条内置技能快路径、按 profile.scope 生成的紧凑动作索引、其他 skill 列表、App 规则、可选记忆摘要 | 每次调用；明确动作要领问句另可预载少量匹配详情，工具 schema 不枚举 id |
| 2 `<skill>/SKILL.md` | 完整技能、记忆规则或 App 专属能力 | 按需 `read`；内置训练快路径来自同一份模板，无需重复读 |
| 3 SKILL.md 指向的文件 | 维度索引、动作详情 | 按需 `read`；明确匹配详情已预载时直接回答 |

## 文件地图（只读、内存，按 profile 白名单生成）

```
action-library/SKILL.md                    维度与取值（id + 中英释义 + 数量）、查法、放宽规则、场所规则
action-library/compact.md                 id｜中文名｜部位｜器械｜难度｜注意部位｜类型｜体位｜场所｜默认剂量｜perSide｜禁忌
action-library/index/<维度>/<取值>.md       id｜名称（中英）｜关键标签｜用途｜默认剂量
    维度：scene / equipment（none=徒手）/ muscle / category / level / caution / position / unilateral
action-library/details/<动作id>.md          用途、要领、注意、禁忌、替代、剂量与范围、单侧、器械、场所、体位
plan-training/SKILL.md                     排课原则 + 参数硬规则；直接 show_plan，复杂/失败时可选 check_plan
action-coaching/SKILL.md                   讲动作、纠错、show_actions
user-memory/SKILL.md                       仅记忆开关开时存在
<profile.skills[].name>/SKILL.md (+files)  App 专属 skill（本次不写内容）
```

- 运行时由 `SkillFiles.build(profile, catalog, memory:)` 生成，会话按（profile、目录实例、记忆开关）缓存；`catalog()` 返回新目录即重建，随远程目录更新。
- 内置 SKILL.md 源文件在 `skills/<name>/SKILL.md`，由 `tool/embed_prompts.dart` 嵌入 `prompts.g.dart`。
- 注意部位索引文件名用标准 id：膝 knee、腰 lower-back、肩 shoulder、手腕 wrist、颈 neck、髋 hip、大腿内侧 inner-thigh。

## 工具

| 工具 | 说明 |
|---|---|
| `read(path)` | 读文件；同一轮重复读返回「已读过，见前文」；路径是目录时返回列表 |
| `ls(dir)` | 列目录 |
| `check_plan` | 参数同 show_plan（也接受 `{"plan": {...}}`）；复用 ToolGate 校验 + `PlanDuration` 估算，返回 `ok / errors / warnings / estimatedMinutes / targetMinutes / diffMinutes` |
| `show_actions` / `show_plan` | 最终交付，走原门禁，只产出 `ValidatedActions` / `ValidatedPlan`；id 不放 enum，门禁照判白名单 |
| `remember` / `forget` | 仅记忆开关开时出现 |

没有 search / query / get_action 之类专用查询接口。

## 循环

调模型 → 顺序执行本次全部工具调用（记忆工具等待持久化，结果按调用顺序追加）→ 再调，直到：

- 纯文字（非空、无暗号）→ `ok`；
- show_* 过门禁 → `ok`（重交过为 `rewritten`）；不过 → 错误作为工具结果回给模型（改法换成 Agent 口径），最多重交 `maxResubmits`（默认 2）次；
- 步数超 `maxSteps`（默认 100，error = `AgentStepLimitExceeded`）、请求最终失败、整轮超时、空转、暗号泄露、重交用尽 → 回落 App 模板（同 0.2 `SessionFallback`）。详见下节。

历史只保留每轮的用户消息 + 最终交付（show_* 调用与结果，或纯文字），中间读文件不进历史。`send / reset / CancelToken / busy / limitReached / inputTooLong` 与 0.2 同；reset 或取消后不写历史、轮数，不再发事件。记忆按工具逐条确认，已确认保存的操作保留，未确认保存的迟到结果不会回写缓存或会话，详见下方用户记忆。结果仍是 `CoachTurnResult`，新增 `steps`、`reads`。记账每次模型调用一条，中间步 `CallOutcome.toolStep`，promptVersion 为 `agent-v1-<内核哈希>-<skills哈希>@<app>-<版本>`。

## 事件

`agent.events`（broadcast）：`AgentEvent(turnId, kind, step, path, status)`，kind = `thinking`（第 n 次调模型）/ `reading`（path）/ `listing` / `checking` / `memory`（path = kind）/ `done`（status）/ `retrying`（attempt、maxAttempts、reason、delay）/ `slow`。

## 步数、上下文预算与失败重试（0.3.2）

| 参数 | 默认 | 说明 |
|---|---|---|
| `maxSteps` | 100 | 每轮最多调模型几步（同一步的失败重试不计步） |
| `contextBudgetTokens` | 60000 | 每次请求前估算 system、工具定义、消息正文与工具调用（ASCII ≈ 4 字符/token，中文 1 字/token），不计 `reasoning_content`；超出则把较早的 read / ls 结果压成一行摘要（「已读 xxx（内容已省略…）」）；用户消息、最终交付、提交反馈不动 |
| `keepRecentSteps` | 3 | 压缩时完整保留最近几个工具步 |
| `maxStallSteps` | 3 | 连续 N 次完全相同的工具调用（同名同参数）或连续 N 步无新信息 → 给模型一条提示；再犯（再重复一次 / 再空一步）→ 回落，error = `AgentStalled` |
| `maxRequestRetries` | 4 | 单步请求失败后最多重试几次，只重试这一步 |
| `retryBaseDelay` / `retryMaxDelay` | 1s / 15s | 退避 1、2、4、8s…（×0.8–1.2 抖动）封顶 15s；429 / 503 的 Retry-After 优先，同样封顶 |
| `requestTimeout` | 60s | 单次请求超时（按可重试处理） |
| `turnTimeout` | 360s | 整轮总时限（含重试、退避及等待记忆保存），超出回落，`fallbackReason = timeout` |
| `slowAfter` | 30s | 单步多久未返回发一次 `slow` |

- 压缩只改 read / ls 的 tool 消息内容，assistant 的 tool_calls、reasoning 与 tool_call_id 配对不变；被压缩的文件从「已读」集合移除，模型再 read 给全文。
- 错误分类 `RequestErrorClass`：可重试 = timeout / network / rateLimited（429）/ server（5xx、408、409、425）/ badResponse（空响应、解析失败、流中断）；不可重试 = badRequest（400）/ auth（401/403）/ notFound（404）/ truncated / cancelled / other（非 LlmException）。400 且信息含 context/length/token/maximum 等 = contextTooLong：强制压缩一次再重试一次（不计重试次数，事件 delay = 0），仍失败按不可重试。
- 退避等待与在途请求都可被 `CancelToken` / `reset()` 立即打断，打断后返回 `cancelled`，不回落、不回写会话（世代机制）；已确认的记忆保存保留。每次实际请求（含单步重试）前复查记忆开关，关闭后重建 system / tools / files，并过滤记忆调用、结果与相关推理。
- 最终失败 → 回落模板，`CoachTurnResult.error = AgentRequestFailed(kind: retriesExhausted | nonRetryable | turnTimeout, errorClass, attempts)`，`fallbackReason` 按最后一次错误映射；`records` / `usage` 含本轮全部已发生调用（与取消路径口径一致）。
- 每次请求（含失败与重试）各记一条，`UsageRecord.retry` = 本步第几次重试（0 = 首次）。
- SDK 已在步级重试，建议 App 把 `LlmConfig.maxRetries` 设为 0，避免两层重试叠加。

## 用户记忆

- `enableUserMemory`（默认 true，运行时可切）。关闭时 remember/forget 工具、user-memory skill、记忆摘要都不出现。
- `UserMemoryStore`（`load` / `save` 整表，App 实现）；内置 `InMemoryUserMemoryStore`。
- `MemoryKind`：injury / goal / level / equipment / scene / schedule / body / preference / other。
- SDK 去重（同类相同或互相包含视为同一条，用新说法替换）、每类条数（默认 5）、单条（60 字）与总长度（800 字）上限。
- `remember` / `forget` 逐条等待 store 的整表 `save` 成功，才更新已确认缓存并向模型返回 `ok:true`；失败返回 `ok:false` 工具错误，不能向用户确认已经记下。后续工具从已确认快照继续计算，不再等整轮最终交付才保存。
- App 的 `save` Future 必须代表实际保存完成，失败应抛出异常。SDK 串行执行写入；保存失败不会被吞掉后当成工具成功。
- 已确认保存的前序操作在本轮后续取消 / reset 时仍保留。pending 保存期间取消 / reset 立即结束 `send`，迟到结果不更新缓存、历史或推理；底层 `save` 不可取消时，其完成后由同一写队列补偿到已确认快照。
- `agent.memory()` 读，`agent.clearMemory()` 清空并使此前记忆世代失效；迟到保存的补偿尊重清空意图，不恢复清除前内容。底层写入或补偿失败仍是存储失败，不能据此宣称已经保存 / 清除。
- 清除记忆后，本轮在途响应不能重新保存清除前的记忆；本轮剩余请求禁用记忆并脱敏旧推理，下一轮按开关重新启用。迟到的最终文字仍保留正文，推理协议字段置为空串。

## 降级

- 单轮失败 → App 模板（`fallback`）。
- 整体降级：App 把 `CoachAgent` 换回 `CoachSession`（构造参数基本相同，结果类型相同）。

## App 接入改动点

1. `CoachSession(...)` → `CoachAgent(...)`，参数相同，另可传 `maxSteps`、`enableUserMemory`、`memoryStore`。
2. 实现 `UserMemoryStore`（本地持久化），设置页加「AI 记忆」开关（`enableUserMemory`）和「清除」（`clearMemory()`）。
3. 订阅 `agent.events` 显示进度（如 reading → 「正在查动作库」，checking → 「正在核对计划」，retrying → 「网络不稳，正在重试（2/4）…」，slow → 「还在想…」）。
4. 结果处理不变（`r.plan` / `r.actions` / `r.text` / `r.status`）；Agent 一轮多次调模型，等待时间与 token 比 0.2 长，超时设置留余量。
5. 可选：profile 加 `skills` 写 App 专属 skill。

### 思考模型的工具协议

`CoachAgent` / `CoachSession` 将响应的 `reasoning_content` 保存在 `LlmMessage.reasoning`，用于中间工具、重交和最终历史的后续模型请求。该字段是传输协议数据，不是可渲染正文；App 仍只使用 `CoachTurnResult.text` 和门禁卡片。记忆关闭时推理字段同步脱敏，避免记忆摘要经推理回传。

每条 assistant 消息在 wire 序列化时都带 `reasoning_content`：已有推理按协议回传，Worker 上游不返回、返回 null，或手写 `LlmMessage.assistant(...)` 未指定 `reasoning` 时使用空字符串；预设回落历史也相同。system / user / tool 消息不增加此字段，不生成或补造推理正文。隐私过滤将记忆相关推理替换为空串，仍保留协议字段；单步重试同样执行过滤。

协议依据：[DeepSeek Thinking Mode — Tool Calls](https://api-docs.deepseek.com/guides/thinking_mode/)。
