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
• params：每项都是 {value, source: user|host|preselect|default|derived, quote?, turn}。derived 仅限 minutes，并记录 direction 和完整 basedOn 原来源。包含的项：scene（枚举由当前 profile 与目录实际支持的场景生成；outdoor 等目录和宿主支持后启用）、goal（练什么，用 body.* / purpose.* 编码的数组）、equipment（equip.* 编码的数组，空数组表示徒手）、minutes（整数）、level（1–3）、limits（伤痛限制编码的数组，空数组表示无）。host 只由代码从 CoachContext 写入，模型不得指定。
• seenActionIds：同一计划从首次生成到后续修改期间 search_actions 返回过的动作 id 集合，包含从推荐复用的部分；随 planState 保存恢复，新开无关任务时清空。
• picks：动作节点选中的动作 id。
• plans：plan_id → [{version, plan, estimateSec, fitLog, check: null|{ok, errors}}]
测试：序列化往返无损；恢复后的状态与保存前完全一致。

======== 第 2 步：set_params（记账，并拦住编造的条件） ========
新增工具 set_params。schema 如下：
{ "fields": { "scene"|"goal"|"equipment"|"minutes"|"level"|"limits": { "value": ..., "source": "user"|"preselect"|"default"|"derived", "quote": "用户原话片段，可选", "direction": "shorter|longer，仅 derived minutes" } } }
所有枚举值都写进 schema 的 enum。
scene enum 随当前 profile 与目录支持生成，现有计划卡场景校验保持不变。用户在户外时，不能擅自记成 home 或 gym：先说明暂时没有专门的户外动作，调用 ask_user 提供可选场景；用户选定后以 source=user 和该次回答的 quote 记账。用户坚持只要户外时，说明暂时无法提供并结束任务。
代码校验（任何一条不过，整次调用就失败，并按第 10 步的格式报错）：
1. source=user 时必须带 quote。把 quote 和 userTurns 里的每条消息都去掉空白和标点、转成小写后，quote 必须是其中某条消息的子串。quote 长度 ≤30 字。这是在核对来源，不是在判断意图。
2. 器械只减不加：如果新的 equipment 比当前多出了器械，那么 source 必须是 user，且 quote 必须来自上次设置之后的新用户消息。
3. source=default 的 equipment 只能是空数组（徒手）。source=preselect 只能使用 user_memory 里保存的习惯值。
4. 如果一项的旧值是 user 或 host，就不能用 default 或 preselect 去覆盖它。
5. host 优先级等同 user，参数节点视为已确认，提示词不得再问。用户在对话里用带 quote 的 source=user 可以覆盖 host 的时长等条件；器械仍只减不加，新增加的器械必须来自新的用户原话。
6. 安全类只能收紧，不能放宽：host 给的 limits 和现有 safety avoid，模型与用户只能增加，不能删除；需要放宽时只能由宿主重新传入。创建会话或宿主在会话中更新 CoachContext 时，代码将其中场景、器械、时长、水平及伤痛限制写入账本；变化触发第 3 步的参数更新流程。公开接口不变，planState 保存及恢复 host 来源。
7. 用户仅要求相对调整时，模型可对 minutes 使用 derived，并提供最新用户消息中的 quote 和 direction=shorter|longer；代码不解析原话含义。新值必须符合方向、profile.planRules.derivedStep（默认变化 20%–50%）及 profile 时长范围，并为 5 分钟的整数倍。报错给出可选范围。账本记录 derived 及完整 basedOn 旧值与来源；具体数字由用户明确给出时仍使用 user。
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
• 参数更新：如果参数节点已经 done，之后 set_params 或宿主更新 CoachContext 改变参数，重写参数 stamp 并标为 updated。只改变时长时保留 picks 和已完成 actions，从 planning 重新开始；场景、器械、伤痛、目标或水平变化时，重置 actions 及后续节点并移除不合规 picks，从 actions 重新开始。每次状态变化发节点事件。derived 时长的 stamp 说明相对要求和原时长，不标为用户直接说出的数字。
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
• schema：{ "plan_id"?: string, "operation"?: "edit"|"replace_all", "title": string, "blocks": [ { "kind": "warmup"|"main"|"cooldown", "rounds"?: int, "items": [ { "id": string, "sets"?: int, "reps"?: int, "seconds"?: int } ] } ] }。首次计划不得传 operation；修改已交付计划必须指定 operation 并沿用同一 plan_id。check_plan 失败后同一轮返工不算新修改。
• 用户要求整体换一套时模型使用 replace_all，局部调整使用 edit。replace_all 仅比较上次 show_plan 实际交付版本的 main 动作 ID：新 main 中不在旧 main 的比例至少为 profile.planRules.replaceAllMinDiff（默认 0.5），热身和收尾不计。失败仍保存版本，返回 replace_too_similar、比例和合规候选；候选不足建议先搜索。edit 不限制差异比例。实际交付版本随 state 和 planState 恢复。
• 旧卡片 goal 由各 profile 的有序 legacyGoalMap 从账本 params.goal 和计划结构确定，模型不能传入或覆盖。依次匹配：拉伸/放松 purpose→relax；灵活性/活动度 purpose→mobility；热身 purpose 且只有 warmup 块→warmup；收尾 purpose 且只有 cooldown 块→cooldown；body 目标仅核心→core；body 跨上肢、下肢、核心至少两个大区或含全身编码→fullbody；力量 purpose 或其余单一部位 body→strength；未命中→fullbody。编码采用目录实际值，各 profile 可按业务语义调整顺序；具体映射由配置提供，代码不写死。返回结果包含 legacyGoal；完整目标和 focus 核对仍以账本编码为准。
• 草稿动作只需同时满足：已在 seenActionIds 中，且在 draft_plan 时仍符合当前场景、器械、伤痛和 profile 范围。未搜索或不合规的拒绝，并建议先用 search_actions。草稿使用的新动作由代码加入 picks，重写 actions stamp、保持该节点 done，并发一次节点更新事件。首次 check(actions) 的最少数量和合规门禁不变。
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
• focus：将 params.goal 分为 bodyGoals（body.*）和 purposeGoals（purpose.*）。有 bodyGoals 时，main 块至少有 planRules.focusRatio（默认 0.5）的动作命中任一 bodyGoals；同时有 purposeGoals 时，另行计算至少 focusRatio 的动作命中任一 purposeGoals。只有 purposeGoals 时，按 purposeGoals 计算。命中以目录标签及目录层级／profile.bodyGroups 展开的编码为准，不看名称；分别计算、分别报错，expected 写明目标组及比例（如“main ≥ 50% 含 purpose.stretch”），actual 写实际命中数（如“2/6”），candidates 列可替换的合规动作。goal 为空时 plan 参数节点不能完成。用户给出哪类目标就按哪类核对，不为凑规则追问，也不跳过核对。
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
测试（2026-10-28 预算评审修订）：新会话及恢复首包均 ≤12,288 B，取消 2KB 余量要求；恢复首包软目标 ≤11,264 B，未达到需报告但不算失败。使用 R3 的十动作计划（goal 仅 body.core）和 15 动作带分段合法计划，先以实际 check_plan 验证合法。
• output 完成后“当前状态”只发参数 stamp、plan_id/版本/标题/估时、计划动作名；来源明细和完整计划仍无损保存在 state。任务进行中发完整状态。
• 工具及参数 description 保持 520c3d5 的语义和正文，不靠缩短说明凑预算。set_params.goal 只列 body/purpose、equipment 只列 equip、limits 只列伤痛，search_actions.tags 列全部标签。逐工具 schema 与逐 enum 字节数、重复次数纳入诊断。移除 ls，read 留给问答；系统提示中重复工具说明保留在 description，安全和范围不删。
• search_actions/get_action 原始结果只在下一次模型请求完整可见，再后续请求按批次压成含 id/名称或已查看 id 的归档行，保留 tool_call_id。节点完成归档规则仍保留。重复搜索行仅回 id 并说明之前返回过多少项，硬过滤仍每次执行。
• R3 正常重放 4–6 次调用、2–3 次带 tags 搜索、不调用 get_action，是主验收；另保留 15 次搜索+10 次单独详情的压力重放。两者每次实际序列化请求均 ≤40,960 B。
• focus 和搜索按目录部位层级展开父编码；目录无层级时用 profile.bodyGroups 配置，不在代码写死。goal=body.core 可命中腹直肌、腹斜肌、竖脊肌等配置子编码，账本不要求模型展开。

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
• thinking 开启时，runner 逐次记录实际请求回传的 reasoning_content UTF-8 字节数（不是响应推理字符数）。
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


