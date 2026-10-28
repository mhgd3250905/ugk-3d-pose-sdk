# 第11步评审补充：技能正文、thinking协议和对照准备

核对日期：2026-10-28。只实现批准的三项，未改Worker，未调用真实模型，等待开哥通知Worker修好。

## 改动

技能披露按模型实际可见历史中的read参数path与SDK完整成功返回元数据记录，不看模型自然语言或技能正文是否包含某个词。read先加载的技能，start_task的skills按名称返回“[已在前文 read 中]”；反过来read返回“[已在 start_task 结果中]”。失败read/start_task、伪造文字声明、重复tool_call_id均不能建立错误的加载状态。无关技能read在任务成功开始后归档一行，保留配对ID；已归档内容不复活。技术上下文压缩保护当前任务所需的完整正文，避免引用变成悬空。问答仍可按需read，结束任务后已丢弃的全文必须重新加载。

内部披露元数据不进入toJson请求和宿主保存结构；安全和来源校验、固定节点、动作过滤、卡片结构保持不变。提示词增加推荐/计划直接start_task、不要先read的明确说明。

runner新增--thinking on|off（默认on），映射thinking.type=enabled/disabled，summary、每轮及每次请求都标记模式。只读工具compare_coach_agent_v2读取将来的on/off两份六例证据，比较调用次数、耗时、最大请求、token、数值时长偏差与已确认账本的器械合规；重复追问和参数stamp语义保留原文、节点与参数回执供人工审阅，缺失结果不会标通过。Task以真实执行的任务事件及请求活动快照分类，不依赖取消后回滚的最终状态；不从用户句子或尚未执行的模型工具参数推断。

未来收到Worker修好通知后，分别用--thinking on与--thinking off各运行六例一次，保留两份独立目录，再用只读对照命令比较；本次没有执行这两次真实评测。on/off两次CLI --dry均为modelCalls=0。

## DeepSeek官方文档结论与原文

官方链接：[Thinking Mode / Tool Calls](https://api-docs.deepseek.com/guides/thinking_mode/#tool-calls)；[中文说明](https://api-docs.deepseek.com/zh-cn/guides/thinking_mode/#工具调用)。已同时核对官方页面与Context7的官方文档索引。

关键原文：

> Additionally, in the Turn 2 request, we still pass the `reasoning_content` generated in Turn 1 to the API.

tools分支另要求“must be fully passed back”。携带tools时，仍发送的历史各轮reasoning均需完整回传，即使某次没有实际tool_calls；示例明确保留新用户消息前的推理。无tools请求才无需回传。SDK的Agent请求始终提供工具列表，因此按开哥“文档不同就按文档”的授权，不实现跨用户消息清空。修复任务完成后重建可见assistant时意外丢失reasoning的问题；当前轮内容继续完整保留，记忆关闭隐私脱敏规则不放松。已结束内部工具批次仍按原上下文规则整体移除，不凭空恢复私有推理。

## R6公开记录离线重放

使用已保存R6的六次公开响应工具序列（先read三个技能再start_task）驱动真实CoachAgent、工具处理器及Worker请求体序列化。原私有推理正文未保存，测试使用明确标注的合成占位；精确匹配前五份的字符数、UTF-8和JSON值字节占用。第六份没有后续请求、JSON占用未知，保留null，不伪造。

| 请求 | 修复前实际记录 B | 修复后离线重放 B | 当前请求回传推理UTF-8 B |
|---|---:|---:|---:|
| 1 | 12088 | 12209 | 0 |
| 2 | 20747 | 20868 | 955 |
| 3 | 23533 | 23654 | 2316 |
| 4 | 35029 | 26885 | 5928 |
| 5 | 39546 | 31402 | 6355 |
| 6 | 43265 | 35121 | 6762 |

最大请求35121 B，比40960 B上限少5839 B。原前置三个read在start_task前完整可见，任务需要的正文仍在引用目标中完整存在，无关plan-training归档；所有tool_call_id配对保留。测试没有用删除当前轮reasoning、改变工具description、隐藏标签枚举或预置计划来达标。此处是公开工具序列及同字节推理占用的离线重放，不是新真实模型结果。

## 验证与停止点

ugk_coach全量931项、ugk_coach_ui 79项、ugk_trainer 332项全部通过；三包严格静态分析无问题，未修改分析配置。本次做完提交后停止，未合main、未推送、未打tag，未开始阶段二、三。
