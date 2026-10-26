# Changelog

## coach 0.7.0 / trainer 0.5.0 / coach_ui 0.3.0 — feedback r1 part 1 candidate

- Start the shared trainer immediately with unchanged bundled alpha-WebP standing images. Video preparation, host verification, cache lookup and quiet backoff retries run independently of clocks and speech; dissolve the poster over 180 ms after a composed video frame. Add ordered, current-first preparation with at most two active actions and next-action priority during rest.
- Replace the user action list with a two-column image/name grid, Chinese-name/alias search and combinable equipment/body/type facets. Hide eight pending entries without changing the 219-action catalogue. Open each complete action as a one-action shared training plan; the old detail constructor delegates to training.
- Give expanded routine headers equal top/left clearance, a 5 px title/meta gap, smaller muted metadata and first-line-aligned collapse controls. Enlarge multi-action cutout heroes by approximately 30% while retaining host cutout placement and the shared first-row flight geometry. Keep the selected solid palette.
- Add a backwards-readable grouped `ask_user` form and conversation/UI answer APIs. Infer known scene/equipment/minutes, clarify missing fields in one round with a skip action, and constrain final plans to available equipment, scene and requested duration. Existing exhaustive mode switches must handle the new form enum value.
- Bundle 219 original v3 cover files, 5,316,554 bytes, with exact catalogue hashes. Audit all videos: 187 covers differ from frame zero (183/211 user-visible actions). Preserve original media and report exceptions rather than fabricating identical-pose replacement. See [candidate contract and verification](docs/feedback-r1-part1.md).
- These are candidate versions on `codex/feedback-r1-part1`; merging/pushing main and publishing the three new tags require Kai's approval. Existing tags, R2 objects and source workspaces are preserved.

## coach 0.6.2 / trainer 0.4.2 — 2026-10-26

- Publish compressed R1 media v3 as 657 Cloudflare R2 objects under `https://media.uuugk.win/pack/r1-v3/`; the GitHub Release retains only `catalog.json` and a complete ZIP backup. Media shrinks from 587,456,377 to 163,351,529 bytes; local paths, 219 action IDs and all 211-complete / 8-pending semantics remain unchanged. Update every media receipt and expose its stable per-file download URI.
- Replace fixed v2 catalogue SHA/fingerprint admission with schema, declared version and self-consistent media-manifest validation. Complete actions can form a self-contained AI catalogue; supplied canonical bytes/definitions remain checked against the catalogue's own references. Future-version regression cases pass without changing SDK hashes.
- Add optional host-owned `PoseHubMediaPreparer.prepareAction()` progress/ready/failure streams. Browsing does not prepare; single practice cannot start its clock until ready. Show theme-driven progress, safe failure reason and retry. Uninjected local playback and existing training/Morph Pulse behaviour are preserved; SDK owns no downloader or cache.
- Keep the old whole-pack `downloadUri` as a legacy v2 URL; use `catalogDownloadUri` and each `PoseHubPackFile.downloadUri` for v3. Coach UI remains 0.2.1. See [v3 integration](docs/posehub-app-test-pack-r1-v3.md).

## coach 0.6.1 / trainer 0.4.1 — 2026-10-26

- Adopt the reviewed R1 semantic catalogue with exact SHA256 `a1655e5c64055c14af35850b5468390d9d11161e53a87a0cbe7780ec7ed25dc0`: 211 complete definitions, 8 pending, all 219 action IDs retained. `toAiCatalog()` projects the approved 69 additional definitions without generating defaults; the original 142 canonical definitions remain unchanged.
- Publish whole-pack version `posehub-app-test-pack-r1-v2`. Only `catalog.json` changes inside the ZIP; all 657 media files, the original manifest and canonical JSON retain their bytes. Keep the v1 Release, tags and assets immutable.
- Pin the approved semantic snapshot for the catalogue adapter and loader; preserve raw review/availability flags and all existing UI/player behaviour. Coach UI stays 0.2.1. [Revision and integrity](docs/posehub-app-test-pack-r1-semantics-v2.md).

## coach 0.6.0 / trainer 0.4.0 — 2026-10-26

