# 教练 Agent v2 第 9 步（2026-10-28）

按本日预算评审修订实现。工具及参数 description 恢复并由测试与 520c3d5 原文比较，未缩短。

## 顺序测量（实际 Worker 请求体，thinking 开启，假模型）

| 修改点 | 恢复 10 动作 B | 恢复 15 动作带分段 B |
|---|---:|---:|
| 恢复工具说明后的基线 | 13757 | 13952 |
| 1 output 完成后的精简状态 | 12672 | 12785 |
| 2 按字段拆 enum（原实现已满足，无需变更） | 12672 | 12785 |
| 3 移除 ls | 12399 | 12512 |
| 4 去重系统提示的工具用法 | 12063 | 12176 |
| R3 目标恢复为仅 body.core 后 | 12003 | 12176 |

硬上限 12288 B 通过；软目标 11264 B 未达到，分别超出 739/912 B，按批准不算失败。state 完整来源/plan JSON 无损保留；请求只保留参数 stamp、计划元数据与动作名称。无任务时仅发送已有参数，进行中仍发送完整状态。

## Schema 诊断

基线 SmartFit 工具数组 memory=false 9082 B，true 9898 B；移除 ls 后分别 8809/9625 B（含数组开销）。

| 工具 | schema B（移除 ls 后） |
|---|---:|
| start_task | 325 |
| check | 403 |
| read | 295 |
| search_actions | 1424 |
| get_action | 327 |
| draft_plan | 819 |
| set_params | 3014 |
| check_plan | 258 |
| show_actions | 338 |
| show_plan | 336 |
| ask_user | 1258 |
| remember（可选） | 448 |
| forget（可选） | 366 |

| enum 列表（SmartFit） | JSON B | 同列表重复次数 |
|---|---:|---:|
| start_task.type | 20 | 1 |
| check.node | 57 | 1 |
| search_actions.tags（全部标签） | 1002 | 1 |
| draft_plan.operation | 22 | 1 |
| draft_plan.blocks.kind | 28 | 1 |
| set_params.scene.value | 23 | 1 |
| set_params.goal.value（body/purpose） | 424 | 1 |
| set_params.equipment.value（equip） | 371 | 1 |
| set_params.limits.value（伤痛） | 104 | 1 |
| set_params.source（三值） | 30 | 5 |
| set_params.minutes.source（含 derived） | 40 | 1 |
| set_params.minutes.direction | 20 | 1 |
| set_params.level.value | 7 | 1 |
| ask_user.mode | 24 | 1 |
| ask_user.fields.key | 31 | 1 |
| ask_user.skipLabel | 19 | 1 |
| remember/forget.kind | 84 | 2 |

全量标签只在 search_actions 出现一次，无多份重复全量 enum。source 重复是独立 JSON Schema 字段约束，未删约束。三个 profile 的全部路径/字节/枚举内容由 tool_schema_diagnostics_test.dart 输出，日志保存于 worktree-preserved/coach-v2-step9-schema-final.log。

## 重放与保留行为

正常序列 5 次模型调用、3 次带标签搜索、无 get_action；10 动作卡片、实际 check_plan 和六节点一次通过，最大请求 30163 B（无任务状态简化后首包更小）。压力序列 15 次搜索、10 次单独详情，最大 40031 B；其余请求 11324/25671/31686/34718/37727/35724/12306 B。每次都检查工具 ID 配对。详情与搜索结果仅下一次模型请求完整可见，后续按批次归档；完成节点归档和失败被成功调用取代规则保留。重复搜索仍执行当前参数过滤，重复项只回 id，保存恢复继续有效。

profile.bodyGroups 配置核心子编码，focus 和搜索共用，原目录标签不改；R3 仅 body.core 的十动作计划通过实际 PlanChecker。原用户已批准 seenActionIds/picks 自动补齐规则保留。

## 验证与阶段状态

离线全量：ugk_coach 867 项（另有第11步提前准备的 reasoning 统计 2 项也通过）、ugk_coach_ui 79 项、ugk_trainer 332 项。三包严格静态分析无问题。未运行本次 v2 真实模型评测，因此无真实对话、节点打卡、模型耗时/token/P50/P90；离线请求大小不能代表含真实 reasoning_content 的请求大小。

第1–8步已实现；第9步完成，软目标未达已说明；第10、11步接续实现。未合 main、未推送、未打 tag、未创建 worktree。
