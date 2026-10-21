# Changelog

## 0.3.2 — 2026-10-21

### 推理协议、请求预算与记忆持久化

- 按指定源提交 `9bc392c42222d61d8c57e8dc00373ee165e56e06`，在 main `517fdbef6d9e611eff3f68bc2138f8e00e35c82e` 上集成思考模型修复，分支为 `codex/coach-agent-032-integration`；原修复分支保持原状。
- `LlmMessage.reasoning` 保存模型返回的协议推理，Agent / Session 的中间工具、门禁重交和最终历史继续回传。每条 assistant 消息序列化时都带 `reasoning_content`，缺失或 null 使用空串；不混入用户正文或 `toString()`。
- 记忆关闭时，当前工具轮、单步重试与历史 assistant 的记忆相关推理同步脱敏；上下文压缩仅替换早期 read / ls 的 tool 结果，保留 assistant 的工具调用与推理协议字段。60k 上下文预算不计 `reasoning_content`，历史字符上限仍计入推理长度。
- `CoachAgent.turnTimeout` 默认 180s → 360s，`slowAfter` 默认 15s → 30s；`requestTimeout` 仍为 60s，`contextBudgetTokens` 仍为 60000。
- `remember` / `forget` 逐条等待 `UserMemoryStore.save` 成功后才更新缓存、返回 `ok:true`；保存失败返回 `ok:false` 工具错误，不吞异常后确认成功。已确认保存的前序操作在后续取消 / reset 时保留，不再等整轮最终交付才保存。
- pending 保存期间取消 / reset 立即结束 `send`，迟到结果不写缓存、历史或推理；不可取消的底层 save 完成后，串行队列补偿回已确认快照，并尊重 `clearMemory()` 的清空意图。
- 保留源修复的记忆指令：用户主动陈述水平、器械等稳定事实时，先读 user-memory skill 并分别 remember，工具成功后才确认；没有待完成训练请求时只确认记忆，不擅自排课。训练包未改动。

### 验证与合并边界