- Integrate the unchanged Pose Hub R1 catalogue: 219 original IDs, 142 complete training definitions and 77 explicitly pending. Add a strict, immutable pack model and `toAiCatalog()` that excludes every pending entry and validates the original canonical catalogue.
- Add the SDK action browser, detail and manual single-practice pages, plus Web/Android packed-alpha media from an independently installed whole pack. Preserve existing training layout, no-flash controls and Morph Pulse.
- Distribute 657 media files (587,456,377 bytes) as one verified GitHub Release ZIP (592,170,694 bytes); Git stores only original JSON metadata and code. No media changes, ID renaming, fabricated training defaults or tiered download. Usage/integrity/platform limits: [R1 guide](docs/posehub-app-test-pack-r1.md).
- Additive APIs; no new removals. Trainer pins coach 0.6.0; coach_ui stays 0.2.1. The flat release `c6e261e` was approved on device and integrated into main before this work; the micro-skeuomorphic stash remains untouched.

## trainer 0.2.10 / coach_ui 0.1.2 — 2026-10-25（已批准快进 main）

- Archive trainer 0.2.10 and advance the reviewed candidate to main, including the existing 0.2.4–0.2.9 media, handoff, transparent-video and playback-control changes plus the R4 UI revision. Final integration SHA is recorded in the delivery receipt; this version commit does not create or move tags.
- Apply the Liquid Glass skill's tuned light/dark accessory and control recipes to the trainer's existing layout; unify Cupertino symbols and retain custom host material hooks. The offline Android/iOS/Web showcase preserves the training state machine. The Web/software path is a layout fallback, not proof of native refraction.
- Include the existing coach_ui 0.1.2 `CoachChatList.topInset` / `fadeTop` changes from candidate ancestor `ee83dc3`, preserving default host behaviour. Root coach remains 0.5.0 with no runtime changes in this integration.
- Reuse verified R4 source `4a843a7`: 253 trainer tests, 4 showcase tests and 106 layout bounds with maximum offset 0dp. Coach UI integration validation: 23 项测试与静态分析通过；媒体播放协议 8/8 通过，示例依赖严格锁文件校验通过. R4 native visual, media-composition and device-performance acceptance remains pending; earlier 0.2.8/0.2.9 profile samples do not validate R4.

## trainer 0.2.5 / coach_ui 0.1.2 — 2026-10-24（修复分支，待真机确认后合 main）

- Trainer moves the next-action preview below the info header at the upper left. It removes the paused badge and lets hosts inject `pausedColor` / `onPaused` for the resume button, keeping timer, voice and safety callbacks unchanged.
- Coach UI exposes `CoachChatList.topInset` and `fadeTop`. Hosts can retain initial safe clearance inside the list while allowing scrolling content to paint behind a transparent system bar. Defaults preserve existing hosts.
- Full validation: trainer 216 tests, coach_ui 23 tests, coach 471 tests; package analysis passes. Painting tests verify actual content pixels inside the status-bar area.

## trainer 0.2.4 — 2026-10-24（分支修复，待 SmartFit 真机确认后合 main）

- Add `DrillMedia.videoAvailable` and host-localized `DrillMediaView.unavailableLabel`. Intentional still-only actions do not create a player, resolve a resource, or display a download failure.
- Resolve inherited repository and theme before starting playback. Theme/path/availability/selection changes release the previous controller and frame before loading the replacement.
- Trainer 213/213 and coach 471/471 tests pass; trainer analysis reports no issues. Six new cases cover still-only actions, controller handoff, theme transitions, true failures, and bundled offline dark/light resources. Coach remains 0.5.0 and coach_ui 0.1.1.

## coach 0.5.0 / trainer 0.2.3 — 2026-10-24（待审，未发布）

- Add the pure Dart `CoachConversationController` with immutable observable conversation state, one retained agent, send/cancel/new-conversation/dispose, and display-only history restoration.
- Admit questions only after agent send completes. Centralize question expiry, duplicate-submission protection, text/single-choice/multi-choice answers, original-option ordering, and duplicate question text suppression. Plan-to-UI mapping remains host-owned.
- SmartFit integrates first. Hosts continue to own transport, endpoint, credentials, catalog/profile, storage, navigation and training startup. See the [controller integration guide](docs/coach-conversation-controller.md).
- Trainer 0.2.3 only aligns its coach constraint and Git tag to the proposed 0.5.0 release. UI runtime stays at 0.1.1; its README documents the new optional controller integration. No new tags have been published for this entry.

## coach_ui 0.1.1 / coach 0.4.2 / trainer 0.2.2 — 2026-10-24（已批准合入并发布 tag）