## 2026-10-28 第11步评审补充（已批准）

- 技能正文仅保留一份：按实际可见历史中的read调用path和SDK成功完整返回元数据判断，不解析模型文字。start_task对已read技能返回“[已在前文 read 中]”；start_task已提供全文后的read返回“[已在 start_task 结果中]”。同批按序生效，问答按需read保留。
- 成功start_task后，之前与该任务无关的技能read归档一行、保留tool_call_id；归档不可因后续任务切换复活原文。仍在上下文的start_task全文可以复用。已结束任务的旧工具历史被移除后，不发指向已移除正文的引用。
- 任务需要的正文即使来自先前read，也按原技能保留规则保留到任务结束，不得被技术压缩变成悬空引用。引用/完整返回的内部元数据不进模型协议及宿主保存数据。
- reasoning按DeepSeek现行官方Thinking Mode的tools分支执行：所有仍发送的assistant历史均保留原reasoning_content，包括用户新消息之后及未实际调用工具的消息。该规则与“新用户消息后清空”的预期不同；按开哥授权以文档为准，原文和链接见补充报告。当前用户轮的推理不删；既有记忆关闭脱敏优先保留。
- runner增加--thinking on|off，固定Worker/model/device不变；开关各自新会话跑原六例，每组一次。只有开哥通知Worker已修好后才执行真实对照，目前只做dry及离线测试。
- Task列以真实SDK任务事件/请求时活动任务分类，取消回滚不能改成qa。对照记录调用、耗时、最大请求、token、计划时长偏差/器械合规及待人工审阅的重复追问/参数stamp语义，不凭缺失交付判通过。

