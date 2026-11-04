# 聊天页启用 QA v2

SDK 的 `CoachChatPage` 可直接使用 `CoachQaAgent`。已有 App 不传新配置时继续使用
旧 `CoachAgent`，页面、导航、存储和播放器接线保持原接口。

## App 改什么

在现有 `CoachAppProfile` 中增加两个配置：

```dart
import 'package:ugk_coach_chat/ugk_coach_chat.dart';

final chatProfile = CoachAppProfile(
  appId: coachProfile.id,
  scopeManifest: manifest,
  coachProfile: coachProfile,
  conversationPolicy: policy,
  executionTiming: playerBuilder.executionTiming,
  agentMode: CoachChatAgentMode.qaV2,
  aiTags: appAiTags,
  // 原来的 visual、strings、library 等配置照常传入。
);
```

`appAiTags` 类型是 `Map<String, Map<String, Object?>>`：键为动作 ID，值为该动作的
AI 标签 JSON。由 App 从自己的资源或服务加载，再构造 profile。SDK 不附带标签文件，
不自行访问 Pose-Hub，也不把标签写进聊天历史。未提供或缺少标签的动作回退到目录字段。
动作是否可用仍由 App 的 scope manifest / library 白名单决定，传标签不会扩大范围。

现有 `CoachChatBindings.gateway` 继续提供模型客户端及鉴权；`CoachQaAgent` 按其 SOP
逐步理解用户、追问条件并推荐或修改动作。无需 App 重新写聊天页面、问题表单或解析
「第几个」。回退旧版只需将 `agentMode` 改为 `CoachChatAgentMode.legacy`（默认值）。

## 页面行为

模型生成的单选、多选问题使用 SDK 已有的 `QuestionBubble`。选择后的文字原样交回
Agent；多选合并成一条回答。新问题出现时，旧问题不能再次提交。

QA v2 动作推荐显示从 1 开始的编号；计划按热身、主训练、收操的实际顺序连续编号，
与 Agent 用来解释「换第 2 个」的顺序相同。`assumption` 单独显示，模型返回的快捷按钮
（例如「换场地」）点击后发送同一按钮文字，不转换成宿主命令。

聊天快照保留 QA 条件、待回答问题和最近卡片/计划，重新打开聊天后可以继续回答及
按编号修改。新对话清空这些条件。旧版历史及旧版默认路径继续兼容。

QA 计划交给现有门禁前，聊天适配层将来源统一为 `ai`，并用模型已有的正文补齐原型
计划缺少的摘要。显示、会话内编号状态和保存使用同一份计划，恢复历史时仍重新准入。

器械声明由代码汇总最终入选动作的标签（包括热身、收操），缺标签的动作沿用目录；
不会把用户拥有但本计划未使用的器械写进计划。QA 的准入目录使用同一份器械事实，
避免标签与旧目录的器械口径冲突；未识别的器械 ID 保留原文。换动作、改时长后重算。
聊天交付前复用已有配时器，按宿主真实播放器回调校正卡片/执行双时长到既有容差内，
保留动作 ID、块顺序和连续编号；失败时不会放宽门禁。旧版 Agent 的目录和路径不变。

## 验证入口

普通组件与控制器测试在 `packages/ugk_coach_chat/test`，不调用外部模型。
真实模型页面验证入口为：

```powershell
./tool/coach_chat_qa_v2_live.ps1 -OutputDirectory build/qa-v2-live-my-run `
  -AiTagsDirectory /path/to/app-owned/ai-tags/actions
```

每次使用新的输出目录，报告和截图留在本地 `build`；默认模型为
`deepseek-v4.1-flash`，凭据沿用 `tool/eval_api_config.dart` 的既有加载方式。
模型用量与耗时以实际运行报告为准。该验证通过 Flutter 测试引擎挂载真实聊天页，
不启动模拟器，不代表真机播放或 App 已迁移。
