# ugk_coach_ui 0.1.4

`0.1.4` 本地候选移除消息和计划卡的子树透明合成：入场/展开继续使用原几何时间线、位移和缩放，显隐改为有界裁剪，圆点和scrim直接绘制颜色alpha。列表key、卡片状态、飞图坐标与开始/保存/详情回调保持；材质和图标继续由宿主builders提供。没有新增用户开关或旧透明路径fallback，旧tag不移动；本候选尚未发布。

`0.1.3` 新增可选 `CoachUiBuilders.media` 和 `CoachPlanCard.cutoutTopInset`，让宿主绘制带透明边界裁剪的素材，紧凑封面与展开飞行动画共用同一渲染入口。默认值保持旧素材与卡片几何。测试分支发布 tag 为 `ugk_coach_ui-v0.1.3`，旧 tag 不移动。

`0.1.2` 新增聊天列表的宿主可选参数 `topInset` 与 `fadeTop`，供透明系统状态栏下的真实内容滚动使用。本轮在分支验证后发布新 tag；旧 `ugk_coach_ui-v0.1.1` 不移动。两参数默认值保持既有宿主的列表几何与顶部渐隐。

`0.1.1` 已批准发布：修复展开套路卡在 320px / 2 倍字体时的长中文剂量、循环与分段剂量溢出。该指定回归在浅深主题均通过，包含在 UI 21 项通过记录中；剂量不缩字、不截断，行高与媒体/飞行动画共享测量。配套 coach 0.4.2、trainer 0.2.2 仅修 ASCII 包清单与依赖 tag。公开接口兼容 0.1.0，Flutter 最低版本为 3.44.0；本轮验收和 SmartFit 正式远端锁文件验证使用 Flutter 3.44.7。

给 HipLab / Flare / SmartFit 共用的 Flutter 聊天呈现包。聊天列表的进入动画、消息气泡、询问气泡，以及单动作/多动作套路卡的展开布局与动画由本包实现；产品颜色、字体、文案、素材和操作由 App 注入。

仅依赖 Flutter，不依赖 `ugk_coach`、`ugk_trainer` 或任何 App。App 应先用 coach 门禁校验模型输出，再映射为本包的 DTO。本包不把 DTO 当成可信训练计划，也不会替 App 校验或执行训练。

## 安装

下表保留 2026-10-24 已发布的 0.1.1 配套快照。使用新增系统栏参数时须固定本轮 `ugk_coach_ui-v0.1.2`，不要移动旧 tag。

| 包 | 固定 tag | 完整 SHA |
| --- | --- | --- |
| coach_ui | `ugk_coach_ui-v0.1.1` | `3302d6235a39e2c2b4b51fa196cc32b37c31b54c` |
| trainer | `ugk_trainer-v0.2.2` | `3302d6235a39e2c2b4b51fa196cc32b37c31b54c` |
| coach | `ugk_coach-v0.4.2` | `3302d6235a39e2c2b4b51fa196cc32b37c31b54c` |

App 使用：

```yaml
ugk_coach_ui:
  git:
    url: https://github.com/mhgd3250905/ugk-3d-pose-sdk.git
    path: packages/ugk_coach_ui
    ref: ugk_coach_ui-v0.1.2
```

```dart
import 'package:ugk_coach_ui/ugk_coach_ui.dart';
```

## 对外接口

