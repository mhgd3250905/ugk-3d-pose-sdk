# 全阶段配时与严格交付门禁

分支 `codex/fit-all-blocks` 从 SDK main
`caa6817c51b3cb09c46909288d83aa88bdc2dbd4` 开发。
不包含并行的 `codex/ui-kit-slots`，不修改公开 API、宿主文件、动作选择/排序规则、
已确认剂量来源规则或替换差异率。仅推送功能分支供 Hark 审核，不合 main、不打 tag。

## 搜索与交付

保留原先主体优先的配时顺序，补全热身、主体、放松的计次/计时工作量、组数、轮数；
轮数使用完整 profile 范围，不再硬编码只搜主体 1–4 轮。计次、计时、组间及轮间休息均
使用 catalog/profile 交集，用户明确剂量继续锁定，冲突继续返回原有用户取舍结果。
旧计划 refit 的起点也归一到同一合法范围。

跨过目标后会重新遍历阶段，探索降低一个动作组数、同时增加另一个动作组数的组合；
另检查各块合法轮数和合法上下界起点。不能通过这些阶段满足容差时，才进一步搜索已保存
分段的工作剂量，保留分段顺序、ID、label、rhythm、holdSeconds、父项 note 和旧版本，
不把分段折成一个新动作。fitLog 继续记录真实、可核对的每步剂量和前后估时。

初始计划已在 10% 内时沿用其剂量；需要配时时仍优先寻找 5% 内的结果。
profile 的 durationTolerance 更严格时从严，不能用它放宽 10% 门禁。
搜索没有找到合格整数剂量时返回现有错误回执结构中的 `duration_fit_failed`，不提交
计划/版本或部分会话更改。修正指引要求模型按既有规则调整一个合规动作再出草稿，候选
不足则先搜索；明确条件无法兼容时询问用户。代码不擅自增删动作，也不把搜索失败当成
数学无解证明。原最小值/最大值证明不可行与明确剂量冲突仍走既有 question 流程。

`show_plan` 重新计算真实 PlanDuration，旧缓存的 estimate/check.ok 不能绕过门禁；
目标分钟没有变化的旧超差计划也会 refit。失败保留原会话、版本和交付状态。
focus 编辑在追加版本之前完成必要配时，避免先存超差 v2、展示时又加 v3；合格的未改
动作继续保留原剂量。Trainer 同步按整块重复热身/放松多轮，保留每轮动作顺序、组数、
双侧、分段、组休/轮休、进度、语音、跳过及提前结束语义。circuit 的既有执行语义不变。

## HipLab +24 原失败复现

证据源为 `E:/AII-3D/hiplab-releases/coach-v2-plus24-20261031/sdk-duration-gate-repro.md`
和同目录 `live/results.json` 第三轮。采集文件 SHA-256：
`82dab1f1055003772682c06171f929b1e15b49dec6ecf7ece12c3404fba6eaf4`。

原记录没有原始 draft_plan 响应体或 pre-draft snapshot。测试严格按复现文档重建草稿前
状态，并从原交付计划投影有序动作选择；不把这些重建输入当成历史捕获的模型请求。
原失败计划、49 步 fitLog、profile、catalog 原动作对象、action-kit 与语音 manifest
均保留，来源与夹具 SHA 见
[夹具说明](../packages/ugk_trainer/test/fixtures/hiplab/fit-all-blocks/README.md)。

| 指标，目标 300 秒 | 修前 | 修后 |
| --- | ---: | ---: |
| 卡片 PlanDuration | 335 秒（+11.6667%） | 309 秒（+3.0000%） |
| 训练器，含原 15 秒准备 | 349 秒（+16.3333%） | 323 秒（+7.6667%） |
| fitLog 步数 | 49 | 38 |

保留六个动作、原先顺序、version 2 和 replace_all。热身 n-leg-circles 从 4 次到 1 次，
h-hip-gate 从 6 次到 5 次；均在原目录/profile 范围内。其余剂量亦由原搜索器计算，
不是修改素材周期或降低执行要求来凑时长。

训练器验证保留 action-kit 的 lead、真实阶段和中文换侧语音扩展，包含 15 秒准备；
同时求和 SessionBuilder.phases 并自然遍历 SessionEngine，验证结束、访问时长和完成
动作数。这是离线执行时间线证据，不是本轮设备播放或重新请求模型的记录。

## 泛化与既有测试变化

