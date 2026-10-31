# 配置档、动作隔离与素材闭包

本附录属于设计稿，**没有实现任何字段、过滤器、素材拆包或自动测试**。
SDK 当前 main/本设计分支基线为 `3fbd179063e9b8433cadd5387295ac07b7b93800`，已包含执行
时长回调。下列范围与素材盘点起于 `700d0100f1cb42ef122e774a6ee0076d1916b5e5`，相关
目录、selector 和素材声明在该次执行时长修复中没有改变。SF 迁移基线为
`3eb2a9e88ef4d28e02f4cf306c1716d61baa7f10`。公开 API 名称以主设计稿为准。

## 已核实的现状与缺口

| 当前实现 | 事实 | 对新模块的约束 |
| --- | --- | --- |
| `lib/src/profile/coach_profile.dart:10–43,405` | `DrillSelector` 的 ids、prefix、apps、tags、categories **取并集**；全空选择全库 | 不能在宽泛 apps/tags 选择器上追加 ids 并声称变为硬白名单；新模块须在受限 Catalog 上使用 id-only profile，空名单拒绝初始化 |
| `lib/src/agent/action_search.dart:44,271` | 检索用 `profile.scope(catalog)`，详情经 `NodeGates.actionProblem` | 保留既有安全/器械门禁，先把 Catalog 本身缩为本 App 授权、语义完整的视图 |
| `lib/src/agent/action_tool_handler.dart` | 旧虚拟目录路径已经转到同一检索/详情路径 | 新模块继续使用这条链路；不得另外导出全库 Markdown/原始 JSON 给模型 |
| `lib/src/agent/skill_files.dart:311–334` | 详情可按 scope 隐去名单外 alternative | 新的受限 Catalog 和序列化层必须同时去除外部 alternative/media/skill 引用，防止旁路泄漏 |
| `lib/src/plan/plan_validator.dart:126,160–208` | 现有校验检查父 item 与每个 segment 的 ID、mode 和 profile 范围 | 新增严格集合守卫是补充，不替换结构、剂量、安全、场景及器械校验 |
| `lib/src/agent/external_plan_focus_handler.dart` | 外部 focus 在改会话前先严格解码与 PlanValidator 校验 | 已存计划“发到对话”必须沿用这个入口；不能直接拼一条展示消息冒充可编辑计划 |
| `lib/src/agent/session_snapshot_handler.dart:147–164` | schema 验证后恢复 sessionState；现有 snapshot 没有新模块的 scope 身份封套 | 新模块必须在 restore 前检查 App/profile/catalog/scope 身份和所有动作引用，不把旧快照默认视为仍有资格 |
| `packages/ugk_trainer/pubspec.yaml:48–55` | 当前包直接声明完整 delivery/semantic JSON 和 `standing/` 目录 | 仅在运行时过滤 Catalog 不能满足 HipLab/托马斯的物理素材隔离 |

上述路径均相对 SDK 根。这里只列设计需要用到的实际边界，不把已存在的 scope 校验说成
完全没有校验，也不把它升级成尚未实现的严格构建保证。

## CoachAppProfile 字段草案

`CoachAppProfile` 放在新的 Flutter 对话模块；纯数据的 scope manifest 和严格 ID 守卫
由 `ugk_coach` 拥有。Chat 可以依赖 UI/播放器类型，纯 Dart Coach 不能反向依赖 Flutter。

| 字段 | 必填/默认 | 语义与初始化校验 |
| --- | --- | --- |
| `appId` | 必填，稳定的 `smartfit` / `hiplab` / `flarelab` | 与存储 namespace、调用记录、scope manifest 身份一致，不使用显示名称作隔离键 |
| `revision` | 必填，配置档版本 | 文案或主题修订可以不改变动作资格；资格变化必须另改 scope policy/hash |
| `scopeManifest` | 必填、不可空 | 显式 `allowedActionIds` 与固定目录身份；不得使用 `*`、前缀、标签或空集合表示全库 |
| `allowedActionIds` | 从 manifest 派生的只读 getter | 不再保存第二份集合，避免字段漂移；模型、UI 与构建器读取同一数据 |
| `coachProfile` | 必填 | 复用既有范围说明、场景、安全与计划规则。模块构造 id-only 内核 profile，旧宽泛 selector 不得扩张授权集合 |
| `doseOverrides` | 默认空映射 | 按显式动作 ID 声明剂量投影/单位；key 必须在白名单内，字段语义、mode、合法范围与节奏来源都要匹配；不能只把“次”改成“秒” |
| `conversationPolicy` | 必填 | 本 App 对话范围、范围外请求回应、可给的相关建议、安全规则和用户点名不支持动作时的处理。结构化 ID 资格仍由代码守卫 |
| `conversationPolicy.outOfScopeGuidance` | 可选，默认 `disabled` | 只有明确开启时，才能使用配置档核准的引导文案/CTA 提及其他 App；默认只说明本 App 专长及库内建议，不跨 App 引导，不自动导航；顶层访问若需要仅作只读 getter |
| `strings` | 必填，SF 预设精确保留 `3eb2a9e` 文案 | 空态标题/说明、输入提示、建议语、范围外说明、安全提示、错误/重试/取消/历史/新对话等可本地化文案 |
| `visual` | 必填，SF 预设原值 | `CoachUiStyle`、对话主题、图标 builder、`cutoutFor` / `cutoutBuilder`，以及需要时引用的 `TrainerTheme`；尺寸、布局、时序不开放为品牌任意改写项 |
| `executionTiming` | **新 Chat 模块必填、不可 null** | 沿用已定的同步、纯函数、无 IO `PlanExecutionTimingCallback`，由播放器实际使用的同一 builder 提供；旧 `CoachAgent` 的参数仍 nullable，不改变旧接入默认行为 |

