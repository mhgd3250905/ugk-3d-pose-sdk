# ugk_coach · 三 App 共用的 AI 训练助理 SDK

仓库 `mhgd3250905/ugk-3d-pose-sdk`，根目录是纯 Dart 包 **`ugk_coach`**，`packages/ugk_trainer` 是 Flutter 训练执行包（PR #1 已合入）。

给 **FlareLab（托马斯训练助手）/ HipLab（开胯训练助手）/ SmartFit（智能健身助手）** 用的同一套助理内核：AI 只从 Pose-Hub 动作目录里挑动作，输出统一的 **TrainingPlan v1**，SDK 负责校验，不合格时回传错误重交，达到对应入口上限后回落到 App 自己的模板；每次模型调用都记账。各 App 只需提供 **profile（侧重/范围）+ 自己的 UI**。

- 纯 Dart，不依赖 Flutter（Web 也能用）；`dart:io` 的部分（文件缓存、JSONL 记账）单独在 `package:ugk_coach/ugk_coach_io.dart`。
- 一个动作 id = 定义 + 封面 + 示范视频 + 建模源（Pose-Hub spec）+ 语音：`assistant.resolve(id)` 带出整套素材。
- 当前开发版本为 **0.3.3**，基于 main `b26e4fd`，待开哥批准合入。377 项 SDK 测试、分析 0 问题及 SmartFit 最终真实六条通过：计划均 1 步、28.6–36.3 秒，要领问答 1 步、25.4 秒，无回落、编造 id 为 0、记忆隔离通过。Agent 内联作用域内的紧凑索引和三条技能快路径，常规计划直接提交门禁；见[基线拆解](docs/coach-033-baseline-analysis-2026-10-21.md)、[前后对比与验收状态](docs/coach-033-speed-2026-10-21.md)及[项目维护台账](docs/project-ledger.md)。

## 维护与事实来源

[项目维护台账](docs/project-ledger.md)是当前维护状态、PR 合并、验证证据和未决事项的统一记录入口。包版本以 [pubspec.yaml](pubspec.yaml) 为准；版本变更历史见 [CHANGELOG.md](CHANGELOG.md)；当前 Agent 设计见 [docs/agent-plan.md](docs/agent-plan.md)。[docs/design.md](docs/design.md) 记录 0.1.2 的历史设计取舍。

## 架构（0.1 旧接口）

下图与目录说明保留 0.1 `CoachAssistant` 的结构；当前推荐入口是下文的 0.3 `CoachAgent`。

```
                         ┌────────────── App（Flutter）──────────────┐
                         │  UI（对话、套路卡、播放器）  profile.json   │
                         │  FallbackPlanner（模板）     Preflight（安全话术）│
                         └──────────────┬────────────────────────────┘
                                        │ ask(text, context, conversation, cancel)
┌───────────────────────────────────────▼─────────────────────────────────────────┐
│ assistant/  CoachAssistant ── preflight → 拼提示词 → 调模型 → 解析 → 校验 ─┐       │
│                                    ▲            │ 不合格（带错误清单）      │       │
│                                    └── 重写 1 次 ┘ 仍不合格 / 断网 / 超时 → 回落 │
│             CoachConversation（历史，App 持久化）  HistoryPolicy（裁剪）           │
├──────────────┬──────────────┬──────────────┬──────────────┬─────────────────────┤
│ prompt/      │ envelope/    │ plan/        │ llm/         │ usage/              │
│ kernel.md    │ JSON 提取容错 │ TrainingPlan │ LlmClient    │ UsageRecord         │
│ + profile    │ reply/ask/   │ v1 编解码     │ OpenAI 兼容   │ Memory / JSONL /    │
│ + 目录表      │ plan 信封     │ PlanValidator│ Fake（测试）  │ 回调 / 多路 sink     │
│ 覆盖/追加/版本 │              │ 时长估算      │ 取消/超时/重试 │ 单价 → 估算花费      │
├──────────────┴──────────────┴──────┬───────┴──────────────┴─────────────────────┤
│ catalog/  Catalog（pose-hub-catalog@1）  CatalogRepository（内置/缓存/远端+sha256） │
│           AssetResolver（id → 封面/视频/spec/语音）  DrillPackAdapter（读 SmartFit 小包）│
├────────────────────────────────────┴──────────────────────────────────────────────┤
│ config/  LlmConfig（地址/模型/max_tokens/温度/超时/重试/单价）  AuthProvider（key / 中转）│
│ profile/ CoachProfile（范围、侧重、场所规则、剂量上限、提示词版本与变量）                 │
└───────────────────────────────────────────────────────────────────────────────────┘
        ▲ 动作目录 catalog.json（Pose-Hub 发布，带版本）          ▲ 模型：DeepSeek @ OpenCSG（上线经中转 Worker）
```

