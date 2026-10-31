# main 多轮执行与配时对账

基线：SDK main `5321e85710a09e22da9e173ff443ac4567ab2f08`。
分支：`codex/main-rounds`。推送本分支供 Hark 审核，审核前不合 main；不打 tag。

## 修复范围

训练器此前只展开 `circuit && rounds > 1`，因此 Coach 合法生成的 main 多轮被折叠为一轮。
现在 main 和 circuit 都按轮展开完整动作列表，每个 occurrence 有独立进度索引与 round/rounds。
main 每轮保留原 sets、组间休息、左右侧、换侧和分段顺序；circuit 原有每轮单组规则不变。
轮间仍使用原训练器口径 `max(restBetweenRoundsSeconds, transitionSeconds)`，默认下限 15 秒，
没有为了凑卡片数字额外增加休息。

训练页显示既有 `TrainerStrings.roundOf` 的轮次文案；保留原剂量/组数/侧别文本。
轮完成和下一轮语音沿用 circuit 链路，main 多组预告仍报组数。
跳过、上一个、提前结束、完整完成统计和未知动作的 plannedSets 都按实际轮数处理。
没有新增或改变公开接口。

经开哥选择，Coach 的 `PlanDuration` 以训练器为准：轮休已覆盖到下一轮首动作的过渡，
不再重复加一次 transition。比如单动作 100 秒、两轮、默认准备 10 秒、轮休下限 15 秒，
总时长由 240 秒修正为 `10 + 100 + 15 + 100 = 225` 秒。
`PlanBuilder`、`plan_timing`、剂量搜索顺序、可用范围和容差规则均未修改；估时变化后仍由
原配时器重新选择剂量。

## 重新配时门禁

测试实际调用现有 `PlanBuilder.draft` 和已保存 circuit 的 `refit`，使用真实 PoseHub 目录、
HipLab profile 和六个双侧动作。不是手工把工作秒数改到目标值。
每个目标各覆盖 main 与 circuit，共 8 例；卡片 estimate、原始 phase 总和和引擎 visits 一致，
误差不超过 1 秒，并使用现有 10% 配时门槛（同时不宽于 profile 容差）。

| 目标 | main 实际 / 轮数 | circuit 实际 / 轮数 | 对目标误差 |
| --- | --- | --- | --- |
| 5 分钟 / 300 秒 | 315 秒 / 1 | 315 秒 / 1 | 5.00% |
| 10 分钟 / 600 秒 | 627 秒 / 2 | 627 秒 / 2 | 4.50% |
| 20 分钟 / 1200 秒 | 1255 秒 / 3 | 1255 秒 / 3 | 4.58% |
| 30 分钟 / 1800 秒 | 1883 秒 / 4 | 1883 秒 / 4 | 4.61% |

另有 12 个逐 phase/engine 契约用例覆盖 main/circuit 的 rounds 1/2/3、双侧、多组、
分段、轮休 0/5/15/50 秒和 warmup/main/cooldown 混合块。
契约比较的是同一节奏事实、同一准备参数下的计划。宿主另外提供的节奏或准备覆盖不能
默认为 Coach 已知数据，真实现场回放因此单独保留原始配置并解释差额。

## 三份真实原稿重放

以下为修复后对原 JSON 重新估时与离线执行排程；没有重写原计划剂量、调用模型、修改 App
或操作设备。卡片列是 SDK `PlanDuration` 的重算值，含其默认 10 秒准备；不代表已在设备
刷新缓存卡片。执行列使用各现场原始节奏和准备参数。

| 原稿 | 捕获卡片估时 | 重算卡片估时 | 执行主体（不含准备） | 宿主准备 | 执行总时长 |
| --- | ---: | ---: | ---: | ---: | ---: |
| HipLab「居家开胯入门」v1，目标 10 分钟 | 629 秒 | 614 秒（10分14秒） | 609 秒 | 15 秒 | 624 秒（10分24秒） |
| HipLab「大腿内侧开胯短练」v2，目标 5 分钟 | 315 秒 | 300 秒（5分） | 292 秒 | 15 秒 | 307 秒（5分7秒） |
| SF 已验收五分钟 v3，6 动作、main 一轮 | 313 秒 | 313 秒（5分13秒） | 335 秒 | 10 秒 | 345 秒（5分45秒） |

HipLab 原故障的主体执行分别为 446/197 秒，加现场准备是 461/212 秒。修复后 11/6 个
occurrence 全部按原稿走完，两轮 main 的 planned/completed sets 正确计为 2。
HipLab 卡片和含准备执行的 10/7 秒差额可以逐项对账：宿主准备比 Coach 默认多 5 秒，
原始动作 kit 又分别有 5/2 秒起拍 lead；Coach 的原现场 catalog 只提供每次动作周期，未带
这些外部 lead。若训练器也使用 10 秒准备，执行总时长为 619/302 秒。

