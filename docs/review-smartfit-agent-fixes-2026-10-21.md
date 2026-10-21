# SmartFit 联调引出的 SDK 修改说明（待 SDK 维护者审核）

日期：2026-10-21（Asia/Shanghai）。本说明由 SmartFit 接入侧提交，用于 SDK 侧独立审核，不代表 SDK 已批准或修复已合入 main。

## 审核入口与固定范围

| 项目 | 固定标识 |
| --- | --- |
| 仓库 / 分支 | `mhgd3250905/ugk-3d-pose-sdk` / `fix/coach-agent-reasoning-replay` |
| 审核 main 基线 | `1d1aad86f516bd7121cc73c71d623043f1042dc3` |
| 本说明绑定的修复 head | `9bc392c42222d61d8c57e8dc00373ee165e56e06` |
| 已测实现与测试 source | `43dfef637144a1e08b5eda5ed743db0671ba5a8d`；与上述 head 的运行、测试和包配置一致 |
| SmartFit 运行 source / 分支 head | `5743073691547d44aec891ab6d4a45b5b3fa381b` / `e6c547da32de59a5e2aac72189a8eaadd92af95c` |
| SmartFit 当前依赖 | git ref 固定 SDK 完整 SHA `43dfef637144a1e08b5eda5ed743db0671ba5a8d`，按临时联调规则使用 |