```
lib/
  ugk_coach.dart            核心入口（纯 Dart）
  ugk_coach_io.dart         dart:io 适配：FileCatalogCache、JsonlUsageSink
  src/config  catalog  profile  plan  envelope  prompt  llm  usage  assistant  io
prompts/       kernel.md（系统提示词内核 v2，SDK 与评测共用这一份）context.md rewrite.md
profiles/      flarelab.json hiplab.json smartfit.json（SDK 与评测共用）
schema/        catalog / catalog-manifest / coach-profile / coach-reply 的 JSON Schema
tool/          embed_prompts.dart  make_manifest.dart  packs_to_catalog.dart
example/       quickstart.dart（离线）  smoke.dart（真实调用）
docs/          design.md（决策与取舍）  smoke-2026-10-20.md
eval/          评测（原 ai-coach-eval，subtree 并入）：tools/validate.py eval.py build_prompt.py export_parity.py、cases/、results/、README（设计说明与评测结果）
test/fixtures/ pose-hub-catalog.json（目录快照）golden/（提示词金样）parity.json（校验对照）packs/
```

## 0.3 Agent 版接入（推荐）

`CoachAgent` 与 `CoachSession` 用法相同（构造参数、`send` / `reset`、`CoachTurnResult`）。系统提示词内含按 profile 筛选的紧凑动作索引与排课、讲要领、展示三条技能快路径；动作详情按需读取，常规计划直接 `show_plan`，`check_plan` 留作可选自检，最终门禁始终执行。明确点名的要领问答可自动预载少量详情，省去模型请求文件的一次往返。设计、文件地图、事件与记忆见 [docs/agent-plan.md](docs/agent-plan.md)。

```dart
final agent = CoachAgent(
  client: client,
  catalog: () => catalogRepo.current,
  profile: hiplabProfile,
  fallback: (r) => SessionFallbackReply('先按模板给你排一套', plan: myTemplateFor(r.context)),
  memoryStore: myMemoryStore,   // App 实现 UserMemoryStore；enableUserMemory 可随时切
);
agent.events.listen((e) => showProgress(e));   // reading / checking / done …
final r = await agent.send(userText, context: CoachContext(scene: 'home'));
```

默认整轮时限为 360s，单步请求时限为 60s，30s 发出 `slow` 事件；60k 上下文估算不计推理协议字段，只压缩较早的 read / ls 工具结果。0.3.3 沿用这些参数；单步失败保留已有工具进度后重试，记忆关闭时重试也过滤记忆相关推理。`badResponse` 提供结构、长度及 SHA-256 诊断，供区分 SSE、空正文、结构错误等情况，不记录响应正文或推理原文。

普通排课首请求只提供直接交付路径，门禁拒绝后才开放 `check_plan`；用户明确要求检查/自检或 profile 配置了 App 专属技能时可从首请求使用。`AgentTools.build(includeCheckPlan:)` 默认 true，直接构造工具的调用方行为兼容。

