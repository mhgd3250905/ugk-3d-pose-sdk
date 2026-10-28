# 教练 Agent 门禁盘点（待开哥审阅）

基线：`31f0f18cc7b1982d79c39d64c124358bb42884ed`，`codex/coach-agent-todo`，2026-10-28。本文是现状盘点与建议，不是已实施方案。本轮只读取源码和已有评测记录、写本文；没有改代码、运行测试或模型，也没有提交、合并、推送或打 tag。

范围是CoachAgent及共享工具、计划校验、来源账本，并包括公开CoachSession/CoachAssistant兼容入口中仍会阻止交付的检查；另列配置故障和技术中止。Trainer媒体下载、播放器、渲染等不属于本次训练Agent门禁。模型仍负责理解目标、选动作和解释；代码负责可计算的执行数据、调度与缺省值。

## 结论与分类口径

R4 的反复返工来自规则与任务的冲突。当前 `plan_balance` 把热身、主体、放松的动作条目串接，跨块不清零，只看每个动作的**第一个** muscleGroups 编码；sets 和 rounds 不参与连续次数统计。因此拆块、减轮无法消除这项错误。对“保留刚推荐的四个肩部动作、只练肩”的要求，代码实际迫使模型删动作或塞入其他部位，不能把这种改变任务后的通过算作有正常解。最后交付删掉前平举，不证明前六次拒绝合理。

建议以“目标和已确认约束不被擅自改变”为可解性的前提：A 只拦真正违反底线的选择；B 由代码完成计算、状态推进和呈现修正，回执说明；C 结合目标给一次 warning，不拦交付。代码无法完成 B 时，应给结构化的不可行原因或必要澄清，不能反复要求模型猜一个可通过的数字/排列。

|类别|范围|拒绝或修正的边界|
|---|---|---|
|A 底线|安全/伤痛、器械/场景、目录/scope/seen、用户目标、来源真实性；以及解析、身份与状态完整性的必要防护|保留真正错误的拒绝。若当前目录下没有合法动作，则明确“当前条件不可满足”或询问是否调整条件，结束无解的重交循环。协议错误与训练建议错误分别计数。|
|B 确定性计算|剂量、时长、顺序、分组、缺省值、ID/版本/节点、卡片派生字段、幂等、呈现约束|自动完成或修正并在回执列出变化。只能修改代码拥有的派生值，不能借自动修正改写用户目标、已确认时长/器械、伤痛限制、引用或模型选的动作集合。|
|C 专业判断|热身/收尾的训练适用性、单部位连续/拮抗与均衡等编排建议|结合任务目标一次 warning；不要把目录粗标签或通用经验当作一票否决。明确伤痛禁忌仍归 A。|

“未观测”表示现有真实记录没有该项证据，**不表示所有历史为 0**。源码里相同条件的重复入口合为一行，列出重复位置；同一错误码混合多个性质的条件会拆行。已自动修正或仅 warning 的行为另列，不伪装成当前拒绝。

## 一、入口、工具协议、澄清与技能

以下位置均指基线代码。`invalid_arguments` 等通用码不能单凭码名分类，须看具体触发条件。

|检查 / 代码位置|保护什么|类别与建议|合法条件下是否一定有解|历史真实拒绝证据|
|---|---|---|---|---|
|未知工具 `unknown_tool`；[coach_agent.dart:1852](E:/AII-3D/3D-Pose-SDK/lib/src/agent/coach_agent.dart:1852)；旧接口 [tool_gate.dart:239](E:/AII-3D/3D-Pose-SDK/lib/src/tools/tool_gate.dart:239)|只执行已经提供的工具。|A：保留；回执列当前可用工具，禁用的记忆工具不要继续暴露。|工具列表存在时可纠正；工具未安装不是模型可解决。|未观测。|
|JSON 非对象/语法错误 `invalid_json / invalid_arguments`；[coach_agent.dart:1685](E:/AII-3D/3D-Pose-SDK/lib/src/agent/coach_agent.dart:1685)、[terminal_tool_handler.dart:86](E:/AII-3D/3D-Pose-SDK/lib/src/agent/terminal_tool_handler.dart:86)、[tool_gate.dart:255](E:/AII-3D/3D-Pose-SDK/lib/src/tools/tool_gate.dart:255)|避免对无法确定含义的数据执行操作。|A：不可无歧义恢复才拒绝；B：明确别名/额外包装等可规范化偏差统一修正。不要猜造内容。|协议本身可解；SDK 已给出互相冲突 schema 时无解。|S− R6 `invalid_json` 1；早期记录另见证据表。|
|工具 schema 的 required/type/enum/additionalProperties；[agent_prompt.dart:60](E:/AII-3D/3D-Pose-SDK/lib/src/agent/agent_prompt.dart:60)|限制各工具接收的数据形状和编码。|拆分：来源、目录、目标编码 A；剂量/轮数/卡片派生字段 B，应从模型入参中移出；无害多余字段 B 忽略并说明。|枚举与实际目录/profile不同步时会无解；不能把 schema 声明当作 runtime 已校验的证据。|D+ R6 `invalid_tags` 1；D− R6 `invalid_arguments` 2；其余按具体分支统计。|
|同批重复ID `duplicate_tool_call_id`；[coach_agent.dart:1597](E:/AII-3D/3D-Pose-SDK/lib/src/agent/coach_agent.dart:1597)|工具调用与回执一一对应，防止结果错配。|B：在内部建立唯一映射，保留上游原 ID 的诊断信息；无法保证配对则技术错误停止，不算训练选择错误。|修正 ID 由代码可解。|未观测。|
|`ask_not_last`；[terminal_tool_handler.dart:40](E:/AII-3D/3D-Pose-SDK/lib/src/agent/terminal_tool_handler.dart:40)|提问后暂停，不再执行同批其他动作。|B：调度器让 ask 在依赖工具完成后暂停；多个问题合并/延期要保留原意，不要求模型单独返工排序。|正常同批可由代码处理。|未观测。|
|ask JSON/对象、question 非空、mode 不合法；[ask_user.dart:163](E:/AII-3D/3D-Pose-SDK/lib/src/tools/ask_user.dart:163)、[ask_user.dart:188](E:/AII-3D/3D-Pose-SDK/lib/src/tools/ask_user.dart:188)|使问题可呈现且模式含义明确。|A：完全无法理解的问题拒绝一次；B：可确定的默认 mode、空白规范化和 UI 数据生成由代码做。|有效问题有解；缺失内容不能凭空编造。|`invalid_ask`：D+ R3/R6 各1，S+ R1 1；历史更早见附表，现有证据未逐条证明是哪一子条件。|
|ask 多余字段和跨模式字段、固定 skipLabel；[ask_user.dart:187](E:/AII-3D/3D-Pose-SDK/lib/src/tools/ask_user.dart:187)、[ask_user.dart:217](E:/AII-3D/3D-Pose-SDK/lib/src/tools/ask_user.dart:217)、[ask_user.dart:251](E:/AII-3D/3D-Pose-SDK/lib/src/tools/ask_user.dart:251)|避免 text/choice/form 的结构冲突。|B：去掉不生效字段、由代码设置按钮文案；有歧义保留原问题用 text 呈现。|正常问题可解。|归入上述 `invalid_ask`，不能把同一回执重复计到每个子条件。|
|choice 2–6项、非空、去重、每项中文12码点/英文12词、multiple布尔；[ask_user.dart:229](E:/AII-3D/3D-Pose-SDK/lib/src/tools/ask_user.dart:229)|控制选项控件可用性。|B：完整选项值和显示标签分离、去完全重复项/分页或转 text；不要截断真实值导致两个选项含义合并。|只有1个或超过6个合理选项时，当前 choice 门禁可能无解。|同上；无法从外层 `invalid_ask` 唯一归因时标未知。|
|form 1–3组、key仅scene/equipment/minutes且唯一、label长度、2–64项、非equipment不能多选；[ask_user.dart:255](E:/AII-3D/3D-Pose-SDK/lib/src/tools/ask_user.dart:255)、[ask_user.dart:278](E:/AII-3D/3D-Pose-SDK/lib/src/tools/ask_user.dart:278)|限制旧表单的 UI 形状。|B：由代码生成表单并保留原始选项；不应让模型为布局返工。真实不受支持的字段改 text 问题。|有效训练问题可能含goal/limits，当前 form key 不能表达。|同上；当前六组无该子条件确证。|
|本地 confirmation 构造/提交完整性：3组、预选包含、当前待答卡、选项/场景器械关联、分钟可解析；[ask_user.dart:109](E:/AII-3D/3D-Pose-SDK/lib/src/tools/ask_user.dart:109)、[training_confirmation.dart:15](E:/AII-3D/3D-Pose-SDK/lib/src/agent/training_confirmation.dart:15)、[coach_agent.dart:957](E:/AII-3D/3D-Pose-SDK/lib/src/agent/coach_agent.dart:957)|防止过期/伪造 App 回答被当作用户已确认条件。|A：当前卡身份和来源保留；B：label到编码映射及分钟解析由代码持有，中文文本解析不应成为英文用户的门槛。|旧卡只认固定中文场景/分钟标签，合法本地化输入可无法通过。|未观测；不是当前六组自动预注入的入口。|
|任务中 read/ls 动作目录 → `use_action_search`；[skill_tool_handler.dart:39](E:/AII-3D/3D-Pose-SDK/lib/src/agent/skill_tool_handler.dart:39)、[skill_tool_handler.dart:57](E:/AII-3D/3D-Pose-SDK/lib/src/agent/skill_tool_handler.dart:57)|防止绕开当前条件的动作检索与seen来源。|A：过滤与seen不能绕过；B：将已知目录路径路由到同一安全检索接口，避免仅因工具选错返工。|有动作不代表旧目录路径可读，存在纯流程拒绝。|D− R3 1，S+ R1 1。|
|技能文件/目录不存在 `not_found`；[skill_tool_handler.dart:80](E:/AII-3D/3D-Pose-SDK/lib/src/agent/skill_tool_handler.dart:80)、[skill_tool_handler.dart:123](E:/AII-3D/3D-Pose-SDK/lib/src/agent/skill_tool_handler.dart:123)|避免凭空读取资料。|A：未知路径拒绝；B：索引中失效路径由安装/打包校验承担，不应反复让模型寻找。|缺文件属于配置不可解。|未观测。|
|记忆参数 `invalid_memory`；[memory_tool_handler.dart:26](E:/AII-3D/3D-Pose-SDK/lib/src/agent/memory_tool_handler.dart:26)、[memory_tool_handler.dart:48](E:/AII-3D/3D-Pose-SDK/lib/src/agent/memory_tool_handler.dart:48)|避免错误类型/空内容造成记忆误写或误删。|A：保留真实用户授权及写入含义；B：类别默认、空白和已存在内容去重可由代码做。|有效kind/text可解；模型不知道记忆是否真实表达时不能靠猜。|六个有效标签run未观测。|
|记忆保存失败/取消/超时 `memory_save_failed / cancelled / timeout`；[memory_tool_handler.dart:3](E:/AII-3D/3D-Pose-SDK/lib/src/agent/memory_tool_handler.dart:3)、[memory_tool_handler.dart:66](E:/AII-3D/3D-Pose-SDK/lib/src/agent/memory_tool_handler.dart:66)、[coach_agent.dart:1791](E:/AII-3D/3D-Pose-SDK/lib/src/agent/coach_agent.dart:1791)|未成功保存不得向用户谎称记住。|A：成功事实真实性保留；B：存储重试/回滚归代码，失败回执不算模型选错。|I/O、取消或时间不足时模型无解。|早期阶段一 R5 有记忆错误/空转，详见附表；有效标签六run未见记忆拒绝。|
|空正文 `empty_reply`；[tool_gate.dart:205](E:/AII-3D/3D-Pose-SDK/lib/src/tools/tool_gate.dart:205)|不交付空白答复。|B：允许模型继续当前循环；若任务已有可交付卡，说明可由代码从数据生成，不能因缺一段说明重做计划。|技术空响应可能不是模型任务判断错误。|未观测可独立确认计数。|
|进行中 plan 只输出文字 → `missing_plan`；[coach_agent.dart:1483](E:/AII-3D/3D-Pose-SDK/lib/src/agent/coach_agent.dart:1483)|计划类必须有真实卡片，不能用文字冒充交付。|A：保留必须有卡；B：已具备合法草稿时由代码完成交付，不再为show_plan打一次模型调用；缺数据才指出真正缺项。|没有可行计划时继续要求卡片会循环；应允许明确不可满足并结束任务。|旧记录有缺卡结果；不能把所有“未出卡”都当作该码的拒绝次数。|
|金丝雀泄漏 `canary_leak`（正文/工具名/解码参数）；[tool_gate.dart:312](E:/AII-3D/3D-Pose-SDK/lib/src/tools/tool_gate.dart:312)、[coach_agent.dart:1542](E:/AII-3D/3D-Pose-SDK/lib/src/agent/coach_agent.dart:1542)|保护内部标记及提示边界。|A：保留，技术安全事件独立记账，不对泄漏内容做猜测修补。|通常有不泄漏的回答；恶意/异常响应可安全停止。|有效标签六run未观测。|
|同批前项失败 `skipped_after_error`；[batch_handler.dart:13](E:/AII-3D/3D-Pose-SDK/lib/src/agent/batch_handler.dart:13)|失败后不使用未成立的依赖。|B：依赖调度由代码处理；可继续的独立项不应被机械跳过；不算一次新的拒绝。|上游失败不代表后续每项都错。|多次出现；证据计数已排除 skipped，不与真实失败相加。|
|交付后剩余调用 `skipped_after_completion`；[batch_handler.dart:23](E:/AII-3D/3D-Pose-SDK/lib/src/agent/batch_handler.dart:23)|一次交付只提交一个最终状态。|B：幂等结束/下一轮排队；保持一次提交，不要求模型返工。|代码可处理。|不计新的模型错误。|

