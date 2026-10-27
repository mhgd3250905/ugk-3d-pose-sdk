# 教练 Agent v2 实施规格

本文件依据开哥批准的《教练 Agent v2 实施手册》第 0 节与第 1–11 步编写；按该手册执行，手册替代 v1 的冲突要求。

## 0. 总原则

把模型当成“教练”，代码当成“助理”。
• 教练（模型）只做四件事：听懂用户、决定要不要追问、挑动作和定计划结构、写 1–2 句说明。
• 助理（代码）负责其余所有事：记住用户条件并标来源、按条件筛动作、填剂量、算时长并配平、判定每一步是否完成、生成打卡文字、压缩上下文。
• 模型可能犯的错，要在它出错的那一个工具调用上当场拦下，不能拖到 show_* 才打回。
• 代码不解析模型写的自然语言。不用正则去抓数字或器械名，也不做关键词意图判断。代码只看工具参数里的结构化字段。
• 保持不变：pi 式循环；三类任务和固定节点顺序；由模型判断任务类型；不限追问轮数；新会话首包 ≤12KB 且不含动作目录；计划以卡片交付；“排成计划”复用前三个节点；42bc4eb、005dd9d、cc03d4a 的行为和测试；安全底线；对宿主的公开接口和事件流保持兼容，只允许新增字段。

======== 第 1 步：会话状态（助理的账本） ========
新建 lib/src/agent/session_state.dart，定义 CoachSessionState，可以 toJson/fromJson，并并入现有 CoachPlanState 的保存和恢复（005dd9d 那套）。字段如下：
• userTurns：本会话每条用户消息的原文和序号。
• task：{type: qa|recommend|plan, nodes:[{id, status: pending|current|done|updated, stamp, doneAtTurn}], reused}
• params：每项都是 {value, source: user|host|preselect|default, quote?, turn}。包含的项：scene（枚举：home/office/gym/outdoor）、goal（练什么，用 body.* / purpose.* 编码的数组）、equipment（equip.* 编码的数组，空数组表示徒手）、minutes（整数）、level（1–3）、limits（伤痛限制编码的数组，空数组表示无）。host 只由代码从 CoachContext 写入，模型不得指定。
• seenActionIds：本任务里 search_actions 返回过的动作 id 集合。
• picks：动作节点选中的动作 id。
• plans：plan_id → [{version, plan, estimateSec, fitLog, check: null|{ok, errors}}]
测试：序列化往返无损；恢复后的状态与保存前完全一致。

