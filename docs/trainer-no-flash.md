# 第 1 批：共享训练入口与静态帧

分支 `codex/trainer-no-flash`，基于 SDK `7d9be56`。盘点分支
`codex/shared-capabilities-audit@f479178` 已普通推送。

**结论：通用入口、poster 预热和首帧切换归 SDK。** 用户复测侧边图标小 bug
已未再出现，按最新指示跳过其根因定位，不作为本批阻塞项，也不宣称已修复该缺陷。

HipLab `0f507a3` 自有媒体的 poster 未解码时透明，视频 WebView 已创建；训练入口
没有统一预热和 start gate，存在初始化内容可见的窗口。它与底部侧按钮闪帧的因果
关系未确证。HipLab 抽查 4 动作×浅深 poster 与既定 `posterTime` 对齐，已有 seek
逻辑，不能仅因 poster 不是第 0 帧就判错。SF `52d30ae` 延续 `4a4bdbe` 的独立
播放 poster，并在入场前保留已解码图片、路由结束后才创建视频。

## SDK 与 App 边界

`ugk_trainer_runtime` 新增 `TrainerLauncher`、`TrainingPosterImages`、`TrainerPoster`：
同 bundle/物理宽度/provider 预热与绘制，保留已解码图片；首图失败/超时不入场；
防重复开练、后台中断、时钟 gate、退出保存协调；进出动画期间 poster-only，
切换冷 miss 复用既有静帧；轻量预备侧按钮字形。视频复用已有真实 `first-frame`
协议，metadata/ready 不触发揭图。字形 CPU 预备不保证 GPU atlas 已缓存。

`CoachAppProfile.trainingExperience` 可选，null 使用默认体验。
`CoachChatTrainingAdapter.call` 赋给现有 required `onStartTraining`，实际消费该配置，
并衔接 request 的 `onStarting` / `holdTransition`。普通开练也用同一 launcher。
显式旧 startGate、mediaBuilder、退出回调保持优先。

| App | 需要的接线/数据 |
|---|---|
| HipLab | 普通/快捷入口改 SDK launcher；聊天保留业务计划转换，导航接 SDK adapter；drillOf 提供 `DrillMedia` 的暗/浅视频、播放 poster、duration、posterTime 与媒体策略，移除自有媒体 builder。App 不补预热或遮罩。 |
| SF | 当前显式 route/gate/media hooks 兼容不变；后续统一入口时替换 open_training 通用部分与 poster helper，保留业务安全检查/语音/保存。 |

SDK 尊重所提供的视频、播放 poster 和时间点，不把列表 thumbnail 当播放首帧。
`first-frame` 表示已有可呈现帧，不保证揭图瞬间严格落在视频时间 0。

## 验证

固定 App 提交的隔离副本、本地 SDK path override，Flutter 3.47.8 / Dart 3.13.7。
Flutter 测试文件串行；按用户要求已关闭模拟器，后续未再启动设备或 Gradle。

| 验证 | 结果 |
|---|---|
| SDK 新行为 / 既有相关回归 | 7/7 + 55/55 |
| Chat adapter / controller | 11/11 |
| runtime / chat analyze --fatal-infos | 均无问题 |
| SF 浅深固定整页关键帧 | 2/2，32/32 零像素差，基线未更新 |
| HipLab 默认共享链逐帧 | 2/2，436 张 widget 帧；72/72 转场样本已解码 poster、0 视频 surface；接线 analyze 无问题 |
| 真实模型 | 未改模型/计划逻辑，不调用 |

原始 PNG、JSON、日志和 App 临时接线补丁在 `build/trainer-no-flash/`，不入库。
原生基线 162 PNG / 149 秒录像仅作旁证，平均约 9.45 fps，不等于真机逐刷新帧验收。
本批不合 main、不打 tag，不提交 App 或正式 pin 改动。
