# 卡片与播放器执行时长双门禁

分支 `codex/fit-executed-duration`，基线 SDK main
`700d0100f1cb42ef122e774a6ee0076d1916b5e5`。仅推送分支等审，不合 main、不打 tag。

## 接口与责任

`ugk_coach` 保持纯 Dart。新增可选的同步回调，SDK 不推测宿主的准备、起拍或换侧开销：

```dart
typedef PlanExecutionTimingCallback =
    PlanExecutionTiming Function(TrainingPlan plan);

const PlanExecutionTiming({
  required double totalSeconds,
  required List<PlanBlockExecutionTiming> blocks,
  bool containsManualCounting = false,
});

const PlanBlockExecutionTiming({
  required String blockId,
  required double seconds,
});

CoachAgent({ /* 原参数 */ PlanExecutionTimingCallback? executionTiming });
ToolGate({ /* 原参数 */ PlanExecutionTimingCallback? executionTiming });
```

回调必须是纯函数、同步且无 IO，不修改候选计划；相同计划与播放器配置应返回相同结果。
准备、起拍、换侧、组休、轮休及其他实际插入的 phase 全部进入 `totalSeconds`。
`blocks` 按输入计划的 block 顺序一一对应，明细使用播放器实际的 phase 归属。
无块归属的 phase 仍计入总秒数，所以分块合计可以小于总秒数。

`evaluatePlanExecutionTiming(plan, callback)` 统一调用并验证结果：所有秒数必须有限且非负，
块数、顺序和 ID 必须匹配，ID 不能空或重复，分块合计不能超过总秒数（浮点容差 1e-9）。
回调抛出任意对象返回 `execution_timing_callback_failed`；非法结果返回
`invalid_execution_timing`。错误包含安全的 `actual.reason`，不复制原异常或私有配置。
失败不保存候选或新版本，不交付，也不静默回退到卡片时长。Agent 会立即返回
`TurnStatus.error` 和安全的 `PlanExecutionTimingException`，不会让模型重试修复宿主配置。

未传 `executionTiming` 时，保持 main 700d010 的卡片配时、回执字段、旧调用和默认外观。
`ToolGate` 的新参数用于 Agent v2 输出链路；旧版 `CoachSession` 接入方式保持原样。
回调是运行时依赖，不写入会话快照。恢复快照时，宿主仍须为 Agent 注入自己的回调，
恢复的旧成功 check 和缓存估时不能绕过新门禁。

## 必须复用播放器 builder

`ugk_trainer/engine.dart`（也由 `ugk_trainer.dart` 转导出）新增：

```dart
extension SessionBuilderPlanExecutionTiming on SessionBuilder {
  PlanExecutionTiming executionTiming(TrainingPlan plan);
}
```

它仅调用已有的 `SessionBuilder.phases(plan)`，汇总全部 `phase.seconds`，按
`phase.blockIndex` 汇总分块，并检查 `phase.isWork && phase.selfPaced`。
没有另一套准备、起拍、换侧或执行估时公式。

宿主必须把**播放器实际使用的同一 builder** 交给 Coach，不能另造一个使用默认配置的
builder，也不能把 `PlanDuration + 固定几秒` 当成执行回调。加载目录、action-kit、语音
manifest 等 IO 在创建回调之前完成。若播放器的节奏、语音或配置改变，规划与播放两端
须同步更新依赖。

在宿主原有初始化和训练入口中接线：

```dart
import 'package:ugk_coach/ugk_coach.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

// playerBuilder 是宿主已用来启动 TrainerPlayer 的同一实例，配置已加载。
final agent = CoachAgent(
  client: client,
  catalog: () => catalog,
  profile: profile,
  executionTiming: playerBuilder.executionTiming,
);
// 原训练入口仍使用：TrainerPlayer(..., sessionBuilder: playerBuilder)
```

若现有播放器根据计划创建 builder，则抽取同一个无 IO 工厂，两边都调用它；不能复制
两份配置。HipLab 使用原 15 秒准备、authored action-kit 节奏和中文语音换侧配置；SF 使用
原 10 秒准备、`trainerRhythms(library)` 和 `known: library.contains`。这些数值属于各自
宿主配置，SDK 配时器没有硬编码它们。

宿主侧必须增加一条断言测试，使用其真实播放器 builder 和实际候选计划：

```dart
final timing = evaluatePlanExecutionTiming(plan, agent.executionTiming!);
final phases = playerBuilder.phases(plan);
expect(timing.totalSeconds,
    closeTo(phases.fold<double>(0, (sum, p) => sum + p.seconds), 1e-9));
expect(timing.containsManualCounting,
    phases.any((p) => p.isWork && p.selfPaced));
```

此分支没有修改 App 源码或 App 的 SDK pin。下面的真实门禁通过 SDK harness 注入各宿主
的 builder；宿主正式接入时仍须加上参数、断言测试，并重跑自己的真实门禁。

## 配时、范围与交付

注入回调后，draft、focus 编辑、refit、恢复后的 show_plan 使用同一测量契约。
卡片仍由原 `PlanDuration` 计算，存储的 `estimateSec` 和卡片展示不改；执行时长全部来自
回调。两者都必须落在目标 ±10% 内，profile 更严格时从严，边界含等号。

