# 设计决策与取舍（ugk_coach 0.1.0）

> 2026-10-20 · Hark 在开哥全权授权下拍板。标「待定」的列在文末，等开哥确认。

## 1. 范围

**做**：配置与鉴权抽象、动作目录（读取 / 远端热更新 / 素材解析）、TrainingPlan v1 编解码与校验、提示词模板、OpenAI 兼容客户端、调用记录、编排（重写 + 回落 + 取消）。
**不做**：UI、模板生成器（由各 App 实现 `FallbackPlanner`）、训练执行（README 只规划接口）、流式输出。

## 2. 与已有契约的关系（沿用，不另起炉灶）

| 契约 | 来源 | SDK 怎么用 |
|---|---|---|
| drill-pack format 1 | SmartFit `docs/drill-pack-spec.md` | 目录里每个 drill 的定义字段同名同义；`DrillPackAdapter` 可直接读小包 |
| pose-hub-catalog format 1 | 3D-Pose-Hub `feat/ai-coach-catalog` 809f36a | SDK 的目录模型就是它；`schema/catalog.schema.json` 原样带入 |
| TrainingPlan v1 | SmartFit `docs/plan-schema.md` | 输出 JSON 完全一致，SmartFit 的 `TrainingPlan.fromJson` 能直接读；校验规则是它的超集 |
| profile / 内核提示词 / 校验器 | ai-coach-eval d0c5cab | profile JSON 即 `CoachProfile`；内核即 `prompts/kernel.md`；`PlanValidator` 与 `validate.py` 逐条对齐 |

**为什么强求和评测逐字节一致**：评测花的是真钱，结论（首轮通过率、编造率、token）只有在线上发的提示词、用的校验器与评测完全一样时才成立。所以：
- `test/prompt_test.dart`：三个 App 的系统提示词 == `build_prompt.py` 产物（金样）。
- `test/parity_test.dart`：`validate.py --selftest` 的 24 个用例，错误分类（E_*）一致。
- `PlanDuration` 与 `estimate_seconds` 同口径（合法样例都是 10.7 分钟）。

原先 SDK 自己写了一版内核和更严的校验（动作 doseRange 判错、主训练排在放松后判错），看到评测已在用另一套后改为对齐：doseRange 超出、其他块顺序问题降为**警告**；只有「热身在放松后」判错。需要更严时 `PlanValidator(enforceDrillDoseRange: true)` 或 `extraRules`。

## 3. 关键决策

