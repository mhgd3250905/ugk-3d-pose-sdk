# AI 训练助理 · 评测（第 1 阶段：profile + 提示词 + 校验 + 评测）

> 来源：原独立仓库 ai-coach-eval（d0c5cab → 73acd1b → c60023f），以 git subtree 并入本仓库 `eval/`，历史保留。
> 并入后去重：profile、提示词内核、动作目录快照都以**仓库根**为唯一来源，评测脚本直接读它们，SDK 与评测用的是同一份。

三个 App（托马斯 FlareLab、开胯 HipLab、智能健身 SmartFit）共用一个 AI 训练助理：模型只能用 Pose-Hub 统一动作目录里的动作，按固定 JSON 输出动作 id + 剂量；App 校验通过后渲染成套路卡，可保存、可直接跟练。本目录是 Python 侧的校验器与评测，Dart 侧实现在 `lib/`（`PlanValidator`、`PromptBuilder`）。

动作目录本体在 Pose-Hub `catalog/`（分支 `feat/ai-coach-catalog`，809f36a）。

## 目录

| 路径 | 内容 |
|---|---|
| `../profiles/{flarelab,hiplab,smartfit}.json` | 每个 App 的配置（唯一来源；格式即 SDK `CoachProfile.fromJson`） |
| `../prompts/kernel.md` | 通用提示词内核 v2（唯一来源；SDK 嵌入 `lib/src/prompt/prompts.g.dart`） |
| `../test/fixtures/pose-hub-catalog.json` | Pose-Hub catalog v0.1.0 快照（142 个动作），评测默认目录；`--catalog` 可换 |
| `../schema/catalog.schema.json` | 动作目录 JSON Schema（与 Pose-Hub `catalog/catalog.schema.json` 相同） |
| `../test/fixtures/golden/*.md` | 三个 App 拼好的完整系统提示词（`build_prompt.py` 产物，SDK 金样） |
| `../test/fixtures/parity.json` | `export_parity.py` 产物：自测 24 例 + 补充规则样例与 Python 判定，Dart `test/parity_test.dart` 逐例对照 |
| `tools/validate.py` | 回复校验器（规则对齐 SmartFit `plan_validator.dart` + profile 范围检查），`--selftest` 跑 24 个手写样例 |
| `tools/build_prompt.py` | 拼提示词：内核 + profile + 按 profile 筛过的紧凑目录表 |
| `tools/export_parity.py` | 导出 Python 校验结果给 Dart 对照测试 |
| `tools/eval.py` | 评测：调用模型 → 校验 → 失败回传错误重写一次 → 统计 |
| `cases/cases.json` | 24 条用例（每个 App 8 条） |
| `results/` | 每轮原始回复（`round<N>/<用例>.a<尝试>.json`）、汇总（`round<N>.md/.json`）、调用账本 `calls.jsonl`（不含密钥）、两版内核 `kernel-v1.md` / `kernel-v2.md` |

命令都在仓库根运行：

```bash
python3 eval/tools/validate.py --selftest                       # 24/24
python3 eval/tools/export_parity.py                             # 改了 validate.py 后重导 test/fixtures/parity.json
for p in flarelab hiplab smartfit; do python3 eval/tools/build_prompt.py --profile profiles/$p.json --out test/fixtures/golden/$p.md; done
python3 eval/tools/eval.py dry                                  # 不调模型走一遍流程
```

## 1. 回复格式

模型每轮只输出一个 JSON 对象（与 SDK `EnvelopeParser` 相同）：

```jsonc
{"kind": "plan",  "plan": { TrainingPlan v1 }, "text": "一两句说明（≤80 字，只做字幕）"}
{"kind": "ask",   "text": "一个问题？", "options": ["选项1", "选项2"]}   // 信息不足，只问 1 个
{"kind": "reply", "text": "……"}                                          // 不出计划：越界、需就医等
```

`plan` 就是 SmartFit `docs/plan-schema.md` 的 TrainingPlan v1，只扩了一处：`scene` 增加 `gym`。kernel v2 要求按 `kind → plan → text` 的顺序写（见第 5 节，先写 text 时模型偶尔会忘了写 plan）。

## 2. profile

