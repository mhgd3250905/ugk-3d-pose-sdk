# Coach 显式动作范围

范围是 `ugk_coach` 的可选配置；不传 `scopeManifest` 时保留旧接入行为。本批不创建 Chat 模块，不迁移 App 或修改 pin。SF 名单按 **219 授权 / 211 可规划**定稿；HipLab **45**、托马斯 **51** 仍为候选，尚未生成正式签核 manifest。

## 三处真实边界

| 边界 | 做法与理由 |
| --- | --- |
| 目录 / 工具暴露 | 检索、详情、提示目录和候选使用显式名单、完整训练语义与 App profile 的交集，避免给模型推荐范围外动作。 |
| 计划准入 | 出卡，以及跨 App 的 focus、restore、开练入口，检查计划实际 parent、segment、replacedFrom 动作 ID，避免旧计划或导入数据成为范围外训练入口。 |
| 素材打包 | 沿用第 1 批 runtime 与白名单素材闭包工具，只打包名单内动作的封面、视频、kit、命名语音等引用，避免名单外素材进入 App。 |

这些检查保留原有安全、剂量、器械、场景及卡片 / 执行双时长规则。素材闭包由打包工具负责，范围模块不逐轮检查素材路径或任意历史文本。

## Manifest 与受限目录

`CoachActionScopeManifest.fromCatalogBytes` 接收以下参数：

| 参数 | 用途 |
| --- | --- |
| `appId` | 对应 App profile；初始配置不匹配时报配置错误。 |
| `catalogBytes` | master delivery 或 canonical catalog 原字节，用于配置时核对动作 ID 与读取动作事实。 |
| `allowedActionIds` | 显式完整动作 ID 列表，不支持 tag、前缀或通配授权。 |
| `policyVersion` | 配置版本字符串，默认 `'1'`。 |
| `catalogSha256`、`allowlistSha256` | 可选的包配置元数据；不传时计算，传入时在加载配置时核对一次。 |

空名单、空 ID、重复 ID、未知 ID、通配或前缀表达式会抛出 `CoachActionScopeConfigurationException(code, field)`，不退回全库。`computeAllowlistSha256(ids)` 与素材工具一致：先检查重复，再按 ID 排序，以 UTF-8 每行一个 ID、末尾 LF 计算。

`fromJson(json, catalogBytes: bytes)` 用于读取配置；`toJson()` 保存名单与上述包元数据。目录和名单 SHA 不承担会话授权或运行期防篡改职责。

```dart
final manifest = CoachActionScopeManifest.fromCatalogBytes(
  appId: profile.id,
  catalogBytes: masterBytes,
  allowedActionIds: configuredIds,
  catalogSha256: configuredCatalogSha,
  allowlistSha256: configuredAllowlistSha,
);
final scope = manifest.restrict(
  catalog: appPlanningCatalog,
  profile: profile,
);
```

宿主仍传原先用于规划的目录；投影保留其剂量、holdSeconds、节奏、素材时间参数和动作顺序。投影只提供当前可规划动作，并移除指向投影外动作的标准 alternative。不要为启用范围配置改动宿主的目录节奏或播放器 builder。

`scope.validatePlan(plan)` 返回实际动作 ID 的 `List<PlanIssue>`；空计划也会被拒绝。它不扫描任意文本、历史候选或工作流记录。测试交付计划时，先断言计划非空，再检查 ID 子集。

## 范围处理与普通工作流记录

`CoachScopeConversationPolicy` 提供 `specialty`、范围内 `suggestions`、`safetyMessage`，以及默认关闭的 `outOfScopeGuidance`。

`scope.evaluateRequest(request, policy)` 接收普通 `CoachScopeRequest`：用户原话、动作 ID 或标准名、目标部位、场景 / 器械 / 保护限制、范围内内容、坚持 / 锁定 / 安全状态等。正常范围内请求不必逐轮提交 `scope_request`；只有真实的范围外处理或安全暂停需要补充该工作流信息。

| 情况 | 处理 |
| --- | --- |
| 部分动作范围外，存在合理替代 | 同目标部位、同场景、同器械硬过滤后选最近候选，记录实际采用 ID，并说明“本 App 没有 X，用 Y 练同一部位”。 |
| 部分动作范围外，没有合理替代 | 删除该部分并告知未覆盖目标，保留范围内内容，重新配时。 |
| 整个需求超出专长 | 不出范围外计划，说明本 App 专长，并给范围内建议。 |
| 用户坚持或锁定不可用动作 | 如实说明没有，不暗换动作或剂量。 |
| 安全 / 伤痛问题 | 安全优先，沿用原安全规则；保护部位设置本身不等于当前正在疼痛。 |

