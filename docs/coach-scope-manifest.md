# Coach 显式动作范围与范围外决策

本接口属于 `ugk_coach` 的可选新增能力。旧调用不传 `scopeManifest` 时保持原接口；
统一 Chat 模块后续必须启用它。本批不创建 Chat、不修改 App、不生成 HipLab 或托马斯
正式授权 manifest。SF 按 **219 授权 / 211 可规划**定稿，HipLab **45 项仍为候选**。

## 两种目录身份分别绑定

`CoachActionScopeManifest.fromCatalogBytes` 同时接收：

- `catalogBytes`：固定 master delivery 或 canonical catalog 的原字节。用于验证授权
  ID 存在性、源目录 SHA 和内部请求事实。允许 219 个授权 ID 中包含不可规划的 8 项。
- `planningCatalog`：宿主正在使用的逻辑目录，例如 SF 的桥接目录、HipLab 含既有
  holdSeconds/节奏投影的目录。不得为了启用范围守卫换掉宿主剂量或播放器的 builder。

目录 SHA 不能互相替代：`catalogSha256` 是 master 原字节摘要，
`planningCatalogSha256` 是宿主完整逻辑投影摘要，覆盖 `Catalog.toJson()`、每个
`Drill.raw` 及 typed taxonomy，包含未建模的 holdSeconds/rhythm 数据。
`restrict(catalog:, profile:)` 每次核对逻辑投影摘要，拒绝同 ID 集合下偷偷更换剂量、
节奏或场景/器械语义的 provider。

```dart
final manifest = CoachActionScopeManifest.fromCatalogBytes(
  appId: profile.id,
  catalogBytes: frozenMasterBytes,
  planningCatalog: appPlanningCatalog,
  allowedActionIds: approvedIds,
  catalogSha256: expectedMasterSha,
  planningCatalogSha256: expectedPlanningSha,
  allowlistSha256: expectedAllowlistSha,
  policyVersion: '1',
);
final scope = manifest.restrict(
  catalog: appPlanningCatalog,
  profile: profile,
);
```

`fromCatalogBytes` 可计算缺省摘要，供可信配置生成/测试使用；正式配置应固定全部期望
摘要。`fromJson(json, catalogBytes:, planningCatalog:)` 要求 serialized 三份摘要并逐项
重验，不能只信 JSON 声称的 hash。`assetManifestSha256` 可选且若传入必须是合法摘要。

`computeAllowlistSha256(ids)` 与第 1 批素材闭包工具一致：精确 ID 排序，UTF-8 每行一个
ID，含最后一个 LF。**先检查重复再排序**，不去重掩盖配置错误。名单为空、ID 有空白、
通配符、tag/prefix 表达式或在 master 中不存在时，构造即抛
`CoachActionScopeConfigurationException(code, field)`，不会退回全库。

## 受限目录与引用检查

实际可规划集合为显式名单、master/宿主完整训练语义及原 `CoachProfile` 的交集。
保留宿主 planning catalog 的顺序，profile 转为该集合的 id-only selector，不改变
原搜索顺序、剂量范围或计划规则。scope 的 Catalog、raw、集合和 profile 数据不可变。

投影只包含可规划动作；原目录全库 `raw`、`problems`、App 索引不进入模型目录。
alternative、结构化动作引用和嵌套的外部动作元数据被剔除，不能只过滤顶层 `drills`
却通过序列化找回全库。跨 App 的资源路径被剔除；原 video timing slot、顺序和
repSeconds 保留为无可下载地址的 timing 元数据，剂量/rhythm 原值不变。实际播放媒体
由宿主的白名单资产绑定提供，不能把 timing-only 条目的空地址当作媒体已验收。
带范围外 ID 的自定义 skill 正文/文件不进入投影；标准工具目录仍由受限 Catalog 生成。

`scope.validatePlan(plan)` 和 `validateReferences(json)` 返回 `List<PlanIssue>`：

- 父 item、segment、`replacedFrom`、alternative 与结构化 source/reference ID 均检查。
- snapshot 的 picks、seen、pendingSearchIds、candidateIds、candidateRows、候选二维行
  首 ID、recommendation ID 都不能借历史或 ledger 绕过。
- 含 `drill.<id>` / `point.<id>` 的 segment cue 也按真实动作 ID 检查；明确资源路径中的
  master 范围外 ID 不可伪装成另一动作的执行引用。
- 用户原话中的外部动作名/ID不自动授权，也不因单纯出现在用户消息文本中而被删掉。

空计划不会通过 `validatePlan`；调用侧测试必须先断言非空计划，再验证全部 ID 子集。
这些接口只做 ID/语义身份边界，不代替既有剂量、安全、器械、场景与双时长门禁。

## 范围外产品矩阵

`CoachScopeConversationPolicy` 提供可信专长说明、范围内建议和可选范围外引导：

