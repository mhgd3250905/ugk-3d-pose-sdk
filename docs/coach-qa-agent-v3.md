# AI 问答 Agent v3：常规 agent + 工具验收 + SOP 引导

日期：2026-11-04。分支：codex/qa-v2-fixes（PR #12）。决定人：用户（13:59、14:28、14:34）。

## 原则

1. **模型掌舵**。每一轮由模型自己决定：先查动作库、先问、还是直接交结果。代码不判意图、不改路由、不替模型改结果。
2. **动作库 = 知识库**。模型通过 `search_actions` 查，查到什么由代码按标签确定性返回。
3. **交付 = 工具**。`ask_user`、`show_actions`、`build_plan`、`swap`、`reply` 是交付工具，每个都有脚本验收。不合格把原因原样退回模型（tool result），模型改好重交。代码绝不静默修改、补、删、重排交付内容。
4. **SOP = 引导 skill**。`coach_qa_sop.md` 只写「怎么问答、怎么用工具」，不写代码规则的复述。改后跑 `dart run tool/gen_qa_sop.dart`。
5. **代码只保留**：验收器、安全与场景准入（`QaAdmission` / `QaFinder.passes`，模型绕不过）、组数/时长配置（确定性，结果在 tool result 里告诉模型）、条件状态记录。不设工具调用次数上限：何时交付由模型判断，靠 SOP 引导（用户 14:35）。

## 对外接口不变

`CoachQaAgent` 构造参数、`send(text, language:)`、`CoachQaReply`（kind / text / cards / chips / assumption / conditions / plan / planSeconds / question / askStep / llmCalls / elapsed / usage / issues / toolTrace / steps / form / language）、`planOrderedIds` / `planMainIds`、`CoachQaState` 的持久化字段（`ugk_coach_chat/lib/src/core/qa_state.dart` 读写的部分）全部保持兼容。三个 App 不改代码。新增字段只追加，旧字段照常写（`form` 可以写模型最后一次 `set_conditions` 的参数）。

## 一轮怎么跑

```
system: SOP + 应用信息
history: 最近 8 轮（用户原话 + 上轮交付摘要）
user: [已知条件] [当前卡片/计划（带编号）] [预选候选 ≤12 个] [用户这句话]
loop（不设次数上限）:
  模型调一个工具
  信息类工具（search_actions / set_conditions）→ 返回结果，继续
  交付类工具 → 验收；不过 → 退回原因，继续；过 → 本轮结束
模型不调用任何工具而直接输出文字 → 提示「请调用工具交结果」继续；整轮超时沿用 App 现有的 turnTimeout，不在 SDK 里另设上限
```

- `toolChoice: 'auto'`，一次给全部工具。
- 首轮预选候选：代码按已知条件和上一轮焦点用 `QaFinder` 预取（不判意图，只按条件），省一次 search。
- 每次模型调用的 `extraBody` 仍是 thinking max。

## 工具与验收

| 工具 | 参数 | 验收（不过就退回原因） |
|---|---|---|
| `set_conditions` | place、place_word、equipment、equipment_known、avoid_joints、no_floor、quiet、easy、small_space、minutes、language | id 合法（场景、器械、关节都在 taxonomy 里）。记入状态，返回更新后的 [已知条件] |
| `search_actions` | muscles、stretch_muscles、types、roles、goals、patterns、position（坐/站/跪…）、exclude、limit≤12 | 参数 id 合法。返回范围内动作行（带姿势、躺地、器械、关节负担标签）；范围外的不返回 |
| `ask_user` | step（place / equipment / safety）、question、options、multi | 同一步本轮或上轮刚问过 → 退回；place 已知还问 place → 退回；非居家问器械 → 退回；选项数 place 4、equipment ≤6 |
| `show_actions` | text、items[{id, why}] 3–5 个、chips、assumption | id 必须在本轮 search 结果或预选候选里；且过准入；不重复；正文提到卡片外动作 → 退回 |
| `build_plan` | title、text、minutes、segments[{name, ids}] 或 main_ids、warmup_ids、cooldown_ids、block_names、chips、assumption | 全部 id 过准入且在已见候选里；无重复；retime（模型自报 mode=retime）时主训练集合必须等于当前计划；配时后时长偏差超出 ±12% → 退回「差多少、建议加/减几个或改组数」，不自动补删；正文提到卡片外动作 → 退回。热身收操由模型从 roles=warmup/cooldown 的搜索结果里指定，不给就没有 |
| `swap` | text、changes[{position, new_id, why}]、mode（swap/easier/harder）、chips | 编号在卡片范围内；new_id 过准入；easier 难度必须更低、harder 更高；同一处（`QaFinder.sameArea`）；其他编号不变 |
| `reply` | text、items（可空）、chips | 知识、安全、闲聊、无合格替换时用。items 同 show_actions 规则；安全危险信号已确认时 items 必须为空（由 `safety` 状态判定） |

退回文案格式统一：`不合规：<原因>。请改好后重新调用 <工具>。`

## 状态（代码记，模型读）

- 条件：place / equipment / 限制 / 来源（user / memory / default / skipped）。
- 上轮 ask 的 step（防连问）。
- 当前卡片（动作卡 ids 或计划，带全局编号，含热身收操）。
- 本轮已见候选（search 结果 + 预选）。
- 焦点（muscles / types / minutes）。

## 删除

- `fill_form` 理解步、`QaForm` 驱动的意图强转与路由覆盖（保留 `QaForm` 类型只为持久化兼容）。
- `_answer` / `_swap` 里按 intent 分支、强制沿用候选顺序、默认分钟覆盖。
- `QaPlanBuilder.build` 的自动补主训练、自动挑热身收操、自动删动作；只保留按给定动作配组数与时长、报告偏差。
- `_consistent` 事后改写步：并入各交付工具的验收。

## 测试（桩模型，`test/qa_v2/`）

每条沙盘场景一个用例，验证：工具路径、验收退回文案进入下一次请求、最终交付不被代码改动。

1. 没说地点要练某处 → ask place；同轮再问 → 退回。
2. 居家没说器械 → ask equipment；健身房问器械 → 退回。
3. 记忆有地点 → 问地点被退回。
4. 跳过问题 → 按默认条件，`conditions.placeSource=skipped`。
5. 办公室要动作 → show_actions 里放躺地动作被退回。
6. 「还有坐椅子的」→ search position=seated。
7. 15 分钟一套，只给 2 个动作 → 退回时长偏差，模型加动作后通过；代码未补。
8. 前半坐后半站 → segments 两段，顺序原样。
9. 「顺序不对」→ 重交新顺序生效。
10. 换第 N 个（含热身位）→ 只变该位。
11. 无合格替换 → reply，卡片不变。
12. easier 给了更难的 → 退回。
13. retime 换了动作 → 退回。
14. 再来一套与上一套重复 → 退回。
15. 知识题 → reply。
16. 肩痛危险信号 → reply items 非空被退回。
17. 正文提卡片外动作 → 退回。
18. 模型连续退回后改对 → 最终交付通过，退回原因都出现在后续请求里。
19. 持久化：`qa_state.dart` 存取后状态一致（含 segments 计划）。

另外 `packages/ugk_coach_chat` 全部测试通过（脚本化假模型按新工具更新）。

## 评测（交付后，真实模型）

沿用 `tool/coach/qa_v2_live_probe.dart` 的问法集，指标：该问/不该问、编号换动作、文字与卡片一致、平均调用次数与耗时（目标：平均 ≤3 次、回答轮 ≤20 秒）。