## 二、参数、任务与动作来源

|检查 / 代码位置|保护什么|类别与建议|合法条件下是否一定有解|历史真实拒绝证据|
|---|---|---|---|---|
|空/非对象fields `invalid_fields`；[session_params.dart:108](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:108)|只接受账本字段更新。|B：空更新返回当前状态，明确包装可规范化；不可解析的来源不猜。|空幂等更新本不需要失败。|未观测。|
|`unknown_field`；[session_params.dart:142](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:142)|不写入未声明事实。|A：未知事实字段拒绝；无害附加元数据B忽略。|合法字段可解。|未观测。|
|`invalid_parameter` value/source形状与多余字段；[session_params.dart:153](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:153)|字段有可追溯来源。|A：来源不可猜造；B：无效多余字段剔除。|来源缺失时须模型补真实依据。|未观测。|
|`invalid_source`：禁止host，exclude只user，derived只scene/minutes；[session_params.dart:176](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:176)|模型不能冒充App或用户确认。|A：保留，合并为来源判定。|无真实依据时不能造来源。|S− R1 1（当时derived scene尚未支持）；当前derived scene已允许。|
|无关字段带direction `invalid_direction`；[session_params.dart:207](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:207)|不把方向作用到错误参数。|B：忽略不适用direction并说明。|可自动解决。|未观测。|
|派生时长direction非法；[session_params.dart:217](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:217)|缩短/加长由模型理解，不用代码猜自然语言。|A：保留正确方向枚举要求。|用户意图不明确时正常澄清。|未观测。|
|`derived_missing_baseline`；[session_params.dart:229](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:229)|计算相对时长有基准。|B：使用已确认值或明示profile默认；仍无基准正常询问。|当前基准缺失时模型不能编造。|未观测。|
|`invalid_derived_config`；[session_params.dart:240](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:240)|派生比例、时长范围配置有效。|B：加载时检查，向宿主报配置错误，非模型重试。|配置错误时无解。|未观测。|
|`derived_out_of_range`：方向/比例/范围/5分钟网格；[session_params.dart:258](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:258)|相对时长调整符合约定。|B：模型只给direction+quote，代码计算新值/basedOn；可行集空时说明边界，询问取舍。|5分钟再shorter，或比例与网格无交集时无解；不应让模型试数。|未观测。|
|scene受支持编码 `invalid_value`；[session_params.dart:299](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:299)、[session_params.dart:642](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:642)|不擅自把户外记成室内。|A：保留；不支持场景正常说明并由用户选替代。|目录/App不支持时无可交付解。|有效六run未观测该具体码。|
|minutes/level类型与范围；[session_params.dart:645](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:645)|分钟数、水平能执行。|B：default/derived由代码计算；A：明确用户值不能静默改义，冲突时协商。|profile范围外或无合法网格时可能无解。|未观测。|
|goal/equipment/limits编码数组、重复项；[session_params.dart:649](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:649)|引用真实目录编码。|A：未知目标/器械/限制不能伪造；B：数组去重与无歧义规范化。|目录没有所需编码时能力不足。|未观测独立参数码；搜索invalid_tags另计。|
|quote非空字符串；[session_params.dart:312](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:312)|user/derived/exclude有真实证据。|A：保留，不用自动生成内容冒充原话。|没有用户依据时不应有成功覆盖。|D+ R6 `invalid_quote` 1（回执为quote非原话）；准确子分支以原回执为准。|
|quote最多30字符；[session_params.dart:324](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:324)|限制证据体积。|B：改为turn/span或自动截取实际存在的短片段，保留完整原始消息。|英文真实完整原话可超限；与真实性无关。|上述1次不能重复归为长度命中；未见长度独立确证。|
|`quote_not_found`；[session_params.dart:335](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:335)|引用确实来自用户消息。|A：保留文字来源核对；它不证明原话到编码的语义映射正确，语义仍由模型负责。|原话不存在时不应伪造解。|现存旧码`invalid_quote`与新码不能机械合并为当前触发次数。|
|exclude只增不减 `equipment_exclude_cannot_relax`；[session_params.dart:351](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:351)|不擅自恢复用户排除物品。|A：真实授权；B：按最新明确原话更新环境物可用性，取消独立于伤痛的永久单调规则。|用户后来明确“现在有垫子”仍不能解除旧排除，合法输入可无解。|未观测。|
|exclude新原话 `equipment_exclude_quote_not_new`；[session_params.dart:373](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:373)|新增排除有用户依据。|A：真实原话保留；B：同一句原话的增量应可合并，不能用turn必须增长代替真实性。|同轮分两次写“没有垫子/不靠墙”，第二次可能被拒。|未观测。|
|derived scene覆盖user/host `source_conflict`；[session_params.dart:387](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:387)|推断不覆盖明确事实。|B：保留原值并kept，不要求模型返工。|原值有效时无需拒绝。|A R1另两次低来源冲突已改kept；此剩余分支未观测。|
|推测场景 `derived_quote_not_new`；[session_params.dart:399](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:399)|不重复用旧消息改场景。|A：引用来源保留；B：同轮推断重算/幂等由代码处理。|同轮纠正映射可能因同turn被拒。|未观测。|
|派生分钟 `derived_quote_not_new`；[session_params.dart:414](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:414)|旧“短一点”不能被反复累计缩短。|A：同一要求不能多次累加；B：同次试算应固定basedOn重算，不要求新用户消息。|同轮修正数值可能被拒。|未观测。|
|default/preselect低来源覆盖高来源；[session_params.dart:427](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:427)|保持已确认事实。|B：当前已kept；建议先判定不采用，再校验被忽略的低来源值，减少无意义失败。|当前错误低来源值会先触发invalid_value，即使最终不应采用。|A R1精确2次；Q已0次。|
|`quote_not_newer_than_host`；[session_params.dart:434](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:434)|旧消息不覆盖更新的App设置。|A：保留；同值幂等，冲突需较新用户依据。|无更新依据不应覆盖。|未观测。|
|`stale_user_quote`；[session_params.dart:447](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:447)|旧用户条件不覆盖新条件。|A：保留，统一来源排序和幂等。|无更新依据不应覆盖。|未观测。|
|`preselect_not_in_memory`；[session_params.dart:460](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:460)|预选确来自习惯。|A：保留；无法核对则明示default或询问，不冒充记忆。|不存在的习惯没有真实解。|未观测。|
|`default_equipment`；[session_params.dart:471](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:471)|默认不能授权额外器械。|A：保留；环境物由代码算，不混入模型默认器械。|目标可能无徒手动作，须说明/询问。|未观测。|
|`equipment_not_newly_confirmed`；[session_params.dart:483](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:483)|新增额外器械有明确授权。|A：授权保留；B：同一句“有哑铃和弹力带”分次增量合并。|第二次追加会因sourceTurn不增长被拒，是真实原话也可能无解。|未观测。|
|`limits_cannot_relax`；[session_params.dart:499](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:499)|模型不能放宽用户/App伤痛限制。|A：保留；B：可自动并集、说明未放宽，减少误删重交。只能由宿主按既定授权规则更新host安全基线。|安全池可空；此时应明确不提供。|未观测。|
|`invalid_host_context` scene/minutes/level；[session_params.dart:591](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:591)|宿主输入本身有效。|B：宿主边界/加载时错误，不向模型重交计划。|坏host值模型无解。|未观测。|
|ActionTags/bodyGroups/装备编码构造异常；[action_tags.dart:16](E:/AII-3D/3D-Pose-SDK/lib/src/agent/action_tags.dart:16)、[action_tags.dart:43](E:/AII-3D/3D-Pose-SDK/lib/src/agent/action_tags.dart:43)|目录命名空间和层级有效。|B：打包/加载验证，报告目录故障。|坏目录或profile模型无解。|未观测。|
|`invalid_task_type`；[agent_task.dart:54](E:/AII-3D/3D-Pose-SDK/lib/src/agent/agent_task.dart:54)|推荐/计划类型由模型明确判断。|A：非法枚举一次协议错误；不在代码解析用户关键词推断类型。|合法枚举存在。|未观测该具体码。|
|`reuse_unavailable`；[agent_task.dart:114](E:/AII-3D/3D-Pose-SDK/lib/src/agent/agent_task.dart:114)|只复用真实已有结果。|A：不能伪造过去结果；B：代码从state决定实际可复用部分并重建依赖，回执告知。|恢复不全/未完成状态下，合法业务请求可能被纯状态拒绝。|未观测该具体码。|
|start/check入参 `invalid_arguments`；[task_tool_handler.dart:12](E:/AII-3D/3D-Pose-SDK/lib/src/agent/task_tool_handler.dart:12)|任务类型/可选参数可解析。|A：type不能猜；B：node和无意义可选字段由代码管理。|协议可纠正。|未观测该入口独立确证。|
|`skills_unavailable`；[task_tool_handler.dart:49](E:/AII-3D/3D-Pose-SDK/lib/src/agent/task_tool_handler.dart:49)|任务需要的技能已安装。|B：SDK加载故障，不让模型换计划碰运气。|缺文件无解。|未观测。|
|`wrong_node / invalid_node`；[node_gates.dart:34](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:34)、[node_gates.dart:192](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:192)|固定阶段顺序。|B：代码拥有节点并自动推进，重复/过期check返回现态；保留真实事件。|业务正常但状态落后时模型未必能修复。|有效六run可见5次wrong_node：D+ R4 1、S+ R4 3、S− R4 1。|
|参数节点 `missing_parameters`；[node_gates.dart:61](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:61)|推荐有goal，计划有scene/goal/minutes。|A：goal未知正常澄清；B：默认字段统一补齐，不靠check调用补状态。|真实goal缺失不能编造；默认配置错模型无解。|有效六runmissing_parameters共5；跨入口以回执记录，不重复累加。|
|通用 `invalid_picks`：至少profile.minActions且不重复；[node_gates.dart:108](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:108)|动作卡/计划至少一定数量。|C：数量变建议；B：去重。purpose-only推荐和plan仍硬min3，应取消为业务拒绝。|只有1–2个合法动作、用户只要1个时可能无法通过。|A R2/R4各精确1次少于3动作；Q无该拒绝。|
|body推荐动态min、0仍要求1；[node_gates.dart:222](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:222)、[node_gates.dart:286](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:286)|少量目标候选时降低配额。|C：取消硬配额，只保留非空有效卡；0合规项正常说明不可用；搜索窄时一次warning。|0候选无解；池里3个也不代表用户必须要3个。|这是Q的实现，Q未拒；不能因此宣称不存在无解条件。|
|`unseen_actions`；[node_gates.dart:122](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:122)、[node_gates.dart:295](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:295)、[node_gates.dart:361](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:361)|只能选真实搜索到的动作。|A：保留，draft/show复用同一来源判定；不把get_action当seen授权。|安全过滤后不可见时应说明无可用结果。|S− R2 1次。|
|`incompatible_actions`；[node_gates.dart:137](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:137)、[node_gates.dart:307](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:307)、[node_gates.dart:376](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:376)|动作当前仍满足底线。|A：统一资格判断，避免各层口径漂移。|池可空，应停止无解循环。|未观测该具体码；旧阶段equipment见附表。|
|`recommendation_focus`；[node_gates.dart:317](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:317)|每个推荐命中body目标主次/子部位。|A：目标一致保留；不能用无关动作补数。|目标合规候选可为0，需说明目录不足。|Q未拒；A R2旧门禁未核目标而交付偏题，是漏检而非0拒绝等于好。|
|节点 `missing_plan / plan_not_checked`；[node_gates.dart:158](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:158)、[node_gates.dart:171](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:171)、[node_gates.dart:631](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:631)|引用正确草稿及已核对状态。|B：代码绑定activePlanId/latest并执行核对；仅底层A失败回模型，C不应让状态永久不过。|坏state或C规则无解会连带死锁。|不能把上层计划失败重复计数。|
|新增picks `actions_not_complete`；[node_gates.dart:345](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:345)|阶段完成后才补入draft所用动作。|B：资格通过后代码同步picks/stamp；删除仅先后顺序的额外拒绝。|合规seen动作也可因节点不完整被拒。|未观测。|
|目录不存在/profile范围；[node_gates.dart:565](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:565)|不引用虚构或范围外动作。|A：统一拒绝、说明当前能力边界。|目录可能无满足目标动作。|旧阶段out-of-scope不能从未出卡反推；有效六run无独立确证。|
|额外器械/环境物；[node_gates.dart:570](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:570)|不使用未授权额外物品或明确排除物品。|A：保留effectiveEquipment统一事实。|目标/装备组合可无可用动作。|旧阶段E4 R4有2次equipment拒绝，包含中文名/编码漂移，见附表。|
|场景、禁地面、禁姿态；[node_gates.dart:576](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:576)|动作在当前环境可做。|A：保留，不静默将办公室改居家。|目标仅有地面动作时办公室可无解。|未观测该入口独立拒绝。|
|cautions/contraindications伤痛冲突；[node_gates.dart:591](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:591)|不触及明确限制。|A：保留；标签未知只能提示不确定，不能说已安全验证。|所有候选触限时无安全解。|未观测该入口真实拒绝。|
|`task_required`；[action_search.dart:70](E:/AII-3D/3D-Pose-SDK/lib/src/agent/action_search.dart:70)|只在活动推荐/计划中检索。|B：模型明确任务后代码初始化/恢复；单独查询缓存不增加安全性，不应为打卡多一次请求。|有合法搜索参数、但无活动task会拒绝。|D+/S历史wrong_task_type与其语义相关，码不同；不能冒算为task_required命中。|
|`invalid_tags`；[action_search.dart:86](E:/AII-3D/3D-Pose-SDK/lib/src/agent/action_search.dart:86)|只用真实标签编码。|A：未知编码拒绝；明确别名B归一化。|目录没有该标签能力时不能虚构。|D+ R6 1次position.seated；E4旧invalid_search另列。|
|`invalid_limit` 1–20；[action_search.dart:99](E:/AII-3D/3D-Pose-SDK/lib/src/agent/action_search.dart:99)|限制单页体积。|B：clamp/分页并说明，不影响动作选择。|可自动解决。|未观测。|
|搜索资格过滤；[action_search.dart:124](E:/AII-3D/3D-Pose-SDK/lib/src/agent/action_search.dart:124)|不暴露可选为计划的违规动作。|A安全过滤保留；B检索偏好level/pose过窄时可按已批准策略放宽一次。空结果本身并非ok:false。|可搜空，不能由min数量继续造成死循环。|D− R1/R2各1次no_new_info终止；不能把每个隐藏动作计一次拒绝。|
|详情ids 1–10、唯一 `invalid_ids`；[action_search.dart:279](E:/AII-3D/3D-Pose-SDK/lib/src/agent/action_search.dart:279)|详情批量受控。|B：去重/分批/空列表no-op。|纯批次数量不应使业务无解。|未观测。|
|详情 `incompatible_actions`；[action_search.dart:291](E:/AII-3D/3D-Pose-SDK/lib/src/agent/action_search.dart:291)|详情的选择仍符合条件。|A资格保留，可逐项返回状态，不让一个无效id挡住整批合法详情；详情不新增seen。|整批一项失败会隐藏其他合法项。|未观测。|
|search/get包装类型/多余字段/重复数组；[action_tool_handler.dart:14](E:/AII-3D/3D-Pose-SDK/lib/src/agent/action_tool_handler.dart:14)|参数可解析。|A不可识别语义拒绝一次；B字符串化数组等无歧义结构规范化、去重/limit默认统一处理。|合法内容写成JSON字符串目前会多次失败。|D− R6 invalid_arguments 2次正是tags数组被写成JSON字符串。|

