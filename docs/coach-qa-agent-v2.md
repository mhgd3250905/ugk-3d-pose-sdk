# AI 问答推荐 Agent v2（原型，可选启用）

状态：原型，分支 `codex/coach-qa-agent-v2`。与现有 `CoachAgent` 并存，没删旧代码，App 都没改。
入口：`package:ugk_coach/ugk_coach_qa_v2.dart` → `CoachQaAgent`。

> 和 `docs/coach-agent-spec.md` 有几处偏离（不反问场地、不走 source/quote 流程、工具从 14 个减到 4 个）。这是用户已批准的 v2 设计，要不要进主线由用户决定。

## 解决 v1 的五个问题

| v1 问题 | v2 做法 |
|---|---|
| 8 个场景第一轮反问「在哪练」 | 场景按 用户原话 → 本会话/注入记忆 → App 默认（profile.defaultScene）取。不反问，只回传 `assumption`（如「按居家徒手」），再给一个「换场地」chip。`ask_user` 只用于安全问题 |
| 14 个工具，一次推荐要调 2–7 次模型 | 4 个工具：`respond` / `build_plan` / `find_actions` / `ask_user`。代码先按原话预检索 8 个候选放进用户消息，模型大多一次调用就能作答 |
| search_actions 取标签交集、不排序，整串子串匹配 | `QaFinder`：先硬过滤（场景、器械、躺地、冲击、避开部位、难度上限），再打分排序（主动肌 / 被拉伸肌、目的、sessionRole、难度贴合、名称分词 bigram、点名器械），并去掉同组变体，每个结果带一句代码生成的理由 |
| 备注是套话，知识题和安全题不附动作 | prompt 禁止套话，代码再兜底删掉「全程不憋气…」这类尾巴；每张动作卡一句「为什么适合你」；知识题、安全题按规则附动作 |
| 「第二个 / 太难了 / 这几个」不绑定上次的内容 | `CoachQaState` 记住上次展示的卡片和计划。换第 N 个、换简单点/难一点、就用这几个都由代码按 ai-tags 的 alternatives / regressions / progressions 处理，**不调模型** |

## 组成

- `qa_action.dart`：`QaAction`。有 Pose-Hub `catalog/ai-tags`（`pose-hub-ai-tags@1`）标签就用标签，按 id 对不上的回退到目录字段；`QaActionIndex.taggedCount` 统计覆盖率。
- `qa_lexicon.dart`：中文口语同义词典（瘦肚子→有氧+腹部，翘臀→臀大肌/臀中肌，膝盖疼→避开膝，西裤/不躺→不躺地，楼下/安静→最多低冲击，睡前/跑后/晨起→拉伸目标……），外加场景词、器械词、「只有 X」、时长、跟进句识别。
- `qa_finder.dart`：硬过滤和打分。负重器械不拿环境物替代（哑铃不能用水瓶顶），垫子可以用毛巾顶。候选少于 4 个时只放宽「目的」，不放宽硬过滤。
- `qa_plan_builder.dart`：模型只给主训练 id 和分钟数，代码排 热身(2) / 主训 / 收操(2)（≥9 分钟才排，纯拉伸不加热身），调组数、增删动作，直到 `PlanDuration` 估算落在目标 ±12% 内。产出现有的 `TrainingPlan`。
- `coach_qa_agent.dart`：`CoachQaAgent.send(text, language:)` → `CoachQaReply{kind, text, cards[{id,name,why}], chips, assumption, plan, planSeconds, question, llmCalls, elapsed, usage}`。

## 动作标签

- 来源：Pose-Hub `codex/ai-action-tags` @5d17c24 `catalog/ai-tags/actions/*.json`（ai-draft，未经人工审核）。只读，没改 Pose-Hub。
- 测试动作包 app-test-pack-r1：211 个动作里 **209 个命中**新标签，没命中的 `h-sleeper-stretch`、`scapular-C` 走目录回退。
- SDK 里不打包标签：调用方把 `Map<id, json>` 传给 `aiTags:`。打包方式和标签审核状态待定。

## 评测（真实模型，只跑一遍）

`SIM_AGENT=v2 AI_TAGS_DIR=…/catalog/ai-tags/actions dart run tool/sim_user.dart scenarios.json out.jsonl`

- 配置和 v1 一样：SmartFit profile、deepseek-flash（思考开启）、中转 ai.uuugk.win。场景是同样的 20 个，另加 3 个多轮跟进（换第二个、肩痛后排计划、换场地）。
- 打分标准：切题、无多余反问、具体、安全、速度，每项 1–5 分，v1 和 v2 都由同一人按同一标准打。

| | v1 | v2 |
|---|---|---|
| 平均分（5 项均值） | 3.26 | 4.52 |
| 反问场地/时长 | 9 轮（8 个场景） | 0 |
| 平均每轮模型调用 | 3.38 | 0.92（需要调模型的轮 1.05） |
| 每轮耗时 平均 / 中位 / 最大 | 10.4 / 7.9 / 26.5 秒 | 5.7 / 5.5 / 14.4 秒 |
| 推荐 / 计划 | 2–7 次调用 | 都是 1 次，平均 6.7 / 6.1 秒；代码跟进 0 次调用，<0.2 秒 |

v2 最差的三个场景：
1. S09「想练背 → 太难了」：退阶把热身和收操也换了，有两个换成了提踵（不是练背的动作），时长从 15 分钟涨到 20 分钟。评测后已修复：只换主训练；退阶和替换必须和原动作练同一处；换完按原时长重排。修复只经过离线测试，没有重跑真实模型。
2. S17「只有弹力带练手臂」：14.4 秒，2 次调用（模型多查了一次 find_actions）。另外它说库里没有二头动作：确实没有弹力带弯举，但也没提可以换别的器械。
3. S18「随便练练」：一次调用就花了 14.4 秒（模型思考时间长），内容没问题。

评测后又改了一处（同样没重跑）：点名了部位但一处都没练到的动作，排序时重罚。这样肩痛问练胸、办公室练核心时，不会再混进提踵、消防栓这类凑数的动作。

## 待定

- v2 是否接到 SmartFit 测试包：要决定 App 怎么拿到 ai-tags（打进 SDK assets，或者 App 自己带）。
- 「第二个动作」在计划里按整体顺序数，热身也算在内（v1 也是这样）。要不要改成只数主训练？
- 思考模式：耗时多半花在模型思考上（单次 3–14 秒）。v2 的推理负担已经很轻，可以试 `thinking: disabled` 来压到 5 秒以内，但要再跑一次评测。
- 和 coach-agent-spec 的偏离（见开头）要用户确认。