| App | 动作范围 | 动作数 | 场所 | 默认 | 侧重 |
|---|---|---:|---|---|---|
| flarelab | `select.apps=[flarelab]`（App 内有成片的 51 个，17 肌群 × A/B/C） | 51 | 居家、健身房 | 20 分钟 | 托马斯专项：承重肩/支撑臂、压缩核心、髋外展与腿；撑地前必热身手腕肩胛；教练口吻 |
| hiplab | `select.apps=[hiplab]` | 46 | 居家、办公室 | 12 分钟 | 拉伸/活动度 ≥ 六成，配 1–3 个髋部小力量；不排上肢/胸/腹；温和 |
| smartfit | 全库 | 142 | 居家、办公室、健身房 | 15 分钟 | 全身通用，注意推/拉、上/下肢平衡；库里没有的动作用最接近的替代并写 notes |

profile 字段：`id`、`appName`、`focus`（侧重，逐行进提示词）、`rules`（语气、越界处理）、`select`（白名单/标签筛选：ids / idPrefixes / apps / tags / categories，减 exclude）、`scenes`（每个场所默认器械、接受哪些动作场所、是否禁止着地体位）、`defaultScene`、`goals`、`limits.minutes`、`vars`（默认时长、默认难度、离线回落模板 id）。

## 3. 提示词 = 内核 + profile + 紧凑目录表

内核要点（`prompts/kernel.md`）：
- 只能用目录 id、逐字拷贝，禁止编造；库里没有的用最接近的替代并写进 `plan.notes`，没有替代就 `reply`。
- 严格输出信封 JSON；`ask` 只问 1 个问题、给 2–4 个选项；只要知道目标/部位/场所/时长之一就用默认值直接排。
- 安全：剧痛、麻木/放射痛、肿胀、刚受伤、术后、孕期/产后 6 个月内、头晕胸闷 → `reply` 建议就医，不出计划；一般不适 → 部位写进 `plan.avoid`，不选 `cautions` 含该部位的动作。
- 场所与器械：按 profile 的场所规则；办公室不着地；“没器械”只用徒手和场所默认器械；`plan.equipment` 列全。
- 剂量：mode 跟目录单位一致、在范围内调；硬限同 TrainingPlan v1；单侧动作 perSide=true。
- 编排：热身 → 主训练 → 放松；时长预算 ±25%（给了动作条目数参考）；肌群平衡；同块不重复；循环块写法。

目录表一行一个动作：`id|名称|类型|肌群|器械|体位|单侧|难度|场所|默认|范围|注意|用途`（体位带 `*` 的是着地体位）。拼好后的系统提示词约：flarelab 8.0k 字 / hiplab 7.0k 字 / smartfit 14.7k 字（实测输入 4.5k / 4.5k / 9.5k token）。

## 4. 校验器

`eval/tools/validate.py`，规则对齐 SmartFit `lib/domain/plan_validator.dart`，并加了 AI 专用检查：

| 规则 | plan_validator.dart | validate.py |
|---|---|---|
| schemaVersion=1、至少一个块、块不为空 | ✓ | ✓（另查 title/summary/goal/scene/level/targetMinutes 的类型与枚举） |
| exerciseId 在目录 | ✓ | ✓ `E_UNKNOWN`，并计入“编造 id” |
| 动作在本 App 范围 | — | ✓ `E_SCOPE` |
| sets 1–6、reps 1–30、workSeconds 10–120、rest 0–180、rounds 1–6 | ✓ | ✓ `E_DOSE`（另查轮间休息 0–300、targetMinutes 在 profile 范围） |
| mode 与动作剂量单位一致 | — | ✓ `E_DOSE`（防止计时动作被写成计次，执行层数不了拍） |
| perSide = unilateral | ✓ | ✓ `E_SIDE` |
| 保护部位（计划 avoid ∪ 请求 avoid）命中 cautions | ✓ | ✓ `E_AVOID` |
| 器械 ⊆ 用户可用（场所默认 + 用户所说；健身房全有） | ✓ | ✓ `E_EQUIP` |
| 办公室不着地；动作场所匹配（健身房也接受居家动作） | 只查着地 | ✓ `E_SCENE` |
| 热身块不在放松块之后 | ✓ | ✓ `E_ORDER` |
| 剂量超出动作 doseRange、估算时长偏离 >40%、块内重复、plan.equipment 漏写 | — | 警告（不判失败） |