建议 manifest 的可序列化字段为：

```text
CoachActionScopeManifest
  schemaVersion
  appId
  policyVersion
  catalogVersion
  catalogSha256
  allowedActionIds[]       // 排序、去重后的显式 ID
  allowlistSha256          // 对约定 canonical JSON 字节计算
  assetManifestSha256
```

`catalogSha256` 指固定输入目录及语义投影的身份，不用显示版本字符串代替内容校验。
实现时确定 canonical JSON 的排序/UTF-8/换行规则，并用同一个生成器写 manifest、scope
投影和打包输入；不是分别维护三份手填名单。允许 ID 必须存在于该固定**主目录**，重复、
拼写错误、空白或未知 ID 直接返回配置错误，不能退回全库。授权集合增加须经过 App 清单
审阅；远端 Catalog 新增动作，即使 app/tag 匹配，也不会自动进入既有 profile。

manifest、policy 和 strings 可以来自配置资料；函数、Widget、主题实例、执行 callback
以及网关鉴权信息不能序列化进去。网关与凭据属于宿主运行时绑定，不写 snapshot/日志。
profile 可以引用素材 manifest 身份，但不把庞大目录或 profile 副本复制到每条消息/会话。

### 三个 App 的初始范围

| App | 推荐首批显式授权来源 | 不能作出的推断 |
| --- | --- | --- |
| SF 全量 | 固定内部 delivery 目录的 **219** 个 canonical ID，700d010 与当前 3fbd179 的该目录相同，见本文清单 | 不意味着未来新 ID 自动放行；219 个素材 ready 不等于所有语义可计划 |
| HipLab 拉伸/髋/臀 | 先冻结当前 `hiplab.json` 已列明的 **45** 个 ID，维持排除 `n-thomas-test`，作为待签核初始清单 | 不能把“所有拉伸”自动扩大为全库所有肩/胸/手腕动作；不按 `h-` 前缀放行 |
| 托马斯专项 | 当前 FlareLab 专项目录的 **51** 项展开为显式清单，包含经该 App 选择的热身、支撑、核心、腿、侧撑和全旋链体能 | “托马斯”指该 App 的 Flare 专项，不是用动作名或字符串 `thomas` 搜索；`n-thomas-test` 不能因此自动加入 |

HipLab 与托马斯的业务范围仍以用户的产品决定为最终资格。推荐先把现有范围逐项冻结，
再在后续配置审核中确认是否增删；本设计既不扩大旧清单，也不宣称已经完成新业务清单
签核。scope manifest 应将签核版本写成明确值，发布实现不能以本表“候选”字样代替签核。

SF 当前 219 个动作中，**211** 个具有完整训练语义，另 **8** 个仍不完整。当前
`AppTestCatalog.fromSdk` / SDK `toAiCatalog()` 区分了这两种资格，迁移必须保留：
产品授权名单可以是全部 219 项，给 Agent 的 planning Catalog 仍是授权集合中的完整
语义子集；其余项不能凭空补剂量或被规划器使用。动作库页可按原行为展示它们，其
“可展示”不等于“可开练/可规划”。本地尚未下载视频也不应被误用为永久缩小授权集合的
条件，能否按清单准备媒体由原素材准备链路判断。

这 8 个不完整 ID 是 `h-bilateral-farmer-hold-native`、`h-db-shrug`、
`h-floor-nordic-hand-reset`、`h-kneeling-thread-needle`、`h-pike-scapular-elevation`、
`h-towel-isometric-curl`、`h-wall-palm-lift`、`o-supported-ankle-eversion`。
SF profile 旧 notes 中“142 个动作”不是当前数量依据。当前素材仍是内部测试目录，
`reviewed/releaseEligible` 标志不会因这次迁移被改写为正式内容验收。

## 隔离必须覆盖的完整链路

设 `A` 为显式授权 ID 集，`C` 为该目录版本的语义完整动作集；Agent 只持有 `A ∩ C`
的不可变投影。新会话构造后不能在一次请求中切到另一个 profile/catalog 快照。