- Fix expanded routine dose wrapping at narrow widths and large text sizes without shrinking or truncating the dose. Shared row measurement drives row layout, cumulative media slots, flyer destinations and text collision bands during expansion and collapse.
- Keep all package manifests ASCII. This prevents Windows system decoding of Git metadata from swallowing the version after a non-ASCII description. Coach/trainer runtime code is unchanged; trainer now pins `ugk_coach-v0.4.2` so it does not transitively load the old non-ASCII manifest.
- Published tags: `ugk_coach_ui-v0.1.1`, `ugk_coach-v0.4.2`, `ugk_trainer-v0.2.2`, all fixed at `3302d6235a39e2c2b4b51fa196cc32b37c31b54c`. The exact 320px/2x/light-and-dark/expanded/long-Chinese-dose regression exists and passed before publication. SmartFit source `9d2ff7d` was merged only after a fresh GitHub cache passed native Pub strict-lock validation with the reviewed Flutter 3.44.7 toolchain. Old tags are unchanged; later status-only documentation does not move these tags.

## ugk_coach_ui 0.1.0 / ugk_trainer 0.2.1 — 2026-10-24（已批准合入并发布 tag）

- Extract the established SmartFit conversation list, message bubbles, clarification UI and animated routine card into a Flutter-only presentation package. Hosts inject theme, typography, copy, trusted media and callbacks; transport, credentials, gate admission, storage and navigation remain host-owned. See the [integration API](packages/ugk_coach_ui/README.md).
- Trainer pins the coach release tag instead of a relative package path, so hosts can pin the coach and trainer tags together. No trainer runtime or coach changes; coach remains 0.4.1.
- Approved and pushed: `ugk_coach_ui-v0.1.0` and `ugk_trainer-v0.2.1` both point to `f0ea0647586913b205fc6dbb75fc9f97cedc55ce`. SmartFit verified the unchanged lockfile from GitHub using a fresh Git cache before merging its accepted source `7f3458d` into main. Subsequent status documentation does not move these tags.

## 0.4.1 / ugk_trainer 0.2.0 — 2026-10-23（已合入并推送 main）

- 2026-10-24 文档收束：验收源码 `64a54874307449c8685577f8eeb913296b207a7c` 已合入；批准状态文档 `8b60032c2f43fd8e91f8802c8f054a8ecb7cc110` 已核对远端一致。版本保持 0.4.1 / 0.2.0，当前快照与后续安排见[台账](docs/project-ledger.md)。FlareLab 接入后做真机验收，SmartFit/HipLab 暂不升级。

- `PlanItem.segments` / `PlanSegment` 扩展 TrainingPlan v1：按段保存剂量、素材动作 ID、节奏；旧无分段计划编码不变，新分段严格校验，防止漏段后错误记为完成。
- trainer 修复唯一组 × 必需侧 × 分段统计及浮点结束边界，提供公开缺省自动节奏、休息延长、计时段提前完成、声音开关；详见[接入说明](docs/trainer-020-integration.md)。
- 根包只新增计划模型支持；本轮没有改 Agent 工具/提示词。SmartFit 接入回归中的既有 `askUser` 穷举编译障碍按下方 0.4.0 升级提示处理。

## 0.4.0 — 2026-10-23

- **源码兼容性提示（破坏性变更）**：新增 `AgentEventKind.askUser` 会使宿主对 `AgentEventKind` 的旧穷举 `switch` 编译失败。升级到 0.4.0 或更高版本时必须补 `askUser` 分支（或明确的兜底），并按 [ask_user 接口说明](docs/ask-user.md)接入问题气泡。仅升级依赖不保证旧穷举代码可编译。

