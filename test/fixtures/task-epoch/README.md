# SF five-3 公开任务切换回归

`five-3-public.json` 来源是上轮已保留的真实模型 case，原文件 SHA-256：
`ffe472247656aecbccfeb77d743464377e46a5c6040d6e2849fc3018ad69c3f0`。
提交的分析证据见
`docs/reports/fit-executed-duration-20261101/recommendation-intermediate-failure.json`。

本 fixture 只提取三条用户输入、首次实际交付的计划版本和 14 次原始公开工具调用。
不含 system、reasoning、请求头、凭据或整段模型 wire history；不修改旧证据。

关键顺序是 C6 show_actions → C7 search_actions → C8 相同 ID 的 show_actions。
原故障在 C8 再次清空来源池；修正后应在 C8 正常结束本轮。因此最小离线重放在
首次成功交付处停止，原 C9/C10 仅作为原失败重试证据保留，不把它们执行到下一用户轮。
这不是新真实模型运行，不据此报告真实调用预算的改进。

第 3 轮沿用原 C11–C14 参数、检索、草稿与修复：C12 的主体差异不足仍须拒绝，
C13 是原样保存的实际修正，不能放宽差异、seen、安全或双时长门禁来让测试通过。
测试核对推荐成功/失败都不改变第 1 轮计划，后续 edit/replace_all 仍基于其 SDK 版本。