1. **纯 Dart 核心 + io 适配分离**。三个 App 都是 Flutter，但核心不 import Flutter / `dart:io`，Web 和命令行测试都能跑；`FileCatalogCache`、`JsonlUsageSink` 放 `ugk_coach_io.dart`。资源读取用回调注入（`rootBundle.loadString`），不需要 Flutter 适配包。
2. **目录用函数注入：`catalog: () => repo.current`**。助理每轮现取，热更新零接线；同时也能塞固定目录做测试。
3. **远端更新只信校验过的字节**：清单（小）→ 版本比较 → 下载 → 大小 + sha256 + 目录内版本 + 可解析，全过才写缓存、切换、发 `updates`。任何一步失败保留原目录。启动时缓存与内置取版本较新的（App 升级带了更新的内置目录时不会被旧缓存盖住），缓存坏了丢掉。
4. **系统消息不含本轮条件**。本轮条件进用户消息首行。代价：模型要多读一行；收益：同一 App 所有调用共享系统前缀，DeepSeek 前缀缓存命中（冒烟 4520 prompt token 中 4096 命中，缓存价约一折）。也因此**不按场所/器械预筛目录表**（会破坏前缀），靠校验器兜底。
5. **App 不知道的条件就不说**。`CoachContext.equipment == null` 表示 App 不知道（用户可能在话里说了「我有哑铃」），校验信任计划声明的 equipment；`{}` 表示明确没有。什么都不知道时只发用户原话——与评测输入一致。
6. **规范化优先于重写**（重写要再付一次钱）：缺 id/source 自动补；`seconds` 当 `workSeconds`；直接给计划本体就包上信封；场所/等级/时长以本轮条件为准；保护部位并上本轮条件。凡有歧义的（mode 写错、perSide 错、id 不存在）不猜，交给重写。
7. **重写一次，然后回落**。重写消息附上模型自己的上次输出和 `- E_xxx 说明` 清单（与评测 `format_feedback` 同文）。网络 / 超时 / 限流 / 鉴权 / 服务端 / 截断错误**不重写**直接回落：重写解决不了这些，还会再花一次钱或再等一次。截断（`finish_reason=length`）的 token 照样记账。
8. **取消是一等公民**。`CancelToken` 直接作为 `http.AbortableRequest` 的 abortTrigger，HTTP 真正中止；取消不回落、不写会话，记一条 cancelled。超时也走同一中止通道。
9. **调用记录一次调用一条，结果写在轮末**。每条同时带 `outcome`（这次调用怎样）和 `turnOutcome`（这一轮最后怎样），核算花费与统计通过率都不用再 join。sink 出错吞掉，记账永远不影响对话。单价 SDK 不内置（DeepSeek 经 OpenCSG 的价目没有可靠来源），由 App 传 `Pricing`。
10. **preflight 钩子**。安全话术（胸痛、头晕）、本地命令（`@saved:`）在调模型之前处理：更安全、零花费、不受网络影响。SmartFit 现成的 `safety_script` 可直接挂上。
11. **历史裁剪**：最近 10 条、≤ 6000 字；只有最近一份计划保留完整 JSON（「再短一点」「换掉第 2 个」需要它），更早的压成一行 `id×剂量` 摘要；裁完以用户消息开头。
12. **提示词按 `# ` 标题切段**，App 用段名替换 / 追加；缺变量直接抛错，而不是把 `{{x}}` 发给模型。版本号含三份模板的内容哈希，改了文字不升版本也能在记录里看出来；`promptHash` 再加上目录版本的影响。
13. **问题代码分两层**：细代码（`reps_range`、`per_side` …，稳定，App 可按它定制 UI）+ 粗分类（E_DOSE …，与评测一致，用于统计和回传模型）。

## 4. 不做 / 推迟

- **流式**：输出是单个 JSON，半截无法展示；推理模型的思考过程也不该给用户看。UI 用「正在排计划…」+ 取消即可。若以后要「打字机」效果，可在 `LlmClient` 加 `stream()`，只用于 `kind=reply`。
- **多模型路由 / 自动降级到更便宜的模型**：等有线上数据再说。`LlmClient` 是接口，加一个路由实现不影响其他层。
- **SDK 内置模板生成器**：三个 App 的模板差异大（SmartFit 模板 + 规则对话、HipLab A–F/M、FlareLab 六方向），放 App 侧更合适。
- **JSON Schema 运行时校验**：Dart 侧手写结构检查（带中文路径与消息，能直接回传模型）；schema 文件作为文档和跨语言契约。

## 5. 已知限制

- 目录快照、profile、内核都来自**本地已提交但未推送**的 Pose-Hub 809f36a / ai-coach-eval d0c5cab；它们改了要同步（README「开发」一节）。
- `scene` 被规范化为本轮场所，模型若按别的场所排了动作，表现为动作级的场所/器械错误而不是计划级错误（重写信息仍然准确）。
- 时长偏离只是警告；模型可能系统性偏短（冒烟：目标 10 分钟，估算 8.7）。
- 冒烟里模型的 text 说「你没说……场地，默认居家」，而 App 其实已告知场所——内核第 3 条要求说明默认值，提示词可微调（属于评测侧）。

## 6. 待开哥拍板

见 CHANGELOG 0.1.0 末尾「待定」。