`remember` / `forget` 等待 `myMemoryStore.save` 成功后才返回 `ok:true`；App 实现必须在保存完成后才完成 Future，失败应抛出异常，SDK 会返回工具错误。已确认保存的操作在后续取消时保留；pending 保存被取消 / reset 后不会回写缓存或会话，底层迟到写入由串行队列补偿。每条 assistant 请求消息均带 `reasoning_content`，没有推理时为空串。

## 0.2 工具版接入（降级）

0.2 起入口是 `CoachSession`：模型每次回复只能是「纯文字」或「文字 + 一个工具」，两个工具：

| 工具 | 用途 | 参数 |
|---|---|---|
| `show_actions` | 看动作（演示卡） | `items`: 1–6 个 `{actionId, note?}`，不带剂量，不重复 |
| `show_plan` | 开练 / 改计划 | 完整 TrainingPlan v1（同一动作全计划只出现一次，多做用 sets） |

门禁 `ToolGate` **只判不修**：不合格就把全部错误（位置、错误码、期望、实际、改法）作为 tool 结果回给模型重交，
最多重交 2 次；仍不过、网络错误或回复里出现提示词暗号 → 回落 App 模板。卡片只接受门禁产出的
`ValidatedPlan` / `ValidatedActions`（私有构造，App 造不出来；模板计划也要经 `admitTemplate`）。

```dart
import 'package:ugk_coach/ugk_coach.dart';

// --dart-define=UGK_APP_KEY=...（值不进仓库）
const appKey = String.fromEnvironment('UGK_APP_KEY');

final client = OpenAiCompatibleClient(
  config: LlmConfig.ugkWorker, // Base URL https://api.uuugk.win/v1，模型 deepseek-v4-flash-0731
  auth: UgkWorkerAuth(
    appKey: appKey,                          // 请求头 X-App-Key
    deviceId: () => deviceIdStore.getOrCreateUuid(), // 请求头 X-Device-Id：每设备首次生成 UUID，持久保存一直用
  ),                                         // 不带 Authorization（中转站 token 在 Worker 里）
);

final session = CoachSession(            // 一个 App 一个会话；关弹窗不清空
  client: client,
  catalog: () => catalogRepo.current,
  profile: hiplabProfile,
  fallback: (r) => SessionFallbackReply('先按模板给你排一套', plan: myTemplateFor(r.context)),
);

final r = await session.send(userText, context: CoachContext(scene: 'home', avoid: {'膝'}));
switch (r.status) {
  case TurnStatus.ok || TurnStatus.fallback:
    showText(r.text);
    if (r.plan != null) showPlanCard(r.plan!);        // ValidatedPlan
    if (r.actions != null) showActionCards(r.actions!); // ValidatedActions
  case TurnStatus.limitReached: askUserToReset();     // 会话到硬上限（默认 20 轮 / 4 万字符），session.reset()
  case TurnStatus.inputTooLong: tellUserTooLong();    // 默认 500 字
  case TurnStatus.busy: ignore();                     // 上一轮还在进行：本次被拒绝，未调模型
  case TurnStatus.cancelled || TurnStatus.error: showTemplateEntry();
}
```

- 并发策略：**拒绝，不排队**。同一会话一次只处理一轮，进行中再 `send` 立即返回 `TurnStatus.busy`（不调模型、不占轮数）；`isFull` 的硬上限把进行中的一轮也计入。App 应在等待回复时禁用发送按钮。
- `reset()` 让进行中的旧轮作废（会话世代 +1）：旧轮的模型响应或异步回落晚到时返回 `cancelled`，不写历史、不计轮数。取消（`CancelToken`）在模型返回后、异步回落返回后都会复查，取消后历史与轮数不变。
- 门禁以本轮 `CoachContext` 明确给出的 `level` / `minutes` 为准：计划的 `level` / `targetMinutes` 不一致报 `context_conflict`（E_CONTEXT）打回重交，不替模型改值。暗号检测覆盖参数 JSON 解码后的全部字符串（防 `\u0055…` 转义绕过）。