1. **初始化与检索。** 严格构造受限 Catalog 与 id-only CoachProfile。模型的 compact
   index、维度索引、`search_actions`、`get_action`、旧 `read action-library/...`、skill
   文本与 catalog facts 都由该投影生成。不要先传全库给模型再依赖系统提示“不要用”。
   `Catalog.raw`、全库 `problems`、alternative、素材路径和其他 App 的资源索引也要
   投影或剔除，不能只过滤 `drills` 后仍序列化完整 raw。
2. **草稿与复配。** 在进入配时搜索前对所有 ID 做严格集合检查；父 item、segments、
   新增/替换候选均不能逃过。名单外 ID 返回明确结构化错误及库内重选指引，保持原计划、
   版本、active/focus 不动，进入已有重出草稿链路。错误不附送名单外动作的全库详情。
3. **计划准入与交付。** `PlanValidator` / `PlanChecker` / `show_plan` 最终准入再检查
   集合。复配、focus 编辑、模板和显式预设均使用同一守卫；旧成功 check、缓存估时或
   `ValidatedPlan` 来自另一 profile 不能直接复用。集合通过后仍需剂量、安全、器械、
   场景及卡片/执行双时长校验。
4. **历史与快照。** 模块 snapshot 封套增加 appId、profile revision、scope policy/hash、
   catalog 身份。恢复前扫描全部历史计划版本、picks、seen IDs、recommendations、
   active/focus、savedRef 关联及 ledger 结构化引用。跨 App/profile 不兼容快照不装进
   Agent；旧文件保留，给出可理解的恢复错误或只读归档，不能静默删除部分动作凑成新计划。
   同 App 文案/主题修订可以兼容；scope 缩小或目录语义改变须重新逐项准入。
5. **外部计划/发到对话。** 宿主传完整计划给模块，模块先做相同范围/结构/剂量校验，
   再调用既有 `focusExternalPlan`，成功才设置 focus/savedRef。失败无模型请求、无状态
   变更；不得仅把卡片插入 UI 就认为模型获得了当前讨论计划。含外部动作的保存计划不
   静默替换/删项后导入或覆盖存储：先拒绝该次事务，给明确替代预览。推荐 CTA 是
   “按范围内方案重新生成”，用户点击才发起普通新计划任务（可调模型），不伪造
   savedRef、不写原库、不声称非法导入成功。另一明确 CTA 可“采用并另存为新计划”，
   新 externalId 创建成功后再走原 external focus。不是强迫采用即保存，也不新增
   localDraft focus 域。原保存仍保留，更新原记录须走公开 API 文档的显式确认与 CAS。
6. **保存与开始训练。** 传给宿主的保存/开练请求携带已准入的不可变计划及 profile/scope
   身份；异步存储、导航等待后执行副作用前再次比对身份。宿主不得重配剂量、截断计划或
   换成另一份 DTO。历史保存计划越界时拒绝开练/覆盖保存，保留原存储记录并说明原因。
7. **替代、素材与缓存。** 替代动作必须仍在 A∩C 且通过当前安全门禁。新的可执行计划中
   `replacedFrom` 等可解析动作来源字段也须通过集合检查，不能用来挂载名单外详情或
   资源；旧越界来源保留在隔离归档中，不静默截掉字段后放入 active 计划。素材解析、
   预加载、缩略图/剪影 renderer、
   action-kit/voice 查询及下载请求在调用宿主 provider 前再次检查 ID；拒绝直接使用模型
   自带路径/URL。缓存按 App/scope/media manifest 身份命名，旧外部素材不进入新缓存索引。

纯 Dart 的严格 ID 守卫建议作为 `ugk_coach` 的可选新增能力，旧 API 未传时保持旧行为；
新 `ugk_coach_chat` 必须启用，不能提供“生产关闭隔离”的配置。Chat 自己构造 Agent，
宿主提供网关客户端而不是一个可绕过守卫的自定义 Agent 实例。

用户自由输入当然可能包含名单外动作名称或 ID，这不是动作授权；**但不意味着整个
请求一律拒绝**。用户已经确定下面的产品处理，代码隔离与这套回应同时成立。无需向
模型开放全库负面索引来证明拒绝资格，也不能说整个 Pose-Hub 不存在某动作。

### 名单外请求的确定处理

