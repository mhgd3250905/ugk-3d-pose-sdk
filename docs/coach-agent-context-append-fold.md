# 只追加上下文与阈值折叠

本方案最初经开哥 2026-10-28 确认。以下保留历史合同；当前分支默认预算见首节，历史数值不代表当前默认值。本文不代表分支当前合并或发布状态。

## 2026-11-02：默认预算放宽与缓存用量日志

`codex/context-budget-widen` 基于 main `0a6c3aa`，仅将 off/on 软阈值按原值乘四，
改为 163,840 / 204,800 B（160/200 KiB），硬上限改为 262,144 B（256 KiB）。
thinking 模式使用 200 KiB 软阈值，保留原 off/on 阈值关系。
默认 `maxTurns` 从 20 改为 50；独立的 `maxHistoryChars=40000` 保持不变。
折叠、不可裁剪的当前轮、失败轮恢复、完整历史/账本/快照等规则均沿用已有实现。

同一 epoch 内 system/tools 固定，历史消息（含 reasoning）只追加，动态状态位于末尾；
已有前缀测试及真实 HTTP 比较用于核验，不新增缓存或前缀机制。
`TokenUsage` 新增默认 null 的 `promptCacheHitTokens/promptCacheMissTokens`，
保留 DeepSeek 原始 `prompt_cache_hit_tokens/prompt_cache_miss_tokens`，
经既有 `UsageRecord.toJson()` 写入日志；服务端未返回时省略，既有 `cachedTokens` 及计费语义不变。
缓存命中率以实际 usage 和字段覆盖率报告，不用 JSON 前缀字节推算命中 token。
唯一一段 40 轮真实长聊和两次场景/器械切换验收见[一页报告](reports/context-budget-widen-20261102.md)。

## 2026-11-01：请求投影与完整存档分离

`codex/chat-context-fit` 保留 40,960 / 51,200 B 软阈值和 65,536 B 硬上限。
旧第 6 条的无损字段继续保存在 `ContextTurnLedger.toJson()`、会话快照和界面历史中；
不再把每轮完整 task / candidates / params / seenActionIds 重复发送给模型。
否则“折叠”为全量 ledger 后仍随轮数增长，恢复 seed 还会一直占据请求预算。

超过软阈值先将已结束轮归入 ledger，并将旧恢复消息投影为用户/最终回复，移除旧工具链与推理。
若仍超预算，使用 `requestSummaryMessage()` 去掉逐轮重复状态，保留原话、交付引用、问答和最新参数；
仍不足时逐步省略旧交付正文、缩至近期轮及近期恢复消息。退出模型视图的内容仍完整保存在存档中。
当前输入、当前轮 assistant/reasoning、最新未消费回执与末尾事实不截断；当前轮已消费回执仍只在硬阈值或上游强制折叠时归档。
若不可折叠的当前载荷自身超限，仍返回 `AgentContextBudgetExceeded`；下一轮可折叠已结束失败轮，避免历史导致永久卡死。

`ContextRequestDiagnostics` 新增兼容的 `ledgerTurnsCompacted/restoredMessagesFolded/ledgerBytes/seedBytes`，
原有 before / after / tail / completedTurnsFolded / receiptBodiesFolded / fitsHardLimit 保留。
`ugk_coach_chat` 经原有 `requestSizeBytes` 端口透传真实 OpenAI `buildBody` 编码器，取消包装不再掩盖精确计数。
`chat.turn.result` 每轮向宿主 observer 提供错误类型与本轮数值诊断，不含原话、回执正文或异常消息；宿主将该事件写入自己的运行日志。
网络、鉴权、上下文、计划门禁、服务/超时分别提示；既有轮数/历史上限单独提示新对话，不更改原轮数策略。

手机 runtime 导出未包含 request / snapshot / result.error，不能据此追认具体手机错误或还原实际字节；
脱敏结构回放与真实模型验证单列，见[本轮报告](reports/chat-context-fit-20261101.md)。

## 历史批准合同（2026-10-28）