**目标一致性覆盖边界：** 当前推荐只核body，不核purpose-only（[node_gates.dart:201](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:201)）；仅`purpose.stretch`时，安全/器械/scene合规的力量动作仍可能通过。quote存在只证明文本来源，不证明目标编码的映射正确（[session_params.dart:335](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:335)）。这两点应进入评审，不能把“所有目标都已核对”写成现状，也不建议再加自然语言关键词门禁。

## 三、草稿、配时与计划核对

|检查 / 代码位置|保护什么|类别与建议|合法条件下是否一定有解|历史真实拒绝证据|
|---|---|---|---|---|
|draft非JSON对象 `invalid_arguments`；[draft_tool_handler.dart:9](E:/AII-3D/3D-Pose-SDK/lib/src/agent/draft_tool_handler.dart:9)|草稿可解析。|A：无法识别所选动作才拒绝；B：可确定包装修复。|合法结构可解。|未观测此入口独立确证。|
|handler自动默认后仍 `missing_parameters`；[draft_tool_handler.dart:27](E:/AII-3D/3D-Pose-SDK/lib/src/agent/draft_tool_handler.dart:27)；builder [plan_builder.dart:81](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:81)；checker [plan_checker.dart:183](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:183)|真实参数充分。|B：合为一份requirements/defaults；A仅缺真实goal正常澄清。checker actual仍用params.keys，应改为真正缺项。|默认值坏/goal缺失可能无解。|有效六run共5：D+ R4、D− R4、S− R1/R4、A R4各1；Q默认补齐后为0。|
|ledger类型 `invalid_parameters`；[plan_builder.dart:95](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:95)|内部参数能计算。|B：内部状态修复或配置错误，不让模型为代码类型错误返工。|坏ledger模型无解。|未观测。|
|替换阈值 `invalid_profile`；[plan_builder.dart:110](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:110)|配置比例有效。|B：加载时检查。|坏配置对所有计划无解。|未观测。|
|`invalid_operation`；[plan_builder.dart:122](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:122)|整体换/局部改由模型判断。|A：保留真正非法意图枚举；B缺省edit/沿用本次操作可代码处理。|合法枚举可解。|历史no_delivered_plan不是此非法枚举，另列已自动化行为。|
|`operation_conflict / operation_required`；[plan_builder.dart:156](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:156)、[plan_builder.dart:177](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:177)|同次返工保留操作含义。|B：本次继承操作、ID/版本归代码；模型只在新整体替换意图时给replace_all。|漏字段/试算修复不应无解。|未观测具体码。|
|`invalid_plan_id`：修改不匹配/新ID碰撞；[plan_builder.dart:190](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:190)、[plan_builder.dart:251](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:251)|不更新错计划。|B：绑定唯一当前交付版本，代码创建新ID，歧义才询问。|ID碰撞/恢复引用丢失模型无解。|未观测。|
|规划/核对 `wrong_node`；[plan_builder.dart:221](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:221)、[plan_checker.dart:110](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:110)|节点顺序。|B：代码推进；删去独立重交门槛，复用真实事件。|状态机落后会无解。|有效六run总5次wrong_node，见上表，不在此重复相加。|
|标题/blocks形状 `invalid_draft`；[plan_builder.dart:233](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:233)|草稿结构完整。|B：标题/分组/元数据由代码生成；A未知动作或无选择不得猜。|格式可解；空动作池不能造计划。|未观测。|
|block类型/items/rounds `invalid_block`；[plan_builder.dart:273](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:273)|分组能执行。|B：代码分组、排序、默认轮数。|用户选动作正常也可因模型分组格式被拒。|未观测。|
|item字段/整数剂量 `invalid_item`；[plan_builder.dart:294](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:294)|执行剂量可处理。|B：从目录生成、规范化；A缺失动作ID不猜。|剂量可补，目录缺定义需说明。|未观测。|
|单动作 `incompatible_action`；[plan_builder.dart:314](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:314)|ID存在/seen/scope/条件合规。|A：保留统一资格；同类失败一次说明全部问题。|安全池可空，应终止或澄清。|未观测该具体码。|
|剂量/休息区间无交集 `invalid_dose_range`；[plan_builder.dart:333](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:333)、[plan_builder.dart:382](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:382)|代码使用可执行范围。|B：目录/profile配置校验，非模型试数问题。硬安全剂量边界不能绕过。|区间无交集时任意合法模型输入也无法过。|未观测。|
|补picks透传门禁；[plan_builder.dart:454](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:454)|新动作真实已搜且合规。|A来源/安全保留；B节点/picks自动补齐，取消额外流程失败。|安全动作可因状态门槛被拒。|未观测。|
|legacy goal推导StateError；[legacy_goal.dart:52](E:/AII-3D/3D-Pose-SDK/lib/src/agent/legacy_goal.dart:52)，调用[plan_builder.dart:407](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:407)|旧卡枚举兼容。|B：profile必须有fallback/启动校验；不要让模型补legacy_goal。|有映射但无命中且无fallback时合法目标无解。|未观测。|
|`replace_too_similar`；[plan_builder.dart:488](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:488)|兑现整体换一套与历史交付差异。|A整体替换意图保留；B计算比例/列可换池；候选不足正常说明不可满足，不为凑比例重复试草稿。|可替换合规动作不足时无解。|有效六run未观测；原有回归测试不是实测次数。|
|`duration_unfit`；[plan_builder.dart:525](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:525)；`plan_duration` [plan_checker.dart:327](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:327)|实际训练时长贴近确认分钟数。|B：合为有可行性判断的配时器；误差仍不可达时正常说明最佳可达值/请用户取舍。|最小剂量过长、最大剂量不足、整数网格/启发式局限均可无解。|有效六run未观测这两个码；E4旧context_conflict见附表。|
|核对计划ID/损坏卡 `invalid_plan_id / invalid_plan`；[plan_checker.dart:124](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:124)、[plan_checker.dart:171](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:171)|核对最新且可解码的版本。|B：绑定当前版本，代码生成字段自行修复；坏存档技术错误，不归模型。|状态损坏可无解。|未观测。|
|PlanRules配置 `invalid_plan_rules / FormatException`；[plan_checker.dart:198](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:198)；[coach_profile.dart:260](E:/AII-3D/3D-Pose-SDK/lib/src/profile/coach_profile.dart:260)|比例、阈值、拮抗、derivedStep配置有效。|B：加载时校验，一次宿主诊断。|错配置可能使所有合法计划不过。|未观测。|
|`plan_safety`；[plan_checker.dart:277](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:277)、[plan_checker.dart:303](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:303)|真实scope/伤痛禁忌合规。|A：保留，与admission/legacy avoid共享规范化和事实。|可无安全候选。|有效六run未观测；不要把未验证字段warning当安全通过证明。|
|`plan_equipment`；[plan_checker.dart:283](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:283)、[plan_checker.dart:307](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:307)|实际器械均可用。|A：保留，与同一effectiveEquipment事实一致。|目标与器械可无交集。|E4 R4旧equipment 2次，非当前码，且有名称/编码错误。|
|`plan_card_conditions`；[plan_checker.dart:314](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:314)|卡片分钟和器械对应账本/实际动作。|B：代码重建派生字段再核A，删去模型重选动作的返工。|可确定修正。|未观测。|
|`plan_structure` 热身/收尾阈值；[plan_checker.dart:337](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:337)|常规训练阶段齐全。|B分组归代码；C是否必需取决于目标，纯拉伸/短训练不能机械硬挡。|纯stretch+mobility会失去pureStretch豁免；缺允许prep动作时可能无解。|有效六run未观测该码。|
|`plan_block_purpose`；[plan_checker.dart:359](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:359)、[plan_checker.dart:397](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:397)|热身/放松不是不合阶段的高负荷。|C：purpose是目录近似，不是安全证明；结合目标/剂量一次warning。B可整理既选动作阶段，不擅自换动作。明确伤痛仍A。|死虫式仅标core却可低剂量激活；缺activation标注时合理方案被拒。|Q R3精确1：warmup死虫式purpose.core；修成活动度后才出卡。|
|`plan_focus_body / plan_focus_purpose` 的真实目标偏离；[plan_checker.dart:413](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:413)、[plan_checker.dart:438](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:438)|计划主体兑现用户部位/目的。|A：真实偏离保留拒绝，主次/子部位一致处理；候选不足先说明能力。|目录/限制可使目标不可满足，不能硬加无关动作凑数。|有效六run未观测这些码。|
|同上固定focusRatio且body/purpose分别达标；[plan_checker.dart:422](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:422)|用比例代理目标契合度。|C：比例属于适用性规则，需与真实目标分开评审；B先算候选可行性。当前原规格阈值仍存在，本文仅建议，未放宽代码。|两目标组分开>=高比例但动作交集不足，可互相冲突；目录标注不全可误拒。|未观测，不等于普遍有解。|
|`plan_focus` 无body/purpose目标；[plan_checker.dart:440](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:440)|不能交付无真实目标计划。|A：回参数询问，B统一编码归一化，不能代码猜用户想练什么。|目标未知时不可自动造解。|未观测。|
|`plan_balance` 同块重复ID；[plan_checker.dart:450](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:450)|避免重复条目误加训练量。|B：按阶段合并剂量/稳定去重，明确训练重复意图保留；不改不同动作集合。|小动作池/合理重复可被不必要硬拒。|13次balance回执都不是此子条件；不能将13重复记到这里。|
|`plan_balance` 连续首部位<=3；[plan_checker.dart:457](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:457)|通用负荷交替经验。|C：结合目标，仅主体；B能重排时稳定重排，无合法交替则warning，不塞无关动作。|单部位专项/仅同部位安全动作；跨热身收尾累计，会使保留原选择集合无解。|统一标签六run可见13次，全部R4；Q精确6。|
|`plan_balance` 固定拮抗组覆盖；[plan_checker.dart:471](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:471)|泛化的前后/拮抗均衡。|C：从目标和限制判断是否相关，一次warning，不强补用户没要或伤痛不允许的部位。|专项、一侧受伤、目录/器械缺一侧时无解。|现有13次balance不能归给此子条件；未观测独立命中。|
|`legacy.errors`全量提升/失败退planning；[plan_checker.dart:506](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:506)、[plan_checker.dart:554](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:554)|复用旧校验与防错误交付。|B：统一A/B/C内核，A错误才回模型选动作，B修正、C不重置节点。|C无解会被包装成plan_check_failed并不断重置。|wrapper有效六run14次=balance13+block_purpose1，不能再与子项相加。|