## 2026-10-28 真实评测后六项整改（本节优先于旧条款）

1. 三个 profile 按场景提供 ambientEquipment：home/gym 为 mat、wall、chair，office 为 chair、wall。用户明确指定未知场景只用 wall，单列 ambientEquipmentUnknown=[equip.wall]（给出的三个场景列表数学交集也含 chair，本实现遵循明确指定的 wall）。有效器械为账本 equipment 加环境物再减 equipment_exclude。徒手代表不需额外携带器械。equipment_exclude 仅准 user 来源及本轮新原话，只累计排除、不增加可用器械；保存恢复保留，变化重置动作依赖。搜索、草稿、核对、交付及回落计划共用同一规则。打卡展示当前可用环境物。
2. 进行中的当前状态增加 candidates=[id,本地化名称,主部位编码]，仅含本任务已搜索、当前仍合规的动作，按首次出现顺序、最多40条。参数变化时重新过滤。动作归档保留ID/名称或明确指向实际非空candidates；结束任务仍使用精简状态。保持新会话/恢复首包≤12,288 B及正常/压力序列每包≤40,960 B，不缩工具说明或删除推理来满足预算。
3. 搜索少于3条且hiddenEquipmentCount≥5时提示缺失器械数量及前两种器械，并建议必要时ask_user；同任务连续两次无新动作时提示从现有candidates选择并check(actions)，不阻断。计数保存恢复，新任务/复用转计划时清零。
4. 尚无交付计划时，draft_plan忽略合法operation并回执note“首份计划，已忽略 operation”；修改已交付计划的operation规则继续保留。已完成推荐且参数未变，start_task(plan)省略reuse时默认复用；显式false重启。参数变化的节点重置仍阻止复用，不检查用户文字。
5. 回复语言使用宿主CoachContext.language（locale），系统明确“用 {locale} 语言回复用户”；R6评测传en。节点部位/器械使用目录本地化名称，缺翻译使用可读名称而非编码。中文ask_user长度限制不变；英文按单词计，label≤6词、choice选项≤12词、form选项≤24词。
6. runner把updated视为已完成节点，仍核对固定顺序和非空stamp；器械评测计入环境物与排除项。逐例记录模型发起search_actions次数（含同批较早失败后被跳过的请求，与实际工具回执另行核对）。真实链路为https://ai.uuugk.win/v1、deepseek-flash、Bearer key（UGK_API_KEY优先，本地API Key行兜底），只接受完全相同的响应标签；旧Worker/model/device评测条款作废，SDK App默认配置不改。

