# 推荐动作卡

`CoachRecommendCard` 保持 UI 包的纯展示边界，无 `ugk_coach` 或 `ugk_trainer` 运行时依赖。传入经 SDK 门禁交付的动作 ID 和说明，素材、名称与元信息从宿主当前语言的可信目录适配器读取。组件不解析模型说明来猜测器材、难度或素材路径。

```dart
CoachRecommendCard({
  Key? key,
  required List<String> actionIds,
  required String note,
  required CoachExerciseLibrary library,
  required ValueChanged<String> onOpenAction,
  ValueChanged<List<String>>? onPlanFromActions,
})
```

`CoachExercise` 增加可选的 `levelLabel`、`equipmentLabel`，与已有 `name` 一样由 App 按当前 locale 本地化。名称可由 `drill.name.of(language)` 解析；难度和器械的标签应来自目录/宿主的本地化表，不能直接把 `equip.chair` 等内部编码呈给用户。旧套路卡适配器无需修改这些新增字段。

## SmartFit 消息映射

```dart
// imports: package:ugk_coach/ugk_coach.dart as coach
//          package:ugk_coach_ui/ugk_coach_ui.dart as ui
Widget recommendationFor(coach.CoachConversationMessage message) {
  final actions = message.actions;
  if (actions == null) return const SizedBox.shrink();
  return ui.CoachRecommendCard(
    actionIds: actions.items.map((item) => item.id).toList(),
    note: message.text,
    library: localizedExerciseLibrary,
    onOpenAction: (id) => openSingleActionTraining(id),
    onPlanFromActions: (ids) => onUserChoosesPlan(ids),
  );
}
```

`localizedExerciseLibrary` 是与当前动作库共用的目录适配结果；`openSingleActionTraining`、`onUserChoosesPlan` 属于 App 的导航和会话操作。只显示推荐、不提供排计划入口的页面，直接省略 `onPlanFromActions`。按钮不会调用模型或自行创建任务；它原样回传本次推荐 ID 的不可变列表。

快照恢复后，按 `controller.restoreSession(snapshot, savedMessages)` 得到的 `controller.state.messages` 再调用同一个映射。推荐 ID 和说明来自快照重建后的消息，不能用 App 显示消息伪造训练状态。无需把 Flutter widget、图片字节或媒体地址写入快照。切换语言时重建 `CoachExerciseLibrary`，推荐 ID 和说明保持原交付值。

## 和动作库共用首帧

对于 PoseHub 已打包动作，动作库的两列卡片使用
`assets/pose_hub/app-test-pack-r1/standing/<id>.webp`。将同一个可信路径传入 `CoachExercise.stillCutout`；推荐卡优先使用它，其次 `poster`，不播放动作视频。宿主继续通过已有 `CoachUiBuilders.media` 注入包资源加载：

```dart
final builders = ui.CoachUiBuilders(
  media: (context, request) => Image.asset(
    request.asset,
    package: 'ugk_trainer',
    fit: request.fit,
    alignment: request.alignment,
    gaplessPlayback: true,
    semanticLabel: request.semanticLabel,
    errorBuilder: (_, _, _) => const SizedBox.shrink(),
  ),
);
```

组件使用固定的主题媒体底色、透明首帧和无进度圈的加载方式；原生默认资源加载使用 `gaplessPlayback`，解码前保持媒体底色。无目录记录或缺素材时使用静态占位，不显示 ID 或调试文案。未知目录动作不能点击进入训练。媒体 builder 自己处理图片错误时，仍保留组件外层的主题媒体底色。

颜色、字体、表面、点击与媒体均沿用 `CoachUiTheme` / `CoachUiBuilders`。固定文案新增 `CoachUiStrings.planFromActions`、`actionUnavailable`；中文可传“排成计划”“动作暂不可用”，英文可使用默认值。没有改动训练页、套路卡或它们的动画。

## 渲染与验证

`test/recommend_card_test.dart` 覆盖 1/6 个动作、缺素材、原 ID 回调、可选按钮、中英文、主题覆盖与窄屏大字体。通过 `COACH_RECOMMEND_CAPTURE=<absolute png path>` 单独运行其中的 capture 测试，会以当前仓库原始 PoseHub 首帧和实际 Flutter 组件导出六动作浅色截图；这是 widget 渲染证据，不代替原生设备验收。
