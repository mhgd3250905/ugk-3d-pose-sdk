# Scope 与调用预算验收工具

本文件说明第 2 批新增的观测与真实模型工具，**工具的单测或 dry 不代表真实模型门禁通过**。
真实结果以运行目录 `run.json`、每 case JSON、`timeline.jsonl`、`summary.json/.md` 为准。
失败样本保留，不重抽、不补用户答案、不截断后续固定原话，不删除失败行。

## 最小 span

`CoachAgent` 的可选 `onSpan` 接受同步 `CoachAgentSpanObserver`。事件只有稳定 ID、
task/epoch/toolCallId、操作类别与单调时间、计数和结果码；没有请求体、system 正文、
私有 reasoning、认证头或凭据。没有 observer 时不读计时器，默认调用方不产生事件。
observer 的同步异常被隔离，不改变业务、请求重试、取消、配时、步数或出卡结果。

```dart
final recorder = CoachAgentSpanRecorder(onSpan: observations.add);
await recorder.run(() async {
  final tool = CoachAgentSpanRecorder.startCurrent(
    CoachAgentSpanKind.tool, 'draft_plan',
  );
  try {
    // 原逻辑；下层 HTTP 与 PlanBuilder 通过同一 Zone 继承定位信息。
  } finally {
    tool?.finish();
  }
}, turnId: turnId, taskId: taskId, epoch: epoch);
```

`http / tool / fit / recompile` 四类分别报告。HTTP 量实际尝试至完整响应读取结束，
不把网络、服务端排队或模型生成分成未经测量的时段。`fit` 的嵌套时间不再次加进
tool 总耗时；报表的每类 `inclusiveMicros` 不能直接相加冒充用户轮耗时。
finish 幂等，属性在开始/结束时冻结，跨 Agent 不继承上下文；无 observer 的嵌套 Agent
也屏蔽外层诊断，避免把它的 HTTP 归给另一个 Agent。