失败时 `format_feedback()` 把错误逐条回传给模型重写一次（输出被截断时额外提示“少想一点、输出紧凑 JSON”）；重写仍失败，App 回落到模板（见第 7 节）。

离线自测：`python3 eval/tools/validate.py --selftest`（24/24 通过），`python3 eval/tools/eval.py dry`（不调模型走一遍流程）。

## 5. 评测结果（DeepSeek `deepseek-v4.1-flash-1017`，OpenAI 兼容，`response_format=json_object`，temperature 0.3）

用例：每个 App 8 条，含常规、健身房、指定器械、办公室无器械、疼痛部位、不存在的动作（风车分解、波比跳、髋外展机/史密斯）、越界（开胯 App 练胸、托马斯 App 办公室）、红旗（术后、孕期、腿麻）、模糊请求（“练练”“开胯”“想动一动”）、5 分钟超短。

| 指标 | 第 1 轮（kernel v1，24 条全跑） | 第 2 轮（kernel v2，只重跑 2 条失败用例） |
|---|---|---|
| 一次通过率 | 21/24（87.5%） | 2/2 |
| 重写后通过 | 22/24 | — |
| 全部用例最终通过 | 22/24 | **24/24** |
| 意图/越界处理正确 | 22/24（失败的 2 条是无计划，不是处理错） | **24/24** |
| 编造 id | 0 | 0 |
| 越界 id（在目录但不在 App 范围） | 0 | 0 |

- 失败原因只有两类：① `kind=plan` 却只写了 text 没写 plan（F3、H5，推理较长时出现；重写一次仍复现）；② 推理吃满 `max_tokens=4000` 被截断（H3，改 6000 后重写通过）。kernel v2 改成 `kind → plan → text` 顺序、要求思考简短、text ≤80 字后，F3、H5 一次通过。
- 越界处理：开胯 App 练胸 → 说明范围并提议髋部方案；风车 → 说明库里没有分解动作、不编；托马斯 App 办公室 → 说明不覆盖；三个红旗全部 `reply` 建议就医；波比跳 → 用库内动作代替并写 notes；三条模糊请求两条追问、“开胯”按默认直接排（两者都算对）。
- 耗时与 token（单次调用平均）：出计划 35.8 秒 / 10.3k token（输入 7.0k、推理 2.6k）；追问 3.4 秒 / 7.8k；不出计划的回答 6.6 秒 / 6.0k。
- 调用账本（`eval/results/calls.jsonl`）：**评测计费调用 29 次、255,740 token**；另有 4 次连通/限流排查小调用（约 2.3k token，估算）和 1 次被命令超时打断的调用（可能已计费，token 未知）；5 次 429 限流（网关 TPM，不计费）。合计约 34 次、约 25.8 万 token。
- 说明：第 1 轮前 14 次调用用 `max_tokens=4000`，之后 6000。网关 TPM 很低（与 SDK 冒烟测试共用时容易 429），评测串行跑。没有重复跑同一用例做稳定性测试，24/24 是单次结果，不代表稳定通过率。

复现：
```bash
python3 eval/tools/eval.py call --round 3 --attempt 1 --cases F1,H3 --gap 20   # 首次生成（串行）
python3 eval/tools/eval.py call --round 3 --attempt 2 --cases F1,H3            # 只对失败的回传错误重写
python3 eval/tools/eval.py summary --round 3                                   # 汇总（未重跑的用例沿用上一轮）
```

## 6. SDK 分层建议（ugk_coach）

“一个动作”是最小单位：定义 + 封面 + 视频 + spec + 语音，SDK 给一个 id 就能带出整套。