HipLab 和 SF 各覆盖 5/10/20/30 分钟 × 计次/计时/双侧热身，共 24 个实际 fitter→Trainer
矩阵用例，卡片与各自含准备的执行时间线均在目标 ±10% 内。HipLab 使用原 15 秒准备
和中文语音；SF 使用宿主原 10 秒准备和 authored execution/lead。
SF 使用不可变的六动作夹具，并按当前宿主 `_planningCadence` 建立独立的计划视图：
`assets.video.sources[*].repSeconds = rhythm.cycleFor()`，原视频路径、执行周期和 lead
不改。原始 SF v3 的 313/345 秒回放夹具与文件保持不变，不把它冒充已对齐的目录。

本次变更的既有测试逐项如下，未放宽任何容差：

| 既有用例 | 旧 → 新 | 原因 |
| --- | --- | --- |
| plan_timing_normalization：忽略旧模型剂量 | 目标 3 → 4 分钟；卡片仍 225 秒；误差 25% → 6.25% | 原 3 分钟整数域不合格，改用合法目标继续验证无关的字段忽略行为 |
| plan_timing_normalization：结构化 fitLog | 目标 3 → 4 分钟；首步仍 110 → 225 秒 | 保留原日志身份与数值断言，消除对近似成功的依赖 |
| plan_timing_normalization：整数空档 | ok=true、保存 225 秒计划 → duration_fit_failed、无 plan/version、状态不变 | 180 秒目标不能交付误差 25% 的计划；225 秒和 25% 仍作为失败诊断 |
| plan_timing_normalization：宽轮数/轮休 | 455 → 1259 秒；误差 62.083333% → 4.916667%；withinTolerance false → true | 不再漏搜 profile 的合法轮数和轮休 |
| output_gate：7 分钟分段计划 | 479 → 439 秒；误差 14.047619% → 4.523810%；withinTolerance false → true；通知 14.0% → 4.5% | 组数/轮数及休息联合搜索得到合格结果；8 分钟 479 秒用例不变 |
| segmented_plan_refit：1 分钟分段计划 | 100 → 62 秒；误差 66.666667% → 3.333333%；withinTolerance false → true | 搜索原先遗漏的合法分段工作量；旧最佳 1 组 → 新最佳 4 组，reps 10 → 1、time 60 → 10，分段结构和元数据保留 |
| focus_plan_edit：自定义剂量保留 | 测试目标 10 → 28 分钟，剂量/两轮/元数据原断言不变 | 自定义剂量实际约 28 分钟，原标注 10 分钟会进入应有的时长修复 |
| focus_plan_edit：分段剂量保留 | 测试目标 10 → 22 分钟，剂量/两轮/分段原断言不变 | 编辑后完整两轮约 22 分钟，继续验证原有保留语义 |
| focus_plan_edit：保留第 1 个重复项后删除 | 测试目标 10 → 9 分钟，原剂量断言不变 | 删除后的保留剂量接近 9 分钟，避免把该用例变成配时修复测试 |
| focus_plan_edit：保留第 2 个重复项后删除 | 测试目标 10 → 9 分钟，原 79 秒/来源项断言不变 | 同上，79 秒不应因这个无关测试的目标标注而被重新配时 |

新增根包测试覆盖每类块的四种剂量、profile/catalog 交集、超过四轮、组合搜索、明确剂量
锁、整数空档拒绝、普通与分段 refit、历史越界剂量归一化、旧缓存与 focus 交付回滚。
Trainer 新测试同时覆盖所有块重复时的顺序、休息、双侧、分段、语音、跳过、提前结束、
结果计数和整条时间线与卡片的契约。所有结果以三包最终测试及 fatal-info 静态分析为门禁。

最终验证：

| 包 | 全量测试 | 新增测试 | `dart analyze --fatal-infos` |
| --- | ---: | ---: | --- |
| ugk_coach | 1342 通过 | 37 | 0 问题 |
| ugk_coach_ui | 158 通过 | 0 | 0 问题 |
| ugk_trainer | 529 通过 | 44 | 0 问题 |

Coach 使用 `dart test --concurrency=1 --reporter expanded`，两个 Flutter 包使用
`flutter test --no-pub --reporter expanded`。完整日志保留在对应包的
`build/fit-all-blocks/`，初次全量中的旧预期失败另留 `coach-tests-initial.log`；最终
Coach 门禁使用 `coach-tests.log` 和 `coach-analyze.log`。格式和 `git diff --check`
通过，15 个有哈希的 HipLab 夹具文件与来源投影核验通过。