- 自定义请求头：`LlmConfig.headers`（静态）或自定义 `AuthProvider`（动态）。直连 New API（ai.uuugk.win）时 Cloudflare 会拦 Python 默认 UA，Dart 默认 UA 实测可过。
- 提示词：内核 v3（`prompts/kernel_v3.md`）= 身份与范围 / 防破甲 / 回答方式 / 何时用哪个工具 / 参数规则 / 被打回时 / 多轮修改 / App 配置（profile 生成）/ 用户上下文。本轮条件放用户消息前缀，系统消息不变以命中前缀缓存。暗号默认 `defaultPromptCanary`，可用 `ToolPromptBuilder(canary: ...)` 换。
- 0.1 的 `CoachAssistant.ask`（JSON 信封）保留一版，标 deprecated，HipLab / 托马斯可不跟着升；后续版本移除。

## 快速上手（0.1 旧接口，deprecated）

```yaml
# pubspec.yaml
dependencies:
  ugk_coach:
    git: {url: https://github.com/mhgd3250905/ugk-3d-pose-sdk.git, ref: main}
```

```dart
import 'package:ugk_coach/ugk_coach.dart';

final repo = CatalogRepository(bundled: BundledCatalogSource(() => rootBundle.loadString('assets/coach/catalog.json')));
await repo.load();

final assistant = CoachAssistant(
  client: OpenAiCompatibleClient(
    config: LlmConfig.deepSeekOpenCsg.copyWith(baseUrl: 'https://coach-relay.example.workers.dev/v1'),
    auth: RelayAuth(appToken: () async => appToken),
  ),
  catalog: () => repo.current,                 // 热更新后自动用新目录
  profile: CoachProfile.fromJson(jsonDecode(await rootBundle.loadString('assets/coach/hiplab.json'))),
  fallback: FallbackFn((r) => myTemplateReply(r)),   // 断网 / 两次不合格时
  usage: myUsageSink,
);

final conv = CoachConversation();             // App 自己存：conv.toJson()
final r = await assistant.ask('睡前想开开胯，10 分钟', context: const CoachContext(scene: 'home', avoid: {'膝'}), conversation: conv);
switch (r.reply?.kind) {
  case ReplyKind.plan:  showPlanCard(r.reply!.plan!);      // TrainingPlan v1，可保存、可直接练
  case ReplyKind.ask:   showQuestion(r.reply!.text, r.reply!.options);
  case ReplyKind.reply: showText(r.reply!.text);
  case null:            showError(r.outcome);              // cancelled / 没配回落时的 error
}
```

离线跑一遍完整流程（假模型故意先错后对）：`dart run example/quickstart.dart`。

## 配置

| 项 | 位置 | 说明 |
|---|---|---|
| 地址 / 模型 | `LlmConfig.baseUrl` `model` | OpenAI 兼容，填到 `/v1`。预设 `LlmConfig.deepSeekOpenCsg`：`https://opencsg.com/aigateway/v1`、`deepseek-v4.1-flash-1017` |
| max_tokens | `maxTokens`（预设 6000） | **推理模型的思考也算 completion**：冒烟一次 completion 3102，其中推理 2453。太小会 `finish_reason=length` → 回落 `truncated` |
| 温度 | `temperature`（null = 不传） | 有的推理模型不接受温度；评测用 0.3 |
| 超时 / 重试 | `timeout`（单次尝试，预设 90s）`maxRetries` `retryBackoff` | 网络、超时、429、5xx 重试，429 遵守 Retry-After；401/403、截断不重试 |
| JSON 模式 | `jsonMode`（默认开） | 发 `response_format: json_object` |
| 其他参数 | `extraBody` | 原样并入请求体（`top_p` 等） |
| 单价 | `pricing: Pricing(inputPerMillion, cachedInputPerMillion, outputPerMillion, currency)` | 每百万 token；用于调用记录里的估算花费，以账单为准。SDK 不内置单价 |
| key 来源 | `AuthProvider` | `ApiKeyAuth(key)` / `ApiKeyAuth.lazy(读安全存储)`：App 内配置（开发、内测）；**`RelayAuth`：上线推荐**，key 只在中转 Worker；`NoAuth`：上游代理注入（沙盒） |