- Agent 新增终止工具 `ask_user`：一次只问一个问题，支持 text、choice 的单选/多选，choice 为 2–6 个短选项、每项不超过 12 个 Unicode 码点。`AskUserQuestion` 为通过校验的不可变结果；`AgentEventKind.askUser` 和 `CoachTurnResult.question` 向 App 交付同一问题。回答通过同一 Agent 的下一次 `send()` 以文字进入会话，SDK 不在工具循环内等待。
- 提问与 `show_plan` / `show_actions` 互斥，一次回复只允许单个 `ask_user`；混合工具整批在执行前拒绝，避免先读取文件或写记忆。参数错误沿用工具反馈和重交上限；取消/reset 及异步记账期间作废的轮次不提交问题历史或计数。
- SDK 记录本次任务已交付的问题数，跨消息保留；最多 3 次，第四次调用拒绝并要求用已有回答和合理默认值交付方案。`questionsAsked` 供宿主查看；成功交付计划/动作卡（包括有效的回落计划）或 `reset()` 后清零，普通文字回复不清零。
- 排课技能改为只补会改变方案的缺口，一次一件事、choice 优先、不重问已知条件；信息足够（如“在家 20 分钟练核心”）、到上限或用户说“直接出”时直接排课，使用默认值时一句话说明。询问轮只发问题、不读动作库、不先长篇编排；稳定事实在用户回答后、交付前再按记忆规则保存。
- App 接口、气泡去重及回答示例见 [ask_user 接入说明](docs/ask-user.md)；真实多轮评测和离线验证见 [0.4.0 评测记录](docs/coach-040-ask-user-eval-2026-10-23.md)。`CoachSession` 降级入口及 `ugk_trainer` 0.1.7 行为保留。

## ugk_trainer 0.1.7 — 2026-10-23

- 归档 [PR #6](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/6) 的沉浸式舞台与玻璃控件 UI，含自主计次目标持续展示、系统大字号适配、Tab / Enter / Space 操作及焦点环。合入 main 的提交为 `eb29c749a52c1b226841726a3fba8e9f62e9e6be`，复审 head 为 `b84881f58c035b1fce2ff929cdb207e465821c92`。
- 训练包版本从 0.1.6 归档为 0.1.7；根包 `ugk_coach` 保持 0.3.3。既有媒体缓存、内测预览门禁和训练引擎行为保留；本次收束只调整训练包版本与文档。
- 复审 source 的 170 项 Flutter 测试、377 项根包 Dart 测试通过，`flutter analyze --no-pub` 为 0 问题；合并树与复审树一致。真机帧率及宿主完整训练尚未验收。完整版本细节与证据适用范围见[训练包 CHANGELOG](packages/ugk_trainer/CHANGELOG.md)及[维护台账](docs/project-ledger.md)。

## 0.3.3 — 2026-10-21

- 按 `profile.scope` 生成一动作一行的紧凑索引并内联到 Agent system，保留 id、中文名、部位、器械、难度、注意/禁忌，以及直接排课所需的场所、体位、默认剂量与 perSide。原维度索引和完整详情仍可按需读取。
- 三条内置训练技能快路径从同一份模板内联：计划筛选后直接 `show_plan`、动作展示直接 `show_actions`、要领问答只补所需详情。普通排课初始工具列表不提供 `check_plan`，提交被门禁打回后才开放；明确要求检查/自检或配置 App 专属技能时初始仍可使用。`AgentTools.build(includeCheckPlan:)` 默认 true，保留直接调用兼容性；最终门禁、真实 id 限制、红旗和记忆持久化确认照常执行。
- 明确点名的要领问句可自动预载本 App 匹配详情：精确名称优先、泛称最多三项；未知/过度歧义/计划/展示请求保留按需 read，下一轮重新选择，不遗留预载。数据字段没有指令权，匹配的 App 专属技能优先于通用快路径。
- `badResponse` 新增安全诊断，区分非 JSON、SSE、无 choices、结构异常、空正文、仅推理、HTTP 200 error 信封，保留已报告用量、失败 finish 标签、长度和 SHA-256，不保存正文/推理。接受与重试规则不变；旧臀桥四次错误因缺失原始响应，无法倒推出具体网关根因。
- 沿用 0.3.2 的 maxSteps、超时、预算和重试默认值。带 tools 的跨轮 reasoning 按 DeepSeek 当前官方协议保留，不以删字段换速度。
- SDK `dart test` 377 项通过，`dart analyze` 0 问题。SmartFit 最终同六条真实冒烟全部通过正确性与性能目标：4 条计划均 1 步、28.616–36.306 秒、9,592–10,634 token；要领问答 1 步、25.397 秒。合计 8 步/8 请求、180.430 秒、74,130 token，无回落、编造 id 为 0，记忆隔离通过。开哥批准后，main 已快进包含验收提交 `a931a04d6362ce8efba262556b34df3b485cc51d`，批准状态文档不改变已验源码。见[逐步基线](docs/coach-033-baseline-analysis-2026-10-21.md)、[完整前后对比](docs/coach-033-speed-2026-10-21.md)和项目维护台账。此前余额不足 403 与性能未达标候选保留原状态，未作为最终验收结果。

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
