# 组合可达范围与模型重编

分支 `codex/fit-feasible-range` 基于 SDK main
`99c14495685f160019e10340ea6f0de6418a65b9`。不改配时搜索顺序，不增加公开 Dart API、
模型工具或会话字段，不修改 App、目录剂量、节奏或准备时长。仅推送分支等审，不合 main、
不打 tag；并行的 ui-kit-slots 分支独立保留。

## 失败回执

所选组合在合法剂量域下过长、过短，或者配时未找到容差内的整数剂量时，返回现有错误
结构的 `duration_fit_failed`。不提交失败计划、版本或部分会话变更。回执在顶层增加：

| 字段 | 含义 |
| --- | --- |
| targetSec / toleranceRatio | 目标秒数及容差，至多 10%，profile 更严格时从严 |
| minEstimatedSec / maxEstimatedSec | 当前组合在 catalog/profile 与已确认剂量范围内的上下界 |
| direction | 下界超上限为 remove_action；上界低于下限为 add_action；整数空档为 adjust_selection |
| removeCandidates / addCandidates | 可删或可加候选，包括动作 ID、名称、块、序号和变更后的范围 |
| removeCandidateCount / addCandidateCount | 所有已评估合法候选数；返回列表各最多 8 项 |
| rangeOverlapsTarget | 候选变更后的范围与目标容差相交，不能据此声称整数解必然存在 |
| requiresSearch | 加入候选尚未被模型搜索时为 true，须先 search_actions 再提交草稿 |
| needsDraftRebuild / clarificationAllowed | 是否应重编；当前组合不合格不能自动转成用户问题 |

例如 SF 原五分钟组合返回 targetSec=300、minEstimatedSec=336、maxEstimatedSec=14044、
direction=remove_action、needsDraftRebuild=true、clarificationAllowed=false，附可删候选。
模型据此调整一个未确认动作并重出 draft_plan；一次增删仍不够时继续重编未确认组合。
工具不自行删动作，也不把未搜索候选写入 seenActionIds。

候选遵守当前安全/器械/场景规则、catalog/profile 剂量交集及作用域剂量锁；不能删除用户
明确剂量所引用的必需动作，也不能通过删除块来绕过明确块级约束。先评估全部合法候选，
再排序截取展示。无重叠候选只表示这些单步变化尚未证明可达，不表示全库无解。

## 何时允许澄清

目录固定剂量是内容约束，模型的 picks 是模型选择，两者都不是用户确认。用户剂量锁必须
具有 source=user、真实用户回合及匹配原话 quote；不从动作名关键词、picks 或 focus 导入
猜测动作确认。现有 dose.actionId 提供可验证的必需动作引用，不新增动作确认接口。

仅在用户明确锁定部分本身的保守下界已超预算，或明确剂量本身越出允许范围/模式且不能
靠增删未确认动作消除时，保留澄清。全局剂量存在并不自动允许反问；缺少充分不可修复
证明时继续重编。明确剂量本身的矛盾仍按原机制解释原因并询问取舍。

Agent 在当前回合私有地保存待修复回执。修复尚未完成时，模型紧接着调用 ask_user 会
收到同一范围/方向/候选，要求先重出草稿；合格草稿后解除拦截。未进入时长修复流程的
地点、安全、参数缺失询问保持原流程，不新增持久化状态或历史字段。

## SF 与 HipLab 原始记录回归

SF 来源是 `Sport-Helper-coach-ui-kit/docs/reports/sdk-ui-kit-plus51-sdk99c1449/`
中的五分钟记录及 offline-five-minute-diagnosis；真实采集 SHA-256：
`6382e8d3f47d3b44ac994ed450f7fb89f43c9badb67fee5b180d186824270e76`。
原三批工具回复、用户原话、32 个 seen 动作、原 profile、五个所选动作定义和旧回执保留。
原记录只有澄清，没有已交付计划。

回归通过真正的 CoachAgent 协议重放原三批工具调用，再追加明确标注的 FakeLlmClient
合成修复回复：读取新回执、删除候选中的椅起立、重出草稿、show_plan。不发网络或真实
模型请求，也不将合成修复冒充原模型采样。详情和哈希见
[SF 夹具说明](../test/fixtures/fit-feasible-range/smartfit/README.md)。

HipLab 复用此前第三段“换一套，缩短到 5 分钟”的不可变夹具，通过 Agent 协议交付；
其草稿前状态是原复现文档说明的重建状态，不声称历史捕获了完整 pre-draft snapshot。

| 离线修复/重放，目标 300 秒 | 卡片秒数 | Trainer 含原准备时长 |
| --- | ---: | ---: |
| SF：原组合范围 336–14044，原先直接澄清；删除椅起立后交付 | 291（-3.00%） | 292（-2.67%，含 10 秒准备与 authored lead） |
| HipLab 第三段：保持原六动作、旧版与替换语义并交付 | 309（+3.00%） | 323（+7.67%，含 15 秒准备、原 lead 和中文换侧语音） |

SF 原椅起立为手动计次，336 秒是规划下界，不能说成原计划真实自动执行最短时间。
修复后已去掉该动作。两份 Trainer 回归均求和 phases 并自然遍历 SessionEngine；这些
是离线协议和时间线证据，不是新的真实模型或设备验收。

`PlanBuilder._fit` 方法体与 99c1449 逐字一致，规范化换行后的 SHA-256 为
`6f90529dbf0f55a3e90c1057f5a58b68170a8ec519eb93f7f99f64d4d46243a0`。

## 验证

| 包 | 全量测试 | `dart analyze --fatal-infos` |
| --- | ---: | --- |
| ugk_coach | 1359 通过（新增 17） | 0 问题 |
| ugk_coach_ui | 158 通过 | 0 问题 |
| ugk_trainer | 531 通过（新增 2） | 0 问题 |

新增测试覆盖候选过滤、范围和方向、8 项展示截断前的完整评估、未搜索候选标记、部分
动作锁仍可删除其他动作、真实锁定下界证明、伪来源不能制造用户锁、禁止立即反问以及
两份真实记录的离线交付和自然完成时间线。原明确剂量冲突、安全、器械和数据状态边界
仍保留。

8 项既有“当前组合不可行就澄清”的预期按新语义调整：plan_timing_normalization 三项、
plan_fit_all_blocks 两项、output_gate 两项、plan_duration_delivery_gate 一项。
110/625、110/225、310/310 秒等原范围及容差不改；失败不改旧计划或会话。
旧 Agent 恢复用例从一次调用后反问，改为三次调用后重编交付 189 秒计划（目标 180 秒），
保留原用户输入、剂量和旧版本。其他旧用例改为验证带范围的重编回执。

Coach 命令为 `dart test --concurrency=1 --reporter expanded`；两个 Flutter 包使用
`flutter test --no-pub --reporter expanded`。最终日志在对应包 `build/fit-feasible-range/`；
第一次旧预期失败另存 coach-tests-initial.log。格式、diff check、文档链接、8 个 SF
夹具哈希和原始采集哈希均通过核验。公开导出文件与 pubspec 没有改动。