SF 原稿只有一轮，本次轮次/轮间修复不改变它。其已有 32 秒差异来自另一处目录/节奏
口径：当时 AI 目录投影没有视频源的 `repSeconds`，Coach 按每次 3 秒估算；宿主用
`rhythm.execution`，深蹲多 10 秒、靠墙天使多 10 秒、反向卷腹多 12 秒。测试显式保留
原稿与差额，没有注入 cadence、改变剂量或把契约容差放宽到 32 秒。

### SF 宿主如何统一目录估算与执行节奏（仅接入说明）

本节说明宿主后续怎么配置，不在本分支实施。SF 原稿及回归仍保留卡片 313 秒、执行
345 秒的现场事实。宿主应在创建 CoachAgent/PlanBuilder 之前生成一致的目录视图，
同时把同一份节奏配置传给 TrainerPlayer，而不是修改已验收的原始素材包或计划剂量。

**字段入口：** 普通 `mode=reps` 动作的 Coach 估时读取原始 catalog JSON 的
`drills[*].assets.video.sources[*].repSeconds`（单位：秒/次）；Dart 对应
`Drill.assets.videos` 中首个 `repSeconds > 0` 的视频源。缺省回退为 3 秒/次。
JSON 中是单数 `video.sources`，不是 `assets.videos`。有效源还必须有 `app` 和真实
`path`，否则解析器会丢弃该条记录。应更新估时实际选中的首个有效源，避免前面的旧值
仍优先生效；只在数组末尾追加新值不保证生效。

例如，宿主在传给 Coach 的目录视图中补齐深蹲的周期：

```json
{
  "id": "h-squat",
  "assets": {
    "video": {
      "status": "ok",
      "sources": [
        {
          "app": "pose-hub",
          "path": "media/h-squat/h-squat-r3/h-squat.rgb-alpha.mp4",
          "repSeconds": 4.0
        }
      ]
    }
  }
}
```

这是字段示意，宿主合并时保留动作和资产的其他字段。示例 path 来自该原稿的
`files.video.path`；宿主使用自己已校验媒体版本中的真实值。
修改的是传入 `Catalog.fromJson(...)` 的规划目录视图，不重写下载清单、原文件或校验 SHA。

**不带额外起拍的统一周期方案：** 对这份 SF 原稿的四个计次动作，目录与执行共用下列
秒/次值：`h-squat=4`、`h-wall-angel=4`、`h-reverse-crunch=4`、`w-dead-bug=3`。
将这些值分别写入上述目录字段，并显式覆盖执行节奏：

```dart
const repSecondsById = <String, double>{
  'h-squat': 4,
  'h-wall-angel': 4,
  'h-reverse-crunch': 4,
  'w-dead-bug': 3,
};
final rhythms = rhythmsFromCatalog(
  coachCatalog, // 已补齐视频源 repSeconds 的同一份目录。
  overrides: {
    ...existingExecutionRhythms, // 保留其他动作的既有配置。
    for (final entry in repSecondsById.entries)
      entry.key: Rhythm.fromRepSeconds(entry.value),
  },
);
// 将 rhythms 传给 TrainerPlayer；Coach 使用上面的 coachCatalog。
```

按此配置对该原稿做临时内存对照，卡片与 phase 总和均为 344 秒；未回写宿主、素材或
夹具，原始回归的 313/345 秒仍保持不变。

`Rhythm.fromRepSeconds` 的 lead 为 0，执行每侧每组时长为 `reps × repSeconds`，与普通
计次估时一致。计时动作继续使用计划 `workSeconds`；准备、换侧及过渡参数也应统一。
显式 overrides 很重要：`rhythmsFromCatalog` 优先级是 overrides、顶层 `rhythm`、
目录 holdSeconds、视频源 repSeconds、默认值。SF 的嵌套 `rhythm.execution` 是宿主
适配约定，需要宿主解析后传 overrides；仅补该嵌套对象不会让 Coach 自动读取它。

**保留原 execution/lead 的方案：** 固定起拍是一次性开销，不是每次周期。这份原稿的
深蹲有 1 秒 lead，仅将目录周期补成 4 秒仍会留下这 1 秒；不要把它均摊成一个随 reps
变化的“每次秒数”。若宿主保留含 lead、细分相位及对应语音的原始 execution，应把这些
开销单独对账；卡片的实际排程时长可用同一 `SessionBuilder(rhythms: ..., prepSeconds: ...)`
排出的 `phases(plan)` 累加 `seconds` 获取（含准备），而非它不含准备的 `planSeconds`。
普通计次的 `PlanDuration` 当前不读取该固定 lead；让 Coach 配时也支持完整 execution
仍需后续独立对齐，不能把单独改卡片显示当作配时器已对齐。