### 旧 Validator 被新 Checker 复用的拦截（仍需一并调整）

以下均位于 `lib/src/plan/plan_validator.dart`。当前六组没有这些子规则的独立拒绝确证（旧阶段E4装备/时长有记录，见附表）；“未观测”适用前述统计边界。

|检查 / 代码位置|保护什么|类别与建议|合法条件下是否一定有解|历史真实拒绝证据|
|---|---|---|---|---|
|schema_version；[plan_validator.dart:78](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:78)|卡片版本有效。|B：codec固定生成，坏state宿主错误。|代码自产错误模型无解。|未观测。|
|title非空；[plan_validator.dart:81](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:81)|可呈现标题。|B：默认标题。|可自动补。|未观测。|
|summary非空；[plan_validator.dart:84](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:84)|可呈现摘要。|B：从计划/标题生成。|可自动补。|未观测。|
|旧goal枚举；[plan_validator.dart:87](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:87)|旧卡兼容。|B：legacyGoalMap，故障前置。|坏映射无解。|未观测。|
|scene仅home/office/gym；[plan_validator.dart:93](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:93)|旧宿主实际支持范围。|A能力边界；B卡片值取账本，不暗改户外。|outdoor当前不支持。|未观测。|
|scene_unsupported；[plan_validator.dart:95](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:95)|profile场景支持。|A：正常告知不可用。|超App能力无解。|未观测。|
|卡片scene与context冲突；[plan_validator.dart:98](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:98)|不改用户场景。|A确认事实；B卡片取权威账本。|内部写错可修。|未观测。|
|level 1..3；[plan_validator.dart:101](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:101)|水平字段可执行。|B：账本/default生成。|配置损坏时无解。|未观测。|
|minutes_range；[plan_validator.dart:104](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:104)|产品支持时长范围。|B：能力边界提前检查/协商；A明确用户时长不可偷偷改成范围内值。|正常用户要求超产品能力时无解。|未观测。|
|未知卡片equipment编码；[plan_validator.dart:107](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:107)|不声明不存在器械。|B卡片由实际动作生成；A实际器械真实性。|声明字段可修。|E4 R4旧装备码漂移不能推广到新代码。|
|empty_plan；[plan_validator.dart:127](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:127)|不交空卡。|A：保留真实有内容的要求；B空壳阶段删除。|候选为空应告知无方案。|未观测。|
|rounds_range；[plan_validator.dart:139](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:139)|轮数在执行范围。|B：统一配时计算。|配置区间冲突可无解。|未观测。|
|rest_between_rounds_range；[plan_validator.dart:142](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:142)|轮间休息范围。|B：代码生成。|配置区间冲突可无解。|未观测。|
|warmup在cooldown后 block_order；[plan_validator.dart:149](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:149)|阶段顺序。|B：稳定重排。|可自动修复。|未观测。|
|empty_block；[plan_validator.dart:156](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:156)|没有无内容阶段。|B：删除/重组空块。|动作池空则按A说明无方案。|未观测。|
|segment ID空/重复；[plan_validator.dart:169](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:169)|子段引用唯一。|B：代码编号。|可修复。|未观测。|
|segment holdSeconds<=0；[plan_validator.dart:172](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:172)|执行时值有效。|B：目录默认/规范化。|缺执行定义时技术错误。|未观测。|
|segment label空；[plan_validator.dart:175](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:175)|标签可显示。|B：删除空标签/目录名。|可修复。|未观测。|
|segment rhythm schema；[plan_validator.dart:178](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:178)|节奏结构可执行。|B：从目录生成，具体字段见后表；A专有模式能力不能伪造。|坏目录可无解。|未观测。|
|unknown_exercise；[plan_validator.dart:192](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:192)|真实动作ID。|A：共享目录资格。|无所需目录动作时无解。|未观测。|
|out_of_profile；[plan_validator.dart:205](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:205)|App scope。|A：共享范围判定。|scope空时无解。|未观测。|
|mode_mismatch；[plan_validator.dart:212](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:212)|剂量单位符合目录。|B：代码按目录换算，当前builder已处理。|不应要求模型算单位。|旧invalid_dose_mode有效run6次，当前已自动处理；不是该legacy码本轮触发。|
|缺reps；[plan_validator.dart:225](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:225)|计次动作有剂量。|B：目录默认。|目录无定义时配置问题。|未观测。|
|缺workSeconds；[plan_validator.dart:230](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:230)|计时动作有剂量。|B：目录默认。|同上。|未观测。|
|reps硬范围；[plan_validator.dart:228](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:228)、[plan_validator.dart:349](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:349)|执行范围。|B范围内计算，硬安全上限保留在配时器。|范围/目标可冲突。|未观测。|
|workSeconds硬范围；[plan_validator.dart:233](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:233)、[plan_validator.dart:349](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:349)|执行范围。|B同上。|同上。|未观测。|
|sets硬范围；[plan_validator.dart:246](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:246)、[plan_validator.dart:349](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:349)|组数执行范围。|B同上。|同上。|未观测。|
|rest硬范围；[plan_validator.dart:259](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:259)、[plan_validator.dart:349](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:349)|休息执行范围。|B同上。|同上。|未观测。|
|enforceDrillDoseRange=true；[plan_validator.dart:353](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:353)|宿主把目录推荐剂量变硬限。|B：范围提前给配时器；C软推荐不升级成模型重交。|硬区间与时长可能不交。|未观测。|
|per_side；[plan_validator.dart:272](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:272)|单侧训练量正确。|B：目录unilateral生成，builder已实现。|可确定修正。|未观测。|
|avoid；[plan_validator.dart:282](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:282)|明确保护部位。|A：与safety同一规范化依据。|安全池可空。|有效六run未观测。|
|equipment；[plan_validator.dart:287](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:287)|实际器械可用。|A：统一effectiveEquipment。|能力组合可无解。|E4 R4 2次回执，不是每个嵌套issue各算1。|
|position；[plan_validator.dart:295](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:295)|当前环境禁地面/姿态。|A：共享scene准入。|环境与目标可无解。|未观测。|
|动作scene；[plan_validator.dart:300](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:300)|动作适合当前场景。|A：共享scene准入。|同上。|未观测。|
|too_many_items；[plan_validator.dart:310](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:310)|执行器条目容量。|B：确定性合并/分组，保留不同动作；仍超真实容量则一次明确能力错误，不偷偷删动作。|用户正常要求可能超产品容量。|未观测。|
|宿主extraRules任意error；[plan_validator.dart:331](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_validator.dart:331)|宿主自定义约束。|逐条要求宿主声明A/B/C、适用目标、可修正性；不能把任意error默认当安全底线。|任意外部函数都可能拒绝所有合法输入，仓库不能枚举未提供函数体。|本轮六组没有额外规则命中确证。|

