# 只追加上下文与阈值折叠

本方案经开哥 2026-10-28 确认，在四项信息/状态修复 `aa02101` 全量通过后实施。不合 main、不推送、不打 tag，不改 SDK App 默认 LLM 链路。

## 已批准合同

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