恒速无 lead 方案会改变原先的起拍及细分相位语音，宿主需按自己的执行体验选择；本分支
不切换任何宿主节奏、不修改上述真实夹具，也不处理这 32 秒差异。宿主完成配置后应以
同一原稿、相同准备参数比较 Coach 估时与实际 phase 总和，再刷新或重新生成卡片估时。

真实原稿、最小目录、原始 kits/执行节奏以及 SHA/捕获位置分别位于：

- [HipLab 夹具说明](../packages/ugk_trainer/test/fixtures/hiplab/main-rounds/README.md)与[来源清单](../packages/ugk_trainer/test/fixtures/hiplab/main-rounds/manifest.json)。
- [SF 五分钟夹具说明](../packages/ugk_trainer/test/fixtures/smartfit/five-minute/README.md)与[来源清单](../packages/ugk_trainer/test/fixtures/smartfit/five-minute/manifest.json)。

## 既有测试期望逐项变更

没有改生产配时规则，也没有放宽旧测试的 10% 门槛。仅以下 5 个既有用例受估时变化影响：

| 文件 / 用例 | 旧值 → 新值 | 原因 |
| --- | --- | --- |
| `test/plan_timing_normalization_test.dart`：structured fit changes | `afterEstimatedSec` 240 → 225 秒；before 110 不变 | 两轮之间少计一次重复的 15 秒过渡。 |
| 同文件：interior integer-dose gap | 估时 240 → 225 秒；误差 33⅓% → 25%；区间端点 110/240 → 110/225 | 目标仍为 180 秒，相同合法剂量按新算术仍超出 10%，`withinTolerance=false` 不变。 |
| 同文件：bounds include legal unsearched rounds and rest | 估时 500 → 455 秒 | 四轮有三处边界，去掉 `3×15` 秒重复过渡；原有不误判不可行的断言保留。 |
| 同文件：proven maximum shorter than target | `maxEstimatedSec` 640 → 625 秒；min 110 不变 | 两轮、每轮三组 100 秒，加准备 10 秒与一次轮休 15 秒。 |
| `test/output_gate_test.dart`：stale segmented card success | 成功夹具目标 7 → 8 分钟（420 → 480 秒），输出 `targetMinutes` 7 → 8；保留 10% 判断并新增精确估时 479 秒断言 | 原 7 分钟案例在修正算术后最优候选为 479 秒，超出 10%；8 分钟是同一原始分段结构的合法达标点。保留分段、动作、设备和不额外追问检查。 |

原来的 7 分钟场景没有删除：新增独立回归，实测仍为 479 秒，误差 `59/420=14.047619%`，
明确要求 `withinTolerance=false` 并显示“配时误差 14.0%。”，防止将近似结果误报达标。
这是原有离散剂量空隙处理规则，未改为放宽容差或伪造达标。

## 验证文件

- [phase 与 engine 时长契约](../packages/ugk_trainer/test/plan_duration_rounds_contract_test.dart)：12 例。
- [5/10/20/30 分钟真实配时契约](../packages/ugk_trainer/test/plan_fitter_trainer_contract_test.dart)：8 例。
- [main 多轮行为、语音和结果](../packages/ugk_trainer/test/main_rounds_behavior_test.dart)：12 例。
- [main/circuit 轮次文案与进度](../packages/ugk_trainer/test/main_rounds_player_test.dart)：2 例。
- [HipLab 两份真实计划](../packages/ugk_trainer/test/hiplab_main_rounds_test.dart)：7 例。
- [SF 原五分钟计划](../packages/ugk_trainer/test/smartfit_five_minute_replay_test.dart)：4 例。

全量结果：

| 包 | 全量测试 | `dart analyze --fatal-infos` |
| --- | --- | --- |
| ugk_coach | 1305 通过（新增 1，按上表调整 5 个既有用例） | 0 问题 |
| ugk_coach_ui | 158 通过（未改代码或测试） | 0 问题 |
| ugk_trainer | 485 通过（新增 45） | 0 问题 |

Coach 使用 `dart test --concurrency=1 --reporter expanded`，两个 Flutter 包使用
`flutter test --no-pub --reporter expanded`。两份 HipLab 与 SF 原稿、目录和原始节奏的
来源/文件哈希验证通过；改动格式和 `git diff --check` 通过，公开导出与方法签名不变。