| 接口 | 输入与用途 |
| --- | --- |
| `CoachChatList` / `CoachChatEntry` | 输入按时间正序的行快照及内容 widget；内部反向列表保证最新消息在底部。接收 App 所有的 `ScrollController`、时间标签 builder、顶部渐隐颜色、输入栏占高、typing widget 和初始已读 ID 集合。`topInset`（默认 0）仅增加列表内容顶部留白，`fadeTop`（默认 true）控制原有顶部渐隐。 |
| `CoachMessageBubble` / `CoachBubbleData` | 文字、用户/助理角色、可选标题、选项与已选索引；`optionsActive` 控制可答状态，`onOption` 回传索引。可替换 `optionBuilder`。 |
| `CoachQuestionBubble` / `CoachQuestionData` / `CoachQuestionMode` | 一个澄清问题，`text` 或 `choice`；支持单选立即回答，多选先切换再确认。接收 `enabled`、`onTextAnswer`、`onChoiceAnswer`。`answered`、`answeredChoices` 用于历史展示。 |
| `CoachPlanCard` | 接收 `CoachRoutine`、`CoachExerciseLibrary`、`saved`、`landing`；可选 `cutoutTopInset` 指定 cutout 在外卡坐标中的顶部位置，默认 null 保持旧位置。`onStart(CoachOriginRect)`、`onSave()`、`onOpen()` 全由 App 执行。紧凑单动作 130px，多动作 240px；保留展开/收起与减弱动态效果。 |
| `CoachRoutine` / `CoachRoutineItem` | 预先本地化的标题、总时长、器械/水平/元信息、调整说明和剂量；`detailDose` 可表达循环内单组或一组多段摘要。无网络/训练引擎依赖。 |
| `CoachExerciseLibrary` / `CoachExercise` / `CoachMediaPalette` | App 可信动作目录的 ID、名称、分类、提示词、主题匹配的 asset 路径、可选动态/静态 cutout 与媒体底色/文字色。路径由 App 解析，勿直接采用模型提供的路径。 |
| `CoachUiTheme` / `CoachUiStyle` | 按 widget 子树注入 `colors`、`typography`、`strings`、`builders`；各 App 或并列聊天视图可使用不同主题，无全局可变配色。未注入时使用 Flutter Material Theme。 |
| `CoachUiColors` / `CoachUiTypography` / `CoachUiStrings` | 语义颜色、文字样式、所有固定文案及时间/详情标签函数。`CoachUiTheme` 也把字体样式传给内部文字，App 无需采用任何固定品牌字体。 |
| `CoachUiBuilders` | 可注入 `pressable`、`controlFace`、`textAction`、`surface`、`icon`、`startButton`，保留现有玻璃/图标/触感体系；可选 `media(context, CoachMediaRequest)` 返回 Widget 或 null（使用默认 Image.asset）。列表、气泡、卡片核心布局仍在 SDK。 |
| `CoachMediaRequest` | 可信目录中的 `exercise` 与所选 `asset`，以及 `cutout`、`still`、`landing`、`fit`、`alignment`、可选 `semanticLabel`。封面、静态飞行图和缩略图均经过同一 builder。 |
| `CoachGreetingBlock` / `CoachTimeMark` / `CoachTypingBubble` | 问候、时间及等待气泡。typing 可注入进度标签和取消回调。 |
| `CoachOptionPill` / `CoachAppear` | 可复用的选项和进入动画；减弱动态效果遵循 `MediaQuery.disableAnimations`。 |

`CoachOriginRect` 为 `Rect? Function()`：App 可在进入与退出播放器时读取卡片的实时屏幕位置。`coachRectOf` 提供已布局 widget 的安全矩形读取。

## 透明素材与封面突出卡片

宿主可根据本地可信清单中的 alpha 边界绘制素材；SDK 不扫描像素、不裁改源文件、不下载素材。`media` 返回 null 时使用原来的 asset 图，适合缺少边界或校验不匹配时回退。宿主应尊重请求中的 `fit`、`alignment`、`semanticLabel`，并对同一资源在封面和飞行图中使用一致的裁剪；SDK 继续控制淡入、落地与展开动画。

```dart
final builders = CoachUiBuilders(
  media: (context, request) {
    final bounds = verifiedBounds[request.asset];
    if (bounds == null) return null;
    return buildBoundedAsset(
      request.asset,
      bounds: bounds,
      fit: request.fit,
      alignment: request.alignment,
      semanticLabel: request.semanticLabel,
    );
  },
  // surface 可将背景面向下留 14dp；保留传入 padding 和 child 几何。
);
// CoachPlanCard(..., cutoutTopInset: 0);
```

`buildBoundedAsset` 与 `verifiedBounds` 属于宿主实现，以上为组合示意。`cutoutTopInset: 0` 让人物触及外卡顶部，仅允许图像进入既有内边距；不会增加卡片总高度、移动按钮或让图像越出外卡。把宿主背景面下移 12–16dp 后，人物可露出背景面上沿。扩展命中区域仅覆盖既有顶部内边距，并调用 `onOpen`；展开/开始按钮仍维持原坐标和优先级。非 cutout 卡不受该参数影响。负值、NaN 和无穷值不受支持。

## 内容滚入透明系统状态栏

宿主负责全屏布局、透明系统栏和图标明暗。让聊天列表 viewport 从页面顶端开始，把顶部安全留白放进列表内容，而不是用外层 `SafeArea` 缩小列表；固定导航按钮和输入栏仍由 App 各自保护。