### 为什么上线要走中转

key 打进安装包可被反编译取出、无法单独吊销；中转 Worker 持有 key，App 只带可吊销的 App 令牌，还能在 Worker 上做限流、按设备配额、统一记账。最小 Cloudflare Worker：

```js
export default {
  async fetch(req, env) {
    if (req.headers.get('X-App-Token') !== env.APP_TOKEN) return new Response('forbidden', {status: 403});
    const url = new URL(req.url);
    if (!url.pathname.endsWith('/chat/completions')) return new Response('not found', {status: 404});
    const body = await req.json();
    body.model = env.MODEL;                            // 由服务端决定模型与上限，App 改不了
    body.max_tokens = Math.min(body.max_tokens ?? 6000, 8000);
    return fetch(`${env.UPSTREAM}/chat/completions`, {
      method: 'POST',
      headers: {'Content-Type': 'application/json', Authorization: `Bearer ${env.API_KEY}`},
      body: JSON.stringify(body),
    });
  },
};
```

## 动作目录

格式是 Pose-Hub 统一目录 **`pose-hub-catalog` format 1**（`schema/catalog.schema.json`，与 3D-Pose-Hub `feat/ai-coach-catalog` 分支 809f36a 同一份）。每个 drill 的定义字段与 SmartFit drill-pack format 1 同名同义，另有 `doseRange / purpose / apps / tags / assets / completeness`。SDK 宽容读取：未知字段忽略；缺必填字段的动作跳过并记入 `catalog.problems`；`formatVersion ≠ 1` 拒绝。

```dart
final repo = CatalogRepository(
  bundled: BundledCatalogSource(() => rootBundle.loadString('assets/coach/catalog.json')),
  cache: FileCatalogCache(File('${(await getApplicationSupportDirectory()).path}/coach/catalog.json')),
  remote: RemoteCatalogSource(manifestUrl: Uri.parse('https://cdn.example.com/pose-hub/catalog/manifest.json')),
);
await repo.load();                 // 缓存与内置取较新的一份；缓存坏了丢掉
final res = await repo.refresh();  // 启动后 / 每天一次：updated | upToDate | rejected | failed | noRemote
repo.updates.listen((c) => revalidateSavedPlans(c));
```

- **远端更新**：先拉小清单 `manifest.json`（`schema/catalog-manifest.schema.json`），版本比当前新才下载目录；**大小、sha256、目录内版本号、能否解析** 全部通过才写缓存并切换，否则 `rejected` 并保持原目录。清单用 `dart run tool/make_manifest.dart catalog.json > manifest.json` 生成。
- **随目录版本走**：助理每次 `ask` 读 `repo.current`，提示词里的目录表、校验器、调用记录的 `catalogVersion` / `promptHash` 都跟着变。已存计划在目录更新后可用 `assistant.validate(plan)` 复核（动作被下架会报 `unknown_exercise`）。
- **素材解析**：`assistant.resolve('glute-max-A', variant: 'dark')` → `ResolvedDrill { cover, video, spec, voice{lineId → 路径+时长}, voiceKeys, missing }`。按 profile 的 `assetApps`（缺省 `[profileId, 'pose-hub']`）挑来源；`baseByApp: {'pose-hub': 'https://cdn/…/'}` 给远端素材加前缀。`AssetResolver(...).missingReport(drills)` 列缺素材。
- 统一目录之外，`DrillPackAdapter` / `tool/packs_to_catalog.dart` 可直接把 SmartFit 的 `assets/packs` 转成同格式目录。

## 输出规范与校验（0.1 JSON 信封接口）

模型每轮只输出一个 JSON 对象（`schema/coach-reply.schema.json`）：

