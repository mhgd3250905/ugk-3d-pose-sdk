# ugk_trainer 通用训练模块方案（2026-10-20 摸排定稿）

历史方案：其中决定 A 的“无节奏次数动作默认自主完成”已由 2026-10-23 自动语音引导要求替代。当前行为以 [trainer 0.2.0 接入契约](trainer-020-integration.md)为准，旧计划与接入 API 保留。

## 摸排结论（代码实查）
| 部分 | 托马斯 3D-Body | 开胯 HipLab | SmartFit | 取谁 |
|---|---|---|---|---|
| 计划模型 | 自有 TrainingRoutine，一次一个动作页 | PlanStep（分段/换边） | **ugk_coach TrainingPlan v1**（组×次、循环、轮间休息、单侧） | SmartFit（= SDK 统一格式） |
| 引擎 | DrillTimer（计次靠手点“完成”） | SessionEngine 绝对时间 | 同源 SessionEngine | 合并，补“自主计次”相位 |
| 动作节奏 | 无 | **action-kit 6 种 kind + 相位**（起/停留/落/呼吸） | 只有 repSeconds | HipLab，进 Pose-Hub 目录 |
| 语音队列/输出 | 无 | **10-19 安卓修复版**（tailGrace、stop 清队列、前台服务） | 10-18 旧版拷贝 | HipLab |
| 语音素材 | 无 | 单 manifest.json | 每包 voice/ + common 包 | 抽象 VoiceSource，两种适配 |
| 视频 | DrillMedia 原版 + web 播放器 | 拷贝 | 拷贝（+浅色） | SmartFit 版 + 托马斯 web 端 |
| 后台保活 | 无 | **Kotlin 前台服务 + 唤醒锁** | 只常亮 | HipLab，做成插件 |
| 训练页 UI | 841 行，12 种语言 | 1044 行，疼痛阶梯/感受反馈 | **最新打磨**（倒计时环、固定槽位、触感、深浅色） | SmartFit 为底，HipLab 功能做插槽 |
| 训练记录 | 每动作一条，重试 Session ID 冲突 | 疼痛/连续天数 | history | 统一 SessionResult，开始时定 sessionId |

## 包结构（ugk-3d-pose-sdk/packages/ugk_trainer，Flutter 包，依赖 ugk_coach）
1. engine/（纯 Dart）：SessionBuilder(TrainingPlan + Rhythm) → phases；SessionEngine 绝对活动时间；新增 selfPaced 相位（等用户点“完成本组”）；holdSeconds 走 rep_hold。
2. rhythm/：Rhythm = ActionKind + KitPhase，来源 Pose-Hub 目录新字段 `rhythm`（目录 0.3.0）：HipLab 46 个取 action-kit；SmartFit 由 repSeconds 推导；缺省按剂量（time→hold，reps→selfPaced）。
3. voice/：VoiceQueue / JustAudioOutput / VoiceLineController（HipLab 版）；SessionScript 合并（SmartFit 组/轮 + HipLab 节奏与换边余量）；VoiceSource 接口 + ManifestVoiceSource / DrillPackVoiceSource；无语音语言自动降级为提示音。
4. platform/：TrainingKeepAlive（安卓前台服务插件，iOS/web 空实现）+ 常亮。
5. ui/：TrainerPlayer（SmartFit 播放页为底），TrainerTheme、TrainerStrings（App 传入，支持托马斯 12 语言），插槽：onDiscomfort（HipLab 疼痛阶梯留在 App）、feedbackBuilder、mediaBuilder（默认 DrillMedia WebView，含 web）。
6. result/：SessionResult（sessionId 开始即定、每项组数/时长/跳过/不适事件）→ App 自己存，保存重试幂等。

## PR 顺序（每步本机审过再下一步）
1. SDK：ugk_trainer 0.1.0 + 移植两边测试；Pose-Hub 目录 0.3.0 加 rhythm。
2. SmartFit 切换（模型最近，风险最低）。
3. HipLab 切换（疼痛阶梯/反馈走插槽，语音时序测试原样保留，本机耳机复测）。
4. 托马斯切换：一个计划一次连续训练；获得语音（中英）、后台保活；修 Session ID 冲突。

## 默认决定（开哥可改）
- A 托马斯计次动作保留“自己点完成本组”，计时动作跟倒计时。
- B 托马斯语音只做中/英（复用通用台词），其余 10 种语言只有提示音+屏幕倒数。
- C 动作节奏只在 Pose-Hub 目录维护一份（rhythm 字段）。
- 安卓前台服务每个 App 需在 Play Console 补“媒体播放”前台服务声明（开哥手动）。