| 请求情况 | 行为 | 告知与交付条件 |
| --- | --- | --- |
| 只有部分动作不支持，存在合理替代 | 在 A∩C 中按同目标部位、同场景/器材和当前安全条件找最近合规动作，重新提交草稿 | 明示“本 App 没有 X，用 Y 练同一部位”；不能暗换。交付前重新通过 ID/剂量/安全和卡片、执行双时长门禁 |
| 部分动作不支持，也无合理替代 | 去掉不支持的未锁定部分，保留能满足的范围内内容，重新配时/重出草稿 | 明示去掉了 X、哪些原目标本次未覆盖；不可把一个无关动作说成等效替代。删项后两个时钟仍须在目标容差内，不改目标、不截断播放、不豁免 |
| 整个需求超出 App 专长，例如 HipLab 只练胸背 | 不生成或交付声称满足范围外需求的计划 | 一句 profile 中的本 App 专长，加最近的范围内推荐/建议 CTA；用户一键选择后才开始相应范围内计划，当前 `plan=null` |
| 用户坚持名单外动作、不接受替代 | 如实说明当前 App 没有，不能假装安排了 | 保持 `plan=null`，可保留范围内 CTA；不因坚持而扩大 allowlist，不默认提其他 App |
| 用户已明确锁定剂量/不可替代条件，或有伤痛/安全约束 | 伤痛与安全门禁优先；替代授权不解除这些锁 | 无法同时满足时说明冲突、让用户明确选择调整，不能暗中删锁、换剂量或建议违反安全条件的“最近动作” |

“合理”不是仅文本相似：候选须在授权且语义完整的目录中，目标部位、场景、器材和
已知限制相容；优先已有 ActionSearch/NodeGates 的资格规则。没有满足条件的候选就
走无合理替代，不捏造同目标收益。若删除后没有合法内容、整数剂量仍不可达或不能在
保留用户锁的前提下通过双时长门禁，则不交付空/近似计划；沿既有重编/冲突处理说明
原因，不能将 `null` 或空 items 当成一份合格计划。

名单外 X 只作为用户原话及独立的替代/删除告知保留，不把它写进可执行计划的
`exerciseId`、segment 或 `replacedFrom`，也不借告知查询/下载它的素材。模块保存
告知与新卡片的关联，历史恢复后不能只留下替代后的卡片而丢掉“改了什么”的说明。

模型若仍在 draft_plan 返回外部 ID，SDK **拒收这一份草稿**、保持当前计划与版本不动，
只给名单内合规候选和重编指引；模型随后提交合法草稿并告知替代/删项。这是计划生成
阶段的修正流程，不能先交付非法计划再清理，也不能让宿主在保存/开练回调里改计划。

`outOfScopeGuidance` 默认 disabled 时，所有范围外路径均不输出其他 App 名称、链接或
跳转。显式启用后，只使用 profile 核准的引导内容；引导不能伪装当前计划可执行，也
不能代替本 App 专长说明或安全提示。用户点 CTA 才交由宿主导航，不自动打开/切换 App。
自然语言是否如实告知、是否偷偷跨 App 宣传需要真实模型验收；ID 集合守卫不能被说成
已经证明任意自然语言语义都正确。

### 保存版本与并发版本分离

`savedRef.baseVersion` 继续表示导入基准的 SDK 会话计划版本；宿主 `storageRevision`
是独立的不透明 CAS token。scope/profile revision 和内容 hash 都不能冒充它。替代预览
不是写入授权；更新原保存必须带原 storageRevision 做原子比较，失败/冲突保留原记录
和当前卡片。另存须经用户选择并生成新 externalId；接口细节见主公开 API 草案。

## 剂量覆盖：避免字段名称相似造成执行偏差

现有 `TrainingPlan` v1 的普通 `PlanItem` 是 `reps` 或 `workSeconds`；
`holdSeconds` 只出现在 `PlanSegment`。HipLab 的 `KitDose` 则有 reps、seconds、
holdSeconds，action-kit 的 `rep_hold` 表示**每次动作的停留秒数**。
现有 `CoachPlanMapper` 将 `workSeconds` 映射到 `CustomStep.seconds`；播放侧从真实
phase/kit rhythm 取得 holdSeconds。不能假称普通 PlanItem 已支持一个同名字段。

建议 `doseOverrides` 为按 ID 的可序列化声明，由 SDK 内置、版本化 normalizer 执行，
不允许各 App 传一段任意配时修补函数：

| 语义 | 规范计划字段 | 展示/模型说明 | 必须同步验证 |
| --- | --- | --- | --- |
| 固定保持/拉伸总时长 | `mode=time`、`workSeconds` | 可显示“保持 N 秒”；旧 Hip DTO 的 seconds 按既有映射处理 | catalog 默认剂量与 seconds 范围、perSide、同一 builder 的实际阶段 |
| 自动节奏计次 | `mode=reps`、`reps` | 保留“每侧 N 次”等原文，不能因为 Hip 侧重拉伸改成计时 | catalog reps 范围、authored rhythm、lead、sets/rounds |
| 每次重复中停留 | 已支持的 segment：`reps` 与 `holdSeconds`，配合 `rep_hold` rhythm | “N 次，每次停留 H 秒” | hold 合法范围、cycle/hold 定义、语音、计划及播放器所读的同一字段 |
| 手动计次 | catalog 的 self-paced rhythm，计划保留 reps | 执行总时长归“估算” | `containsManualCounting=true`，仍接受双数值门禁，不能豁免超差 |

