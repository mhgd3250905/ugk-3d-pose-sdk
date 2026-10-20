# ugk_trainer 0.1.3

三 App（托马斯 3D-Body / 开胯 HipLab / SmartFit）共用的跟练模块。方案见仓库根目录 `docs/trainer-plan.md`。

| 层 | 内容 | 来源 |
|---|---|---|
| `engine/`（纯 Dart） | `SessionBuilder`（TrainingPlan v1 + 每动作 `Rhythm` → 固定长度相位：准备/组/换边/组间/轮间/结束）、`SessionEngine`（绝对活动时间；自主计次 `completeSet`；`restartWith` 换动作；相位访问日志） | SmartFit `session.dart` |
| `rhythm/` | `ActionKind`（6 种）+ `KitPhase` + `RepPlan`；`Rhythm.fromJson`（目录 `rhythm` 字段）/ `fromActionKitJson` / `fromRepSeconds` / `forDose`；`rhythmsFromCatalog` | HipLab `action_kit.dart` |
| `voice/` | `VoiceQueue` / `VoiceLineController` / `JustAudioVoiceOutput`（10-19 安卓修复版）；`SessionScript`（SmartFit 组/轮 + HipLab 节奏计数、换边余量）；`VoiceSource` 接口 + `ManifestVoiceSource` / `DrillPackVoiceSource`；`SessionRunner` | HipLab / SmartFit |
| `platform/` | `TrainingKeepAlive` / `TrainingHold`（安卓前台服务 + 唤醒锁，本包 Android 插件）、`ScreenAwake`（wakelock_plus） | HipLab |
| `media/` | `DrillMedia`、`DrillMediaView`（封面 → WebView/iframe 循环示范）、本地资源服务 | SmartFit + 3D-Body web |
| `ui/` | `TrainerPlayer`、`TrainerTheme`、`TrainerStrings`、`TrainerCountdownRing` | SmartFit `player_page.dart` |
| `result/` | `SessionResult`（开始即定 `sessionId`）、`SessionRecorder`、`ResultSaver` | 新 |

`package:ugk_trainer/engine.dart` 只导出纯 Dart 部分（可在 `dart test` / 工具里用）；`package:ugk_trainer/ugk_trainer.dart` 导出全部。

## 接入

```yaml
dependencies:
  ugk_trainer:
    git:
      url: https://github.com/mhgd3250905/ugk-3d-pose-sdk
      path: packages/ugk_trainer
      ref: <commit>
```

```dart
final result = await Navigator.of(context).push<SessionResult>(
  MaterialPageRoute(
    builder: (_) => TrainerPlayer(
      plan: plan,                                   // ugk_coach TrainingPlan v1
      rhythms: rhythmsFromCatalog(catalog),         // 见下「动作节奏」
      drillOf: (id) => TrainerDrill(id: id, name: …, cue: …, media: DrillMedia(…)),
      strings: myStrings,                           // TrainerStrings
      theme: myTheme,                               // TrainerTheme
      voice: TrainerVoice(source: voiceSource, output: voiceOutput, settings: settings),
      onFinished: (r) => store.upsertSession(r.sessionId, r.toJson()),
      onDiscomfort: …, feedbackBuilder: …, mediaBuilder: …, // 可选插槽
      notificationIcon: 'mipmap/ic_launcher_monochrome',
    ),
  ),
);
```

### 各 App 要提供什么

1. **VoiceSource**（语音素材）
   - HipLab：`ManifestVoiceSource.load(rootBundle.loadString, kitVoices: {id: KitVoice.fromActionKitJson(kit)})`，读 `assets/voice/manifest.json`。
   - SmartFit：`DrillPackVoiceSource.load(rootBundle.loadString)`，读 `assets/packs/index.json` + 各包 `pack.json`。
   - 托马斯：复用其中一种（中/英）；`VoiceSettings.language` 填语音语言代码。素材里没有该语言时（其余 10 种）自动降级为只有提示音 + 屏幕倒数，不会说半句话（决定 B）。
   - 输出用一个 App 级 `JustAudioVoiceOutput()`（App 退出时 `dispose()`）。iOS 锁屏保活靠它循环本包的静音片段，Info.plist 需有 `UIBackgroundModes: audio`。