单测落点：ambient_equipment_test、action_search_candidates_test、context_*_replay/restore_budget_test、task_defaults_test、plan_operation_test、locale_tool_labels_test、eval_node_completion_test、eval_locale_wire_budget_test。JSON Schema预算压缩只去掉同类型primitive enum已隐含的冗余type，不改枚举允许值、说明或校验边界；enum等字面量不递归修改。

## 2026-10-28 ca72bc3 评测后自动推进整改（本节优先于旧条款）

1. 固定节点与门禁保留，改为代码自动打卡：start_task 完成 understand；set_params 在必填条件齐全时完成 parameters，补原有 equipment/level/limits 默认值并返回 stamp。缺条件的合法 set_params 仍可成功，但不伪造完成。show_actions 校验 ids 作为 picks 并完成 actions/output；draft_plan 用同一来源和安全门禁选择动作，成功后完成 actions/planning，在同一回执运行原 check_plan，通过才完成 review，失败返回 errors/fix 并回 planning。真实节点事件不变，不增加模型调用。check/check_plan 可选，已完成节点重复调用返回当前状态，不重复发事件；核对仍不放宽。
2. 标准路径：推荐 start_task → set_params → search_actions → show_actions；计划 start_task → set_params → search_actions → draft_plan → show_plan；可以顺序批量调用。连续空搜索的提示也改为直接 show_actions/draft_plan，不再要求单独 check。推荐转计划默认复用不变。
3. 搜索只接受已启动且未完成的 recommend/plan 任务；否则 fix 为“先调用 start_task，可以和搜索放在同一批”。为兼容已批准的同一计划续改和累计 seen 规则，已交付计划可显式 start_task(plan,reuse=true) 重开 planning/review/output，保留原 plan_id、参数、picks、seen 和交付比较基准；仅允许完整固定节点已完成且真实交付版本存在。reuse=false 仍创建新任务。此处仅解决步骤顺序冲突，不解释用户文字，不放宽来源或安全。
4. 剂量模式不符时，使用目录默认 reps/seconds，保留输入 sets，回执 notes 说明转换；之后仍走原配时算法。搜索的完整行、重复行均带 doseMode，candidates 格式更新为 [id,名称,主部位编码,reps|seconds]。
5. note 中文最多120码点，英文最多2句且45词。超长先取前两句，再按字/词截断并交付；回执 noteTruncated=true、note=“已截断”。空值、非字符串、卡片其他校验不变。英文动作名缺项只报告原目录事实，不自行翻译。
6. purpose/body/pose/level 各前缀内 OR，前缀间 AND；部位父子展开及其他硬过滤不变。scene 可用 derived，必须引用本轮用户原话，stamp 显示“办公室（推测）”/“Office (inferred)”。明确 user/host 可覆盖推测；推测不能覆盖明确地点，default/preselect 不能覆盖推测。原相对时长 derived/direction/basedOn 规则不变。模型判断地点语义，代码不做自然语言判断。
7. runner 与 comparison 共用账本+环境物-排除的器械判断，expectedEquipment=[] 也包含环境物。真实工具拒绝按 UsageRecord 实际失败批次记录（每批首个失败后余项跳过），包括最后一次不可见回执；skipped 和非工具拒绝不计。可见回执单独留证。当前轮只评测 thinking off 六例各一次，链路及 SDK App 默认配置不变。

单测落点：automatic_node_progress_test、output_note_completion_test、plan_builder_dose_mode_test、search_tag_groups_test、derived_scene_params_test、eval_quality_test；原安全、宿主条件、保存恢复、换一套及预算回归继续执行。系统重复工具用法移到技能/工具说明，未删安全底线或历史 reasoning。
