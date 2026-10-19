# Changelog

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