**旧 Validator 本来仅warning的项：** goalOutOfProfile（:89）、avoidVocabulary（:115）、其他块顺序（:152）、同块duplicateExercise（:208）、levelHigh（:304）、equipmentUndeclared（:313）、duration偏差约±40%（:321）、默认doseRange（:353）。专业建议保持C；器械声明/排序/时长改为B自动处理。不要再把这些warning一律升级成新的硬门禁。

### 解码/分段每项前置检查（不会凭同一个schema码合并掉语义）

这些在新链路可被包成`invalid_plan`，在旧接口直接报`schema`。对应的**代码生成字段**归B；ID是否真实、能力是否合法仍归A。下表每项实测均未观测独立命中，不能从单测样本推断次数。

|检查 / 代码位置|保护什么|分类 / 建议|可解性 / 历史|
|---|---|---|---|
|plan对象 [plan_codec.dart:54](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:54)|可解码容器。|B代码生成；不可解析存档技术错误。|坏数据无自动解；实测未观测。|
|字符串字段 [plan_codec.dart:60](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:60)|元数据类型。|B默认/规范化。|可修；未观测。|
|整数必填/类型 [plan_codec.dart:71](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:71)|执行整数数据。|B目录默认/计算。|坏目录可能无解；未观测。|
|blocks数组 [plan_codec.dart:84](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:84)|分组容器。|B代码生成。|可修；未观测。|
|block对象 [plan_codec.dart:92](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:92)|阶段容器。|B代码生成。|可修；未观测。|
|block type枚举 [plan_codec.dart:97](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:97)|阶段类型。|B代码分组。|可修；未观测。|
|items数组 [plan_codec.dart:107](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:107)|动作集合可读。|B代码结构化；A不可猜选择。|缺动作不能编造；未观测。|
|item对象 [plan_codec.dart:114](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:114)|动作执行条目。|B代码结构化。|同上；未观测。|
|exerciseId非空 [plan_codec.dart:123](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:123)|动作引用。|A不能猜所选动作；B已选ID序列化。|缺引用要明确缺项；未观测。|
|mode枚举 [plan_codec.dart:127](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:127)|reps/time单位。|B目录生成。|缺目录定义需诊断；未观测。|
|perSide布尔 [plan_codec.dart:135](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:135)|单侧执行字段。|B目录生成。|可修；未观测。|
|sets/对应剂量/rest整数 [plan_codec.dart:139](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:139)、[plan_codec.dart:143](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:143)、[plan_codec.dart:148](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:148)|剂量结构。|B统一配时器。|范围无交集可能无解；未观测。|
|segments数组 [plan_codec.dart:150](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:150)|分段容器。|B代码生成。|损坏存档不能丢段；未观测。|
|segment对象 [plan_codec.dart:158](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:158)|分段条目。|B代码生成。|同上；未观测。|
|segment允许字段、组侧休息继承 [plan_codec.dart:163](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:163)|避免子段重复计算父剂量。|B规范化继承关系。|可修；未观测。|
|segment id非空唯一 [plan_codec.dart:169](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:169)|唯一引用。|B代码编号。|可修；未观测。|
|segment exerciseId非空 [plan_codec.dart:176](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:176)|动作引用。|A动作真实，B结构生成。|无引用不能猜；未观测。|
|segment mode [plan_codec.dart:179](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:179)|单位。|B目录生成。|可修；未观测。|
|segment reps/workSeconds正数 [plan_codec.dart:185](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:185)|有效剂量。|B计算。|范围冲突可能无解；未观测。|
|segment只能有对应模式剂量 [plan_codec.dart:191](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:191)|不重复计时/计次。|B选目录模式并说明。|可修；未观测。|
|segment holdSeconds正数 [plan_codec.dart:194](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:194)|有效保持时长。|B计算。|同上；未观测。|
|segment label非空 [plan_codec.dart:198](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:198)|标签。|B目录名/去空。|可修；未观测。|
|rhythm对象 [plan_codec.dart:202](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:202)|节奏容器。|B从目录结构生成。|坏定义诊断；未观测。|
|rhythm.kind/禁止计划启用self_paced [segment_rhythm.dart:5](E:/AII-3D/3D-Pose-SDK/lib/src/plan/segment_rhythm.dart:5)|执行器模式能力真实。|A不伪造专有模式；B从实际支持模式生成。|不支持则明确能力限制；未观测。|
|lead>=0、hold/reps正整数 [segment_rhythm.dart:12](E:/AII-3D/3D-Pose-SDK/lib/src/plan/segment_rhythm.dart:12)|执行数值。|B计算/规范化。|可修；未观测。|
|phases数组 [segment_rhythm.dart:19](E:/AII-3D/3D-Pose-SDK/lib/src/plan/segment_rhythm.dart:19)|节奏阶段容器。|B代码生成。|坏定义技术故障；未观测。|
|phase对象 [segment_rhythm.dart:26](E:/AII-3D/3D-Pose-SDK/lib/src/plan/segment_rhythm.dart:26)|单阶段结构。|B代码生成。|同上；未观测。|
|phase id非空唯一 [segment_rhythm.dart:30](E:/AII-3D/3D-Pose-SDK/lib/src/plan/segment_rhythm.dart:30)|节奏引用唯一。|B代码编号。|可修；未观测。|
|phase.seconds有限正数 [segment_rhythm.dart:34](E:/AII-3D/3D-Pose-SDK/lib/src/plan/segment_rhythm.dart:34)|节奏时间有效。|B计算。|范围冲突可无解；未观测。|
|cueAt在阶段内 [segment_rhythm.dart:38](E:/AII-3D/3D-Pose-SDK/lib/src/plan/segment_rhythm.dart:38)|提示落在执行期间。|B确定性定位。|可修；未观测。|
|cue字符串/数组 [segment_rhythm.dart:42](E:/AII-3D/3D-Pose-SDK/lib/src/plan/segment_rhythm.dart:42)|提示可播放。|B目录生成/规范化。|缺内容不能编造专有音频；未观测。|

## 四、交付与并发提交