- 本次 0.3.2 在 Dart 3.12.2 执行 `dart test` 342 项全部通过，`dart analyze` 0 问题，`git diff --check` 通过。经开哥批准，main 已包含代码集成提交 `31fb6f806612e0416f3bea4e32332068fd333473`；后续批准状态文档提交不改变已验证源码。
- 原修复 source `43dfef637144a1e08b5eda5ed743db0671ba5a8d` 的根包 304 项、训练包 126 项测试及两包分析通过，属于历史证据。SmartFit App source `5743073691547d44aec891ab6d4a45b5b3fa381b`（217 项测试、分析 0 问题）的真实 Worker 六类分组验证，分别绑定 SDK `712cb7b3d636a5314c5aa08211c822928a0af4f4` / `43dfef6`；不能当作新 0.3.2 代码树的真实 Worker 验收。完整来源和 204.564s 等记录保留在[台账](docs/project-ledger.md)与 [SmartFit 报告](https://github.com/mhgd3250905/Sport-Helper/blob/feat/smartfit-skill-agent/docs/coach-agent-smoke-2026-10-21.md)。
- 本次批准范围为 SDK 主线集成及推送；SmartFit App 主线集成待独立安排。本次未新增真实 Worker、真机 UI 或完整训练流程验收结论。

## 0.3.1 — 2026-10-21

### Agent：步数、上下文预算与失败重试
- `CoachAgent.maxSteps` 默认 10 → 100（可配）。
- 上下文预算 `contextBudgetTokens`（默认 60k 估算 token）：超出时把较早的 read / ls 结果压成一行摘要，保留最近 `keepRecentSteps`（3）步，tool_call_id 协议不变；被压缩的文件可再读全文。
- 防空转 `maxStallSteps`（3）：相同工具调用或连续无新信息先提示，再犯回落（`AgentStalled`）。
- 单步请求失败只重试那一步：`RequestErrorClass` 分类，指数退避 + 抖动（1/2/4/8s 封顶 15s，`maxRequestRetries` 默认 4），429/503 尊重 Retry-After；上下文超长先强制压缩再重试一次；退避与在途请求可被取消 / reset 打断且不回写。
- `requestTimeout`（60s）、`turnTimeout`（180s）、`slowAfter`（15s）；事件新增 `retrying` / `slow`。
- 最终失败回落模板，`error = AgentRequestFailed(kind, errorClass, attempts)`，records / usage 完整；`UsageRecord.retry` 标注重试序号；`LlmException.retryAfter`（客户端在 429/503 时填）。

### 审核修复（PR #5）
- 每次实际请求（含重试）前复查 `enableUserMemory`：退避期间或在途失败前关闭记忆，重试请求按当前开关重建 system / tools / files，并过滤本轮记忆调用与结果。
- 固定本轮 reset 信号，`retrying` 事件后立即复查作废：同步监听器里 `reset()` 时旧轮即时返回 `cancelled`，不再等退避。
- 目录 `read` 与 `ls` 共用目录去重 / 新信息 / 压缩跟踪：不同目录探索不再误判空转，重复目录仍受防护。
- 压缩元数据按具体 tool 消息关联（不再按 tool_call_id），跨步骤复用 id 时不错配摘要与已读集合。

## 0.3.0 — 2026-10-21

### 新增：Agent 版（Skill 渐进式披露）
- `CoachAgent`：Pi 式工具循环（调模型 → 执行全部工具 → 再调，直到纯文字或 show_* 过门禁），`maxSteps` 默认 10；超限 / 网络 / 超时 / 暗号泄露 / 重交用尽回落 App 模板。`send` / `reset` / 取消 / busy 与 0.2 同，reset 或取消后不写历史、不写记忆。
- 三层披露：第 1 层系统提示词 `prompts/agent_kernel.md`（不含动作表，工具不放 id enum）；第 2 层 `skills/<name>/SKILL.md`（action-library / plan-training / action-coaching / user-memory）；第 3 层按 profile 白名单生成的索引与动作详情（`SkillFiles`，只读、内存，随目录更新重建）。
- 工具：`read` / `ls` / `check_plan`（复用门禁 + 时长估算，返回与 targetMinutes 的差）/ `show_actions` / `show_plan` / `remember` / `forget`；无专用查询接口。
- 过程事件流 `CoachAgent.events`（thinking / reading / listing / checking / memory / done）。
- 用户记忆：`enableUserMemory`（默认开、运行时可切）、`UserMemoryStore` + `InMemoryUserMemoryStore`、`MemoryKind`、去重与上限、`clearMemory()`。
- profile 新字段 `skills`（App 专属 skill）；`CoachTools.build(idEnum:)`；`CoachTurnResult.steps` / `reads`；`CallOutcome.toolStep`（Agent 中间步）。
- 文档 `docs/agent-plan.md`。

### 兼容
- 0.2 `CoachSession` 保留作降级，行为不变；0.1 `CoachAssistant` 仍为 deprecated。

### 本机验收（2026-10-21）
- PR #4 已合入 main，合并提交 `1f8be6edf9c0c57575d963448af379e8fdf8df2a`；与复审 head `48417e03f5ff05d4434dc2e15cc36237464153d2` 的代码树一致。
- 根包 `dart test` 284 项全部通过，`dart analyze` 无问题；修复复现、适用代码状态及非阻塞 P3 见 [项目维护台账](docs/project-ledger.md)。
- 该 main 基线首次真实 Worker 冒烟暴露推理协议回传问题；修复分支随后完成多步与记忆六类分组验证，历史证据及当前集成状态见上方 0.3.2 与台账。历史 0.1 冒烟和 0.2 tools 请求不作为 0.3 真实验证的替代证据。

## 0.2.0 — 2026-10-21

### 新增：工具版（function calling）
- `CoachSession`：单会话多轮（`send` / `reset`），用户输入上限（500 字）、硬上限（20 轮 / 4 万字符，超了返回 `TurnStatus.limitReached`，不报错）。
- 两个工具 `show_actions`（1–6 个动作、不带剂量）/ `show_plan`（TrainingPlan v1）；本 App 动作白名单写进参数 enum。
- `ToolGate` 门禁（只判不修，不修 JSON 语法）：错误码 `invalid_json` `schema` `unexpected_field` `items_count` `multiple_tools` `unknown_tool` `empty_reply` `unknown_exercise` `out_of_profile` `mode_mismatch` `avoid` `duplicate_action`（看动作 / 计划内同块或跨块重复），并沿用 0.1 其余计划规则；剂量超推荐、时长偏差、块顺序不理想只警告。一次报全部错误（位置 / 错误码 / 期望 / 实际 / 改法）作为 tool 结果回给模型，最多重交 2 次，仍不过回落模板。
- `ValidatedPlan` / `ValidatedActions` 私有构造，只能由门禁产出；模板计划经 `ToolGate.admitTemplate`。
- 内核提示词 v3（`prompts/kernel_v3.md`）含防破甲段与暗号；回复或参数里出现暗号整轮丢弃、直接回落。
- `LlmMessage` 支持 tool 角色 / tool_calls，`LlmRequest.tools` / `toolChoice`，`LlmResponse.toolCalls`；`OpenAiCompatibleClient` 带工具时不发 response_format，正文可为空。
- `LlmConfig.headers`（自定义请求头）、`LlmConfig.ugkWorker`、`UgkWorkerAuth`（X-App-Key + X-Device-Id，不带 Authorization）。
- `PlanIssue` 增加 `expected` / `actual` / `fix`。

### 审核修复（PR #3）
- `CoachSession` 会话世代：`reset()` 后进行中的旧轮返回 `cancelled`，不写回新会话。
- 并发策略为拒绝：进行中再 `send` 返回新增的 `TurnStatus.busy`；硬上限计入进行中轮次，历史不再按响应到达顺序倒置。
- 异步回落返回后复查取消与世代，取消返回 `cancelled`，历史与轮数不变。
- 暗号检测覆盖参数 JSON 解码后的全部字符串（`\u0055GK-…` 转义不再漏检）；Python `validate_tool_turn` 同步。
- 新错误码 `context_conflict`（E_CONTEXT）：计划 `level` / `targetMinutes` 与本轮 `CoachContext` 明确值冲突即打回重交；Python 评测校验同步，`parity_tools.json` 增至 31 例。

### 兼容
- 0.1 的 `CoachAssistant`（JSON 信封）保留一版，标 `@Deprecated`，行为不变。

### 评测
- `eval/tools/validate.py` 新增 `validate_tool_turn`（与 ToolGate 同口径，`test/fixtures/parity_tools.json` 逐例对照）；`eval/tools/eval_tools.py` 工具版评测；用例 24 + 破甲 8。

## 0.1.3 — 2026-10-20

### 修复
- 异步鉴权头准备纳入同一请求的取消/超时及 finally 清理；存储等鉴权准备失败不遗留计时器、不发送或重试 HTTP。
- 取消/超时后迟到的鉴权结果不再触发请求；已有 HTTP 重试与取消语义保持。HipLab 新中转用宿主 AuthProvider 提供 X-App-Key / X-Device-Id，无需改变其他 App 的默认鉴权。

### 验证
- 根包 `dart test` 168项、`dart analyze` 0问题；训练包118项、`flutter analyze` 0问题。新中转真实调用与手机流程由HipLab单独记录，不由SDK单测推定通过。

## ugk_trainer 0.1.0 — 2026-10-20

新 Flutter 包 `packages/ugk_trainer`（依赖本仓库 ugk_coach），按 `docs/trainer-plan.md` 第 1 步实现；根包 ugk_coach 未改（根 `analysis_options.yaml` 排除 `packages/**`）。

### 新增
- **engine/**：以 SmartFit `session.dart` 为底，输入 ugk_coach `TrainingPlan` + 每动作 `Rhythm`；绝对活动时间；自主计次相位（`completeSet`，决定 A）；rep_hold `holdSeconds`；换边间隔可由语音脚本加宽；相位访问日志；`restartWith` 换动作。
- **rhythm/**：`ActionKind` / `KitPhase` / `RepPlan`（HipLab action_kit）；`Rhythm.fromJson`（目录 `rhythm` 字段，目录 0.3.0 另做）、`fromActionKitJson`、`fromRepSeconds`、`forDose`；`rhythmsFromCatalog`。
- **voice/**：HipLab 10-19 版 `VoiceQueue` / `VoiceLineController` / `JustAudioVoiceOutput`（去 dart:io，web 可编译）；合并版 `SessionScript`；`VoiceSource` + `ManifestVoiceSource`（HipLab manifest）+ `DrillPackVoiceSource`（SmartFit 包）；无该语言语音时只放提示音（决定 B）。
- **platform/**：`TrainingKeepAlive` / `TrainingHold`（HipLab 前台服务做成本包 Android 插件，通道 `ugk_trainer/training_session`，通知文字由 App 传）；`ScreenAwake`。
- **media/**：`DrillMedia` / `DrillMediaView`（原生 WebView + 本机资源服务；web iframe），播放页随包。
- **ui/**：`TrainerPlayer`（SmartFit 播放页为底）、`TrainerTheme`、`TrainerStrings`、插槽 `onDiscomfort` / `feedbackBuilder` / `mediaBuilder`。
- **result/**：`SessionResult`（开始即定 `sessionId`）、`SessionRecorder`、`ResultSaver`（失败可重试、同 id、不重复保存）。

### 验证
- `flutter test` 92 个全过，`flutter analyze` 0 问题；根包 `dart test` 165 个全过、`dart analyze` 0 问题。
- 未在沙盒验证：Kotlin 插件编译、真机语音/锁屏保活、web 构建。

## 0.1.2 — 2026-10-20

### 修复
- `OpenAiCompatibleClient` 重试退避（含 429 `Retry-After`）的等待可被 `CancelToken` 打断：取消后立即抛 `cancelled`，不再发下一次 HTTP 请求（HipLab PR #25 审核 F25-5）。

### 验证
- `dart test` 165 个全过（新增「退避等待中取消」），`dart analyze` 0 问题。

## 0.1.1 — 2026-10-20

同步第 1 阶段成果（ai-coach-eval c60023f、Pose-Hub PR #11 809f36a）；未调用真实模型。

### 变更
- **提示词内核 v2**（ai-coach-eval c60023f）：`kind → plan → text` 顺序、kind=plan 时 plan 必填、思考简短、text ≤80 字、`plan.equipment` 含场所默认器械。三份系统提示词金样由 `build_prompt.py` 重新生成，与 SDK 渲染逐字节一致。
- **提示词版本号**：`kernel-v2-<内核哈希>…`（新增 `kernelRevision = 2`），当前 `kernel-v2-694a82ed`；调用记录据此区分 v1 / v2。
- **重写轮**：输出疑似截断（JSON 未闭合 / 没有 JSON）时追加「少想一点、输出紧凑 JSON」，与评测 `format_feedback` 一致。
- **校验器对齐**：mode 必须与目录剂量单位一致、动作 scenes 必须匹配计划场所——两条错误规则与 `validate.py` 逐例逐条对齐。对照测试改为数据驱动：`eval/tools/export_parity.py` 导出 24 例自测 + 8 条补充样例及 Python 实际判定（`test/fixtures/parity.json`），`parity_test` 比对错误分类集合和每类条数（之前只比分类，并放过连带错误）。
- 修复两处与评测不一致：`PlanCodec` 严格模式不再重复报「缺少 title / goal」（由 `PlanValidator` 报一次）；`CoachAssistant` 在信封 / 结构有错时也跑规则校验，重写一次回传全部错误。
- **评测并入 `eval/`**（git subtree，保留 ai-coach-eval d0c5cab → 73acd1b → c60023f 历史）：`tools/validate.py`、`eval.py`、`build_prompt.py`、用例、两轮结果与调用账本（已检查不含密钥）、README 设计说明。profile / 内核 / 目录快照 / 目录 schema 以仓库根为唯一来源，评测脚本直接读，重复副本已删。

### 核对（无改动）
- 动作目录快照 `test/fixtures/pose-hub-catalog.json`（0.1.0，142 个动作）、`schema/catalog.schema.json` 与 Pose-Hub PR #11 `feat/ai-coach-catalog` 809f36a 的 `catalog/catalog.json`、`catalog/catalog.schema.json` 逐字节相同。
- `profiles/*.json` 与 ai-coach-eval c60023f 逐字节相同（d0c5cab 之后未改）。

### 验证
- `dart test` 164 个全过，`dart analyze` 0 问题；`python3 eval/tools/validate.py --selftest` 24/24；`eval.py dry` 跑通。

### 待定（等开哥拍板）
1. OpenCSG 上 DeepSeek 的单价（输入 / 缓存命中 / 输出，每百万 token），填进 `Pricing` 后调用记录才有花费。
2. 中转 Worker：用哪个 Cloudflare 账号 / 域名部署，App 令牌怎么发（每 App 一个固定令牌，还是按设备签发）。
3. 目录远端发布位置（manifest.json + catalog-<版本>.json 放哪个 CDN / GitHub Release），以及由 Pose-Hub 发布时自动生成清单。
4. Pose-Hub PR #11（809f36a）合并 / 改动后，本仓库再同步一次目录快照（README「开发」一节）。
5. 校验严格度：动作推荐范围（doseRange）、估算时长偏短目前只警告不重写；要不要升为错误（更规范，但重写率和花费会上升）。
6. v2 内核尚未用 SDK 做真实冒烟（评测第 2 轮只重跑了 v1 失败的 2 条）；需要时跑一次 `example/smoke.dart` 或全量 24 条评测。

## 0.1.0 — 2026-10-20

首个版本（Hark 主导，开哥全权授权）。

### 新增
- **配置**：`LlmConfig`（地址、模型、max_tokens、温度、超时、重试、JSON 模式、额外参数、单价），预设 `deepSeekOpenCsg`；`AuthProvider`：`ApiKeyAuth`（含 lazy）、`RelayAuth`（中转 Worker，上线推荐）、`NoAuth`。
- **动作目录**：`Catalog` 读 `pose-hub-catalog` format 1；`CatalogRepository`（内置 / 本地缓存 / 远端清单 + 大小 + sha256 + 版本校验，热更新与 `updates` 流）；`AssetResolver`（id → 封面 / 视频 / spec / 语音，明暗版本、远端前缀、缺素材清单）；`DrillPackAdapter` 读 SmartFit 小包。
- **计划**：TrainingPlan v1 模型与 `PlanCodec`（严格 / 宽容），`PlanValidator`（与 ai-coach-eval `validate.py` 对齐，24 例对照），`PlanDuration` 时长估算。
- **输出**：回复信封 reply / ask / plan，`extractJsonObject` 容错（围栏、think、说明文字、末尾逗号、BOM）。
- **提示词**：`prompts/kernel.md`（与评测同一份，三份系统提示词金样逐字节一致），按段覆盖 / 追加 / 变量，版本号带内容哈希。
- **模型调用**：`OpenAiCompatibleClient`（超时与取消真正中止请求、退避重试、Retry-After、推理内容与缓存 token 解析、截断识别），`FakeLlmClient`。
- **调用记录**：`UsageRecord`（时间、App/profile、模型、提示词/目录版本、四类 token、耗时、结果、问题代码、估算花费），`Memory` / `Jsonl` / `Callback` / `Multi` sink 与汇总。
- **编排**：`CoachAssistant.ask`：preflight → 调用 → 解析 → 校验 → 带错误重写一次 → 回落（App 的 `FallbackPlanner`）；离线 / 超时 / 限流 / 鉴权 / 截断直接回落；`CancelToken` 取消；`CoachConversation` 与 `HistoryPolicy`。
- JSON Schema：目录、清单、profile、回复信封；工具：`embed_prompts`、`make_manifest`、`packs_to_catalog`；示例：`quickstart`（离线）、`smoke`（真实）。
- 带入快照：pose-hub-catalog 0.1.0（Pose-Hub 809f36a）、三个 profile 与内核（ai-coach-eval d0c5cab）。

### 验证
- `dart test` 151 个全过，`dart analyze` 0 问题。
- 真实冒烟 1 次计费调用：首轮通过；prompt 4520（缓存 4096）/ completion 3102（推理 2453）/ 31.0 s。见 docs/smoke-2026-10-20.md。

### 待定（等开哥拍板）
1. OpenCSG 上 DeepSeek 的单价（输入 / 缓存命中 / 输出，每百万 token），填进 `Pricing` 后调用记录才有花费。
2. 中转 Worker：用哪个 Cloudflare 账号 / 域名部署，App 令牌怎么发（每 App 一个固定令牌，还是按设备签发）。
3. 目录远端发布位置（manifest.json + catalog-<版本>.json 放哪个 CDN / GitHub Release），以及由 Pose-Hub 发布时自动生成清单。
4. Pose-Hub `feat/ai-coach-catalog`（809f36a）与 ai-coach-eval（d0c5cab）推送 / 定稿后，本仓库同步一次快照与金样。
5. 校验严格度：动作推荐范围（doseRange）、估算时长偏短目前只警告不重写；要不要升为错误（更规范，但重写率和花费会上升）。