1. **动作目录与素材解析**（`catalog/`）：读 Pose-Hub `catalog.json`（App 内置一份 + 按 tag 拉新版，比 `version`），`DrillSelector` 按 profile 取范围；`AssetResolver` 按“本 App → Pose-Hub 发布版本 → 其他 App”顺序把 id 解析成 cover/video/语音文件；drill-pack@1 是一个动作的落地格式（SmartFit 已有 93 个包，HipLab action-kit 做适配）。
2. **TrainingPlan schema 与校验**（`plan/`）：TrainingPlan v1 编解码（宽容读已存计划 / 严格读模型输出）、`PlanValidator`（规则同本目录 `validate.py`，Python 版用来跑评测、Dart 版跑在 App 里，两边用同一批样例做一致性测试）。
3. **AI 提示词拼装与模型调用**（`prompt/`、`llm/`、`envelope/`）：内核 + profile + 紧凑目录表；OpenAI 兼容客户端（DeepSeek）；信封解析；“生成 → 校验 → 回传错误重写一次 → 回落模板”的编排；记录 token/耗时。
4. **训练执行**（`session/`）：把计划展开成时间线：准备 → 每组工作（计时或计次，计次按视频 repSeconds 数拍）→ 单侧换侧（5 秒）→ 组间休息 → 动作间过渡（15 秒，预告下一个）→ 轮间休息；语音时间线用动作包台词（name/intro/cue/side_switch/rest/finish）+ 公共包数字/单位/口令拼，按实测 ms 排队避免重叠。参考 SmartFit `lib/domain/session.dart`、`lib/voice/session_script.dart`、`session_runner.dart`，HipLab `lib/hip/voice/session_script.dart`、`session_engine.dart`、`hip_session.dart`。
5. **各 App 只带 profile 和 UI**：App 提供 `profile.json`（范围、侧重、语气、场所、默认值、回落模板）、套路卡/跟练页的 UI、离线模板；目录、校验、提示词、模型调用、执行引擎都来自 SDK。

## 7. Dart 侧接入建议

- **共用包结构**：`ugk_coach`（纯 Dart：catalog / plan / prompt / llm / envelope / session）+ `ugk_coach_flutter`（素材加载、视频播放、just_audio 语音队列）。App 只依赖这两个包和自己的 `assets/coach/profile.json`。
- **接口位置**：SmartFit 已有接缝 `lib/domain/plan_generator.dart` 的 `PlanGenerator` / `AiPlanGenerator` 占位，用 SDK 实现 `AiPlanGenerator.generate()`；结果走同一个 `PlanValidator`。
- **离线回落**：`CoachAssistant` 增加 `fallback` 参数（`PlanGenerator`），在三种情况调用：无网络/超时、模型两次都没过校验、模型返回 `reply` 但用户点了“仍然给我排”。SmartFit 回落 `TemplatePlanGenerator`；HipLab 回落 `hip-content.json` 的 routines（A–F、M）；FlareLab 回落 6 个方向组合（warmup/support/core/legs/side/flare × A/B/C）。profile 的 `vars.fallbackTemplates` 列出可用模板 id。
- **SmartFit 需先做的改动**：`Equipment` 枚举遇到不认识的器械会回落成 `none`（`Equipment.byName`），接全库前要改为保留原 id 或拒绝该动作；`scene` 增加 `gym`；7 个动作的 `unilateral` 要与目录同步（见疑点 2）；49 个 FlareLab 动作在 SmartFit 内没有素材包，要么 SDK 按 id 远程拉取，要么先补 drill-pack。

## 8. 需要开哥拍板

1. **App 范围是否只限 App 内已有成片**：现在 flarelab 只用 App 内 51 个（`t-seated-straddle-lift-1leg` 这类托马斯专项不收）；smartfit 用全库 142 个，其中 49 个 SmartFit 内没有素材。要不要等 SDK 能远程拉素材后再放开？
2. **7 个动作改成单侧**：glute-max-A、h-band-pallof、h-supine-twist、n-seated-ir-drop、n-seated-knee-lift、s-9090、t-seated-straddle-lift-1leg（依据 HipLab sided 与 FlareLab 处方）。同意的话 SmartFit 包要同步 `unilateral` 和 `side_switch` 台词。
3. **FlareLab 49 个动作的手标标签**（类型/器械/体位/单侧/难度/剂量/注意部位/替代）是按处方文案判断的，未经专业审核，需要过目（审阅表在 Pose-Hub `catalog/review/catalog-review.md`）。
4. **剂量折算**：forearms-A（4 方向）、scapular-A（Y/T/W）记成“每组含多个方向”；forearms-C 按距离改成每侧 30 秒。可以接受，还是要给 TrainingPlan 加多段动作？
5. **模型成本与限流**：出计划平均约 36 秒、1 万 token/次；网关 TPM 低，多人同时用会 429。上线前要确认额度，或者换非推理模型/关推理以降时延。
