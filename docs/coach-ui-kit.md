# 通用教练界面接入

SDK 基线：`66dd98a549c1ff5fedecb626a7c88583090a1440`。
参考来源固定为 Sport-Helper
`13c0bb4cc24982be50bbb2471fc83ace6f64e40b`；参考仓库只读，其后来 main 的变化不在本次迁移中。

本次只新增界面、摘要和路由导出，以及可选主题/文案字段。原有组件不自动切换到新界面；
TrainerPlayer、单练入口、会话模型、保存链路和现有主题字段的默认行为不变。
不改宿主项目、不合 main、不打 tag；验证后仅推送 `codex/coach-ui-kit`。

## 从会话到生成卡片：15 行

此卡片适配只需同时依赖 coach 与 coach_ui；训练时再使用 trainer。
`ugk_coach` 仍是纯 Dart，`ugk_coach_ui` 的运行时依赖仍只有 Flutter。
两层通过 Dart 结构记录传递数据，UI 不导入会话模型或 ExerciseLibrary。
以下函数体直接用于宿主的 build；`cutoutFor` 返回按当前深浅主题选择的剪影，缺图返回 null。

```dart
Widget buildTask(CoachSessionState state, bool waiting,
    VoidCallback cancel, ImageProvider? Function(String) cutoutFor) {
  final summary = CoachTaskSummary.fromState(state);
  return CoachTaskBubble(
    title: summary.title,
    status: summary.status,
    phase: summary.phase,
    parameters: summary.parameters,
    picks: summary.picks,
    complete: summary.complete,
    waiting: waiting,
    onCancel: cancel,
    cutoutFor: cutoutFor,
  );
}
```

需要的 import 为 `package:flutter/material.dart`、`package:ugk_coach/ugk_coach.dart`、
`package:ugk_coach_ui/ugk_coach_ui.dart`。只读摘要不发起模型请求，也不修改任务或会话。

## 新增导出及参数

`ugk_coach` 新增：

```dart
CoachTaskSummary.fromState(
  CoachSessionState? sessionState, {
  CoachTaskState? task,
  CoachTaskSummaryCopy copy = const CoachTaskSummaryCopy(),
});
CoachTaskSummaryCopy({stageLabel, parameterLabel, status, title});
String levelZh(int level);
```

`summary.stages` 为六个有序记录 `{id, label, status}`，其中 status 只有
done/current/pending，updated 对外显示为 done；不暴露内部 stamp。
六阶段是 understand、parameters、actions、planning、review、output。
原生成卡片的进度仍是四段，使用独立的 `phase`（0–4），不改成六段。
摘要还包括 `status`、`parameters`（`{field, label, user}`）、`sceneLabel`、`goalLabel`、
`title`、原顺序 `picks` 和 `complete`。

标题、标签、levelZh 和空 picks 状态句严格沿用参考逻辑；只有 `source == 'user'` 高亮。
未知参数标识不作为文案显示，参数标签顺序仍为 scene / goal / equipment / level / limits。
没有 picks 的 actions 阶段回退为“读懂你的需求”，不虚构动作数。
`complete` 仅表示 output done/updated，不代表宿主已接纳回复。

`CoachTaskSummaryCopy` 四个回调均可省略，只替换显示文案，不改变任务选择或进度逻辑：

```dart
String Function(String id, String fallback)? stageLabel;
String Function(String field, Object? value, String fallback)? parameterLabel;
String Function(int phase, int pickedCount, String fallback)? status;
String Function(String? scene, String? goal, String fallback)? title;
```

例如应用可以为 level 的 1/2/3 和 scene 的 home 等已知值提供本地化文案；无效参数先按
既有规则过滤，参数回调不会让未知值变成标签。返回空参数文案会隐藏该标签。
不需要本地化时保持默认中文，不必复制参数映射和回退规则。

`ugk_coach_ui` 新增：

```dart
const CoachTaskBubble({
  Key? key,
  String? title,
  String? status,
  int phase = 0,
  List<({String field, String label, bool user})> parameters = const [],
  List<String> picks = const [],
  bool complete = false,
  bool waiting = false,
  bool visualComplete = false,
  VoidCallback? onCancel,
  ImageProvider? Function(String actionId)? cutoutFor,
});

const CoachDeliveryTransition({
  Key? key,
  required bool preparing,
  required Widget child,
  bool successful = false,
  bool interrupted = false,
});

const PlanFocusLabel({
  Key? key,
  required String? title,
  required VoidCallback? onClear,
  double bottomGap = 0,
  IconData icon = Icons.bookmark_border,
  IconData clearIcon = Icons.close,
});
```