1. 先离线重放 R1/R3/R4，逐请求报告完整 HTTP JSON 与前次的最长公共前缀字节，定位前置当前状态、工具/技能回执归档、压缩和其他前缀改写。诊断不调用模型。
2. 普通请求顺序固定为 system → 只追加的历史 → 末尾一条本次当前状态；当前状态不写回历史。system/tools 在同一有效会话内稳定；取消逐请求回执/技能归档，只在折叠时统一处理。
3. **前缀验收口径（开哥补充确认）：** system/tools 和已发送历史逐字不变并可追加；末尾动态状态排除在稳定前缀外，单独统计其字节数，作为每次请求不可命中缓存的下限。完整 HTTP JSON 的 LCP 仍如实报告，不把 JSON 数组结尾等语法差异伪装为完整前缀相等。
4. 预估下一次请求超过软阈值才折叠。off 软阈值 40,960 B，on 为 50 KiB（51,200 B）；硬上限 64 KiB（65,536 B），写入配置。二进制 KiB 计算与前述 40KB=40,960 B 一致。
5. 只折叠已结束的用户轮：全部 user/assistant/tool 消息替换为一条 role=user 摘要，紧跟 system；摘要前不能残留 assistant/tool。当前用户轮的消息及 reasoning_content 不变。保留历史中的 assistant 必须原样回传 reasoning；被折叠轮的 reasoning 仅随整条 assistant 一起替换，不单独清理。
6. 摘要由代码从真实账本确定生成，不调用模型。开头为“以下是本次会话之前的记录（系统生成）”。无损保留各轮用户原话全文、最终交付文字、卡片引用（类型/plan_id/版本/动作ID）、ask_user问题及回答、参数快照（值/source/quote及现有派生来源）、节点、picks、candidates、当前计划版本、已加载技能名。允许丢弃被折叠轮的 reasoning、原工具回执和被拒调用。
7. 当前单轮自身超过硬上限时，只归档本轮已被模型使用的工具回执正文，保留 tool_call_id；绝不动本轮 reasoning。
8. 接口兼容探针总计最多 4 次 HTTP 尝试：授权中转站 + deepseek-flash + thinking on + tools，两用户轮，首轮整轮折叠为 user 摘要后发送第二轮。任何 400 立即停止并回报，不继续实现或评测。
9. 测试覆盖账本等价、原话/交付/quote逐字保留、当前轮字节不变、未达阈值时稳定前缀完整追加。完成后同一冻结版本 thinking off/on 六例各一次，结果分目录，新增任务类型是否正确、缓存命中/输入token、是否折叠、折叠前后字节、末尾状态字节。

10. **恢复首包补充确认：** 新完整账本恢复按本轮 off/on 软阈值及 64 KiB 硬限，不能为旧 12KB 限额丢原话或来源；新建空会话与无完整账本的旧存档首包继续以 12,288 B 作防退化检查。恢复首包的实测字节单列报告。

目录安全缺口仍按 `aa02101` 的规则处理：没有 limits 时只记开发者日志；缺 cautions/contraindications 对任何非空 limits 相关，保留既有安全处理，不新增业务硬门禁。宿主隐私清除/关闭记忆、reset、取消等既有 API 的安全与竞态行为必须继续通过。

## 参考设计与边界

核对了 [DeepSeek thinking 官方文档](https://api-docs.deepseek.com/guides/thinking_mode/)：带 tools 时保留所有仍存在的历史 assistant 的 reasoning_content。另核对 [官方前缀缓存说明](https://api-docs.deepseek.com/guides/kv_cache/)，实际命中仍由上游 usage 报告，字节前缀稳定不能直接等同 token 命中率。

对照了 [Cline Auto Compact](https://github.com/cline/cline/blob/main/docs/features/auto-compact.mdx) 的阈值触发/摘要替换，以及 [Roo Code context management](https://github.com/RooCodeInc/Roo-Code/blob/main/src/core/context-management/index.ts) 的消息边界处理。二者均为 [Apache-2.0](https://github.com/cline/cline/blob/main/LICENSE) / [Apache-2.0](https://github.com/RooCodeInc/Roo-Code/blob/main/LICENSE)；Roo 仓库当前为归档状态，仅作历史问题参考。这里不引入其 TypeScript/Anthropic 依赖，也不复制摘要生成代码；本项目按已批准的 Dart 账本确定性摘要实现，不使用模型摘要或滑窗丢原话的后备方案。

2026-11-02 缓存日志改动前，另比较了持续维护的 [OpenAI Python 可选用量字段](https://github.com/openai/openai-python/blob/main/src/openai/types/completion_usage.py)（[Apache-2.0](https://github.com/openai/openai-python/blob/main/LICENSE)）和 [LiteLLM](https://github.com/BerriAI/litellm)（[enterprise 目录外为 MIT](https://github.com/BerriAI/litellm/blob/main/LICENSE)）。前者提供可选字段的直接解析参考，后者的多提供商网关及 Python 依赖超出本次记录数值的需要；其[缓存桶与 prompt token 归一化修复](https://github.com/BerriAI/litellm/pull/37173)仍在上游评审。本次沿用 Dart 原用量序列化，不引入依赖、不复制外部实现，服务端缺失字段保持未知。
