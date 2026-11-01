# SF 接入回归修复 · 2026-11-01

分支 `codex/chat-sf-fixes`，基于 main `b025ee88bd1a6d69564ce96a473302739c981c3b`。
实现提交 **`8bb5877513ccb7b900179cd1cb2dc16a3bf66d17`**；11 文件 +854/−13 行，
另加本报告及 README/台账收尾。对照 SF `3eb2a9e`，验证宿主为本地 `083cdad`。

7 条都覆盖实际行为，不是查询已迁入 SDK 的私有实现；原断言全部保留，无需删测。

| SF 原失败 | 归类 / 根因 / 处理 |
| --- | --- |
| chat_home_ia：drawer empty | 聚焦回归 / 返回固定 dismiss、缺 compose 信号 / 新增 `requestCompose()`，宿主 pop 后调用，原输入框下一帧聚焦。 |
| chat_keyboard_focus：foreground | 聚焦回归 / 显式 compose 无法重新激活原输入 / 后台返回仍隐藏键盘，显式请求才恢复聚焦；保留同一 FocusNode。 |
| developer_log_details：raw user text | 日志契约回归 / trim 后才暴露文字 / `chat.user` 事件给 `CoachChatUserInput.rawText/sentText`，宿主按 messageId 去重。 |
| developer_log_details：archive before reset | 归档顺序回归 / core 先 reset，事后观察无法等待 / 可选 `beforeNewConversation(snapshot)` 同步开始、完成后才 reset，新输入排队；归档失败仅诊断并继续。 |
| performance_fixture：mixed 72/12 | 历史显示回归 / 非 AI 模板误套当前计划准入 / 保留只读 raw 计划，72 条原时间戳与 12 卡恢复。 |
| legacy_template：core | 旧档回归 / 原 time 剂量不合当前 reps 定义 / 原 target/dose/context 不变，跨关闭和重启保留，训练/保存仍独立拒绝当前不合规计划。 |
| legacy_template：office-relax | 旧档回归 / 原 mode/场景不合当前目录 / 同上只读恢复；启动恢复失败不写空 envelope 遮盖旧档，仍释放 lease。 |

SF 五包使用临时 path override：旧 SDK **0/7**；修后 SDK + 原 SF 适配器 **3/7**；
临时两文件接入上述公开端口后原断言 **7/7**，另一个原归档失败用例 **1/1**。
仍需 SF 正式接线：`lib/app/coach_chat.dart` 的 compose/归档绑定，以及
`lib/diagnostics/coach_chat_diagnostics.dart` 的原话消费、去重和移除事后重复归档。
所有 SF 生产文件、lock、override、package config 等已原字节恢复，工作区 clean、HEAD 未变。

SDK 全量：**Coach1540、UI178、Trainer578、runtime15、chat43** 全通过（chat 新增 9 条）；
五包 `dart analyze --fatal-infos` 均 0（root 为 `lib test tool`）。默认 golden 通过；
因聚焦 UI 改动重跑原冻结基线，浅/深 **22/22 零像素差**，未放宽阈值或更新基线。
并发/OOM 中断记录保留，最终采用串行低并发通过，不把中断算作通过。未跑真实模型。

接口与接线见[模块文档](../coach-chat-module.md)；SF 验证日志及临时接线 patch 只留本地
`build/sf-integration-verification/`，测试/分析日志在 `build/chat-sf-fixes/`，
像素在 `build/chat-extract-baseline/chat-sf-fixes-final/`。未合 main、未打 tag、未改 App/pin。
