# 宿主进出场编排

`TrainerPlayer` 新增四个可选参数。全部省略时保留原有启动、控件显示、保存和返回
流程；preview 仍使用既有演示与开始按钮流程。媒体舞台和地板不参与控件动画。

## 参数与 dartdoc

以下声明与 `lib/src/ui/trainer_player.dart` 的公开字段一致；构造函数中均默认 null。

```dart
/// Delays an initially training session until this future settles.
///
/// Null preserves immediate startup. While waiting, media is paused and
/// the initial countdown is fixed; no training clock, tick timer, audio or
/// keep-alive starts. The result recorder starts when this gate settles.
/// Errors also release the gate. Leaving or disposing first prevents both
/// startup and saving. Preview mode keeps its existing start-button flow.
/// The future is captured on mount; replacing it does not re-gate a session.
final Future<void>? startGate;

/// Host-driven progress for training controls and the completion view.
///
/// Null preserves the existing layout. Drive linearly from 0 to 1 over
/// 280 ms for the specified stagger; reverse uses the exit curves. Media
/// and the floor are unaffected. Controls ignore input below 1. Reduced
/// motion retains opacity only; preview ignores this animation. After a
/// failed exit save, the completion view ignores it so retry stays visible.
final Animation<double>? chromeAnimation;

/// Runs after a successful save and completion receipt, just before pop.
///
/// The host may await its exit animation and switch video back to a poster.
/// Closing stays locked until this finishes; errors or a one-second timeout
/// still allow pop. It is not called after save failure or for preview exit.
/// Exiting before [startGate] opens also awaits it, without saving a result.
final Future<void> Function()? beforeExitPop;

/// Synchronously announces a confirmed exit before saving begins.
///
/// Called when early exit is confirmed, Finish is tapped, or an unstarted
/// gated session is closed. It runs once until replay, so repeated clicks
/// cannot restart host exit motion. It can overlap motion with saving;
/// [beforeExitPop] then waits for that motion. Preview exit does not call it.
/// A thrown callback does not block the exit.
final VoidCallback? onExitStarted;
```

`startGate` 仅控制初始 training 模式；preview 传入它也不会改变演示播放和开始
按钮的行为。等待期间 pause、上一个、下一个、声音与不舒服操作都不能启动训练。
关闭未开始的页面不生成训练结果，不调用 `onFinished` / `onCompleted`，返回值为
null；如果提供了退出钩子，仍可完成宿主的退场。gate 迟到完成或抛错不会复活已退出页面。

实际开始时才创建 `SessionRecorder`，因此 `startedAt` 和 `activeSeconds` 均不包含
宿主的进场等待。开始顺序仍为录制起点、语音输出、keep-alive、训练时钟、tick。

## 固定控件区间

宿主先完成 280ms 的卡片放大，再以 280ms **线性**驱动 `chromeAnimation`。
SDK 不添加前面的 280ms 等待；下面绝对时间假定宿主采用这个起点。

| 层 | animation 区间 | 绝对时间 | 进场变化 |
| --- | --- | --- | --- |
| 顶部信息卡 | 0 → 200/280 | 280 → 480ms | y: -12 → 0，opacity: 0 → 1 |
| 下一个 / 不舒服胶囊 | 20/280 → 220/280 | 300 → 500ms | y: -8 → 0，opacity: 0 → 1 |
| 提示卡和分页圆点 | 40/280 → 240/280 | 320 → 520ms | y: +16 → 0，opacity: 0 → 1 |
| 倒计时 / 上一个 / 下一个 | 60/280 → 260/280 | 340 → 540ms | y: +16 → 0，opacity: 0 → 1 |
| 暂停大按钮 | 60/280 → 1 | 340 → 560ms | scale: .85 → 1，opacity: 0 → 1 |

常规进场位移和 opacity 使用 easeOutCubic；暂停按钮 scale 使用 easeOutBack。
动画 status 为 reverse 时全部改用 easeInCubic，缩放也不反向回弹。
完成页以完整 0 → 1 区间做 opacity 和 y: +12 → 0，供反向退场。

每层单独监听宿主 animation，只重建该层变换，媒体和地板不被重建或包在 Opacity
内。原始 animation 值小于 1 时，该层屏蔽点击和可操作语义。减少动效时只保留
opacity，宿主将控制器时长改为 150ms。右侧问题标记按钮由宿主自己编排。

## 宿主接入示例

以下字段放在宿主的 State 中；`cardExpand` 和 `showPoster` 由宿主已有的卡片
转场与媒体视图提供。每次打开页面创建一份 gate / chrome 控制器。

```dart
final start = Completer<void>();
late final chrome = AnimationController(
  vsync: this,
  duration: const Duration(milliseconds: 280), // reduced motion 时用 150
);
Future<void>? exitMotion;

Future<void> playEntrance() async {
  await cardExpand.forward(); // 宿主的 280ms 卡片放大
  await chrome.forward();     // SDK 负责区间错开，不要给它再包曲线
  if (!start.isCompleted) start.complete();
}

Widget buildPlayer() => TrainerPlayer(
  plan: plan,
  drillOf: drillOf,
  strings: strings,
  onFinished: saveResult,
  onCompleted: saveReceipt,
  startGate: start.future,
  chromeAnimation: chrome,
  onExitStarted: () {
    exitMotion = chrome.reverse();
  },
  beforeExitPop: () async {
    await exitMotion;
    showPoster.value = true;
  },
);
```

提前结束：确认当帧调用 `onExitStarted`，保存与退场动画并行；等待既有
`onFinished` 和 `onCompleted` 成功后，才调用 `beforeExitPop`，最后 pop receipt。
自然练完仍先显示完成页，直到点击“完成”才通知退出并等待钩子。
`beforeExitPop` 同步抛错、异步失败或超过 1 秒都不会阻塞返回。

保存失败不调用 `beforeExitPop`，沿用现有完成页与重试。即使宿主已把 chrome
反向播到 0，完成页仍保持可见、可重试；原有失败页 200ms 淡入保留。
退出通知每次训练会话只发一次，失败重试不重复通知；重练时重置这一标记。
宿主若支持重练，也应在自己接到重练操作时把 chrome 恢复为 1。

## 验证

`flutter test --no-pub --reporter expanded`：405 项通过。原有 374 项测试文件未修改，
新增生命周期 19 项与动画 12 项。`dart analyze --fatal-infos`：0 问题；格式和
`git diff --check` 均通过。

对 SmartFit、HipLab、托马斯和 FlareLab，四个参数均省略时仍走原有 SDK 路径；
新编排只在宿主主动传参时启用。本次只修改 `packages/ugk_trainer`，不改宿主项目。