```json
{"kind":"plan","text":"一两句说明","plan":{"schemaVersion":1,"title":"…","summary":"…","goal":"relax","scene":"home",
 "equipment":["mat"],"level":1,"targetMinutes":10,"avoid":["膝"],"blocks":[{"id":"b1","name":"热身","type":"warmup",
 "rounds":1,"restBetweenRoundsSeconds":0,"items":[{"exerciseId":"n-windshield","mode":"reps","sets":1,"reps":8,"perSide":false,"restSeconds":10}]}],
 "notes":[],"safetyNotes":[]}}
{"kind":"ask","text":"在家还是办公室？","options":["在家","办公室"]}
{"kind":"reply","text":"……"}
```

**解析容错**（`extractJsonObject`）：去 BOM、`<think>` 段、markdown 围栏、前后说明文字、末尾多余逗号；直接给计划本体按 `kind=plan` 包装；`seconds` 规范成 `workSeconds`。只修无歧义的，其余结构问题逐条带路径报出（`plan.blocks[1].items[0].mode`）。

**校验规则**（`PlanValidator`，与评测脚本 `eval/tools/validate.py` 逐条对齐；`test/parity_test.dart` 读 `eval/tools/export_parity.py` 导出的 32 例——自测 24 例 + 8 条 mode / 场所补充样例——逐例比对错误分类与每类条数）：

| 分类 | 错误（触发重写 → 回落） |
|---|---|
| E_JSON | 不是 JSON；kind / text / options 不合规 |
| E_SCHEMA | 结构、类型、枚举；title/summary 缺失；level 非 1–3；equipment 不是器械 id |
| E_UNKNOWN | 动作 id 不在目录（编造） |
| E_SCOPE | 在目录但不在本 App profile 范围 |
| E_DOSE | mode 与目录剂量单位不符；sets 1–6、reps 1–30、workSeconds 10–120、restSeconds 0–180、rounds 1–6、轮间休息 0–300；targetMinutes 超 profile；动作条目过多 |
| E_SIDE | perSide ≠ 动作 unilateral |
| E_AVOID | 动作「注意」部位命中保护部位（计划 avoid ∪ 本轮 avoid） |
| E_EQUIP | 需要用户没有的器械（App 不知道器械时信任计划声明的 equipment） |
| E_SCENE | 本 App 不支持该场所；计划场所 ≠ 本轮场所；动作 scenes 不被接受；办公室着地体位 |
| E_ORDER | 热身块排在放松块之后 |

警告（不判失败）：超出动作推荐 doseRange（`enforceDrillDoseRange: true` 可改为错误）、goal 不在本 App 侧重、块顺序不理想、难度高于用户 1 级以上、估算时长偏离 ±40%、块内重复、plan.equipment 漏写、avoid 词表外。App 可用 `extraRules` 追加规则。

**流程**：通过 → `model`；不合格 → 把输出和 `- E_DOSE …` 错误清单回传，重写 `maxRewrites`（默认 1）次 → 通过则 `rewritten`；仍不合格 → `fallback(invalidOutput)`；断网 / 超时 / 限流 / 鉴权 / 服务端错误 / 截断 → 直接 `fallback(对应原因)`，不重写；取消 → `cancelled`（不回落、不改会话）；没配回落 → `error`。模型计划会被规范化：`source=ai`、分配 id、保护部位并上本轮条件、场所/等级/时长以本轮条件为准。

## 提示词（0.1 JSON 信封接口）

`prompts/kernel.md` 是系统提示词内核 v2（评测脚本 `eval/tools/build_prompt.py` 直接读这一份；`test/prompt_test.dart` 断言 SDK 渲染结果与它的产物 `test/fixtures/golden/*.md` 逐字节一致）。v2 相对 v1：`kind → plan → text` 顺序、kind=plan 时 plan 必填、思考简短、text ≤80 字、plan.equipment 含场所默认器械（评测第 2 轮把 v1 失败的 2 条修好，24/24）。系统消息 = 内核 + profile（侧重、规则、场所规则）+ 按 profile 筛过的紧凑目录表；**不含本轮条件**，所以同一 App 连续调用共享前缀，命中前缀缓存（冒烟：4520 个 prompt token 里 4096 命中缓存）。本轮条件（App 已知的场所/器械/保护部位/时长…）作为一行前缀放进用户消息，什么都不知道时只发原话。

