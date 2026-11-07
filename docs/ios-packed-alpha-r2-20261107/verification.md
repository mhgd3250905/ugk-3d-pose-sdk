# iOS packed alpha r2 迁移与接入

基线 `739ad34178c9f1739b21aa68e6076e2b9987b166`，分支 `codex/ios-packed-alpha-r2`。
cherry-pick PR #13 的 `b6c7689` 后，仅 README 冲突；保留下载 HUD/onTiming 说明和 iOS 说明。
`training_action_media_test.dart` 自动合并后已复测。动作/目录/视频包不修改，保持基线 r2-v10。

## 后续复核（本轮，已完成）

Flare 使用本地覆盖，SPM 和 CocoaPods 均完成 clean + pub get + iOS debug 无签名构建并通过。
iOS XCTest 四项全过（iOS 26.5 模拟器），先前失败的来源边界用例也通过。
播放器生产代码未改；未跑 Android、未实施保活方案、未做真机验收。
原始日志、成功摘要和 xcresult 保存在 `build/ios-packed-alpha-r2/followup/`。

按用户确认临时修 Flare 的 `app/lib/trainer/trainer_voice.dart`：ordinalSet/ordinalRound
补 `{String lang = 'zh'}`，`lang == 'en'` 使用宿主已有的 Set/Round + 数字音频键，
其它语言向底层 source 传递 lang。仅本地覆盖验证，验完恢复；不提交 App、不改正式 ref。

原生测试夹具改用 `requestMediaDataWhenReady` 在串行队列供给 30 帧，
只在 input ready 时 append，复用同一不可变测试画面。取消“最多轮询 5 秒后仍 append”的路径，
完成等待由 10 秒改为 30 秒，以容纳异步编码；保留 append 成功、writer completed、
全部来源/像素/播放/销毁断言，不改播放器生产源码。

只读检索范围：`3D-HipLab/` 下的本地副本及 `ugk-hiplab/`，未发现 ordinalSet/ordinalRound
的 override；托马斯即本次 Flare，需正式适配的文件只有上述 trainer_voice.dart 两个方法。
`app/test/trainer/trainer_voice_test.dart` 现有英文 ordinal 调用未传 lang，正式接入时须同步检查，
本轮未修改这些测试或期望。保活两条方案不实施；本轮未做 Android 步骤。

## 迁移首轮验证与边界（67683cc，历史记录）

- runtime 全量 162 通过、4 个需显式截图配置的用例跳过；analyze 0。
- 根包全量 1,528 通过、analyze 0。
- Android 对应 packed video/URI、keep-alive、voice controller 共 35 项通过。
  本机已安装 OpenJDK 17，仅通过 JAVA_HOME/PATH 选择，未修改 SDK 生产依赖。
- iOS 浅/深 HUD 用例覆盖下载进度、失败重试、ready 等待 first-frame、对勾淡出。
  这是 iOS 平台 widget 模拟测试，不是 iPhone 画面结论。
- `onTiming`、排队、缓存/下载校验由本次 runtime 全量覆盖；未将受控耗时写成真机网速。
- 临时 iOS 15 最小宿主：SPM 模拟器 debug 构建、CocoaPods device debug 无签名构建均通过。
  这两项只证明插件集成可编译，不能替代 Flare 宿主构建或真机验收。
  原生 XCTest 首次被生成的 objective_c.framework 缺 Info.plist 阻断；
  CocoaPods 第二次执行 3 过、1 失败，已停止。播放/循环/释放、提前销毁、无效尺寸通过。
  来源边界用例在测试视频生成阶段失败：AVAssetWriter input 等待 5 秒后仍不 ready，
  随后 append 报 readyForMoreMediaData=NO。失败位于 PackedAlphaTests.swift 的夹具生成，
  来源边界断言未完整执行；未改变断言或用跳过掩盖失败。