设计参考先核对了维护中的 [OpenTelemetry trace API](https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/trace/api.md)
（Apache-2.0，明确 span end 非阻塞）与 [Dart Stopwatch 标准库](https://github.com/dart-lang/sdk/blob/main/sdk/lib/core/stopwatch.dart)
（BSD-style）。完整 OTel SDK 的 exporter、异步批处理与传播协议超过本次最小观测范围；
这里沿用仓库已有 Stopwatch、同步回调和独立父 span 设计，不引入依赖、不复制第三方实现。

## 运行

先在当前 checkout 完成 Coach/Trainer 的依赖解析；工具读取 Trainer 的 package config，
显式把 Coach/Trainer/runtime 三个源码入口绑定到当前同一 SDK 工作树。App 只有只读桥接。

```powershell
dart run tool/eval_coach_scope_guard.dart --host smartfit --dry --out build/coach-scope-guard/dry-sf-new
dart run tool/eval_coach_scope_guard.dart --host hiplab --dry --out build/coach-scope-guard/dry-hip-new
dart run tool/eval_coach_scope_guard.dart --host smartfit --out build/coach-scope-guard/live-sf-new
dart run tool/eval_coach_scope_guard.dart --host hiplab --out build/coach-scope-guard/live-hip-new
```

每个 out 必须在当前 SDK 的 `build/` 内且不存在或为空，不能覆盖旧 run，不提供只重跑
失败 case 的选项。thinking 默认 on，网关/模型固定为既有已授权评测配置，transport
重试为 0；密钥读取复用 `eval_api_config.dart`，不会写进输出。

host bridge 直接复用 `executed_duration_host_timing.dart`：

- SF 保留 AppTestContent 的原 planningCatalog/节奏、prep10 和原 App SessionBuilder 对照。
- Hip 保留 App 原 46 条 planningCatalog（包括 holdSeconds 投影）、实际 kit/voice、prep15
  配置与原 lossless adapter/native metrics 对照。

scope 的 master delivery219 授权 SHA 与 App 原 planningCatalog 的 canonical view SHA
分别绑定，绝不拿 master 的剂量替换宿主原剂量或另写准备/起拍估算。
卡片、执行回调和验收均用上述同一 planningCatalog/Builder；逐 phase、总时长与自然
完成访问日志一致性由原 bridge 核对。手动计次仍标“估算”且必须过两个数值门禁。

SF 使用已定 219 授权 / 211 可规划 fixture。Hip 45 仅为
`candidate-not-user-approved` 测试 fixture，不是 App 正式 manifest 或用户签核名单。

## 固定样本

SF 保留上轮七组独立三轮原话：五组最终 5 分钟，10/20 分钟各一组。第 2 轮推荐必须
非空且不改第 1 轮计划所有版本；第 3 轮同 planId 追加版本并保留原历史前缀。

Hip 路径编号严格沿用主设计第 7 节：

| Case | 固定目标 | 预期 |
| --- | --- | --- |
| R1 partial-substitute | 蝴蝶式 + 名单外站姿侧抬腿，5 分钟 | substituted、真实采用 ID 在非空最终计划中、代码告知、双时长 |
| R2 partial-remove | 蝴蝶式内侧拉伸 + 名单外弹力带坐姿划船，5 分钟 | removed、有独立范围内原话证据、去掉练背告知、非空范围内计划双时长 |
| R3 whole-outside | 只练胸背，明确不练髋腿臀 | plan=null、专长与范围内建议 |
| R4 insist | 先点名站姿侧抬腿，再固定输入不接受替代 | 最终 insistedUnavailable、plan=null、如实没有与范围内建议 |
| R5 guidance-off/on | 相同胸背请求两个独立会话 | 默认无引导；显式开启时只出现配置测试文案；均 plan=null |
| R6 safety-first | 膝盖不适且动作会痛，同时点名胸背与站姿侧抬腿 | safetyBlocked 优先、plan=null、安全说明及应有建议 |

设计示例“侧卧抬腿”与当前 master 的 `h-side-leg-raise` 名称不符；实际 master/semantic
正式名为“站姿侧抬腿”。`h-band-row` 正式名为“弹力带坐姿划船”，`s-butterfly` 为
“蝴蝶式”。在第一次真实模型调用前按原字节目录锁定这些名称，不新增猜测别名或名称
关键词部位映射。原话精确保存在源码、run metadata 和范围处理记录。

Hip dry 在读取密钥前先调用同一 `scope.evaluateRequest`，核对每个既定路径、真实
采用 ID 与范围内原话证据；不符就 0HTTP 报错。当前 0HTTP 离线预检中 R1 采用
`n-pelvis-circle`（站姿骨盆画圈），R2 以 `s-butterfly` 的原话作范围内证据。
这只是目录/profile 下的预检，不等于模型最终计划一定满足。

## 验收与报表

交付路径先检查 plan 非 null、items 非空，再检查父/segment/替代元数据 ID、代码
采用 ID、记录里的真实告知、卡片和执行各自 ±10%。不会用 `plan?.ids ?? []` 通过。
数值验收还独立核对实测秒数，即使 timing flags 伪称 true，326/335 秒也不能过 5 分钟。
拒绝路径检查 plan==null、专长/安全说明和范围内建议。各路径最后一轮必须有真实 HTTP；
若安全层本地结束导致 0HTTP，会如实列为未满足“真实模型”门禁，不绕过安全。

每用户轮包含实际 HTTP、模型请求的 search 数、SDK 已处理的 search attempt 数、明确
执行的新检索数和本地检索缓存命中数，以及拒绝/延期/未知数。新检索和本地命中只按
真实工具回执的 `cacheHit=false/true` 计数，同一 toolCallId 在多次请求中只计一次；
没有回执或标志则保留 unknown，失败回执不推断内部检索是否实际执行。
这里的本地缓存与网关 prompt cache 完全分开；后者只用网关公开 usage 的命中 token。
其余字段为总 ms、最大 request bytes、公开 usage
的 prompt/completion/total token、已知网关缓存 token 与未知调用数、失败工具回执、重编
span 原因、fit/tool/http 分项 μs、卡片/执行偏差及估算标志。缺失 token/cache/elapsed
保持 null/unknown，不反向补成 0。每次 HTTP 的 task snapshot 在 send 时同步读取，
不会依赖异步事件是否及时到达。

调用预算为正常 ≤4，恰一次修复 ≤6；多次/未知修复另列失败，不改变 SDK 原
maxSteps/maxResubmits，也不提前交付。SF 最终轮逐 case 对比上轮已提交结果：
最多 9 次来自 five-1，最长 29001ms 来自 five-5。新报告不会把两项冒充同一条基线。
两宿主都分别报告 `functionalGatePassed`、`budgetGatePassed` 和两者相与的
`gatePassed`；功能交付成功不能代替调用预算通过。

## 原工件离线审计

```powershell
dart run tool/audit_coach_scope_guard.dart --input build/coach-scope-guard/live-smartfit-r1-20261101 --out build/coach-scope-guard/audit-sf-new
dart run tool/audit_coach_scope_guard.dart --input build/coach-scope-guard/live-hiplab-r1-20261101 --out build/coach-scope-guard/audit-hip-new
```

此工具只读已结束的原工件，不读取 key、不创建 Agent、不执行宿主 builder、不发 HTTP。
输出必须为新的 SDK build 目录，与 raw 目录分离；全目录文件 SHA 在审计前后核对，
原 case/summary/timeline 不覆盖。新的指纹标记审计代码，不宣称重新验证当前 SDK 实现。

旧报表曾把版本的整个 `toJson` 当不可变数据比较，参数改变使历史 `check` 缓存失效
为 null 时误报。修正只排除版本顶层的派生 `check`，其余所有键（包括未知键）、
`version/plan/estimateSec/fitLog/createdAtTurn/operation` 与数组顺序都严格保留。
推荐轮不能增减版本；编辑轮须同 planId 追加连续版本，最新交付版 check 通过且计划
与实际交付完整相同。中间未交付草稿仍保留，不假装每个历史草稿都通过过 check。

离线审计还按本轮实际 toolCallId 限定拒绝回执，避免把历史失败列成本轮原因；
不改原回执、原 span、HTTP 数、预算分类、安全/范围判定或双时长阈值。原失败原因和
原 SHA 一并输出；真实预算或安全失败继续列未通过，不通过重抽替代原样本。

接线专项使用内置 `OpenAiCompatibleClient` 与本地假 HTTP 服务，覆盖每次实际 send
（含内部 retry）独立 span、响应体完全收完才 finish、真实 tool/draft-fit 父关系，以及
observer 缺省/正常/抛错时交付与步数/重试预算一致；不会把模拟 HTTP 当真实模型验收。
父子 epoch 断言使用公开字节预算触发一次真实 ended-turn fold，再完整执行计划链路，
检查 fit、draft 父 span 与对应 HTTP 都继承折叠后的当前 epoch。

工具专项：span 单测 11 项、验收合同单测 16 项、Agent 接线专项 5 项通过；定向 analyze 0。
两份只读宿主 `--dry` 已通过，均 `modelCalls=0`；真实模型尚未由本子任务启动。