- 段：`intro / rules / composition / focus / output / catalog`（按 `# ` 标题切分）。
- 覆盖：`PromptBuilder(overrides: PromptOverrides(version: 'hl2', replace: {'composition': '…'}, append: [PromptSection('tone', '…')], vars: {...}))`；追加段默认插在目录段之前；缺变量直接抛 `PromptRenderException`。
- 版本：`promptVersion = kernel-v<内核修订号>-<内核哈希>.c<本轮模板哈希>.r<重写模板哈希>[+覆盖版本]@<profile>-<profile.promptVersion>`（当前 `kernel-v2-694a82ed…`；修订号是 `kernelRevision`，改内核语义时手动加一），加 `promptHash`（系统消息实际内容哈希），都进调用记录。
- 改 md 后 `dart run tool/embed_prompts.dart`（测试会检查是否同步）。

## 调用记录

每次模型调用（重写算第二次）一条 `UsageRecord`：`at`、`appId`、`profileId`、`model`、`promptVersion`、`promptHash`、`catalogVersion`、`attempt`、`promptTokens / completionTokens / reasoningTokens / cachedTokens`、`latencyMs`、`httpAttempts`、`outcome`（passed / rewritten / rejected / error / cancelled）、`turnOutcome`（model / rewritten / fallback / error / cancelled）、`errorKind`、`issueCodes`、`cost`、`currency`。被截断的调用也计 token（已计费）。

Sink 可插拔：`MemoryUsageSink`（含 `summary`：调用数、轮数、token、花费、各走向轮数、按模型分）、`JsonlUsageSink`（io）、`CallbackUsageSink`（上报自己的服务）、`MultiUsageSink`。sink 抛错不影响对话。

## 各 App 接入（0.1 接口示例）

三个 App 的差异只在 profile + UI（`profiles/*.json`，SDK 与 `eval/` 共用，唯一来源）。

**SmartFit（智能健身助手，全库 142 个）**
```dart
final assistant = CoachAssistant(
  client: client, catalog: () => repo.current, profile: smartfitProfile,
  preflight: (t, c, conv) => safetyScript.match(t),            // 现有 safety_script：胸痛、头晕等直接回复，不花钱
  fallback: FallbackFn((r) async {                              // 断网/不合格：现有 RuleChatEngine + TemplatePlanGenerator
    final reply = await ruleEngine.reply(r.userText, chatState);
    return toCoachReply(reply);                                 // TrainingPlan JSON 两边相同：PlanCodec().decode(plan.toJson())
  }),
);
```
SmartFit 的 `TrainingPlan.fromJson` 能直接读 SDK 产出的计划（同一 v1 JSON）；`AiPlanGenerator` 占位改成调用 `assistant.ask` 即可。素材：`assetApps: ['smartfit']`，`resolve(id).voice['cue1']` 即 drill-pack 的 `voice/zh/cue1.m4a`。

**HipLab（开胯训练助手，`apps: [hiplab]` 46 个）**
```dart
final r = assistant.resolve(id, variant: isDark ? 'dark' : 'light');  // 明暗两套封面/视频
playKeys(r!.voiceKeys);                                               // HipLab 语音是 key 风格：drill.<id> / point.<id>
```
profile 只开 home / office；office 不着地。回落用现有模板 A–F/M（`profile.vars.fallbackTemplates`）。

**FlareLab（托马斯训练助手，`apps: [flarelab]` 51 个）**
profile 开 home / gym；A 徒手 / B 家用 / C 健身房三档由提示词侧重和场所规则决定。目前 FlareLab 动作缺语音（`missingReport` 可查），UI 用字幕即可。