原 `_fit` 搜索阶段、顺序和剂量范围不变。候选按卡片/执行中误差更大的一项排序和确定
搜索方向，不能只让其中一个时钟合格。`fitLog` 的 `beforeEstimatedSec` /
`afterEstimatedSec` 是当时误差较大的那个时钟；最终 `executionTiming` 明确返回执行
总秒数、分块和手动计次标记，`durationErrorPercent` 是两种时长中较大的误差。

可行区间与增删候选的 `minEstimatedSec/maxEstimatedSec` 在注入后指执行时间线边界，
同时附 `minExecutedSec/maxExecutedSec` 与 `minCardSec/maxCardSec`。两个区间都必须
与目标窗口相交，`rangeOverlapsTarget` 才为 true；区间相交仍不能保证存在整数解。
循环块在一轮与多轮时的组数语义不同，范围计算枚举合法分支端点及多块分支组合，逐个
调用真实回调，不用“所有剂量取最大”冒充执行上界。没有改变配时搜索顺序。

下界超标给 `remove_action`，上界不足给 `add_action`，其他未找到整数解的组合给
`adjust_selection`，继续已有 `duration_fit_failed`、候选、重出草稿链路。
仅由当前所选组合无法达标，不得反问用户改时长。没有重抽、截断、容差豁免或近似交付。
旧版与先前计划保持不动。交付前按最终器械等规范化后的计划再检验，防止旧快照元数据
与最终候选不一致。

手动计次不能声称真实自动执行时间。`containsManualCounting=true` 时仍参与数字门禁，
draft 回执的 `executionTiming.isEstimate=true`、`label="估算"`。宿主还可从
`ValidatedPlan.executionTiming` 读取本次通过门禁的测量，`withSessionVersion` 保留它。
纯计时/自动节奏不因 `DoseMode.reps` 被误标为手动；以实际 `selfPaced` phase 为准。

## 固定回归

来源为 HipLab +26 trial-03 第三轮真实草稿、计划、工具回执和最终状态。原始捕获 SHA-256：
`caef5fcfe676a6bf374f83106b54db351376cbaee9313ab9362551661c9924b7`。
fixture 中仅 pre-draft state 明确为重建输入，目录是原对象的 21 项投影；profile、六个
action-kit、中文 voice manifest 原字节保留。完整来源和各文件 SHA 见
[fixture manifest](../packages/ugk_trainer/test/fixtures/hiplab/executed-duration/manifest.json)。

| 离线真实 builder 回归 | 卡片秒数 | 执行秒数 |
| --- | ---: | ---: |
| 原 5 分钟捕获 | 326 | 335，超出 330 |
| 同草稿修复 | 302 | 311 |
| 同六动作 10 分钟 | 594 | 607 |
| 同六动作 20 分钟 | 1176 | 1195 |

逐 phase 核对原准备 +5 秒和四次 authored lead 合计 +4 秒。原及修复后的纯计时计划均
自然遍历 SessionEngine，不截断最后 phase；原捕获自然完成 6/6。
另覆盖 5/10/20 分钟各自的卡片恰好下限、下限外 1 秒、执行恰好上限、上限外 1 秒，
以及锁死 335 秒后拒交、main 多轮、circuit 分支、手动计次仍拒绝超差、回调异常原子拒绝。

## 验证与真实模型

最终三包全量通过：`ugk_coach` **1432**、`ugk_coach_ui` **178**、
`ugk_trainer` **564**；三个包 `dart analyze --fatal-infos` 均为 **0 问题**。
新增 Coach 67 项、Trainer 33 项测试，既有测试及期望值没有修改。
默认 golden 4 项 / 16 张图全部通过，像素差异为 0，未更新基线图。
`PlanBuilder._fit` 方法体与 main 700d010 完全相同。

真实模型最终计划双门禁：**HipLab 7/7、SF 7/7**，每个宿主按五次 5 分钟、一次 10 分钟、
一次 20 分钟独立执行。SF five-3 与 ten-1 含手动计次，明确标“估算”；另外 12 项自然
遍历 SessionEngine 至完成。HipLab 总 90 次调用 / 228046ms；SF 总 116 次 / 328361ms。
每次最终轮及完整三轮的卡片/执行秒数、调用数和耗时见
[真实门禁报告](reports/fit-executed-duration-20261101/README.md) 和
[可核对计划/时间线 JSON](reports/fit-executed-duration-20261101/results.json)。

中间失败单列：SF five-3 的第 2 轮推荐动作连续三次 `show_actions` 遇到
`unseen_actions`，达到既有重交上限，返回 error；第 3 轮仍按预设用户输入执行并通过
双时长门禁。没有重抽或补答。14/14 指最终计划时长门禁，所有三轮合计 41/42 轮成功；
不将该推荐失败写成成功，也未在本分支修改与时长无关的任务切换链路。

真实测试命令：

```powershell
dart run tool/eval_executed_duration.dart --host hiplab --out <新证据目录>
dart run tool/eval_executed_duration.dart --host smartfit --out <新证据目录>
```

每个宿主七次独立三轮会话，最后一轮目标为 5 分钟五次、10/20 分钟各一次。
每次新建 Agent/Controller，不补答、不重抽、传输重试为零；保留失败样本。
模型为授权 gateway 的 `deepseek-flash`，thinking on；凭据沿用既有授权评测配置，
不写进代码、文档或证据。保存公开工具记录、计划、调用数、耗时和源码指纹，剔除密钥、
headers、私有 reasoning。只读宿主源码和素材，不操作设备、不播放音频。
