# 动作库与单练的宿主入口

基线为 main `c97a79a5f03ba1f46f017b995f7f8d97fb3016a9`。本次只增加
`ugk_trainer` 的五个可选参数，均默认 null；不改 TrainerPlayer、训练页样式或完成页。

## 参数

```dart
// PoseHubActionBrowser
final ValueChanged<PoseHubSinglePracticePage>? onOpenPractice;

// PoseHubSinglePracticePage
final Future<void>? startGate;
final Future<void> Function()? beforeExitPop;
final VoidCallback? onExitStarted;
final TrainerMediaBuilder? mediaBuilder;

// 复用既有类型，不新增媒体请求类型。
typedef TrainerMediaBuilder = Widget Function(
  BuildContext context,
  TrainerMediaRequest request,
);
```

`onOpenPractice` 收到 SDK 原本准备 push 的完整单练页。它的公开字段包括
`action`、`mediaBaseUri`、已解析的 `theme`、`mediaPreparer`、`voice`、
`onFinished`、`startMode`、`onStartTraining` 和 `onCompleted`。宿主既可以直接
把这个 page 放进自己的路由，也可以读取字段构造带新参数的单练页，无需重建动作剂量或计划。
回调有值时 SDK 只调用回调，不 push，也不等待或管理宿主的路由。

回调省略时仍由 SDK 使用 `MaterialPageRoute` 打开原有 preview 单练页，准备倒计时
仍为 10 秒。`PoseHubSinglePracticePage` 单独使用时默认仍是 training、准备时间 0。

| 单练参数 | 语义 |
| --- | --- |
| `startGate` | 原样传给 TrainerPlayer。初始 training 等待期间计时、tick、语音、提示音和 hold 不启动，媒体请求 `paused=true`；视频可准备，但不播放。成功或抛错均释放 gate，录制起点从释放时算。先退出或 dispose 不启动、不保存。 |
| `onExitStarted` | 确认提前结束、完成页点“完成”或关闭未开始的 gated training 时同步通知，保存之前触发；每次训练只通知一次，失败重试不重复。 |
| `beforeExitPop` | 保存及完成回执成功后等待，再 pop receipt；关闭未开始的 gated training 也等待，但不保存，pop null。抛错或超过 1 秒直接返回。保存失败不调用。 |
| `mediaBuilder` | 使用 TrainerPlayer 的完整媒体插槽，第一帧即调用；可返回宿主已预加载的海报及自己的播放器。它替代默认媒体，SDK 不会在下面另建一个播放器。必须遵守请求的 `paused`、`mirrored` 和主题；使用 `request.mediaPreparer` 可复用当前会话的媒体准备队列。 |

startGate 和退出钩子对 preview 的语义也与 TrainerPlayer 相同：preview 仍循环演示，
gate 不阻止预览播放；关闭 preview 不保存、不调用退出钩子。需要进场后直接训练的宿主
显式选择 `TrainerStartMode.training`。仅需自定义 preview 路由时可直接 push 回调收到的
page；若还需延迟 preview 视频，由宿主的 mediaBuilder 管理预览播放。

提前结束仍停留在已暂停的最后一帧，保存成功后直接返回，不经过完成页。保存或完成
回执失败才显示原有结果和重试按钮；自然练完仍先显示完成页。回调顺序为
`onExitStarted → onFinished → onCompleted → beforeExitPop → pop(receipt)`。
自然练完时 `onFinished` 已在结束时自动执行，点击“完成”不会重复保存成功的结果。

## 宿主接入示例

下例用宿主的路由时长滑入、滑出，直到路由进场完成才释放训练 gate。媒体由宿主预加载
并通过 `readyMedia` 提供；`exitStarted` 可立即开始宿主的退场准备，`restorePoster`
在返回之前恢复同一海报。所有原有业务回调都保留。

```dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:ugk_trainer/ugk_trainer.dart';

Future<SessionResult?> pushHostedPractice(
  BuildContext context,
  PoseHubSinglePracticePage requested, {
  required Duration hostTransitionDuration,
  required TrainerMediaBuilder readyMedia,
  required VoidCallback exitStarted,
  required Future<void> Function() restorePoster,
}) async {
  final entered = Completer<void>();
  final route = PageRouteBuilder<SessionResult>(
    transitionDuration: hostTransitionDuration,
    reverseTransitionDuration: hostTransitionDuration,
    pageBuilder: (_, _, _) => PoseHubSinglePracticePage(
      action: requested.action,
      mediaBaseUri: requested.mediaBaseUri,
      theme: requested.theme,
      mediaPreparer: requested.mediaPreparer,
      voice: requested.voice,
      onFinished: requested.onFinished,
      onStartTraining: requested.onStartTraining,
      onCompleted: requested.onCompleted,
      startMode: TrainerStartMode.training, // 宿主选择直接训练。
      startGate: entered.future,
      mediaBuilder: readyMedia,
      onExitStarted: exitStarted,
      beforeExitPop: restorePoster,
    ),
    transitionsBuilder: (_, animation, _, child) => SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(animation),
      child: child,
    ),
  );
  final popped = Navigator.of(context).push<SessionResult>(route);
  final animation = route.animation!;
  void release(AnimationStatus status) {
    if (status == AnimationStatus.completed && !entered.isCompleted) {
      entered.complete();
    }
  }
  animation.addStatusListener(release);
  release(animation.status);
  try {
    return await popped;
  } finally {
    animation.removeStatusListener(release);
  }
}
```

将它接到现有 `PoseHubActionBrowser`，只增加 `onOpenPractice`：

```dart
onOpenPractice: (requested) {
  unawaited(pushHostedPractice(
    context,
    requested,
    hostTransitionDuration: appRouteDuration,
    readyMedia: hostMedia.build, // TrainerMediaBuilder，已有缓存/预解码海报。
    exitStarted: hostMedia.beginExit,
    restorePoster: hostMedia.restorePoster,
  ));
},
```

`hostMedia` 由宿主管理，不是新增 SDK 类型。宿主应在 push 前完成海报解码，首次 build
就返回这张海报；等待实际视频首帧可呈现后再移除海报。不要只因 gate 完成就移除海报，
也不要在暂停时替换整个媒体子树；保持媒体 Widget/key 稳定并传入 `request.paused`。
退出钩子里的异步操作应在 1 秒内完成。媒体资源应保留到路由退场完成，再由宿主释放。

## 验证与兼容范围

新增导航测试覆盖自定义回调不 push、完整参数交付、继承主题及原有默认路由。
新增单练测试覆盖第一帧自定义海报、gate 前暂停及无语音/hold、释放后开始、gate 前
dispose、退出顺序、系统返回、保存失败、自然练完与提前结束期间不显示完成页。
原有测试文件未修改。新增导航 4 项、单练生命周期 13 项；完整回归结果：

| 包 | 全量测试 | `dart analyze --fatal-infos` |
| --- | --- | --- |
| ugk_coach | 1278 通过（`dart test --concurrency=1 --reporter expanded`） | 0 问题 |
| ugk_coach_ui | 111 通过（`flutter test --no-pub --reporter expanded`） | 0 问题 |
| ugk_trainer | 422 通过（同上，含原有 405 项） | 0 问题 |

格式检查和 `git diff --check` 均通过。

SmartFit、HipLab、托马斯、FlareLab 不传上述参数时继续使用既有路径。单练的计划、
剂量、结果转换、媒体准备、保存和完成页均交由原 TrainerPlayer 处理。
更完整的生命周期契约见[宿主进出场编排](trainer-entrance.md)。