如果产品要求修改**普通 item** 的每次停留时长，推荐作为后续独立 schema 设计/兼容项
审核；第一步沿用已授权 kit 默认节奏，或使用已支持的 segment 表达，不能私加 JSON 键
然后让 Coach 忽略而播放器采用。转换应可往返，保存/export/restore 后语义不丢失；
不改动作库的真实模式来满足某个时长目标。

## 执行时长回调归入配置档

执行时长回调已随 `3fbd179063e9b8433cadd5387295ac07b7b93800` 进入 SDK main，设计
分支亦基于该提交。接口沿用已定契约，不在 Chat 复制准备/lead/换侧公式：

```text
PlanExecutionTimingCallback = PlanExecutionTiming Function(TrainingPlan)
PlanExecutionTiming(totalSeconds, blocks, containsManualCounting)
PlanBlockExecutionTiming(blockId, seconds)
```

profile 的 callback 由播放器实际同一 `SessionBuilder.executionTiming` 方法提供；若
播放器确需按候选构造 builder，两边调用同一无 IO 工厂，不复制配置。加载 action-kit、
voice manifest 和目录在 callback 安装前完成。模块统一传给 draft/refit/可行区间/
候选/最终交付门禁；两种时长都必须在目标 ±10%，严格 profile 从严。
回调抛错或返回非法值直接拒绝交付，不退回卡片估时；手动计次继续标估算。

每个宿主必须有一条“callback 总秒数等于播放器 phases 总和、分块与手动标记一致”的
断言测试。SF 与 HipLab 保留各自的准备、节奏和语音配置，不能给三个 App 共用一个
貌似通用的默认 builder，也不能用卡片时长加固定几秒替代实际时间线。

## 素材隔离的实现方向