2. **动作节奏 Rhythm**（决定 C）：`rhythmsFromCatalog(catalog, overrides: …)`。优先级：目录 `rhythm` 字段（Pose-Hub 目录 0.3.0，另做）> HipLab action kit（`Rhythm.fromActionKitJson`，作 overrides 传入）> 视频 `repSeconds`（SmartFit，按拍尾计数）> 按剂量缺省（time → 计时保持，reps → 自主计次，用户点「完成本组」，决定 A）。rep_hold 的停留秒数用 `rhythm.withHold(n)`。
3. **TrainerStrings**：播放页全部文案（含安卓常驻通知文字）。`TrainerStrings.zh()` / `.en()` 是 SmartFit 文案的起点，托马斯 12 语言自己传。
4. **TrainerTheme**：颜色/字体 token；`TrainerTheme.dark` / `.light` 为 SmartFit 值。
5. **drillOf**：动作名（App 语言）、休息时显示的要点、示范 `DrillMedia`（`videoAsset` / `posterAsset` 为 App 资源键，可带浅色版）。返回 null 的动作不进训练。
6. **mediaBuilder**（可选）：默认 `DrillMediaView`——安卓/iOS 用 WebView + 本机回环资源服务，web 用 iframe，播放页 `packages/ugk_trainer/assets/media_player/player.html` 随包带。默认只放行 `assets/` 下的 mp4/jpg/png/webp。
7. **onFinished**：训练结束（完成、提前结束、关闭）时调用一次，传一个 `SessionResult`。**按 `sessionId` 覆盖保存**：保存失败时完成页出现「重试」，重试传的是同一个结果（同一 id），不会产生第二条记录。保存成功前「完成」不可点；关闭和系统返回也等待保存，失败时保留完成页供重试。
8. **onDiscomfort**（可选）：返回 `DiscomfortDecision(continueEasier | skip | end | substitute, substituteId:, note:)`；HipLab 疼痛阶梯留在 App，在这里弹自己的页面。缺省是内置三选项底部弹层。事件记入结果。
9. **feedbackBuilder**（可选）：完成页上方的插槽（HipLab 感受反馈），拿到 `SessionResult`。
10. **sessionBuilder**（可选）：传入 `SessionBuilder` 子类，覆写 `phases` 保留 App 的左右侧剂量和组数编排；相位必须保留原计划的 `itemIndex`、`blockIndex`、`itemInBlock`，并以 `done` 结尾。计时、跳过、语音队列和保存仍由播放器管理。
11. **restFeedbackBuilder**（可选）：动作间休息的感受插槽，拿到当前 `phase`、刚结束的 `completedPhase` 和 `reportDiscomfort()`。普通反馈不暂停计时；报告疼痛时，`onDiscomfort` 的 `phase` 指刚结束的动作，`resumePhase` 指实际休息相位，`afterExercise` 为 true。完成页反馈发生在自动保存之后；要持久化完成页的新回答，App 应按同一 `sessionId` 更新补充数据。
12. **DiscomfortDecision.replacementPhases**（可选）：App 的疼痛策略可重建后续相位（减量、替换、方向过滤），`restartItemIndex` 选择开始位置，`withRest` 保留该位置前的休息；全部被过滤时进入 `done`。`voiceClips` 在重排后排入语音队列，用于 App 的疼痛提示。未提供相位时沿用默认动作；`continueEasier` 只表示减小幅度，具体减量由 App 决定。
13. **replayBuilder**（可选）：保存成功后显示再练入口，拿到 `SessionResult` 和 `replay()`。App 先重置自己的疼痛/感受状态，再调用 replay；同一播放器 State 开新会话和新结果 ID，保留共享语音输出，不建立第二个路由。
14. **doseLabel**（可选）：以 `SessionPhase` 按 occurrence 返回 App 的剂量文案，同时用于当前动作和下一动作预览；返回 null 则使用默认剂量文字。
15. **announceDiscomfortPause**（缺省 true）：false 时疼痛对话进出静默暂停/恢复，仍重新激活音频与续期保活；普通暂停按钮的播报不受影响。`DiscomfortDecision.subtitle` 可给出 App 的可见响应，即使没有语音素材也显示。

`SessionResult.completedExercises` 只统计实际完成全部所需侧别/组的动作，跳过不计为完成。引擎的 `completedExercises` 保留播放位置语义；读取实际完成数使用 `fullyCompletedExercises`。
`ItemResult.plannedSideSets` / `completedSideSets` 用 `right`、`left` 表示各侧实际组数，支持不对称编排；原 `plannedSets` / `completedSets` 继续表示成对组。旧结果没有这些字段时按空映射读取。

### Android

- 本包是 Flutter 插件：`com.ugk.trainer.TrainingSessionService`（`mediaPlayback` 前台服务 + 部分唤醒锁）和 `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_MEDIA_PLAYBACK` / `WAKE_LOCK` 权限由包内 manifest 合并进 App，通道 `ugk_trainer/training_session`。
- `JustAudioVoiceOutput` 在训练期间循环包内静音音频，填补两句口令之间的播放空隙：HipLab 真机观察到小米 Greeze 在音频空闲时仍会冻结前台服务并禁用唤醒锁。Android 使用正常播放器音量播放采样值全零的包内音源；设为零音量会被系统标记为客户端静音，不计入有效音频活动（0.1.2 已在真机复现此失败）。iOS 保持零音量。静音播放器不持续申请 Android 音频焦点；口令仍按句申请和释放焦点。来电等中断和耳机断开会暂停保活，训练结束后释放，单会话上限两小时。完成页留屏及快速再练也要验证释放/交接。实际兼容性必须由宿主真机复测确认。
- **Play Console 需补「媒体播放」前台服务声明**（应用内容 → 前台服务权限），每个 App 各自做。
- HipLab 切换时删掉 App 自己的 `TrainingSessionService.kt`、MainActivity 里的 `hiplab/training_session` 通道和 manifest 里的 service 声明，避免两份服务。
- 通知小图标用 `notificationIcon`（`mipmap/…` 或 `drawable/…`），不填用应用图标。

## 测试

`flutter test`（118 个）：引擎（SmartFit session 测试移植 + 自主计次、rep_hold 停留、循环轮间休息、换动作）、HipLab 节奏计数与换边余量、SmartFit 语音时间线、语音队列/播放控制器/just_audio 输出（HipLab 测试移植）、Android间隙保活/中断/加载竞态/两小时上限、无语音降级、训练保活、结果与幂等保存、播放页与 App 插槽、完成页音频释放与快速/延迟再练。夹具在 `test/fixtures`（HipLab manifest 与 5 个 action kit、SmartFit 5 个 pack.json）。

## 未带过来（留在各 App）

- HipLab：开场念课程名（`routine.*`）、按剂量文字找的台词（`textKey`）、紧侧多做一组（D-01）、自测流程。
- SmartFit：星空背景、自绘图标、完成页动画。