替代排序依据目录部位、场景、器械、类别和难度，不按动作名称关键词猜等效性。只传完整标准名时，会按 master 中的精确名称和相关原话解析唯一 ID，再判断范围；这保留了“蝴蝶式”名称被误当成缺失动作的修复，也不把名称解析当作一次搜索或 seen 授权。

`CoachScopeDecisionRecord` 是普通工作流数据：

- 保存 `originalText`、`kind`、`message`、`sourceId` / `sourceName`、`adoptedActionId`、`candidateIds`、`turn`。
- `sourceQuote` 是可选说明信息，直接保存。
- `allowPlan`、`requiresReplan` 根据 `kind` 派生；构造时无需传入。
- `toJson()` / `fromJson()` 用于普通序列化，不签发会话身份或计划版本证明。

`disclosureFor(records, finalPlan, text, policy: policy)` 生成正常范围说明。替代交付仍要求实际采用的 ID 出现在非空最终计划中；缺少时返回 `adopted_action_missing`，沿现有草稿修复流程处理。替代 / 删除后仍须通过卡片和执行双时长检查。

启用范围配置时，`search_actions` 支持 `queries: [{tags, keywords?, limit?}, ...]`；也可在一次模型响应中并行调用多个检索。
每个 query 仍使用原有排序与同一受限目录/seen 更新，单项错误不丢掉其他成功结果。未启用范围配置时工具 schema 保持旧默认，普通并行检索同样可用。
参数和检索回执在草稿之前列出 `requiredActionIds` 与“必须采用”说明；必选项仍须真实检索，不会自动加入 seen 或计划。

## 宿主接线

```dart
final agent = CoachAgent(
  client: client,
  catalog: () => appPlanningCatalog,
  profile: profile,
  scopeManifest: manifest,
  scopePolicy: policy,
  executionTiming: playerTimelineTiming,
  onSpan: spans.add,
);
final conversation = CoachConversationController(agent: agent);
final playable = conversation.prepareTraining(
  savedPlan,
  context: confirmedContext,
);
if (playable == null) return;
// 将 playable.plan 交给使用相同 timeline builder 的播放器。
```

`executionTiming` 继续使用宿主播放器同一 timeline builder 的同步纯函数，不增加 SDK 自行估算的准备 / 起拍 / 换侧开销；手动计次保留“估算”标志。focus 导入不发模型请求，restore / 开练保留实际动作 ID 准入和原业务校验。

## 本批删除的机制与测试

| 删除项 | 对应清理 |
| --- | --- |
| 防篡改摘要与可信消息校验 | 删除对恢复摘要、message、引句逐字证明的鉴真逻辑与伪造消息测试。 |
| 多份目录 / scope 身份绑定 | 删除规划目录深层哈希、运行期反复核对、会话身份及记录与多重计划版本绑定；删除同 ID 伪造目录、身份互换和版本防伪矩阵。 |
| 任意引用深层扫描 | 删除对历史、候选二维行、审计字段、音频键和任意文本的通用遍历测试；保留计划实际动作 ID 检查。 |
| 离线二次审计 CLI / 矩阵 | 删除审计测试结果、再次鉴真真实日志的工具分支，以及为假想攻击路径扩展的参数矩阵。 |

保留的单测覆盖配置、目录投影、实际动作 ID 准入、真实替代 / 拒绝、标准名称解析和普通工作流序列化；一个行为一条。相关测试位于 `test/action_scope_manifest_test.dart` 与 `test/action_scope_policy_test.dart`，候选 fixture 名单不改。

开发期间真实模型只跑相关 2–3 案，完整样本在批次收尾运行一次，不做离线二次审计；原始 JSON / 日志保留在本地 `build/`，不入库。调用数正常 ≤4、含一次修复 ≤6 是优化目标，不是交付门禁；未达时每案一句归因，由用户决定。硬门禁仍是白名单、安全优先、卡片 / 执行双时长。

历史设计稿和已归档报告保留当时事实；当前接入以本页简化接口和根 `AGENTS.md` 的开发规则为准。
