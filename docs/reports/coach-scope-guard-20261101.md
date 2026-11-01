# 第 2 批精简与修复回报（2026-11-01）

分支 `codex/coach-scope-guard`；验证代码 SHA：`214b0429cbe2a136db7ac2199eb9a0c5e2ee90af`。
基线 main 为 `2196326ce8a4b216f60d79ddf4135a6d03fbd13d`，本报告随交付提交保留。
实现与清理共 46 文件、+2474/−24281 行；另更新本报告、README 与台账三份文档。

删除摘要鉴真、可信 message/原话证明、多重 scope/目录/版本绑定、假想路径测试矩阵、离线审计工具和入库运行 JSON。
保留目录/工具暴露、计划准入（含跨 App focus/restore/开练）和素材打包三处真实边界，理由见[删除与保留清单](../coach-scope-manifest.md#本批删除的机制与测试)。
新增一次响应多 query/并行检索；草稿前回执明确列出必须采用的替代 ID，缺项继续重编。

SF `scope_content_without_user_evidence` 根因：把上一轮合法目标误要求为本轮原话子串；已取消正常范围内的强制 scope 证明。
`incompatible_action` 根因：草稿用了当轮未检索到的 `n-windshield`；保留 seen 准入，改用同批检索取得合法来源。

全量测试：Coach **1540**、UI **178**、Trainer **578**；额外 Runtime **15**。四包 `dart analyze --fatal-infos` 均 **0**。
UI/runtime 未改动，默认 golden 通过，基线未更新。旧默认请求体的 13KiB 门槛保持通过。

仅运行指定六个真实案例一次：11 轮原话、42 次 HTTP，功能全部通过；7 份非空计划均在名单内且卡片/执行各在目标 ±10%。
下表时长为出计划轮的“卡片/执行”秒；HTTP 按各用户轮列出，耗时是该案例各轮累计秒。

| 案例 | 卡片/执行 秒 | 各轮 HTTP | 累计秒 | 结果 |
| --- | --- | --- | ---: | --- |
| SF five-3 | 624/629 → 288/291 | 3 / 4 / 4 | 39.632 | 通过；第三轮由旧 6 次降至 4 次 |
| SF five-1 | 573/578 → 294/296 | 4 / 2 / 6 | 39.115 | 通过；第三轮两次修复 |
| Hip R1 替代 | 280/291 | 7 | 24.659 | 通过；实际采用代码指定替代 |
| Hip R2 删除 | 307/315 | 5 | 25.298 | 通过；删除范围外练背并告知 |
| Hip R4 坚持 | 首轮 293/306；次轮无计划 | 3 / 2 | 23.786 | 通过；坚持时如实说明没有 |
| Hip R6 安全 | 无计划 | 2 | 12.810 | 通过；安全暂停优先 |

优化目标待用户判断：SF five-1 第三轮因 `incompatible_action`、`replace_too_similar` 修复两次，用 6 次 HTTP。
Hip R1 有 4 次检索及 `quote_not_found`、`plan_check_failed` 两次修复，用 7 次 HTTP。
Hip R2 无重编、只有 1 次检索，模型仍分步用了 5 次往返。预算是优化目标，未降低任何硬门禁。

原始 JSON/日志只在本地 `build/coach-scope-guard-simplify/`；未做离线二次审计或重抽。
SF 名单 219/211 已定，Hip 45、托马斯 51 仍为候选。后续规则见根 `AGENTS.md`；第 3 批仅关键状态帧零像素，暂不做 `saveBindingId`。
未合 main、不打 tag、不动 App/pin；iOS、真机播放/性能与 App 迁移仍由各 App 换 pin 时验收。