生成卡片不用动作库查询；剪影由宿主的 ImageProvider 提供。空 picks 或没有可用剪影时保留
呼吸核心。宿主应返回稳定、已缓存的 provider，不在每次动画取图时发起下载。
`phase` 范围为 0–4；传入的记录列表与 picks 应使用不可变快照。

## 主题和文案

`CoachUiColors` 构造函数和 `copyWith` 新增可选字段：

| 角色 | 字段 | 浅色默认 / 深色默认 |
| --- | --- | --- |
| 主色 | taskAccent | #0E7673 / #7AD4D5 |
| 生成卡底色 | taskCardSurface | #FFFFFF / #19262B |
| 描边 | taskCardBorder | 黑 6% / 白 8% |
| 卡片光晕 | taskGlow | 主色 6% / 10% |
| 主文字 | taskText | #121614 / #F2F3F5 |
| 次文字 | taskMuted | #5D6661 / #A0A4AC |
| 用户标签及 focus 底色 | taskChipSurface | 主色 10% / 18% |
| 圆球底色 | taskOrbFill | 主色 8% / 14% |
| 进度轨道 | taskProgressTrack | 黑 8% / 白 10% |
| 非用户标签描边 | taskChipBorder | 黑 10% / 白 12% |
| 核心光晕 | taskHalo | 主色 15% |
| 浅色卡近/远阴影 | taskShadowNear / taskShadowFar | 黑 4% / 黑 6%；深色不画阴影 |

使用独立的 task 角色是为了保留原 `accent`、`surface` 等旧字段的默认值；换品牌时通过
`CoachUiTheme(style: ...)` 设置 taskAccent 等字段即可。派生光晕/标签色默认随新的 taskAccent
计算；显式覆盖的字段在 copyWith 后保留。字体家族由宿主主题提供，字号、字重和行高保留参考数值。
标题、状态句与标签的字距保持参考界面的正文继承方式，取消按钮保持 0 字距；不会带入
Material 标题/标签角色的额外字距，实际字形宽度和行高已与源样式对照。

`CoachUiStrings` 新增可选字段，旧字段不变：

```dart
taskThinkingTitle = '正在想怎么练';
taskReadingStatus = '读懂你的需求';
taskCancel = '取消';
planFocusTitle = (title) => '正在讨论：$title';
clearPlanFocus = '取消讨论计划';
```

前三个用于未传标题/状态时的兜底和取消按钮；带来源的标签、阶段句和标题通过摘要的 copy
配置替换。PlanFocusLabel 的两个图标可直接传宿主自己的 IconData。

## 接入交付过渡和当前讨论标签

```dart
CoachDeliveryTransition(
  key: ValueKey(requestId),
  preparing: waiting,
  successful: admittedPlanOrRecommendation,
  interrupted: newerRequestStarted,
  child: waiting ? buildTask(state, true, cancel, cutoutFor) : deliveredCard,
);
PlanFocusLabel(
  title: controller.focus?.title,
  onClear: controller.clearPlanFocus,
  icon: hostBookmarkIcon,
  clearIcon: hostCloseIcon,
  bottomGap: 8,
);
```

回复内容在宿主接纳时即可写入会话；视觉过渡不延迟数据。只有成功接纳的计划/推荐才传
successful；output 已完成但仍 waiting 时不提前显示勾。交付成功保留原卡状态，240ms
完成视觉 + 350ms 停留 + 300ms 高度收起，890ms 后显示交付卡；失败/普通文字沿用 300ms
交叉淡入。新一轮、后台、路由遮挡、TickerMode 关闭或减弱动效会结束当前视觉时间线，
不会排队重放。取消仍由宿主负责移除对应条目。

focus 标签保留 28px 高、圆角 14、180ms 进入、120ms 原位淡出、150ms 换标题；bottomGap
与退场标签一起保留到消失。标题和清除行为由宿主拥有，不隐式修改会话。

## 训练路由

`ugk_trainer` 新增三个导出：

```dart
TrainerSlideRoute<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  TrainerTheme? trainerTheme,
  RouteSettings? settings,
});
TrainerSlideRouteControl;
const TrainerSlideRouteScope({
  Key? key,
  required TrainerSlideRouteControl control,
  required Widget child,
});
// static lookup
TrainerSlideRouteScope.maybeOf(BuildContext context);
```