|检查 / 代码位置|保护什么|类别与建议|合法条件下是否一定有解|历史真实拒绝证据|
|---|---|---|---|---|
|`invalid_output_tool / wrong_task_type`；[output_gate.dart:62](E:/AII-3D/3D-Pose-SDK/lib/src/agent/output_gate.dart:62)、[output_gate.dart:73](E:/AII-3D/3D-Pose-SDK/lib/src/agent/output_gate.dart:73)|交付与任务类别一致。|A：不能伪造计划/推荐；B：工具路由和已有状态接续由代码处理，不为类型切换打卡。|任务/工具错配可纠正；如果没有所需数据则不能自动造卡。|S− R2 `wrong_task_type` 1。|
|`invalid_task_nodes / nodes_incomplete`；[output_gate.dart:84](E:/AII-3D/3D-Pose-SDK/lib/src/agent/output_gate.dart:84)、[node_gates.dart:505](E:/AII-3D/3D-Pose-SDK/lib/src/agent/node_gates.dart:505)|固定阶段的记录完整且通过必要检查。|B：节点作为代码派生事件，检查底线后自动推进；损坏恢复状态由代码修复/报恢复失败。保留真实阶段，不伪打卡。|损坏/不可达节点会无解；不能让模型修内部nodes数组。|当前有效六run未观测这两个具体码；早期流程节点拒绝见下表。|
|show_* 多余字段/非对象；[output_gate.dart:101](E:/AII-3D/3D-Pose-SDK/lib/src/agent/output_gate.dart:101)|限制输出入口只接受ID与说明。|B：忽略确定无害多余字段；A：不能识别ID或试图覆盖已确认值时拒绝。|正常卡有可表达的输入；旧/新schema混用可能拒绝。|D− R6 `invalid_arguments` 2，须以回执确认入口；其他未观测。|
|note 缺失/非字符串/空白 `invalid_note`；[output_gate.dart:119](E:/AII-3D/3D-Pose-SDK/lib/src/agent/output_gate.dart:119)|给卡片补可读说明。|B：确定性生成简短数据说明或允许无note交付；长度不再当拒绝条件。|卡片完全正确但note空时仍拦，属于不必要无解。|S− R6：可见回执2次旧长度拒绝，另1次末次terminal issues证据；当前长度已自动截断，不能说当前仍拒长note。|
|ids类型 `invalid_ids`；[output_gate.dart:132](E:/AII-3D/3D-Pose-SDK/lib/src/agent/output_gate.dart:132)|确保推荐卡能解析所选ID。|A：不可辨识的ID结构拒绝；B：单值/完全重复的无歧义规范化由代码处理。|schema可纠正。|未观测该具体码。|
|已选集合 `unpicked_actions`；[output_gate.dart:192](E:/AII-3D/3D-Pose-SDK/lib/src/agent/output_gate.dart:192)|避免交付未经来源与条件核对的选择。|A：seen/条件/目标校验保留；B：`picks`只是已通过核对的派生记录，应从交付选择自动同步，删除“已seen但还没写picks”的额外门槛。|当前actions已完成后换合规seen动作，也可能仅因picks快照拒绝。|有效标签六run未观测该具体码。|
|推荐/计划最终 `incompatible_actions`；[output_gate.dart:204](E:/AII-3D/3D-Pose-SDK/lib/src/agent/output_gate.dart:204)、[output_gate.dart:279](E:/AII-3D/3D-Pose-SDK/lib/src/agent/output_gate.dart:279)|交付时仍满足目录、场景、器械和限制。|A：保留并复用统一资格判定；最终复核防止中途条件改变，不重复向模型收多份同义错误。|条件变更或候选耗尽时可能无解，应重新检索/澄清或结束。|未观测最终该码；检索/草稿阶段同义错误另列。|
|`invalid_plan_id` 当前计划/最新版本；[output_gate.dart:237](E:/AII-3D/3D-Pose-SDK/lib/src/agent/output_gate.dart:237)|交付正确会话、正确版本的卡。|B：ID与版本由代码持有，show_plan可用当前草稿隐式引用；外来/陈旧ID不能覆盖当前计划。|正常用户不能修复错乱内部ID。|未观测输出入口该码。|
|`plan_not_checked`；[output_gate.dart:248](E:/AII-3D/3D-Pose-SDK/lib/src/agent/output_gate.dart:248)|交付版本确实经过核对。|B：代码同次调用计算检查并交付；A实际失败项仍拦，C项不再让check.ok=false。|C检查无解时当前会使任何show_plan都无法通过。|有效标签六run未观测该具体码；真实balance失败在草稿自动核对阶段发生。|
|已存卡 `invalid_plan / decodeStrict`；[output_gate.dart:258](E:/AII-3D/3D-Pose-SDK/lib/src/agent/output_gate.dart:258)|避免交付损坏的卡片结构。|B：代码自产数据应在构造时正确；不向模型索取内部schema修补；不能无损恢复时技术错误停止。|损坏state/代码Bug模型无解。|未观测。|
|`card_conditions_changed` 时长/实际器械清单不一致；[output_gate.dart:294](E:/AII-3D/3D-Pose-SDK/lib/src/agent/output_gate.dart:294)|文字和卡片条件来自当前确认数据及真实动作。|B：重算派生时长/器械清单并再核 A；A：不能为了匹配卡片反过来修改用户条件。|卡片派生字段可确定修正。|未观测。|
|交付过程中host安全revision、任务对象、取消/reset变化；[coach_agent.dart:2028](E:/AII-3D/3D-Pose-SDK/lib/src/agent/coach_agent.dart:2028)、[output_commit_handler.dart:41](E:/AII-3D/3D-Pose-SDK/lib/src/agent/output_commit_handler.dart:41)|禁止提交已经失效的安全与会话状态。|A：保留最后原子复核；B：刷新/重算归代码，不能算模型错误。|异步变更时旧结果本就不可提交。|没有真实评测触发确证；有现存竞态单测，但不把单测计入实测次数。|
|fallback不准偷偷出计划/未完成任务不准套预设；[coach_agent.dart:2087](E:/AII-3D/3D-Pose-SDK/lib/src/agent/coach_agent.dart:2087)、[coach_agent.dart:2110](E:/AII-3D/3D-Pose-SDK/lib/src/agent/coach_agent.dart:2110)；显式模板资格 [coach_agent.dart:596](E:/AII-3D/3D-Pose-SDK/lib/src/agent/coach_agent.dart:596)|防止模型失败后擅自替换用户请求或交付未经核对模板。|A：保留用户选择与底线；B：提供明确的无法完成结果/显式宿主动作，不能把模板当作零拒绝捷径。|无合法计划时允许诚实终止；不需要存在一个伪成功计划。|部分历史error/fallback结果不能反算成工具拒绝。|

## 五、兼容接口与技术中止（也会拦交付）

这些入口不能从“当前六组没走到”推导为可直接删除。现有公开接口兼容要求仍有效；如以后合并，旧接口应复用同一个规则内核。

|检查 / 代码位置|保护什么|类别与建议|合法条件下是否一定有解|历史真实拒绝证据|
|---|---|---|---|---|
|旧 CoachSession 一次回复最多1个工具 `multiple_tools`；[tool_gate.dart:220](E:/AII-3D/3D-Pose-SDK/lib/src/tools/tool_gate.dart:220)|旧接口只认单次输出工具。|B：批处理/选最终输出由代码统一；Agent主循环已支持批量，不要把此旧限制移植回来。|正常批量工具在旧接口无法通过。|当前有效六run不走旧输出工具协议，未观测。|
|旧推荐items数组/1–6项/单项字段与类型；[tool_gate.dart:365](E:/AII-3D/3D-Pose-SDK/lib/src/tools/tool_gate.dart:365)、[tool_gate.dart:382](E:/AII-3D/3D-Pose-SDK/lib/src/tools/tool_gate.dart:382)、[tool_gate.dart:399](E:/AII-3D/3D-Pose-SDK/lib/src/tools/tool_gate.dart:399)|旧卡片协议可呈现。|B：代码生成旧卡片结构、分页；A：非法或不存在ID仍拒绝。|合法动作超过6个可因UI数量限制拒绝。|同上。|
|旧推荐unknown_exercise/out_of_profile/avoid；[tool_gate.dart:443](E:/AII-3D/3D-Pose-SDK/lib/src/tools/tool_gate.dart:443)、[tool_gate.dart:455](E:/AII-3D/3D-Pose-SDK/lib/src/tools/tool_gate.dart:455)、[tool_gate.dart:484](E:/AII-3D/3D-Pose-SDK/lib/src/tools/tool_gate.dart:484)|目录范围与伤痛底线。|A：保留；应与新入口复用相同scene/equipment/seen资格规则，不能把旧检查不完整当放宽依据。|无可用动作则应说明不可满足。|同上。|
|旧推荐重复ID `duplicate_action`；[tool_gate.dart:469](E:/AII-3D/3D-Pose-SDK/lib/src/tools/tool_gate.dart:469)|避免重复展示相同动作。|B：去重，不改变不同动作的选择。|可解。|同上。|
|旧show_plan外包一层plan拒绝；[tool_gate.dart:503](E:/AII-3D/3D-Pose-SDK/lib/src/tools/tool_gate.dart:503)|旧工具参数形状正确。|B：确定性解包并说明，不要求模型重写全部卡片。|可解。|同上。|
|旧计划 ctx.level/targetMinutes 冲突 `context_conflict`；[tool_gate.dart:524](E:/AII-3D/3D-Pose-SDK/lib/src/tools/tool_gate.dart:524)|确认条件与卡片一致。|B：从权威账本重建派生字段；A：不允许卡片改变用户确认值。旧CoachAssistant已做normalize，当前存在两套不同口径。|权威条件存在时可解。|当前有效六run未走该旧入口。|
|旧计划全计划重复ID强制error；[tool_gate.dart:559](E:/AII-3D/3D-Pose-SDK/lib/src/tools/tool_gate.dart:559)|避免重复编排同一动作。|B：合并同一阶段剂量；跨热身/收尾复用不应按同阶段重复处理。专业适宜性C提示。|同一个安全动作合理用于热身与收尾时会拒绝；新PlanChecker只查同块重复，两套口径不同。|当前有效六run未走该旧入口。|
|CoachAssistant JSON信封提取/kind/text/options/plan存在性；[coach_reply.dart:80](E:/AII-3D/3D-Pose-SDK/lib/src/envelope/coach_reply.dart:80)、[coach_reply.dart:94](E:/AII-3D/3D-Pose-SDK/lib/src/envelope/coach_reply.dart:94)、[coach_reply.dart:107](E:/AII-3D/3D-Pose-SDK/lib/src/envelope/coach_reply.dart:107)|旧文本API能解析回复与卡片。|A：完全不可识别的内容不能冒充计划；B：options上限/包装/派生说明由代码处理，别要求模型承担旧UI形状。|合法多于4个选项会被旧接口拒绝；text超400字本来仅warning。|旧阶段日志按原码列，不能套用新Agent码。|
|PlanCodec卡片/块/动作字段类型、模式、整数；[plan_codec.dart:48](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:48)、[plan_codec.dart:93](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:93)、[plan_codec.dart:133](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:133)|避免损坏数据进入旧卡片。|B：模型不再填写代码能生成的结构/模式/剂量；不可恢复的持久化数据报技术错误。A仅保留动作ID/来源有效性。|由代码生成的数据若错，模型没有正确重交方案。|当前通过新builder生成；未见当前codec本身实测拒绝。|
|PlanCodec segments结构/唯一segment ID/对应剂量/hold/label/rhythm；[plan_codec.dart:168](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:168)、[plan_codec.dart:188](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:188)、[plan_codec.dart:210](E:/AII-3D/3D-Pose-SDK/lib/src/plan/plan_codec.dart:210)；[segment_rhythm.dart:1](E:/AII-3D/3D-Pose-SDK/lib/src/plan/segment_rhythm.dart:1)|确保分段完整，不把缺失片段当一整组。|B：代码生成ID/剂量/节奏结构并保持总训练量；A：分段动作目录/用户条件仍核。损坏存档不能悄悄丢段。|目录/存档不完整时可能无解，应技术错误或明确不可用。|当前六组未用segments交付；离线分段样本不算实测拒绝。|
|并发busy；[coach_agent.dart:807](E:/AII-3D/3D-Pose-SDK/lib/src/agent/coach_agent.dart:807)、[coach_session.dart:227](E:/AII-3D/3D-Pose-SDK/lib/src/tools/coach_session.dart:227)|同会话一次只提交一轮。|B：交互排队/取消由代码处理，保留并发互斥，不记模型拒绝。|忙碌由代码调度解决。|未观测模型失败计数。|
|请求鉴权/网络/429/5xx/截断、重试用尽、上下文超长；[agent_resilience.dart:51](E:/AII-3D/3D-Pose-SDK/lib/src/agent/agent_resilience.dart:51)、[coach_agent.dart:1380](E:/AII-3D/3D-Pose-SDK/lib/src/agent/coach_agent.dart:1380)|协议与网络失败不能伪造成成功答案。|B：限次重试/压缩/明确中止；不能通过改目标、删安全或删必要reasoning凑成功。|服务不可用时模型无解；单独技术失败率。|早期404、429及错误标签详见证据附表；不算模型选错动作。|
|整轮超时；[coach_agent.dart:1274](E:/AII-3D/3D-Pose-SDK/lib/src/agent/coach_agent.dart:1274)、记忆timeout [coach_agent.dart:1799](E:/AII-3D/3D-Pose-SDK/lib/src/agent/coach_agent.dart:1799)|有限时间内释放资源和取消等待。|B：保留技术保护；正确的分阶段超时/恢复由代码处理，不提高训练拒绝数。|超时不能靠重交同规则恢复已耗尽时间。|早期阶段一有预算/超时失败；有效标签最近六run没有单次超过40秒，不代表永不超时。|
|步数/重交次数上限；[coach_agent.dart:1209](E:/AII-3D/3D-Pose-SDK/lib/src/agent/coach_agent.dart:1209)、[coach_agent.dart:1946](E:/AII-3D/3D-Pose-SDK/lib/src/agent/coach_agent.dart:1946)、[coach_agent.dart:2071](E:/AII-3D/3D-Pose-SDK/lib/src/agent/coach_agent.dart:2071)|避免无限工具循环。|B：技术上限保留；优先消除由B/C假拒绝消耗的步骤，不能用降低保护门槛冒充提效。|规则无解时一定耗尽；不是训练方案本身错误证据。|历史未出卡/步数耗尽见附表，不能当成又一条底层规则拒绝。|
|重复工具/无新信息空转 `AgentStalled`；[coach_agent.dart:1974](E:/AII-3D/3D-Pose-SDK/lib/src/agent/coach_agent.dart:1974)|检测循环没有进展。|B：保留，但fresh应反映语义进展，不因版本号增加就当有新信息；候选足够时代码完成派生工作。|候选/规则冲突时模型没有下一步可走。|D− R1/R2各1次 `no_new_info`；不属于ok:false回执。|
|评测≤12,288B首包/恢复、≤40,960B请求、每轮调用预算及模型标签；[eval_coach_agent_v2.dart:517]|验收预算/链路版本，不是训练建议校验。|B：由代码降低重复上下文/派生调用；错误模型标签本次样本作废。不能减少用户目标或隐藏安全信息凑预算。|预算可能因无解规则反复回执超限；本轮R4即例。|Q R4第二轮10调用、最大44,333B，两项失败；不是两次额外工具拒绝。|