[固定范围完整 diff](https://github.com/mhgd3250905/ugk-3d-pose-sdk/compare/1d1aad86f516bd7121cc73c71d623043f1042dc3...9bc392c42222d61d8c57e8dc00373ee165e56e06)。该范围共 10 个文件：4 个运行文件、2 个新增测试文件、4 个文档文件。新增本说明及入口链接只改变文档，不扩大实现范围。

可只读核对：

```sh
git diff 1d1aad86f516bd7121cc73c71d623043f1042dc3 9bc392c42222d61d8c57e8dc00373ee165e56e06 -- lib test
git diff --exit-code 43dfef637144a1e08b5eda5ed743db0671ba5a8d 9bc392c42222d61d8c57e8dc00373ee165e56e06 -- lib test packages tool prompts skills profiles pubspec.yaml pubspec.lock analysis_options.yaml
```

第二条已核对退出码 0。修复分支已吸收 main 的新增文档，原有 main 内容保留；尚未合入 SDK main，也未合入 SmartFit main。

## 为什么需要修改

1. **多步协议失败。** SDK main `1f8be6e` 的首次真实 Worker 请求能完成读 skill，但下一步 HTTP 400，错误要求回传 `reasoning_content`。客户端已解析到响应推理，构造下一步 assistant 消息时却没有带回该字段。
2. **空值仍失败。** 第一版只回传有值推理后，核心计划已成功，但「臀桥怎么做」遇到上游缺失/null 推理的响应，下一步仍因省略字段返回同类 HTTP 400。需要在 Agent/Session 回放消息中保留空字符串；不能伪造推理正文。
3. **工具存在不等于记忆生效。** 对「我是新手，家里有哑铃」，记忆开关和工具都已开启，模型却只生成新手哑铃计划，未读记忆 skill、未调用 `remember`，本机仍为 `[]`。这是模型没有选择记忆工具，不是 App 的 `UserMemoryStore.save` 写入失败。该轮虽然 `status=ok`，仍被判为记忆验收失败。

初始失败、修复过程和逐轮证据均保留在 [SmartFit 固定版本报告](https://github.com/mhgd3250905/Sport-Helper/blob/e6c547da32de59a5e2aac72189a8eaadd92af95c/docs/coach-agent-smoke-2026-10-21.md)。

## 实现改了什么

| 文件 | 变更及目的 |
| --- | --- |
| [lib/src/llm/llm_types.dart](../lib/src/llm/llm_types.dart) | `LlmMessage` 增加可选 `String? reasoning`；仅 assistant 的 `toJson()` 在非 null 时输出 `reasoning_content`，保留真实空串。system/user/tool 不序列化它；不拼入 `content` 或 `toString()`。普通手写消息不传该参数时仍省略字段。 |
| [lib/src/agent/coach_agent.dart](../lib/src/agent/coach_agent.dart) | 中间工具步骤、门禁重交、最终纯文字/卡片历史回传推理。响应缺失/null 时用空串，预设回落历史也保留空字段。当前轮和已提交历史分别标记“请求时开启记忆”的 assistant；关闭记忆后对这些消息的推理作保守清空，保留空协议字段，避免新字段把记忆原文再次传回。记忆始终关闭时正常推理完整回传；`reset()` 清掉历史及标记。历史字符统计包含推理长度。 |
| [lib/src/tools/coach_session.dart](../lib/src/tools/coach_session.dart) | 0.2 会话入口同步处理工具重交、最终历史、预设回落后的空/有值推理回传，并将推理计入历史字符上限，防止保留入口仍遇同类协议错误。 |
| [lib/src/agent/agent_prompt.dart](../lib/src/agent/agent_prompt.dart) | 只增强 `memory=true` 的 `memoryTools` 指令：主动提供稳定条件时先读记忆 skill、按类别调用 `remember`，工具成功后再确认；只有条件介绍且没有待完成训练请求时不擅自交付计划。禁止从默认上下文或一次临时请求推断长期事实。`memory=false` 分支、内核模板、skill 文件及 Agent 存储实现未改。 |

实现提交顺序：`029af4a`（推理回传与记忆推理脱敏）→ `712cb7b`（缺失/null/空值与回落历史）→ `43dfef6`（记忆开启指令）。之后 `5b5aa27` 仅同步 main 文档，`9bc392c` 仅整理验证记录。

SDK 源码只在 SDK 仓库修改。App 没有复制、内嵌、patch SDK，没有修改 pub 缓存或使用 path 依赖。`CoachAgent.send/reset`、`CoachTurnResult`、`ValidatedActions/ValidatedPlan` 的消费方式保持；App 的进度、持久化适配和设置在 App 仓库实现。`maxSteps` 仍为默认 10，未以增大步数或自动重试绕过失败。

## 已有验证与适用范围

- `test/reasoning_replay_test.dart`：15 项新增回归，覆盖 HTTP JSON 请求体中的读库、记忆、自检、最终交付、门禁重交、跨轮历史；missing/null/空串；回落后继续；运行时关闭记忆及始终关闭；推理不混入正文/toString；字符上限。
- `test/agent_memory_prompt_test.dart`：5 项新增回归，覆盖三个 profile 关闭记忆时 system/tools 的 SHA-256 与 `712cb7b` 相同、开启时的指令约束，以及读 skill→记下水平/器械→确认→新对话摘要的可达保存链路。fake 模型测试不替代真实模型验收。
- SDK source `43dfef6`：根包 `dart test` **304 项**、`dart analyze` **0 问题**；`packages/ugk_trainer` 的 `flutter test` **126 项**、`flutter analyze` **0 问题**。
- SmartFit source `5743073`：`flutter test --no-pub` **217 项**、`flutter analyze --no-pub` **0 问题**，严格锁文件检查及 Android debug 构建通过。

真实 Worker 为 `https://api.uuugk.win/v1` / `deepseek-v4-flash-0731`，走实际 App 引擎、控制器、93 动作目录和 SDK smartfit profile；Flutter 测试宿主发真实 HTTP，记忆保存到本机文件。以下不是真机 UI 或完整训练验收。

| 最终采用用例 | SDK / 记忆 | 步数 | 秒 | token | 回落 |
| --- | --- | ---: | ---: | ---: | --- |
| 在家 15 分钟练核心，徒手 | `712cb7b` / 关 | 7 | 140.800 | 63,487 | 否 |
| 臀桥怎么做 | `712cb7b` / 关 | 7 | 101.670 | 39,219 | 否 |
| 我腰不太舒服，想练腿 20 分钟 | `712cb7b` / 关 | 8 | 204.564 | 98,806 | 否 |
| 我是新手，家里有哑铃 | `43dfef6` / 开 | 3 | 35.372 | 11,487 | 否 |
| 新对话排 15 分钟居家力量计划 | `43dfef6` / 开 | 6 | 119.549 | 72,881 | 否 |
| 再开新对话重复同一计划问题 | `43dfef6` / 关 | 7 | 167.122 | 80,886 | 否 |

记忆开启时实际写入 `level=新手` / `equipment=家里有哑铃`，下一新对话的难度 1 计划含哑铃地板卧推和划船；关闭后请求无记忆摘要/工具、计划无哑铃，本机原两条记忆保留。护腰计划的 11 个动作无目录腰部禁忌。核心与臀桥实测确实遇过空/缺失推理响应，后续请求保留字段后不再出现原 HTTP 400。

这是**分组复验**：`43dfef6` 唯一生产代码差异只在记忆开启指令，关闭记忆 system/tools 经三个 profile 的字节等价回归核对，因此复用 `712cb7b` 的前三条真实结果；未声称六条都在最终 SHA 重新请求。token 是 prompt + completion，reasoning 已在 completion 内，不重复相加。问题之间为同一持久设备 UUID 留足请求配额，配额等待不计入单轮耗时，未轮换 UUID。

## 请 SDK 侧重点审核

1. **协议与提供商兼容。** 有值推理回放、missing/null 归一化为空串、纯文字/工具/回落历史的覆盖是否正确；当前 Agent/Session 会给这些 assistant 消息带字段。真实兼容只验证上述 Worker/模型，未完成其他提供商矩阵；是否需要提供商能力开关请由 SDK 侧判断。
2. **隐私及生命周期。** 记忆开启请求的推理采用保守标记，关闭后脱敏且不破坏工具配对；取消、reset、开关切换时标记是否完整。关闭记忆没有抹除用户已说出的当前聊天正文；隔离实测先开新对话，不把“关记忆”宣传成清空聊天。
3. **历史限额变化。** 新增推理被保留并计入字符上限，长对话可能比旧版更早触发 `limitReached`；检查这一行为和现有上限是否合适。推理字段只作传输数据，不应进入 App 渲染或普通正文日志。
4. **记忆指令的产品范围。** 该指令影响所有使用 `CoachAgent` 且开启记忆的 profile，不只 SmartFit。请复核稳定/临时条件边界、不适原话的记忆规则，以及仅介绍条件时不自动排课是否符合 SDK 统一交互约定。模型行为仍可能波动，单轮真实通过不是任意输入都必然调用工具的证明。
5. **持久化确认语义。** 既有 `_save()` 采用串行、best effort 异步保存；本次没有改存储失败处理。`remember` 的工具成功与成功轮次提交，不等于磁盘写入已经完成或保证不会失败。实测另等待并读取本机文件确认落盘；请 SDK 侧判断“记下了”的确认语义是否需要更强持久化保证。
6. **既有未决问题与版本。** [台账 SDK-002](project-ledger.md#未决事项) 的跨消息复用工具 ID 过滤问题仍为原有非阻塞 P3，未在此修复。当前新增构造参数可选，包版本保持 0.3.0；请维护者确认兼容性判断与后续补丁版本安排，不把本说明视为发布批准。

## 审核后的处理

请 SDK 侧基于固定范围回报阻断项、非阻断建议及是否同意采用；若需修改，继续在 SDK 仓库分支补回归和 CHANGELOG，再按影响更新 App ref。SDK 审核及开哥同意前，不合 main。获准后先合 SDK 并推送，确认 App 固定 SHA 已成为 SDK main 上的提交后，再处理 App main。

本说明只提交审核材料，不申请代替维护者作审核结论；不包含密钥、设备 UUID 或原始请求头。