### Flutter 适配要点
- 资源：`BundledCatalogSource(() => rootBundle.loadString(...))`，profile 同理；目录随包放一份，保证首启离线可用。
- 缓存与记账：`FileCatalogCache` / `JsonlUsageSink` + `path_provider`。Web 端不要导入 `ugk_coach_io.dart`，自己实现 `CatalogCache`（如 shared_preferences）。
- 取消：用户点「停止」→ `cancelToken.cancel()`，HTTP 请求真正中止。
- 推理模型一次 30 秒上下（冒烟 31 s）：UI 显示「正在排计划…」并可取消；不建议做流式（输出是一个 JSON，半截无法展示）。

## 训练执行（0.1 历史接口草案）

训练执行已由 `packages/ugk_trainer` 承接，见 [CHANGELOG 的 ugk_trainer 0.1.0 记录](CHANGELOG.md)。以下是根包 0.1 阶段的接口草案，保留作设计背景，实际接口以训练包为准。

计划 → 时间线 → 播放，由 SDK 提供与 UI 无关的部分，App 只接音频/视频播放器：

```dart
/// 计划展开为逐秒可调度的事件（准备、开始、每次计数、换侧、组间休息、过渡、完成）。
abstract interface class SessionTimelineBuilder {
  SessionTimeline build(TrainingPlan plan, Catalog catalog, {String language = 'zh'});
}
class SessionTimeline { final List<TimelineEvent> events; final Duration total; }
sealed class TimelineEvent { Duration get at; }       // Prepare / WorkStart / RepTick / SideSwitch / Rest / Transition / Finish
class VoiceCue extends TimelineEvent { final List<String> clips; }   // 台词由目录内音频拼成：name/intro/cueN + 公共包 n.N / u.* / p.*
/// 运行器：暂停/继续/跳过/上一项；只发事件，不碰播放器。
abstract interface class SessionRunner { Stream<TimelineEvent> get events; void pause(); void resume(); void skip(); void back(); }
```
口径沿用 SmartFit `SessionBuilder` 与 `PlanDuration`（准备 10 s、换侧 5 s、过渡 15 s、reps × repSeconds），语音时长用目录里的解码后 `ms` 排布，保证不重叠；播放链路沿用 SmartFit/HipLab 的 `VoiceLineController`。

## 开发

```bash
dart pub get
dart analyze           # 本次集成的最终结果见交付记录
dart test              # 根包离线验证；历史 source 与验收边界见项目维护台账
dart run tool/embed_prompts.dart        # 改了 prompts/*.md 之后
dart run example/quickstart.dart        # 离线演示
dart run example/smoke.dart             # 真实调用（花钱，按需跑一次）
```

与评测同步（评测已并入 `eval/`，profile / 内核 / 目录快照只有仓库里这一份）：

```bash
python3 eval/tools/validate.py --selftest                     # Python 校验器自测 24/24
python3 eval/tools/export_parity.py                           # 改了 validate.py 或目录后重导 test/fixtures/parity.json
for p in flarelab hiplab smartfit; do python3 eval/tools/build_prompt.py --profile profiles/$p.json --out test/fixtures/golden/$p.md; done
dart run tool/embed_prompts.dart                              # 改了 prompts/*.md 后
python3 eval/tools/eval.py dry                                # 评测流程空跑（不调模型）；真实评测见 eval/README.md
```

目录更新：用 Pose-Hub `catalog/catalog.json` 覆盖 `test/fixtures/pose-hub-catalog.json`、`catalog/catalog.schema.json` 覆盖 `schema/catalog.schema.json`，再跑上面几步；`dart test` 会指出任何不一致。

当前维护状态见[项目维护台账](docs/project-ledger.md)，Agent 设计见 [docs/agent-plan.md](docs/agent-plan.md)，0.1.2 历史设计取舍见 [docs/design.md](docs/design.md)，版本变化见 [CHANGELOG.md](CHANGELOG.md)。
