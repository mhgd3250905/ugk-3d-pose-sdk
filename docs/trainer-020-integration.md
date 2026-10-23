# ugk_trainer 0.2.0 接入契约

2026-10-23，分支 `codex/trainer-shared-player`，基于 SDK main `b8f5b82bcf6f4075480fa6fb2382acea4c44b9c0`。开哥已批准验收提交 `64a54874307449c8685577f8eeb913296b207a7c`，现已快进合入 main；后续收束仅更新批准状态文档。根包配套 `ugk_coach 0.4.1`（分段数据模型），训练包 `ugk_trainer 0.2.0`。本次没有发布目录、语音素材或 pub.dev 包。

依据开哥转交的 FlareLab `sdk-shared-player-audit-2026-10-23.md`：SDK 负责训练计数与语音节奏，App 提供目录、素材、语言、主题和结果存储。计数代表按计划引导的进度，不是动作识别结果。

## 旧接入与升级

旧 `PlanItem`、无 segments 的 TrainingPlan v1 JSON、`TrainerPlayer` 构造、SmartFit repSeconds、HipLab action-kit 和结果 JSON 保持支持。新增播放器按钮默认隐藏，App 不开开关时仍用原控件布局。**行为调整：无节奏的次数动作现在自动报数并完成；不会默认等待“完成本组”。** 原有显式 `Rhythm.selfPacedReps` API 为已有接入保留；新目录应仅对技术尝试明确写 `rhythm.kind: self_paced`，不要把缺资料等同自主计次。

**既有根包升级障碍：** ugk_coach 0.4.0 新增 `AgentEventKind.askUser`，对旧穷举 switch 是源码破坏性变更。升级到 0.4.0/0.4.1 必须补该分支，问题 UI 见 [ask_user](ask-user.md)。本次没有修改 SmartFit 原 App；它的聊天页修复和 ask_user 气泡由 App 后续统一接入。不能把本次 trainer 回归解释为旧 App 无修改即可升级整个 coach 包。

## 自动节奏

```dart
const defaults = RhythmDefaults(
  defaultRepSeconds: 3,
  categoryRepSeconds: {
    'strength': 3, 'core': 3, 'cardio': 3,
    'mobility': 4, 'stretch': 3,
  },
);
final rhythms = rhythmsFromCatalog(catalog, defaults: defaults);
// TrainerPlayer(..., rhythms: rhythms, rhythmDefaults: defaults)
// 或 SessionBuilder(rhythms: rhythms, rhythmDefaults: defaults)
```

优先级：App `overrides` > 目录 `rhythm` > `defaultDose.holdSeconds` > 明确定义的素材 `repSeconds` > 分类缺省值 / 全局缺省值。默认五类 strength/core/cardio/mobility/stretch 都为 3 秒/次；`categoryRepSeconds` 是替换整个映射，未列出的类使用 `defaultRepSeconds`。所有覆盖时长必须为有限正数。视频 `loopSeconds` 永远不参与单次节奏推断。

time 剂量无节奏仍按 `workSeconds` 倒数。reps 无节奏会在每次拍尾报数，到 `reps × 每次秒数` 自动结束本侧/组。停留型缺省以 `holdSeconds` 作为完整单次秒数，不再额外加 3 秒；已有 authored rep_hold 节奏则保留运动相位并替换其 hold 相位。目录带 `self_paced` 才等待主动完成，不需要用户逐次点数。

目录核对结果见 [51 项 JSON](trainer-020-catalog-guidance-2026-10-23.json)：快照 SHA-256 `a6b4699883abb9769ad68aab3d54c3fbeef686cd15bee8bd1cb054c454ea4614`，51 项全部能自动引导，其中 41 项缺省、2 项已有节奏、8 项计时。可复跑：在 trainer 包执行 `dart run tool/audit_catalog_guidance.dart <catalog.json>`。

Pose-Hub 后续为这 41 项补正式 rhythm 并发目录版本；SDK 不擅自给目录写固定运动学节奏。`scapular-A`（Y/T/W）、`forearms-A`（多方向腕部摇摆）、`forearms-B`（腕屈+腕伸）需由目录/计划作者明确分段剂量，SDK 不从动作名猜分段。

**selfPaced 待开哥确认清单：** 此 51 项体能目录中没有“托马斯试做”或其它明确技术尝试项，因此当前建议标记清单为空，41 项不批量标 selfPaced。后续若加入“托马斯完整试做 N 次”“托马斯衔接/连续圈尝试 N 次”等技术任务，建议显式 `self_paced`；这些是待确认的任务类别，不是捏造的已存在动作 ID。半程土耳其起立、北欧离心等仍采用自动节奏，实际精细速度由 Pose-Hub 补齐。

## 一组多段

```dart
final item = PlanItem(
  exerciseId: 'scapular-A', mode: DoseMode.reps, sets: 2,
  perSide: false, restSeconds: 30,
  segments: const [
    PlanSegment(id: 'y', exerciseId: 'y-drill', label: 'Y',
      mode: DoseMode.reps, reps: 8),
    PlanSegment(id: 't', exerciseId: 't-drill', label: 'T',
      mode: DoseMode.time, workSeconds: 20),
    PlanSegment(id: 'w', exerciseId: 'w-drill', label: 'W',
      mode: DoseMode.reps, reps: 8, holdSeconds: 2),
  ],
);
```

示例分段素材 ID 是占位，必须换成 App 已有且目录允许的真实 ID；SDK 不生成素材。每个段的 `exerciseId` 解析各自媒体、语音及目录节奏；`label` 仅为 App 本地化显示文字。可选 `rhythm` 使用目录同形的 JSON（kind、leadSeconds、phases、holdSeconds、reps），不能内联 `self_paced`；自主计次由目录/已有显式 App rhythm 提供。`holdSeconds` 是正整数。父段的组数、侧别和休息由父 PlanItem 统一定义。每段需要与 mode 匹配的正整数 reps/workSeconds，段 ID 在父项内唯一。