```dart
final policy = CoachScopeConversationPolicy(
  specialty: '本 App 专注髋部、臀部和温和拉伸。',
  suggestions: ['温和髋部拉伸', '臀部激活'],
  // outOfScopeGuidance: 默认 null，默认不提其他 App。
);
```

结构化请求类型为 `CoachScopeRequest`，包括原话、源动作 ID/名称/引句、规范 body 目标、
scene/equipment/avoid、已有范围内内容、坚持/锁定/安全状态及当前 session state。
`outsideSpecialty` 默认为 false；它是整需求超出专长的 deny-only 声明，不要求模型猜
未在受限工具枚举中暴露的全库 body 编码，也不能授予动作、seen 来源或放宽任一门禁。
安全拒绝优先于该声明；没有明确范围内 source 时，该声明直接产生无计划的超范围决策。
根控制器必须先验证本轮 quote 与参数来源，不能信模型提交的 `hasInScopeContent` 布尔值。
`evaluateRequest` 另外核对 known source 的精确完整名称/ID字面证据；替代排序不使用
名字关键词。`isKnownBodyCode` 只回答 taxonomy code 是否已知，不暴露全库负面索引。

| 路径 | `kind` | 结果 |
| --- | --- | --- |
| R1 部分范围外，可合理替代 | `substituted` | 同目标部位、同场景、同器械硬过滤后选最近候选；记录实际采用 ID，重新出草稿 |
| R2 部分范围外，无合理替代 | `removed` | 仅在已有独立证据的范围内内容仍存在时删该部分并告知未覆盖目标，重新出草稿 |
| R3 整体超出专长 | `outOfScope` | `allowPlan=false`，专长说明加范围内建议 |
| R4 用户坚持外部动作 | `insistedUnavailable` | 不替代、不出计划，如实说明没有 |
| R5 跨 App 引导关闭/开启 | 以上拒绝路径 | 默认 `outOfScopeGuidance=null`；开启时只输出当前配置的引导，恢复记录不能自行打开它 |
| R6 安全/伤痛优先 | `safetyBlocked` | 在坚持、锁定、替代之前处理，不出计划 |
| 用户锁定且冲突 | `lockedConflict` | 不暗换动作或剂量，等用户调整条件，不出计划 |

替代候选复用 `NodeGates.actionProblem` 的现有当前资格规则，额外要求 catalogue body
一致、source/candidate 场景相容和器械集合相同；没有满足硬条件的候选即不冒充等效。
安全信息缺失不等于验证安全，既有 unknown warnings 不会变成安全承诺。
只给时长或普通范围内 assessment 返回 `inScope`，不会凭空生成一条“删除了请求内容”。

SF 授权但训练说明不完整的动作仍不能进入计划；若请求进入本策略，说明为“暂不能用于
训练/说明不完整”，不虚称 App 没有该可展示动作，也不编出剂量。

## 处理记录与交付告知

`CoachScopeDecisionRecord` 保存 `originalText`、sourceId/name/quote、kind、实际
`adoptedActionId`、候选 ID、scopeIdentity、turn 及可选 planId/version。sourceId 是
用户外部请求的审计事实，不能写进可执行计划的 exerciseId/segment/replacedFrom。
`bindToPlan(id, version)` 生成关联副本，不修改原记录。

`validateRecord` 校验 scope 身份、原话证据、采用/候选集合和三项决策标志一致；
不能将 known outside source 改成 `inScope` 或将伪造 source 改成 `substituted` 免告知。
根 snapshot 层还要校验 turn/originalText 确实属于该会话用户轮。

`disclosureFor(records, finalPlan, text, policy: currentPolicy)` 在交付前核对采用 ID
确实出现在最终非空计划中，并使用当前可信配置重建真实模板。恢复 JSON 中的 message、
guidance、suggestions 不能用来伪造已采用动作或开启跨 App 引导。缺采用项、错误 scope、
不允许出计划却带计划均抛 `CoachScopeDisclosureException`，应回到原重编链路，不能先
保存卡片再改文案。替代/删除记录的 `requiresReplan` 为 true，之后仍须经过卡片与执行
双时长门禁；本组件不直接改计划、不另写时长估算、不进行模型请求。

## 本组件验证

两个 fixture 位于 `test/fixtures/action-scope/`。SF fixture 明示已确认 219/211；
HipLab fixture 明示 `candidate-not-user-approved`、`fixtureOnly=true`，不是生产签核。
`action_scope_manifest_test.dart` 与 `action_scope_policy_test.dart` 包含真实目录投影、
哈希/绑定/不可变性、恶意引用/历史候选/告知防篡改及上述矩阵。根 Agent 负责完整会话、
focus/restore/start、真实模型与总门禁，不能把这些纯组件单测当作 App/真实模型验收。

## Agent 与宿主接线