## 六、四项重点裁决建议

### 1. plan_balance：拆开三件事，不能再作为一个硬拒绝

现状依据见[plan_checker.dart:450](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_checker.dart:450)。重复ID按每块统计；连续部位按**全计划**条目串接，主部位仅取第一个编码，空主部位还会清零；拮抗组按全计划标签集合统计。这不是实际训练负荷模型：不考虑轮/组、剂量、休息、主次部位覆盖，也不根据用户是专项还是全身来决定是否适用。

建议：重复条目归B，在阶段内合并剂量，跨热身/收尾的合理复用不误删；需要的顺序和分组归B，只对主体尝试稳定排序，保留模型选的不同动作；连续同部位阈值和拮抗覆盖归C，由目标判断是否适用，给一次warning。只练肩时，不应为了交替而强塞腿部动作或删掉已推荐的肩部动作；全身目标时可提示分布不足，但不能把一个固定的“3”当安全界线。若未来某项排序属于真实执行安全限制，应独立标成A并提供依据，不能藏在balance里面。

“只统计主体”是必要的去误计，但**不足以解决**四个连续肩部主体动作的问题；“从目标推导适用性”和“不再硬拦单部位连续”才是本例要点。把`maxSameMuscleInRow`调大也只是换一个会遇到的上限，不是根治。

### 2. 热身/放松purpose：目录标签不足以一票否决

现状只接受`stretch/mobility/breath/activation`，Q R3把`purpose.core`的死虫式放warmup因此拒绝一次。低剂量核心动作能否作为激活、某个力量动作能否用极轻剂量准备，属于结合目标和剂量的判断；目录没有activation标注不等于危险。

建议C一次warning，说明标签与阶段不典型；B可在不改所选动作集合的前提下整理阶段、生成剂量；明确伤痛/场景/器械不合仍A。代码不能仅为了凑purpose枚举强换动作。`plan_structure`的热身/收尾必有阈值应一起处理：分组由代码负责，“该目标是否需要完整三段”作为适用性建议，避免“pureStretch仅等于单独stretch”这样的字面豁免制造新冲突。

### 3. 推荐最少数量：取消硬min3，不用少量优质动作换一次拒绝

当前body推荐是`max(1,min(3,合规seen命中数量))`，purpose-only推荐与计划动作门禁仍是profile.minActions=3。前者0候选仍要求1；池内有3项也不代表用户要3项；后者只有1–2个真正合法动作时无解。A R2的一项内收推荐因此被拒，模型随后补了两个偏离目标的动作才过旧门禁，这正是数量门禁反向损害质量。

建议：A保留每个推荐的目标/来源/资格与**有内容的卡片**；B去重；C数量不足或可能搜索过窄时提示一次。模型选1个就可以交付1个，不强迫凑数。0个合规项不是空卡成功，而是正常说明当前能力/条件不足，必要时询问用户是否愿意调整条件，不再让show_actions进入“至少1个”的循环。

### 4. fitLog减轮：已经由代码执行，要统一计算而非再加门禁

当前[plan_builder.dart:568](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:568)的配时过程：先改主体轮数（1–4），再改主体sets，再改主体reps/seconds，最后改非主体计时剂量；先贪心，再逐个main块尝试不同轮数，**不保证多块全局最优**。它按时间误差保留较优方案，不删动作，也不考虑balance。初始误差≤10%直接返回，搜索时以5%为停止目标，最终误差>10%仍报`duration_unfit`，Checker又报`plan_duration`；旧Validator的时长偏差本来只是warning。

Q R3 v1主体2→1轮并减组，拒绝原因却是死虫式热身purpose；Q R4七个草稿版本都已经有代码自动减轮，v1是3→2→1，v2–v7仍有某main块2→1，前六版被balance拒绝。**减轮和balance计数无关**，不能再要求模型改轮解决balance。

建议B合成一个配时器：先算给定动作集合、有效执行范围下的可达区间，再求确定性剂量/轮数/顺序/分组；区分“证明不可达”和“启发式没找到”。不能静默改变用户明确目标、时长或动作集合；若用户明确要求的组/轮数和时长冲突，说明冲突并询问取舍。回执结构化给`blockId/actionId/field/before/after/原因/前后估时/误差`，替代多块下无法区分的“主体轮数由2调至1”。模型只需读最终执行结果并解释，不再抄计算后的轮数重交。

### 已经自动化、应合并而非再次升级为拒绝的行为

|当前行为 / 位置|现状与处理建议|真实历史|
|---|---|---|
|首份operation忽略；[plan_builder.dart:138](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:138)|已是B note，保留，与操作默认统一。|D+ R1 1、D− R4 2次旧no_delivered_plan已不应再发生。|
|剂量模式改目录默认、sets/work/rest/rounds clamp；[plan_builder.dart:289](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:289)、[plan_builder.dart:328](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:328)、[plan_builder.dart:351](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:351)、[plan_builder.dart:395](E:/AII-3D/3D-Pose-SDK/lib/src/agent/plan_builder.dart:395)|已是B，将所有派生剂量集中于配时器。|有效六run旧invalid_dose_mode共6，不应换个校验入口重新打回。|
|note截断；[output_gate.dart:324](E:/AII-3D/3D-Pose-SDK/lib/src/agent/output_gate.dart:324)|当前超长不拒绝；B保留显示处理，不再增加语言长度门禁。|S− R6 note共3次：2可见回执+1末次terminal证据。|
|低来源kept；[session_params.dart:427](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:427)|已是B；可提前跳过不采用字段的无意义值校验。|A R1 2次旧拒绝；Q 0次。|
|非环境物exclude忽略；[session_params.dart:351](E:/AII-3D/3D-Pose-SDK/lib/src/agent/session_params.dart:351)|已是B；与环境物/来源统一解析。|Q没有此类拒绝；此前错误写大量exclude是模型语义错误，非一次次器械门禁拒绝。|
|理解/参数/动作/规划/核对自动节点；[task_tool_handler.dart:95](E:/AII-3D/3D-Pose-SDK/lib/src/agent/task_tool_handler.dart:95)、[params_tool_handler.dart:16](E:/AII-3D/3D-Pose-SDK/lib/src/agent/params_tool_handler.dart:16)、[draft_tool_handler.dart:74](E:/AII-3D/3D-Pose-SDK/lib/src/agent/draft_tool_handler.dart:74)|已是B；保留真实事件，合并冗余状态门禁，不让模型为check单独调用。|D/S wrong_node累计可见5次，A/Q该码已无。|
|推荐转计划默认reuse；[agent_task.dart:136](E:/AII-3D/3D-Pose-SDK/lib/src/agent/agent_task.dart:136)|已按状态复用；后续只继承真实确认与已选结果，不为reuse漏字段重做前三步。|旧D− R4流程额外请求，不应通过修改评测脚本遮盖。|

## 七、真实评测证据及计数范围

### 批次去重和有效性

下面目录均在`E:/AII-3D/worktree-preserved/`。每个目录链接到原始`summary.json`；逐例可读同目录`R1.json`、`R1-transcript.md`等。review内复制的on/off/evaluation不再计数；dry、压力重放、源码重建等离线结果排除。共11个唯一真实批次、567条历史请求记录（含404/429失败），其中统一`deepseek-flash`六批为396条。