执行次序为每组逐段、每段完成所有必需侧，然后下一段；最后才组间休息。一个父项显示一条训练进度、一个结果项，当前段有自己的媒体/剂量/字幕。父 reps/workSeconds 在有非空 segments 时可省略；无 segments 的旧剂量规则不变。`PlanCodec` 保留所有段，坏段报错而不静默丢弃；旧编码不输出空 segments。`TrainingPlan.exerciseIds` 包含父 ID 和分段 ID，用于预取。

自定义 `SessionBuilder` 必须保留 `itemIndex/blockIndex/itemInBlock/set/side/segmentId` 与 `segment`，`SessionPhase.item` 指父项、`exerciseId` 指分段素材。旧自定义相位如果把 Y/T/W 都编码为同一身份且没有 segmentId，SDK 无法判断它们是三段还是重练；须迁移到 segments 或显式 segmentId。`skipSegment(t)` 只跳当前段剩余侧，`skip(t)` 保持跳整个计划项的旧语义。

本轮分段由 App/目录作者提供，未扩展 Agent 的工具生成 Schema 或排课提示词。正式 [TrainingPlan JSON Schema](../schema/coach-reply.schema.json)、PlanCodec 与校验器均接受此可选数据扩展；SDK 不会从“Y/T/W”名字自动生成分段素材和剂量。

## 完成统计

完成身份是 `(itemIndex, set, side, segmentId)`，每个唯一组的全部必需侧和段完成才加一。`previous()` 重练的活动秒数累计，已完成身份去重，不能替代未完成的组；左先行/右先行没有不同口径。跳过复合项的段记 partial；完全完成后才为 completed。提前完成计时段记 `PhaseExit.completed`，这是用户主动结束该段，非自然到时。

统计依据最初工作相位要求，后续疼痛过滤/缩减不会冒充完成原计划。`ItemResult.plannedSets/completedSets` 按实际初始组身份；普通计划等于组数（循环为轮数），自定义右3组/左2组时有3个必需组，前2组需双侧，第3组只需右侧。每侧计数必须完成该侧全部段。整场 `fullyCompletedExercises` 同样检查全部身份；导航位置 `completedExercises` 仍可包含跳过，勿用于实际完成统计。结果 schema 仍为 `ugk-session-result@1`。

## 可选操作与平台策略

`TrainerPlayer` 新增 `showExtendRest`、`showCompleteTimedPhase`、`showSoundToggle`、`showSkipSegment`，均默认 false。打开后分别显示休息 +15 秒、计时工作段提前完成、训练声音开关、跳过分段。`TrainerStrings` 新增同名相关文案都有默认值；已有自定义构造不需增加必填参数。声音开关控制当前训练口令与提示音，App 原持久化设置仍由 App 管理。

自建 UI 可用 `SessionEngine` / `SessionRunner` 的 `extendRest(activeSeconds, seconds: 15)`、`completeTimedPhase(activeSeconds)`、`skipSegment(activeSeconds)`，返回是否执行成功；参数是暂停时间已扣除的绝对活动秒数。提前完成只适用于计时工作段，计次数按 SDK 节奏推进；休息延长不会重播开场或已过的提示。

统一策略：切后台、锁屏继续计时和播报；Android 使用本包唯一 mediaPlayback 前台服务、唤醒锁及静音保活轨，App 配置通知图标及 Play Console 前台服务用途。iOS 必须启用 `UIBackgroundModes: audio` 并使用支持保活的音频输出。Web 不承诺移动系统级锁屏保活。

来电、系统音频中断或耳机断开自动暂停；中断结束保持暂停，用户点继续才恢复。中断期间禁止提前续跑；不适弹窗返回也不能绕过新发生的中断。App 自定义 `VoiceOutput` 要同时实现 `InterruptibleVoiceOutput` 并上报事件才能遵循此策略。系统功能需宿主真机验收；本次单测/代码验证不等于小米长时间锁屏、iOS 来电和原生视频已通过。

## 语音素材清单

SDK 不做 TTS、不内置新语言口令，只调度 App 的 `VoiceSource`。HipLab 可继续用 `ManifestVoiceSource`，SmartFit 继续用 `DrillPackVoiceSource`。目标语言缺失时不偷偷改读中文；按 App 提供的提示音和屏幕倒数降级。未打包提示音时也无法凭空发声。

`ManifestVoiceSource.fromJson` 的最小结构示例（数字为真实文件毫秒时长，示例须替换）：

```json
{
  "clips": {"zh": {"p.go": 500, "n.1": 300, "n.2": 300}},
  "chimes": {"start": 340, "tick": 70, "end": 380, "finish": 700},
  "lines": {"p.go": {"zh": "开始"}},
  "texts": {}
}
```

默认根路径 `assets/voice`；口令位于 `<root>/<lang>/<key>.m4a`，提示音位于 `<root>/chime/<name>.m4a`。完整素材应覆盖开始/暂停/继续/结束、准备/休息/换侧、各目标数字、所用秒数短语、动作名称/要点、节奏词；文件和清单均由 App 打包。逐段名称使用分段动作的 name 语音，无素材时回落提示音；label 不自动转语音。完整清单格式可参考 [HipLab 测试清单](../packages/ugk_trainer/test/fixtures/hiplab/manifest.json)及 [VoiceSource](../packages/ugk_trainer/lib/src/voice/voice_source.dart)。