当前 Trainer pubspec 的整目录 assets 会被 Flutter 依赖资产打包机制纳入 App；不同 Dart
入口、运行时集合过滤或 Dart code tree shaking 都不能作为排除这些声明资产的保证。
Flutter 官方说明 package pubspec 中声明的资源会自动随应用打包，参阅
[Adding assets and images](https://docs.flutter.dev/ui/assets/assets-and-images) 与
[Flutter pubspec options](https://docs.flutter.dev/tools/pubspec)。

用户已确认拆包方向：后续把训练实现抽为**没有动作素材的**
`ugk_trainer_runtime`；旧 `ugk_trainer` 保留完整资产兼容外壳，转导出同一 runtime。
新 Chat 依赖 runtime，三个迁移宿主使用 runtime + 自己的 scope 资产。这里没有新增包
或更改 pubspec；拆包方向已定，实现与兼容证据仍须后续审核。不能承诺“只加一个
chat 包且旧所有依赖声明不动”就能达成物理隔离。

兼容门禁必须证明：只存在一份播放器实现；旧转导出的类型与新 runtime 是同一类型；
Android 插件只注册一次；旧调用默认 asset URI 与完整动作浏览器仍能工作。
HipLab/托马斯新依赖图不能继续间接引用含全库 assets 的 legacy Trainer；仅在文件中
换 import 而 pubspec 仍依赖旧包也不合格。SF 可授权全量包，但仍按同一清单校验。

资产可先由 App-owned 构建目录生成，不要求第一步建立三个额外 pub 包：

```text
fixed master catalog + app scope manifest + media/voice manifest
  -> validate IDs, revisions and checksums
  -> project catalog/skills/templates/kit/voice metadata
  -> resolve per-action asset dependency closure
  -> app-specific explicit assets list and pubspec input
  -> Flutter bundle
  -> inspect AssetManifest + archive entries + metadata references
```

构建生成内容是审核后的生成物或 App 自有输入，不修改 SDK pub cache、不复制三份
运行代码、不通过 path/branch SDK pin 发布。只读完整目录可在开发/构建环境使用；
受限 App runtime 和发给模型的资产中不携带名单外动作的 catalog 定义或完整原索引。

资源闭包包含允许动作对应的浅/深封面、剪影、视频/alpha 对、action-kit、动作语音、
分辨率变体、必要播放器网页/shader；以及无动作归属的公共字体、图标、提示音和通用
语音。共同人体/背景资源可以作为显式 shared 资源存在。闭包不能跟着 alternative
自动把名单外动作拉入；替代不授权时切断引用并提供已允许候选。一个不可分割文件若
含其他动作帧或动作专属语音，不能仅凭文件名标 shared 绕过限制；应由素材源提供合法
拆分版本，或在选定方案前阻止该受限包发布。

构建阶段除了“应有的都在”，还检查“多余的都不在”：

- 将 bundle 路径映射到 owner action ID 集；所有动作 owner 都属于 A，shared 另有
  经过审核的显式清单，未知 owner 失败。针对目录声明、自动分辨率变体、嵌套包 assets
  和物理 APK/AAB/IPA/Web archive 分别核查，不能只检查源码文件夹。
- 检查投影 JSON、kit/voice/template/skill 索引内的所有动作引用，不能留下指向外部动作
  的 URI 或资料。动态下载清单/缓存也使用同一个 allowlist/manifest 守卫。
- scope、catalog、媒体版本哈希不符即拒绝构建；缺少必要资源明确报错，不能为构建成功
  静默增大名单、用另一动作图代替或删除训练项。

## 自动验收草案

三个 App 各有一个命名明确的端到端契约测试：
`smartfit_plan_ids_are_allowlisted`、`hiplab_plan_ids_are_allowlisted`、
`thomas_plan_ids_are_allowlisted`。测试不是只断言一个固定 fixture 的名字集合：使用各自
真实 profile 与 scoped Catalog，通过正常 Agent 草稿/交付链路，并注入恶意模型返回的
父项外部 ID、segment 外部 ID、替代外部 ID，证明未通过集合校验的计划永不交付/保存/
开练、失败状态原子不变，合法重出草稿可以恢复。

每个测试最小可复用断言：交付计划所有父/segment 执行动作 ID 均为 A 的子集。另覆盖：
检索/详情/旧 read 路径不返回外部定义；新增 Catalog ID 不自动获得授权；空名单或未知
ID 不能回退全库；外部 focus、模板、跨 profile snapshot、旧历史与缓存不能绕过。
模型真实门禁记录实际交付 ID，做同一集合断言，不能仅由模型自检回答“是”。

### 范围外产品路径的真实模型门禁

以下是实施阶段**必须运行、当前设计阶段未运行**的最小矩阵；每行至少一条独立真实
模型会话，保存完整固定输入、输出/告知、scope manifest、工具回执、最终计划、两个
时钟、调用数与耗时。不得反复重抽直到某条通过，不能只用 FakeLLM 冒充语义验收。

| 路径与固定样例方向 | 必须断言 |
| --- | --- |
| 部分替代：HipLab 请求库内蝴蝶拉伸与名单外侧卧抬腿，场景器材允许一项库内同部位替代 | 有合法非空计划；全部可执行 ID 在 A∩C；告知 X 不支持及实际 Y；Y 与目标部位/场景/器材/安全条件相容；卡片和执行均达标 |
| 无合理替代删除：HipLab 同时请求内侧拉伸与名单外练背动作，没有合理髋部动作可冒充练背 | 有明确去掉 X、未覆盖练背目标的告知；最终仅范围内非空计划且双时长达标。若范围内内容也不可达则必须 `plan=null` 并说明，不能算成功交付 |
| 整体超域：HipLab 要求“只练胸背，5 分钟” | `plan=null`；出现 profile 专长说明和范围内 CTA，不声称完成胸背计划；用户点击 CTA 后另验范围内准入 |
| 坚持外部：在解释后坚持该名单外动作且不接受替代 | `plan=null`；如实说明没有，不扩大白名单、不假装安排，默认没有其他 App 引导 |
| 默认无其他 App：outOfScopeGuidance 未传/disabled 的范围外请求 | 没有其他 App 名称、链接或跳转；无计划时同时断言专长说明/CTA，不以对 null 做 ID 子集判断冒充通过 |
| 可选引导：同一超域请求，显式启用 profile 核准的 outOfScopeGuidance | `plan=null`；先有专长说明，只出现核准的引导文案/CTA，没有自动导航或虚假的可执行计划 |
| 安全优先：有现有 SDK 可识别的伤痛/危险限制，又要求不支持动作及“最相似”替代 | 不交付被安全门禁拒绝的替代；保留安全提示/必要问题。无安全方案时 `plan=null`，不能为了凑时长忽略限制 |
| 用户锁：部分不支持动作关联明确剂量/不可替代条件，候选无法满足 | 不暗删锁、不暗改剂量；说明冲突并等待显式选择。用户未解除冲突前 `plan=null`，保存记录未被覆盖 |

交付型路径的测试必须先断言 `plan != null`、items 非空，再检查集合、告知与双时长；
拒绝/引导型路径必须断言 `plan == null`、专长/安全说明以及应有 CTA/问题。不能用
`plan?.ids ?? []` 的空集合结果把未交付、无告知或全部超域的回答误记为通过。

构建契约另外检查物理素材闭包；runtime 计划测试通过不代表 APK 里没有名单外素材。
执行时长契约另用实际 builder；ID 子集通过也不代表时长或媒体准备已经通过。

## 风险与建议

| 风险/待决 | 推荐 |
| --- | --- |
| 名单业务含义不清：Hip“拉伸”是否扩大；托马斯是否缩减当前 51 专项体能 | 首批保留当前 45/51 的显式候选，逐项签核后生成 manifest，不使用关键词自动扩容 |
| SF“全量”被误解为可以规划所有 219 条 | 全量授权 219，沿用语义完整子集 211；补齐 8 条由内容来源独立验收，不在搬迁中伪造 |
| 现有 Trainer 全资产声明与受限打包矛盾 | runtime + legacy wrapper 拆分方向已确认；实施阶段单独验证 URI/插件/类型兼容，再迁 App 依赖 |
| 单位覆盖改变实际执行 | 声明式、版本化剂量投影；先沿用 catalog/kit 真实模式，普通 item hold 扩展另审 |
| 快照恢复后旧 scope 重新带入外部动作 | scoped 身份封套 + 恢复前扫描 + 原存储保留；无安全自动迁移时只读归档/开新会话 |
| profile 主题/字符串过度开放导致三个 App 再分叉布局 | 配置只承接已识别品牌差异，SF 原值作为预设；布局/动画由同一模块拥有 |
| 宿主换 builder 但 Coach 继续测旧配置 | profile/runtime 同一配置生命周期；实际 builder 一致性断言及真实模型 5/10/20 门禁 |
| 把部分范围外请求误做一律拒绝，或暗换后声称满足原目标 | 按已定替代/删除/全超域/坚持矩阵处理，告知与卡片绑定，真实模型逐路径验收 |
| 用范围外引导变成默认跨 App 宣传 | `outOfScopeGuidance` 默认 disabled；开启后仅 profile 核准内容且用户主动点 CTA |
| 用 SDK baseVersion 冒充宿主并发写入凭据 | 已定分离 `savedRef.baseVersion` 与不透明 `storageRevision`，原记录更新必须 CAS，冲突不覆盖 |

## 清单来源与候选 ID

只读核对时间为 2026-11-01。HipLab 工作副本 HEAD
`58e2e8117dc89b57a4a2a3660439fd11f3fc3fe6`，另有不属于本设计的未跟踪 UI 工作，未读取
或修改这些新文件。托马斯主仓库 `E:/AII-3D/3D-Body` HEAD
`a2e856423902004eea00f0fb5c8f34b306a27f76`，`app/` 为其 Flutter 工程；本次均只读。

| 输入 | SHA-256 |
| --- | --- |
| HipLab `assets/coach/hiplab.json` | `638b1797561da2cac23cb66ce25449e3e81efe01a103e3360cc4ee3a8ed0f920` |
| HipLab `assets/coach/catalog.json`（46 条，scope 45） | `e3a82ee49833b8f7baf626f0eeb033cfa53429105ac13eaaab12560067269c9f` |
| 托马斯 `app/assets/coach/flarelab.json` | `23b1dc16f472b1bc3886f5922dada817b8ac0099fcad91df49d6def61f79e7c6` |
| 托马斯 `app/assets/coach/catalog.json`（51 条） | `a6b4699883abb9769ad68aab3d54c3fbeef686cd15bee8bd1cb054c454ea4614` |

以下清单仅是上述固定来源展开后的设计输入，正式配置 manifest 尚未生成/实现。

SF delivery 文件 SHA-256：`75881cf91621c967f80732f0219f23e85b35e8bde5d1a51ee75dec5f7c5edd36`。

### SF 全量：219 个 canonical ID

```text
abs-A, abs-B, abs-C, adductors-A, adductors-B
adductors-C, chest-A, chest-B, chest-C, deltoids-A
deltoids-B, deltoids-C, erectors-A, erectors-B, erectors-C
forearms-A, forearms-B, forearms-C, g-cable-hip-abduction, g-cable-hip-extension
glute-max-A, glute-max-B, glute-max-C, h-9090-liftoff, h-adductor-rock
h-banana, h-band-chest-fly, h-band-face-pull, h-band-hip-extension, h-band-hip-ir
h-band-leg-out, h-band-pallof, h-band-pull-apart, h-band-row, h-band-shoulder-ir
h-band-standing-abduction, h-band-standing-adduction, h-band-stepout, h-band-straight-leg-raise, h-band-triceps-pressdown
h-bent-knee-calf-raise, h-bilateral-farmer-hold-native, h-bilateral-upper-back-hug, h-bridge-march, h-bulgarian
h-butterfly-active, h-calf-raise, h-catcow-quad, h-chair-dip, h-chair-kickback
h-chair-lat, h-chair-progressive-front-split-native, h-chair-single-leg-hip-thrust, h-chair-sit-to-stand, h-chair-step-up
h-chair-tspine, h-close-stance-forward-fold-native, h-cobra, h-couch-stretch, h-crunch
h-db-calf-raise, h-db-curl, h-db-floor-fly, h-db-floor-press, h-db-front-raise
h-db-hammer-curl, h-db-kickback, h-db-lateral, h-db-overhead-triceps-extension, h-db-press
h-db-rdl, h-db-reverse-fly, h-db-row, h-db-shrug, h-db-split-squat
h-db-supported-calf-raise, h-dd-shoulder, h-donkey-kick, h-doorframe-forearms-pec-native-r3, h-fixed-bar-vertical-pull
h-floor-nordic-hand-reset, h-forearm-plank, h-forward-lunge, h-goblet-squat, h-good-morning
h-hip-gate, h-incline-pushup, h-knee-hug, h-knee-wall-dorsiflexion-native, h-kneeling-instep-stretch
h-kneeling-pushup, h-kneeling-thread-needle, h-lateral-step-lunge, h-overhead-triceps-stretch, h-pike-scapular-elevation
h-plank-side-step, h-quad-cars, h-quadruped-open, h-quadruped-rockback, h-reverse-clam
h-reverse-crunch, h-russian-twist, h-seated-reachback, h-short-side-plank, h-side-er
h-side-leg-raise, h-sleeper-stretch, h-slider-body-saw, h-squat, h-standing-forearm-rotation
h-standing-wrist-deviation, h-standing-wrist-extensor-stretch, h-step-jack, h-straight-arm-hang-native, h-suitcase-hold
h-suitcase-march, h-sumo-pry, h-superman, h-supine-bilateral-leg-raise, h-supine-heel-slide
h-supine-twist, h-supported-single-leg-calf, h-tabletop, h-tib-raise, h-towel-isometric-curl
h-unsupported-star-reach-native, h-wall-angel, h-wall-calf, h-wall-calf-bent-knee, h-wall-palm-lift
h-wall-straddle, h-wall-wrist-flexor-stretch, hamstrings-A, hamstrings-B, hamstrings-C
hip-abductors-A, hip-abductors-B, hip-abductors-C, hip-flexors-A, hip-flexors-B
hip-flexors-C, lats-A, lats-B, lats-C, n-chair-wiper
n-half-split, n-leg-circles, n-pelvis-circle, n-prone-hip-ext, n-prone-ir
n-seated-ir-drop, n-seated-knee-lift, n-seated-squeeze, n-slider-lateral, n-squat-shift
n-straddle-fold, n-thomas-test, n-wide-fold, n-windshield, o-chair-knee-extension
o-seated-calf-raise, o-seated-catcow, o-seated-fig4, o-seated-ham, o-seated-hip-er
o-seated-sidebend, o-seated-twist, o-stand-crossreach, o-stand-ham, o-stand-lunge
o-stand-quad, o-stand-sidebend, o-supported-ankle-eversion, o-supported-ankle-inversion, o-supported-ankle-pump
o-supported-hip-airplane, o-supported-hip-hitch, o-supported-hip-ir, o-supported-knee-curl, o-supported-march
o-supported-mini-squat, o-supported-single-leg-rdl, o-supported-star-reach, o-wall-hip-hinge-stretch, obliques-A
obliques-B, obliques-C, quadriceps-A, quadriceps-B, quadriceps-C
rotator-cuff-A, rotator-cuff-B, rotator-cuff-C, s-9090, s-butterfly
s-figure4, s-frog, s-kneel-hipflex, s-lizard, s-pigeon
s-seated-fold, scapular-A, scapular-B, scapular-C, serratus-A
serratus-B, serratus-C, t-seated-straddle-lift-1leg, triceps-A, triceps-B
triceps-C, w-bird-dog, w-chair-hip-thrust, w-clamshell, w-dead-bug
w-feet-on-chair-bridge, w-fire-hydrant, w-prone-swimmer, w-wall-sit
```

### HipLab：45 个当前显式 ID

```text
glute-max-A, h-9090-liftoff, h-adductor-rock, h-band-hip-ir, h-band-leg-out
h-butterfly-active, h-couch-stretch, h-hip-gate, h-knee-hug, h-quad-cars
h-reverse-clam, h-squat, h-sumo-pry, h-supine-twist, h-wall-straddle
hip-flexors-A, n-chair-wiper, n-half-split, n-leg-circles, n-pelvis-circle
n-prone-hip-ext, n-prone-ir, n-seated-ir-drop, n-seated-knee-lift, n-seated-squeeze
n-slider-lateral, n-squat-shift, n-straddle-fold, n-wide-fold, n-windshield
o-seated-fig4, o-seated-ham, o-stand-crossreach, o-stand-lunge, s-9090
s-butterfly, s-figure4, s-frog, s-kneel-hipflex, s-lizard
s-pigeon, s-seated-fold, t-seated-straddle-lift-1leg, w-clamshell, w-feet-on-chair-bridge
```

### 托马斯：51 个当前专项目录 ID 候选

```text
abs-A, abs-B, abs-C, adductors-A, adductors-B
adductors-C, chest-A, chest-B, chest-C, deltoids-A
deltoids-B, deltoids-C, erectors-A, erectors-B, erectors-C
forearms-A, forearms-B, forearms-C, glute-max-A, glute-max-B
glute-max-C, hamstrings-A, hamstrings-B, hamstrings-C, hip-abductors-A
hip-abductors-B, hip-abductors-C, hip-flexors-A, hip-flexors-B, hip-flexors-C
lats-A, lats-B, lats-C, obliques-A, obliques-B
obliques-C, quadriceps-A, quadriceps-B, quadriceps-C, rotator-cuff-A
rotator-cuff-B, rotator-cuff-C, scapular-A, scapular-B, scapular-C
serratus-A, serratus-B, serratus-C, triceps-A, triceps-B
triceps-C
```