- Flare SPM 无签名构建两次失败后停止：宿主 `lib/trainer/trainer_voice.dart:85/89`
  的 ordinalSet/ordinalRound 缺少新 SDK `VoiceSource` 的 `{String lang = 'zh'}` 参数。
  Flutter 首次给出签名提示；显式 `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`
  的 Xcode 日志确认真实原因是 Dart 覆盖签名。CocoaPods 的 Flare 构建未继续。
  未改变 SDK 接口去适配旧宿主，也未修改 App 实现或正式 git ref。

原生接口保持：asset/sourceUri 二选一，file/http/https 校验；play/pause/active/visible/
position/dispose 及 ready/first-frame/error/state 仍为同一协议。
`active=false` 清除播放意图，visible 恢复遵循原意图；position 不轮询。
源码与原生合成视频测试不能替代 HTTPS 公共视频的真机解码、方向和边缘验收。

## 测试期望变更（逐条）

| 迁入测试 | 改前 | 改后及原因 |
| --- | --- | --- |
| iOS create failure shows explicit retry status | 直接挂 TrainingActionMedia，查旧文字“视频暂不可用，训练继续 · 重试” | 接入 playbackHandle 和 TrainerMediaDownloadIndicator，查 `media-download-retry`；新基线把失败提示移到 HUD。保留封面、无解码视图、释放 pin 三项断言 |
| iOS ready failure shows explicit retry status | 同上，通过原生 error 触发 | 同上；保留同样三项断言，并继续用原生 error 验证就绪失败 |

未修改其它已有测试期望；新增两个独立 iOS 浅/深 HUD 测试。

## iOS 保活差距与方案（仅评估）

TrainingSessionService 仅 Android；iOS 不注册 training_session，不能套用前台服务/CPU wake lock。
但现有 JustAudioVoiceOutput 已有 playback AudioSession、静音循环、duck/mix 与中断处理，
静音循环有两小时上限；本机 Flare Info.plist 已有 UIBackgroundModes=audio。
因此“完全没有 iOS 保活”与“锁屏必然持续训练”都不是准确结论。

训练时间来自 Stopwatch，Timer 负责推动阶段/播报；系统挂起期间不能承诺实时回调。
恢复后的时钟/过期播报策略、语音关闭/暂停/中断、音频路由、长时间锁屏和进程终止后的恢复
必须分项测试。视频本身在后台退回静帧并释放/暂停，保持静音且不接管 AudioSession。

方案 A：前台训练，后台自动暂停、回前台显式继续，适用于不需要持续语音的宿主。
方案 B：确需后台教练语音的宿主启用音频后台模式，核对 Session 激活/中断与路由、
退出释放和长时稳定性；同时明确静音训练与后台时间语义。另评估持久化时间线检查点，
恢复时补算时间而丢弃过期语音。两方案由用户决定后另单实现，未借本次迁移启用新后台能力。

## App 接入与真机待验

HipLab/托马斯仍从 git 依赖 SDK；将 App 所有 ugk_* 直接依赖和 dependency_overrides
的 git ref 一致改为新 PR 的完整 HEAD SHA，再 pub get，逐项确认 lock 的 resolved-ref 相同。
不在 App 复制播放器或 SDK。升级宿主 VoiceSource 覆盖方法时同步保留 lang 命名参数。
本轮只提供 SHA/说明，App 正式改 ref、签名和出包由用户另行安排。

iPhone 当前不可连接，公共 MP4、Metal 方向/边缘、深浅主题、随包/缓存/飞行模式、镜像、
切动作/返回释放、锁屏/后台/语音，以及真实未缓存进度/完成对勾/断网橙色重试均待真机。
原始日志保存在 `build/ios-packed-alpha-r2/`，不入库。不合 main、不打 tag、不发布。

Flare 临时覆盖已删除、原 pin 恢复，git status 干净；Flutter SPM 设置恢复开启。
最小宿主与测试产物留本地，原生 xcresult 位于 `build/ios-packed-alpha-r2/native-tests.xcresult`。