======== 第 2 步：set_params（记账，并拦住编造的条件） ========
新增工具 set_params。schema 如下：
{ "fields": { "scene"|"goal"|"equipment"|"minutes"|"level"|"limits": { "value": ..., "source": "user"|"preselect"|"default", "quote": "用户原话片段，可选" } } }
所有枚举值都写进 schema 的 enum。
代码校验（任何一条不过，整次调用就失败，并按第 10 步的格式报错）：
1. source=user 时必须带 quote。把 quote 和 userTurns 里的每条消息都去掉空白和标点、转成小写后，quote 必须是其中某条消息的子串。quote 长度 ≤30 字。这是在核对来源，不是在判断意图。
2. 器械只减不加：如果新的 equipment 比当前多出了器械，那么 source 必须是 user，且 quote 必须来自上次设置之后的新用户消息。
3. source=default 的 equipment 只能是空数组（徒手）。source=preselect 只能使用 user_memory 里保存的习惯值。
4. 如果一项的旧值是 user 或 host，就不能用 default 或 preselect 去覆盖它。
5. host 优先级等同 user，参数节点视为已确认，提示词不得再问。用户在对话里用带 quote 的 source=user 可以覆盖 host 的时长等条件；器械仍只减不加，新增加的器械必须来自新的用户原话。
6. 安全类只能收紧，不能放宽：host 给的 limits 和现有 safety avoid，模型与用户只能增加，不能删除；需要放宽时只能由宿主重新传入。创建会话或宿主在会话中更新 CoachContext 时，代码将其中场景、器械、时长、水平及伤痛限制写入账本；变化触发第 3 步的参数更新流程。公开接口不变，planState 保存及恢复 host 来源。
成功时返回当前完整的 params。如果参数节点已经 done，就按第 3 步的“参数更新”规则处理。
profile 改动：删掉 profiles/*.json 和提示词里类似“居家默认有垫子/椅子/墙/砖”的器械默认。器械的默认值一律是徒手。
测试：用 R2 的数据。用户只说了“有瑜伽垫”，之后没有新消息时，模型想把墙和砖加进来，必须被拒绝。quote 不在原话里时被拒绝。用 default 覆盖 user 时被拒绝。
补充测试：host 提供时长不再追问；模型传 source=host 被拒绝；default 覆盖 host 被拒绝；用户原话可以覆盖 host 时长；模型和用户不能去掉 host 伤痛限制；中途更新 CoachContext 触发节点重置；保存恢复无损。

======== 第 3 步：节点门禁与打卡（每一步由代码把关） ========
改造 lib/src/agent/agent_task.dart，并新建 lib/src/agent/node_gates.dart。
• start_task(type, reuse?)：由代码生成节点。recommend 的节点是 understand → parameters → actions → output；plan 的节点是 understand → parameters → actions → planning → review → output。reuse=true 只在上一个任务是 recommend 且已经 show_actions 时允许，前三个节点和 picks 沿用。
• check(node, picks?)：模型只是请求完成某个节点。代码按下表判定。通过时由代码生成 stamp（打卡文字），模型不提供打卡文字：
  understand：task 已创建。stamp 例：“要一份 20 分钟的计划”，或“要推荐动作”。
  parameters：plan 类必须有 scene、goal、minutes；recommend 类必须有 goal。各项经 set_params 或宿主 CoachContext 写入。equipment、level、limits 如果没设置，代码在打卡时自动补 default。stamp 例：“居家（你说的）· 徒手（你说的）· 20 分钟（你说的）· 初学（你说的）· 无伤痛（默认）”。这里 user 写成“你说的”，host 写成“App 设置”，preselect 写成“上次习惯”，default 写成“默认”。英文会话用英文模板，host 显示“app setting”。
  actions：picks 至少 3 个（阈值放在 profile 里）；每个 id 都在 seenActionIds 里；每个都满足 params 的器械、场景和伤痛限制。stamp 例：“选了 10 个核心动作，都不用器材”。
  planning：已有当前版本的 plan（来自 draft_plan）。stamp 例：“热身 3 · 主体 5×3 轮 · 收尾 2，约 20 分钟”。
  review：当前版本的 check_plan 已通过。stamp 例：“安全、时长、器材、均衡、重点都通过”。
  output：由 show_* 成功时自动打卡，不允许对它调用 check。
• 顺序门禁：只能 check 当前节点。如果 check 的节点不对，报错里要写明当前节点是哪个。
• 参数更新：如果参数节点已经 done，之后 set_params 或宿主更新 CoachContext 改变了参数，代码会：重写参数节点的 stamp 并把状态设为 updated；把已完成的 actions、planning、review 重置为 pending；从 picks 里去掉不再符合新参数的动作；把当前节点设为 actions。节点不增、不删、不调序。每次状态变化都发出节点事件。
• ask_user 在任何节点都可以用。用户回答后，从当前节点继续。
测试：用 R3 的数据。参数节点已完成后，用户回答“初学”，模型 set_params(level=1)，此时参数节点的 stamp 应变成“初学（你说的）”，后续节点应被重置。另外测：跳节点被拒绝；picks 里有没搜到过的 id 时被拒绝；picks 里有需要垫子的动作、而用户是徒手时被拒绝。

======== 第 4 步：search_actions / get_action（助理先筛好再递给教练） ========
改造 lib/src/agent/action_search.dart。
• search_actions(tags[], keywords?, limit≤20)：tags 的全部合法值写进 schema 的 enum（从目录生成）。这样类似 purpose.warmup 这种不存在的标签就传不进来。如果业务上需要“热身”，就在目录里加上对应的编码。
• 代码自动用 params 做硬过滤：动作所需器械必须是 params.equipment 的子集；场景要匹配；不能与 limits 禁忌冲突；必须在 profile scope 内。如果还没设置器械，就按徒手过滤，并在结果里写明 filter.equipment=徒手(默认)。
• 每行返回：id、名称、主要部位编码、器械编码、姿态/场景、剂量模式（reps|seconds）、默认剂量、剂量范围、单组估时（秒）、一句话简介。一行控制在约 200 字节以内。返回的 id 都加入 seenActionIds。
• 结果末尾加一行：“已按 居家/徒手/无伤痛 过滤，另有 N 个需要器材的动作未显示”。这样模型知道可以问用户有没有器材，但拿不到这些动作。
• get_action(ids[]，最多 10 个)：批量返回要领和禁忌。提示词里写明“大多数情况不需要调用”。
测试：传入非法标签会被 schema 拒绝；徒手时不会返回任何需要器械的动作；单行大小在上限内。

======== 第 5 步：draft_plan（教练定结构，助理填数、配时长） ========
新建 lib/src/agent/plan_builder.dart。估时复用 plan_validator 里现有的估时函数，保证口径一致。
• schema：{ "plan_id"?: string, "title": string, "blocks": [ { "kind": "warmup"|"main"|"cooldown", "rounds"?: int, "items": [ { "id": string, "sets"?: int, "reps"?: int, "seconds"?: int } ] } ] }。不传 plan_id 就新建计划，传了就生成该计划的新版本。
• 各项只能从 picks 里取。只有当时长不够时，才允许使用 seenActionIds 里符合 params 的其他动作。
• 缺省的剂量用目录默认值补齐。模型给的剂量如果超出目录范围，就夹到范围内，并记入 fitLog。
• 自动配时长：目标 T = params.minutes × 60。如果估时不在 T ±10% 以内，就按下面的顺序调整，每调一次重算一次，进入 ±5% 就停：
  1) main 块的 rounds，在 1–4 之间调；
  2) main 块各项的 sets，在目录范围内调；
  3) main 块各项的 reps 或 seconds，在目录范围内调；
  4) warmup 和 cooldown 的秒数，在目录范围内调。
  如果全部调到极限仍然不在 ±10% 以内：仍然保存这一版，但返回 ok=false、code=duration_unfit，并写明差多少秒、建议加或减几个动作（用差值除以平均单项耗时，向上取整），再列出可以加的候选 id。
• 返回：plan_id、version、estimateMinutes（保留一位小数）、结构摘要、fitLog（例如“主体由 2 轮加到 3 轮”）。不要把完整计划 JSON 原样回传。
测试：用 R3 的结构，模型只给 rounds=2 时，代码应自动配到 20 分钟 ±10%。另测：只给 3 个动作却要 30 分钟时，返回 duration_unfit 和加动作建议；剂量超出范围时被夹住。

======== 第 6 步：check_plan(plan_id)（全部用能直接算的规则） ========
改造 lib/src/plan/plan_validator.dart。规则的阈值放在 profiles/*.json 新增的 planRules 里，代码里不写死。每条规则都要返回通过或失败，以及具体数值：
• safety：任何一项动作都不能触发 limits 对应的禁忌；保留现有安全底线。
• equipment：所有动作所需器械的并集必须是 params.equipment 的子集。这里直接读 params，不再让模型传 equipment 参数。
• duration：估时在 T ±10% 以内。
• structure：minutes 达到 planRules.warmupFromMinutes 时必须有 warmup 块，达到 cooldownFromMinutes 时必须有 cooldown 块。如果是纯拉伸目标，可以在 planRules 里设置不要求热身。
• focus：将 params.goal 分为 bodyGoals（body.*）和 purposeGoals（purpose.*）。有 bodyGoals 时，main 块至少有 planRules.focusRatio（默认 0.5）的动作命中任一 bodyGoals；同时有 purposeGoals 时，另行计算至少 focusRatio 的动作命中任一 purposeGoals。只有 purposeGoals 时，按 purposeGoals 计算。命中以目录标签包含对应编码为准，不看名称；分别计算、分别报错，expected 写明目标组及比例（如“main ≥ 50% 含 purpose.stretch”），actual 写实际命中数（如“2/6”），candidates 列可替换的合规动作。goal 为空时 plan 参数节点不能完成。用户给出哪类目标就按哪类核对，不为凑规则追问，也不跳过核对。
• balance：同一主要部位连续不超过 planRules.maxSameMuscleInRow（默认 3）个；同一块里不能有重复动作；如果 planRules 配置了拮抗对（例如核心的前侧对后侧），就要求两侧都有。
• 结果记入该版本的 check 字段。成功时只返回一句汇总。失败时每条错误都按第 10 步的格式写，并给出可以替换的候选 id。
测试：每条规则至少有一个通过的用例和一个失败的用例。focus 的只有 purpose、只有 body、两者都有三种情况各有一个通过及一个失败用例。

======== 第 7 步：show_actions / show_plan（说明里不再写数字） ========
改造 lib/src/tools/tool_gate.dart 和 coach_agent.dart 里有关展示的部分。
• show_actions(ids[], note) 和 show_plan(plan_id, note)：note 写在工具参数里，就是卡片上方那 1–2 句说明。模型在这次调用里写的 content 正文不再作为说明使用。上一轮四个计划场景的“缺少说明”被拒，就是因为说明写在哪里不明确。
• 门禁只检查：除 output 外的节点都已 done；show_plan 的 plan_id 是最新版本且 check_plan 已通过；show_actions 的 ids 都在 picks 里；note 非空，句末标点（。！？.!?）不超过 2 个，长度不超过 120 字。
• 删除 narrative_minutes、narrative_equipment、plan_description 等所有对说明文字做解析的门禁，以及小数分钟的修补代码。卡片数据自己显示时长、动作数和器材。提示词里写明：note 里不要写时长、动作数和器材，只写思路。
• show_* 成功后，代码给 output 节点打卡并结束本轮。不再把卡片结果回传给模型、让它再说一遍。
• “换一套”等现有行为改为通过 state 实现，原有测试必须继续通过。
测试：节点未完成时 show_* 被拒绝：plan_id 指向旧版本时被拒绝；note 超过 2 句时被拒绝；说明里写“20.3 分钟”或英文单词 block 时不再被拒绝。

======== 第 8 步：一次回复里可以执行多个工具（减少来回） ========
改造 coach_agent.dart 的 _run。这个函数现在约 1300 行，请按工具拆成各自的 handler 文件，循环本身只保留“调用模型 → 执行工具 → 追加结果”。
• 模型一次回复里发出的多个 tool_calls，按顺序逐个执行，后一个能看到前一个改动过的 state。
• 如果其中一个失败，同一次回复里排在它后面的调用一律不执行，返回 {ok:false, code:"skipped_after_error", actual:"第 N 个调用失败"}。
• 提示词里给出推荐的合并方式：start_task + check(understand) + set_params + check(parameters) 可以放在同一次回复里；check(actions, picks) 可以和 draft_plan、check(planning)、check_plan、check(review)、show_plan 放在同一次回复里。节点仍然一个一个打卡，只是不用每次都等一轮模型。
• ask_user 必须是一次回复里的最后一个调用。
• UI 节点事件仍然是每打一次卡发一次。
测试：用假模型（fake_llm_client）在一次回复里发出 6 个调用，应该全部按顺序生效；第 3 个失败时，第 4–6 个被跳过。

======== 第 9 步：上下文压缩与恢复 ========
新建 lib/src/agent/context_compactor.dart。
• 每次请求都由三部分组成：系统提示（角色和底线、技能索引）；一条“当前状态”消息，由代码从 state 生成，内容为 task 及各节点 stamp、params 及来源、picks 的 id 和名称、当前 plan 的版本摘要；以及对话记录。
• 归档规则：一个节点 done 以后，属于该节点的 search_actions、get_action、draft_plan、check_plan 工具结果，在之后的请求里都替换成“[已归档，见当前状态]”，但保留 tool_call_id 的对应关系。已经被后来成功调用取代的失败结果，也压成一行。start_task 返回的技能正文一直保留到任务结束。
• 任务结束后，下一轮只保留用户和助手的可见正文，以及“当前状态”。
• 恢复会话：完整计划留在 state 里，请求里只放计划摘要和 plan_id。恢复会话的首包同样 ≤12KB。
• 去掉模型自己 ls/read 技能的开头两轮：start_task 的结果里直接返回该任务类型需要的技能正文（recommend 返回 ask + action-library，plan 返回 ask + action-library + plan-training）。问答类不调用 start_task，仍然按索引按需 read。新会话首包仍然不含技能正文。
测试：用 R3 的十动作计划和一个 15 个动作、带分段的合法计划（先用 check_plan 验证合法）。恢复首包 ≤12KB，且至少有 2KB 余量。按 R3 的调用序列重放时，每次请求 ≤40KB。

======== 第 10 步：统一报错格式与提示词 ========
• 所有工具失败都返回同一种格式：{"ok":false,"code":"...","field":"...","expected":"具体值","actual":"具体值","fix":"一句可以直接执行的建议","candidates"?:[...]}。禁止出现“见 message”“按期望改正”这类写法。加一条测试，扫描所有错误构造处，确保没有这些字样。
• prompts/agent_kernel.md：删掉旧的工具说明和所有长度限制。写清楚八件事：
  1) 先判断是问答、推荐还是计划；问答直接回答；
  2) 用户说过的条件用 set_params(source=user, quote=原话) 记下；没说过的不要编；
  3) 器材没说就按徒手；只有当徒手明显会让计划变差，而且搜索结果提示“有 N 个需要器材的动作未显示”时，才去问用户；
  4) 不要重复问“当前状态”里已经有的东西；
  5) 可以在同一次回复里按顺序发多个工具，并给出推荐的合并方式；
  6) 排计划时只定结构和动作，时长交给 draft_plan 去配；
  7) note 只写思路，不写数字和器材；
  8) 报错时按 fix 的建议改。
• skills/ask、action-library、plan-training：与上面保持一致，并删掉与之冲突的旧说法。均衡和热身的硬性规则以 planRules 为准，技能里只保留讲解。

======== 第 11 步：评测 ========
• runner 记录每次响应的模型标签。如果响应模型与配置的模型不一致（例如出现带 free 的标签），这一例标为作废，并在回报里写明。Worker 渠道由开哥固定，你不要改 Worker。
• 链路沿用上一轮：api.uuugk.win、deepseek-v4-flash-0731、UGK_APP_KEY 环境变量。六组案例和模拟回答都与上一轮相同，每组跑 1 次。
• 验收线：
  计划类单轮 ≤8 次模型调用，单轮耗时 ≤60 秒，单次请求 ≤40KB；
  推荐类单轮 ≤5 次调用，耗时 ≤25 秒；
  show_* 被拒绝 0 次；
  所有动作和计划所需器械都是用户确认的器械或徒手；
  不重复追问已知信息；
  参数节点的 stamp 与最终计划一致；
  计划时长在 ±10% 以内；
  问答类不走节点。
• 离线全量测试和严格静态分析都必须通过。还要保留并通过以下架构测试：首包 ≤12KB；首包无动作目录；代码里无关键词/正则意图判断；无追问轮数上限；计划必须以卡片交付。

## 与 v1 的差异

- v1 由模型写节点结果；v2 由结构化状态、节点门禁和代码生成的 stamp 负责打卡与参数更新。
- v1 由模型提供完整计划并调用 check_plan；v2 由模型选择动作与结构，draft_plan 填剂量、配平时长，check_plan 按 profile 的 planRules 检查版本。
- v1 按需加载技能；v2 首包只给技能索引，start_task 在任务开始后返回该类型所需技能正文，问答仍按需 read。
- v1 工具逐轮推进；v2 允许同一次模型回复中的工具按顺序执行、失败后跳过后续调用，并保留逐节点真实事件。
- v1 以说明数字和器材一致性门禁校验模型正文；v2 使用工具参数 note，卡片显示数据，删除对说明自然语言的数字及器材解析。
- v2 新增参数来源账本、动作硬过滤、上下文压缩、统一可操作错误和明确的逐轮性能／模型标签验收。
- pi 循环、模型判断任务类型、固定节点、无限业务追问、首包预算、计划卡和宿主兼容及既有保留行为继续保留；阶段二离线索引与阶段三等待 UI 仍在阶段一验收后进行。