```dart
CoachChatList(
  entries: admittedEntries,
  controller: scrollController,
  timeMarkBuilder: buildTimeMark,
  topColor: themeBackground,
  topInset: MediaQuery.paddingOf(context).top,
  fadeTop: false,
);
```

内部顶部 padding 为 `48 + topInset`，viewport 的位置和高度不变，因此初始内容有安全留白，滚动后气泡可以进入系统栏背后。`fadeTop: false` 完全不构建顶部 `IgnorePointer` 渐变，避免不透明起始色盖住滚入内容。默认 `topInset: 0, fadeTop: true` 仍使用旧版 48 px 内容留白和 48 px 顶部渐隐；SDK 不自行读取或推断 App 的安全区、系统栏或路由配置。

## 接入 ask_user

新接入推荐使用 `ugk_coach` 的纯 Dart [`CoachConversationController`](../../docs/coach-conversation-controller.md)。该入口随拟发布的 `ugk_coach-v0.5.0` 提供，目前仍待审，尚未发布；本 UI 包的运行代码、依赖和版本不变。上方安装表保留已发布的 0.1.1 配套快照，勿把拟发布 tag 当成现有 tag。

App 把构造好的一个 agent 交给 controller，并监听 `state`。controller 负责等 `send` 返回后才启用已过门禁的问题、单选/多选校验与排序、同步锁定提交、旧问题失效、取消与新对话；App 不再另存一套“当前可答问题”的状态。agent 进度事件仅用于显示进度，不直接启用询问气泡。

Flutter `State` 中的监听片段如下，`widget.conversation` 由 App 注入；下面以 App 创建并拥有本页面会话的生命周期为例：

```dart
// imports: dart:async, package:ugk_coach/ugk_coach.dart as coach
late final coach.CoachConversationController conversation;

@override
void initState() {
  super.initState();
  conversation = widget.conversation;
  conversation.addListener(_changed);
}

void _changed() {
  if (mounted) setState(() {});
}

@override
void dispose() {
  conversation.removeListener(_changed);
  unawaited(conversation.dispose());
  super.dispose();
}
```

若会话由更长生命周期的 App 服务持有，页面只解除自己的监听，由服务最终销毁 controller。不要在每次 build 或每次回答时重建 agent/controller。

将 `conversation.state.messages` 中的消息映射为 `CoachChatEntry`；一条消息的正文与问题分别处理：

```dart
// m: coach.CoachConversationMessage
final question = m.question;
final content = Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    if (m.text.isNotEmpty)
      CoachMessageBubble(
        message: CoachBubbleData(id: m.id, text: m.text, isUser: m.isUser),
        optionsActive: false,
        onOption: (_) {},
      ),
    if (question != null)
      CoachQuestionBubble(
        key: ValueKey('question-${m.id}'),
        question: CoachQuestionData(
          id: m.id,
          question: question.question,
          mode: question.mode == coach.AskUserMode.text
              ? CoachQuestionMode.text
              : CoachQuestionMode.choice,
          options: question.options,
          multiple: question.multiple,
          answered: m.questionAnswered,
          answeredChoices: m.answeredChoices,
        ),
        enabled: conversation.canAnswer(m.id),
        onTextAnswer: (text) async {
          await conversation.answerText(m.id, text, context: appContext);
        },
        onChoiceAnswer: (selected) async {
          await conversation.answerChoices(m.id, selected, context: appContext);
        },
      ),
    // m.plan 由 App 映射为 CoachRoutine 后添加 CoachPlanCard。
  ],
);
```

controller 在问题正文与 `result.text` 相同时把普通 `text` 留空，正文不同时保留两者。不要用 `else` 把合法普通文字隐藏。`conversation.state.isWaiting` 可用于输入栏、发送按钮和 typing 气泡；`cancel()`、`newConversation()`、`restoreHistory(...)` 会使旧问题失效，恢复的历史不会复活 agent 待答任务。

App 仍负责 AI Key 有无的入口开关、HTTP client/endpoint/Key、动作目录与 profile、进度和失败提示、存储、导航、训练启动，以及 `TrainingPlan` 到 `CoachRoutine` 的映射。本包只收呈现数据与回答回调，未增加 coach、controller、网络或密钥依赖。继续使用 coach 0.4.x 的宿主可以保留旧的 App 会话控制，待自行升级 0.5.0 后再迁移。

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