|代号|原始批次 / summary|版本或源码指纹依据|请求记录数|标签/验收有效性|
|---|---|---|---:|---|
|E1|[stage1-R5-214732](E:/AII-3D/worktree-preserved/coach-agent-real-stage1-20261027-214732-R5/summary.json)|未提交实现，source `f5a01d4…`|1|404，没有模型响应；链路故障。|
|E2|[stage1-sdk-default-R5-214958](E:/AII-3D/worktree-preserved/coach-agent-real-stage1-20261027-214958-sdk-default-R5/summary.json)|同上|4|旧`deepseek-v4-1-flash-261017`；不是当前同模型样本。|
|E3|[stage1-215105](E:/AII-3D/worktree-preserved/coach-agent-real-stage1-20261027-215105-R1-R4-R6/summary.json)|同上；实际含R1/R2/R3/R4/R6|46|三种标签混用，另20次429；仅历史行为证据。|
|E4|[stage1-full6-220522](E:/AII-3D/worktree-preserved/coach-agent-real-stage1-20261027-220522-full6/summary.json)|当时HEAD为规格`348464266c`，实际未提交source `24bc491…`已事后还原，不能冒认候选be113d5|100|旧三种混标签；不与当前同模型算通过率。|
|V0|[v2-step11-218f7f0-run1](E:/AII-3D/worktree-preserved/coach-agent-v2-real-step11-20261028-218f7f0-run1/summary.json)|产品`218f7f01…`；source `76ab856d…`|20|请求deepseek-v4-flash-0731，响应混标签，5例因标签不符停止；作废质量样本。|
|D+|[direct-on](E:/AII-3D/worktree-preserved/coach-v2-direct-deepseek-flash-20261028-on/summary.json)|`1c4990ed…`，产品基线4d3f1cc，source `3a0c527…`|83|全部deepseek-flash。|
|D−|[direct-off](E:/AII-3D/worktree-preserved/coach-v2-direct-deepseek-flash-20261028-off/summary.json)|同上|83|全部deepseek-flash。|
|S+|[search-fix-on](E:/AII-3D/worktree-preserved/coach-v2-search-fix-deepseek-flash-20261028-on/summary.json)|`ca72bc330…`，source `b188fbc…`|70|全部deepseek-flash。|
|S−|[search-fix-off](E:/AII-3D/worktree-preserved/coach-v2-search-fix-deepseek-flash-20261028-off/summary.json)|同上|86|全部deepseek-flash。|
|A|[auto-nodes-off](E:/AII-3D/worktree-preserved/coach-v2-auto-nodes-deepseek-flash-20261028-off/summary.json)|`13bbc84c…`，source `911ffce…`|39|全部deepseek-flash，有逐工具UsageRecord。|
|Q|[quality-off](E:/AII-3D/worktree-preserved/coach-v2-quality-deepseek-flash-20261028-off/summary.json)|`31f0f18c…`，source `10f41d5…`|35|全部deepseek-flash，有逐工具UsageRecord。|

版本补证：[首次直连VERSION](E:/AII-3D/worktree-preserved/coach-v2-direct-deepseek-flash-20261028-review/VERSION.json)、[ca72bc3 VERSION](E:/AII-3D/worktree-preserved/coach-v2-search-fix-deepseek-flash-20261028-review/VERSION.json)、[阶段一实际源码版本](E:/AII-3D/worktree-preserved/coach-agent-expert-review-20261027/TESTED-RUNTIME-VERSION.json)。不把规格HEAD或事后候选commit冒充当时运行源码。

### 拒绝计数方法

A/Q的`turns[].toolUsageRecords[].issueCodes`可精确数实际失败批次：**A=6，Q=7**。失败批次只执行第一个失败工具，`skipped_after_error`及交付后的skipped不算新增拒绝。较早批次没有完整此账本，只能按tool_call_id去重可见失败回执；同一回执在多个请求重复出现仅计一次。

`plan_check_failed`是包装码；一次回执可能含多个子错误，按具体规则可注明同时命中，但不能把wrapper和子错误相加。终止error/标签作废/429/未出卡/fitLog自动修改均不能直接当作新增工具拒绝。旧批次末次回滚可能使失败回执不可见，所以未观测不等于历史从未发生。

|批次|案例|次数 / 具体场景|
|---|---|---|
|E1|R5|0个可见门禁回执，1次404。|
|E2|R5|0个可见失败回执；旧模型链路。|
|E3|R1|可见2：show_plan invalid_json 1、missing_plan_description 1；另有末次plan_not_checked terminal issue无回执，不混为精确计数。|
|E3|R2|0个可见门禁失败；429重试5次。|
|E3|R3/R4/R6|各0个可见门禁失败；各429重试5次。|
|E4|R1|可见3：check_plan context_conflict 1（12.2对15分钟）、missing_plan_description 1、narrative_minutes 1。|
|E4|R2/R5|各0个可见失败。|
|E4|R3|可见5：invalid_search 1（purpose.warmup未知）、check_plan wrong_node 1、context_conflict 1（17.1对20分钟）、narrative_minutes 1、plan_not_checked 1。|
|E4|R4|可见5：invalid_search 1；equipment 2（中文“哑铃”与dumbbell冲突，一次兼有schema）；missing_plan_description 2。每个装备回执含多个issue也只算一次拒绝。|
|E4|R6|可见2：narrative_equipment 2；首个同时有narrative_minutes。规则命中可列装备2/时长1，实际拒绝仍仅2。|
|V0|R1–R6|0个可见SDK门禁拒绝；R1/R2/R3/R4/R6各1次模型标签不符终止，不能写成通过。|
|D+|R1|可见1：no_delivered_plan，首份却传operation=replace_all。|
|D+|R2/R5|各0个可见失败。|
|D+|R3|可见1：invalid_ask，skipLabel。|
|D+|R4|可见3：missing_parameters 1、wrong_node 1（draft仍在actions）、plan_balance 1。|
|D+|R6|可见3：invalid_ask 1（英文form标签）、invalid_quote 1（scene非原话）、invalid_tags 1（position.seated）。|
|D−|R1/R2|各0可见失败回执，但各1次AgentStalled(no_new_info)，无交付。|
|D−|R3|可见1：use_action_search，read旧目录路径。|
|D−|R4|可见5：missing_parameters 1（scene/minutes）、plan_balance 2、no_delivered_plan 2。|
|D−|R5|0可见失败。|
|D−|R6|可见2：invalid_arguments 2，tags数组写成JSON字符串。|
|S+|R1|可见3：invalid_ask 1（skipLabel）、use_action_search 1、invalid_dose_mode 1（h-hip-gate传seconds）。|
|S+|R2/R5/R6|各0可见失败。|
|S+|R3|可见2：invalid_dose_mode 2（骨盆画圈传seconds、猫牛传reps）。|
|S+|R4|可见4：wrong_node 3、plan_balance 1。|
|S−|R1|可见5：invalid_source 1（当时derived scene不允许）、missing_parameters 1（minutes）、invalid_dose_mode 3。|
|S−|R2|可见2：wrong_task_type 1（无recommend任务）、unseen_actions 1。|
|S−|R3/R5|各0可见失败。|
|S−|R4|可见4：missing_parameters 1、wrong_node 1、plan_balance 2。|
|S−|R6|可见3：invalid_json 1、invalid_note 2；另1次invalid_note由末次terminal issues证明，无回执。note应报2回执+1末次证据。|
|A|R1|精确2：source_conflict 2，default覆盖derived场景、preselect覆盖user目标。|
|A|R2|精确1：invalid_picks，只给1个内收动作，硬要求3。|
|A|R3/R5/R6|精确各0。|
|A|R4|精确3：invalid_picks 1（2个动作）、missing_parameters 1、plan_balance 1。|
|Q|R1/R2/R5/R6|精确各0。|
|Q|R3|精确1：plan_check_failed→plan_block_purpose，死虫式warmup只有purpose.core。|
|Q|R4|精确6：全部plan_check_failed→plan_balance；longest先4、后5、最后4，删前平举才通过。|

六个统一标签批次共有**52个可见失败回执**：D+8、D−8、S+9、S−14、A6、Q7；另有S− R6末次note失败1次终止证据。52不是完整历史精确总数。

|规则 / 同一错误只算一次|统一标签六批可见次数|场景|
|---|---:|---|
|plan_balance|13|全部R4：D+1、D−2、S+1、S−2、A1、Q6。|
|plan_block_purpose|1|Q R3死虫式热身。|
|missing_parameters|5|D+ R4、D− R4、S− R1/R4、A R4各1。|
|wrong_node|5|D+ R4 1，S+ R4 3，S− R4 1。|
|invalid_dose_mode（现已自动改）|6|S+ R1 1/R3 2，S− R1 3。|
|invalid_ask|3|D+ R3/R6各1，S+ R1 1。|
|no_delivered_plan（首份operation现已忽略）|3|D+ R1 1，D− R4 2。|
|invalid_picks最少数量|2|A R2/R4各1。|
|source_conflict低来源覆盖|2|A R1。|
|invalid_arguments|2|D− R6 tags字符串。|
|use_action_search|2|D− R3、S+ R1。|
|invalid_note|2可见+1末次证据|S− R6，现超长已截断。|
|invalid_quote / invalid_tags / invalid_source / wrong_task_type / unseen_actions / invalid_json|各1|依次D+ R6、D+ R6、S− R1、S− R2、S− R2、S− R6。|

plan_check_failed包装共14次=balance13+block_purpose1，不再与这些子项相加。E3/E4旧版的`missing_plan_description / narrative_minutes / narrative_equipment / context_conflict`保留为历史证据；不能把已经删除或改为派生数据的旧门禁列成31f0f18当前仍会触发的同名规则。

### Q R4的七版草稿证据

见[Q/R4.json](E:/AII-3D/worktree-preserved/coach-v2-quality-deepseek-flash-20261028-off/R4.json)、[Q/R4完整对话](E:/AII-3D/worktree-preserved/coach-v2-quality-deepseek-flash-20261028-off/R4-transcript.md)、[拒绝摘要](E:/AII-3D/worktree-preserved/coach-v2-quality-deepseek-flash-20261028-review/R4-quality-findings.json)。v1–v6拒绝都在balance，重复ID和missingPairs为空，不是伤痛/器械/目标偏离；v7减少主体动作后通过。第一轮3调用、第二轮10调用，第二轮最大请求44,333B；预算失败是后果，不应以删动作或扩大预算来掩盖规则问题。

### 盘点不能替代的能力边界

1. 宿主`extraRules`是外部函数，仓库只枚举其接入点，无法盘点未提供函数体；应由宿主逐项报A/B/C和适用性。
2. 范围外、红旗症状、不诊断等还存在于系统提示/技能，不是一个能由“ok=true”证明医学适用性的确定性检查。未知目录安全字段当前为warning，不能写成已验证安全。
3. 当前自由note没有自然语言数字/器材语义核对；卡片字段一致、实际环境物stamp不等于note每一句都正确。建议有数字/器材事实的说明由代码引用卡片数据，保留模型的非数值解释；不要恢复已经导致误拒的关键词/正则叙述门禁。

## 八、可删除或合并的规则（待审阅后再实施）

可删除把节点顺序、picks落盘、当前plan_id、check已调用当成独立模型义务的门槛，合为一次真实资格校验后的代码推进；剂量单位、配时、默认值、分组/排序、卡片声明和note显示修正合到同一确定性处理链。推荐硬min3、通用连续部位上限、固定拮抗覆盖、热身/放松purpose白名单的硬拒绝改为按目标的一次warning，不再层层包装重置。来源、scope/目录/seen、器械/场景、伤痛与真实目标底线共享一套依据，保留最终并发安全复核；不要再用新增模型外意图规则来弥补这些流程冲突。