进入固定 300ms easeOutCubic，从右到左；退出固定 280ms，reverseCurve 为
easeInCubic.flipped，使实际向右位移随 elapsed 按 easeInCubic 增长。减弱动效为零时长。
整页第一帧就构建，只移动位置，不对媒体或整页做淡入、缩放；舞台和系统栏保持同色。
没有诊断、帧记录或 SmartFit 活动计数依赖。

控制器公开 startGate、beginExit()、beforeExitPop()、exitSaveFailed()、replay()，以及
只读 entered / exiting / mediaRetired / saveFailed / canPlay。也可直接从 route.control 读取；
控制器由路由创建，没有公开构造函数，Scope 支持子级监听状态。

```dart
final route = TrainerSlideRoute<SessionResult>(
  context: context,
  trainerTheme: trainerTheme,
  builder: (context) {
    final control = TrainerSlideRouteScope.maybeOf(context)!;
    Future<void> guardedSave(SessionResult result) async {
      try {
        await saveResult(result);
      } on Object {
        control.exitSaveFailed();
        rethrow;
      }
    }
    return TrainerPlayer(
      plan: plan,
      drillOf: drillOf,
      strings: trainerStrings,
      theme: trainerTheme,
      startGate: control.startGate,
      onExitStarted: control.beginExit,
      beforeExitPop: control.beforeExitPop,
      onFinished: guardedSave,
      // onCompleted 如有异步保存，也用相同 catch/exitSaveFailed/rethrow 包装。
    );
  },
);
final receipt = await Navigator.of(context).push(route);
```

必须将三个钩子接到播放器，路由才拥有启动/退场编排。gate 在进入完成的整页帧绘制后释放，
之前不走训练时钟、tick、语音或 hold，媒体请求 paused=true。初始 preview 仍沿用既有
TrainerPlayer 语义；宿主要延迟 preview 视频时使用 control.canPlay 配合自定义媒体。
单练页同样可以透传这三个控制器字段。

提前结束确认时 beginExit 同步启动向右退场，保存与动画并行；beforeExitPop 等同一退场完成，
最终由 TrainerPlayer 在保存和回执成功后 pop receipt。保存失败时宿主调用 exitSaveFailed
并 rethrow，路由把现有重试页滑回。动画已经退完但仍保存时，原页面导航被屏蔽，避免穿透点击。
自然练完仍先显示完成页；进场中返回或进入后台不会释放 gate 或保存未开始的训练。
重练接入时调用 control.replay()，继续复用既有播放器的 replay 流程。

## 保留的视觉数值与验证

生成卡沿用圆角 20、内边距 16/14/16/16、描边 0.5、光晕半径 160、圆球 44、弧宽 1.5 /
300°、1400ms 旋转；核心 10 / 光晕 20，1200ms 呼吸的初始 scale .8 / opacity .6 和
Cubic(.37,0,.63,1)；剪影 900ms 停留 / 250ms 淡入 / .94→1、首张延迟 180ms；扫光
1600ms / 250% 宽 / 100%→-150%；1200ms 进度光带占 .4。完成勾路径
M5 10.5 l3.2 3.2 L15 6.8、宽 2.4，260ms 缩放 Cubic(.34,1.56,.64,1)，取消热区 44。
四个 RepaintBoundary 和 disableAnimations/TickerMode 行为保留。

SF 的 coach_task_bubble_test 全部移植为普通数据输入；同时覆盖摘要六阶段、空 picks、
完成态与本地化，交付时间线、focus 标签、路由位移及实际 TrainerPlayer 的 gate、保存和
退出流程。原有测试未修改，结果如下：

| 包 | 全量测试 | `dart analyze --fatal-infos` |
| --- | --- | --- |
| ugk_coach | 1304 通过（新增 26） | 0 问题 |
| ugk_coach_ui | 158 通过（新增 47） | 0 问题 |
| ugk_trainer | 440 通过（新增 18） | 0 问题 |

Coach 使用 `dart test --concurrency=1 --reporter expanded`，两个 Flutter 包使用
`flutter test --no-pub --reporter expanded`。生成卡片包含 SF 原 15 个展开测试、6 个
数值/主题契约测试和 3 个字体对照测试；其余 UI 为 13 个交付过渡和 10 个 focus 标签测试。
trainer 包含 12 个路由测试和 6 个真实播放器接入测试。
15 行摘要适配与训练路由示例均在同时依赖三包的宿主环境通过静态分析；格式、
`git diff --check` 与 60 个本地文档链接检查通过。
