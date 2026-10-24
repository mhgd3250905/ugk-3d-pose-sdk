# ugk_coach_ui 0.1.0

给 HipLab / Flare / SmartFit 共用的 Flutter 聊天呈现包。聊天列表的进入动画、消息气泡、询问气泡，以及单动作/多动作套路卡的展开布局与动画由本包实现；产品颜色、字体、文案、素材和操作由 App 注入。

仅依赖 Flutter，不依赖 `ugk_coach`、`ugk_trainer` 或任何 App。App 应先用 coach 门禁校验模型输出，再映射为本包的 DTO。本包不把 DTO 当成可信训练计划，也不会替 App 校验或执行训练。

## 安装

2026-10-24 已经开哥批准合入并推送 main，正式 tag 如下。后续仅更新发布状态的文档提交不会移动 tag。

| 包 | 固定 tag | 完整 SHA |
| --- | --- | --- |
| coach_ui | `ugk_coach_ui-v0.1.0` | `f0ea0647586913b205fc6dbb75fc9f97cedc55ce` |
| trainer | `ugk_trainer-v0.2.1` | `f0ea0647586913b205fc6dbb75fc9f97cedc55ce` |
| coach | `ugk_coach-v0.4.1` | `88da65ab4e7d6753ab548d779f4168f023dbf9f8` |

App 使用：

```yaml
ugk_coach_ui:
  git:
    url: https://github.com/mhgd3250905/ugk-3d-pose-sdk.git
    path: packages/ugk_coach_ui
    ref: ugk_coach_ui-v0.1.0
```

```dart
import 'package:ugk_coach_ui/ugk_coach_ui.dart';
```

## 对外接口

| 接口 | 输入与用途 |
| --- | --- |
| `CoachChatList` / `CoachChatEntry` | 输入按时间正序的行快照及内容 widget；内部反向列表保证最新消息在底部。接收 App 所有的 `ScrollController`、时间标签 builder、顶部渐隐颜色、输入栏占高、typing widget 和初始已读 ID 集合。 |
| `CoachMessageBubble` / `CoachBubbleData` | 文字、用户/助理角色、可选标题、选项与已选索引；`optionsActive` 控制可答状态，`onOption` 回传索引。可替换 `optionBuilder`。 |
| `CoachQuestionBubble` / `CoachQuestionData` / `CoachQuestionMode` | 一个澄清问题，`text` 或 `choice`；支持单选立即回答，多选先切换再确认。接收 `enabled`、`onTextAnswer`、`onChoiceAnswer`。`answered`、`answeredChoices` 用于历史展示。 |
| `CoachPlanCard` | 接收 `CoachRoutine`、`CoachExerciseLibrary`、`saved`、`landing`；`onStart(CoachOriginRect)`、`onSave()`、`onOpen()` 全由 App 执行。紧凑单动作 130px，多动作 240px；保留展开/收起与减弱动态效果。 |
| `CoachRoutine` / `CoachRoutineItem` | 预先本地化的标题、总时长、器械/水平/元信息、调整说明和剂量；`detailDose` 可表达循环内单组或一组多段摘要。无网络/训练引擎依赖。 |
| `CoachExerciseLibrary` / `CoachExercise` / `CoachMediaPalette` | App 可信动作目录的 ID、名称、分类、提示词、主题匹配的 asset 路径、可选动态/静态 cutout 与媒体底色/文字色。路径由 App 解析，勿直接采用模型提供的路径。 |
| `CoachUiTheme` / `CoachUiStyle` | 按 widget 子树注入 `colors`、`typography`、`strings`、`builders`；各 App 或并列聊天视图可使用不同主题，无全局可变配色。未注入时使用 Flutter Material Theme。 |
| `CoachUiColors` / `CoachUiTypography` / `CoachUiStrings` | 语义颜色、文字样式、所有固定文案及时间/详情标签函数。`CoachUiTheme` 也把字体样式传给内部文字，App 无需采用任何固定品牌字体。 |
| `CoachUiBuilders` | 可注入 `pressable`、`controlFace`、`textAction`、`surface`、`icon`、`startButton`，保留现有玻璃/图标/触感体系；列表、气泡、卡片核心布局仍在 SDK。回调参数分别为同名 `Coach*` 控件，包含其数据、事件及 `child`。 |
| `CoachGreetingBlock` / `CoachTimeMark` / `CoachTypingBubble` | 问候、时间及等待气泡。typing 可注入进度标签和取消回调。 |
| `CoachOptionPill` / `CoachAppear` | 可复用的选项和进入动画；减弱动态效果遵循 `MediaQuery.disableAnimations`。 |

`CoachOriginRect` 为 `Rect? Function()`：App 可在进入与退出播放器时读取卡片的实时屏幕位置。`coachRectOf` 提供已布局 widget 的安全矩形读取。

## 接入 ask_user

1. App 订阅 agent 进度，但仅在 `await agent.send(...)` 返回后，把通过门禁的 `result.question` 映射成 `CoachQuestionData` 并启用回答。
2. `result.text` 与问题正文相同。渲染问题气泡时跳过普通正文，防止重复两条问题。
3. `text` 使用 `onTextAnswer`；`choice` 使用 `onChoiceAnswer` 的原选项字符串列表。单选回传一项；多选回传按原选项顺序排列的已选项。
4. App 立即关闭旧问题的回答状态、保存用户气泡，然后把答案作为同一个 agent 的下一条消息发送。不要为一次回答重建 agent，才能继续多轮澄清并生成套路。
5. 新问题/套路到来、取消、新对话、销毁或恢复历史后，由 App 决定哪些问题仍有效。持久化历史不自动恢复 agent 的待答任务；过期问题传 `enabled: false`。等待异步回答回调期间，本包也会临时禁止重复提交。

App 仍负责：AI Key 有无的入口开关、HTTP client/endpoint/Key、coach 事件和多轮会话、模型输出门禁、回答校验、储存、导航、训练启动与失败提示。网络调用通过呈现数据和回答回调对接，不向本包传入接口地址或密钥。

## 可编译示例与验证

[`example/lib/host_conversation.dart`](example/lib/host_conversation.dart) 展示完整组合：App 的消息 view model 映射到列表、普通气泡、澄清气泡和套路卡；回答、保存、查看详情与开始训练均为外部回调。该示例参与包的分析，并由 widget test 实际挂载。

```dart
final style = CoachUiStyle(
  colors: CoachUiColors.fromTheme(appTheme),
  typography: CoachUiTypography.fromTheme(appTheme),
  strings: const CoachUiStrings(
    answerHint: '说说你的情况',
    submitAnswer: '继续',
    save: '保存',
    saved: '已保存',
    start: '开始训练',
  ),
);
// CoachUiTheme(style: style, child: HostConversation(...));
```

包目录执行 `flutter analyze`、`flutter test`。覆盖文字/单选/多选交互、异步重复提交保护、历史禁用、独立主题和文案、套路展开与操作回调、列表追加，以及公开接入示例。