```dart
final agent = CoachAgent(
  client: client,
  catalog: () => appPlanningCatalog,
  profile: profile,
  appId: profile.id,
  scopeManifest: manifest,
  scopePolicy: policy,
  executionTiming: playerSessionBuilder.executionTiming,
  onSpan: spans.add, // 可不传；不影响业务或重试预算。
);
final conversation = CoachConversationController(agent: agent);
final playable = conversation.prepareTraining(savedPlan);
if (playable == null) return; // 拒绝范围、剂量、安全或双时长不合格的计划。
// 将 playable.plan 交给实际使用同一 SessionBuilder 的播放器。
```

`executionTiming` 沿用已确认的同步纯函数接口；必须与播放器实际使用的 builder 相同。
SDK 不新增准备、起拍或换侧估算。开练准入不重新配时、不修改已保存计划，回调异常或
非法测量直接拒绝；手动计次的 `executionTiming.containsManualCounting` 保留并标“估算”。

Agent 的 `actionScope`、`scopeRecords` 为只读事实。`files()`、工具 gate、动作详情、
搜索、提示目录、自动 check/review、draft/output 都使用同一受限 Catalog 和 Profile；
即使调用 `gateFor(fullCatalog)` 也不会扩大已配置 Agent 的权限。
`focusExternalPlan` 在写入会话之前复用范围规则；非法导入不改变 active/focus/plans，
也不触发模型。宿主不能拿另一套 Catalog 生成的 ValidatedPlan/Actions 作为授权凭证。

未传 `scopeManifest` 时不新增范围 schema 或系统指令，不要求宿主迁移。已启用范围的
Agent 则通过既有 `set_params` 增加可选 `scope_request`，没有增加工具：

```json
{
  "fields": {},
  "scope_request": {
    "quote": "用户本轮完整原话",
    "targetBodyCodes": [],
    "outsideSpecialty": false
  }
}
```

每轮交付前必须完成本轮 assessment；`quote` 严格逐字等于真正用户输入，不能使用
系统回执或改写后的文本。场景、器械与安全限制取自校验后的 Session 参数，模型不能
通过 scope_request 声明另一套约束。混合需求是否仍有范围内部分由代码核对真实
动作/规范部位原话，或已存在的编辑基线；模型不能直接提交 `hasInScopeContent=true`。
当前原话中精确点名的名单外动作由 master 事实自动补入记录，不能靠省略字段隐瞒。
候选 ID 仅提供重编方向；只有实际搜索、详情或已经准入的当前计划动作才具有 seen 来源。

参数与范围记录原子提交；scope_request 不合法时该次 fields 也不提交。场景、器械、
级别、安全条件变化会使旧 assessment 失效，保留标记 superseded 的审计记录。仅时长、
剂量或编辑操作沿用已通过的范围与既有动作失效规则。非法草稿在写入 plans 前拒绝，
返回受限候选和原因，仍使用原 draft_plan/set_params(edit) 重编与既有步数上限。

最终替代/删除说明由代码重建，避免模型同时声称仍包含被删除动作。实际采用 ID 必须
存在于最终计划；替代/删除后继续经过原配时及卡片/实际时间线双门禁，不能补抽或截断。
记录绑定真实 planId/version，历史版本中的实际采用项也必须存在。

## 恢复与可信边界

快照包含 scope 身份、assessment turn、原话审计记录及绑定版本。恢复逐项检查计划、
segment、候选、picks/seen、ledger、推荐、精确版本和告知事实，非法快照不取消当前
会话、不重置状态，也不会回退到旧卡片导入路径。删除记录和 assessment 指针仍不能
抹掉用户原话中可重建的明确名单外请求。

旧 `restoreHistory` 对 scoped Agent 同样先验证再修改状态；合法动作数据重新从当前
受限目录准入，拒绝携带外部引用的同 ID 元数据。新持久化应使用 exportSession 与
restoreSession 成对保存真实会话事实。纯展示文本不是动作授权，不能代替 snapshot。
名单和 catalog hash 是可信宿主配置的身份绑定，不是用户可自签的密码学授权服务。

本批只修改 ugk_coach 及测试/工具/文档，不建立 ugk_coach_chat，不迁移 App 或修改 pin。
runtime 的 cupertino_icons 仍有实际 CupertinoIcons 引用，因此保留；iOS、真机播放、
性能和 App 换 pin 后的迁移验收由各 App 后续完成。

## 实现参考

先对照了维护中的 [OPA](https://github.com/open-policy-agent/opa) 与
[Apache Casbin](https://github.com/apache/casbin)，两者均 Apache-2.0。OPA 将决策和执行
分开，Casbin 提供 deny-overrides 与 domain policy。这里的策略只有固定数据交集和已有
训练规则，不需要额外服务、策略 DSL 或 FFI 依赖；采用不可变精确集合、逐入口再次核验
和拒绝优先，继续使用 SDK 的 Catalog/Profile/NodeGates。未复制这两个项目的代码。
