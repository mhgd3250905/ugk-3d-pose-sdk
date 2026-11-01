# Scope 现场运行工具

`tool/eval_coach_scope_guard.dart` 直接运行固定对话并报告本轮结果。单测、fake transport
和 `--dry` 用于开发检查；真实模型结果以本次 `build/` 输出为准。

## 六个案例、十一轮原话

| 宿主 | 默认案例 | 用户轮数 |
| --- | --- | ---: |
| SmartFit | `five-3`、`five-1` | 各三轮，共 6 轮 |
| HipLab | `R1-partial-substitute`、`R2-partial-remove`、`R4-insist`、`R6-safety-first` | 1、1、2、1，共 5 轮 |

SF 的固定顺序为生成 10 分钟计划、推荐大腿内侧动作、换一套并改成 5 分钟。
Hip 分别检查实际替代、删除范围外练背部分、坚持原动作以及安全暂停。原话由运行脚本
固定，每个案例创建独立会话，不追加模拟用户答案。

`--case` 可用逗号选择固定案例的子集或调整顺序；未传时采用上表默认列表。

```powershell
dart run tool/eval_coach_scope_guard.dart --host smartfit --case five-3,five-1 --dry --out build/coach-scope-guard/dry-sf-new
dart run tool/eval_coach_scope_guard.dart --host hiplab --case R1-partial-substitute,R2-partial-remove,R4-insist,R6-safety-first --dry --out build/coach-scope-guard/dry-hip-new
```

正式运行使用相同案例参数并去掉 `--dry`，每次指定新的 `--out`。输出目录必须在当前
SDK 的 `build/` 内；该目录不存在或为空时才运行。JSON 和日志留在本地 build，不入库。
thinking 默认 on，沿用现有网关/模型配置；客户端和 Agent 的请求重试为 0。
密钥通过既有 `eval_api_config.dart` 读取，不写入日志。

## 同宿主播放配置

- SF 使用原 `AppTestContent` 的目录、节奏、prep10 和原 App SessionBuilder。
- Hip 使用原 46 条 planning catalog（含 holdSeconds 投影）、kit、voice、prep15
  和现有 native timeline helper。

Agent 的执行时长回调和现场测量使用同一 SessionBuilder；桥接对照宿主实际时间线，
不在 SDK 工具中另估准备、起拍或换侧。手动计次继续标“估算”。
App 源码与 pin 保持只读。SF 名单为已定 219 授权 / 211 可规划；Hip 45 是候选 fixture，
不是产品签核后的正式 manifest。

`--dry` 创建 fake Agent 并读取真实播放配置，测一次样例时间线，真实 HTTP 为 0。
它不代替所选对话的真实模型运行。

## 结果与指标

本轮输出包括 `summary.json`、每个案例 JSON、`timeline.jsonl` 和真实运行的
`summary.md`。JSON 的 `results[].turns[]` 直接保留本轮原话、结果、计划/动作 ID、
scope 记录、timing、metrics、failures 和 passed；没有离线二次审计环节。

功能检查包括动作 ID 范围、非空计划/推荐、卡片与执行各自目标 ±10%、实际替代动作
出现在计划中、删除结果以及安全/坚持路径的无计划结果。安全路径还检查暂停说明。
这些检查直接产生本轮 `passed`，不要求消息与某段模板逐字一致。

调用目标为正常最多 4 次、一次修复最多 6 次 HTTP。`metrics.httpTarget` 和
`httpTargetMet` 仅供参考，不参与功能通过判定，也不改变 SDK 步数或修复次数限制。

metrics 包括实际 HTTP 次数、search attempts、最大请求 bytes、HTTP/用户轮耗时、
公开 prompt/completion/total token、网关缓存命中 token、修复次数和原因，以及
HTTP/tool/fit/recompile 的 span 耗时。网关缓存数是 token，不是本地检索缓存命中。
缺失 usage/耗时保留 unknown/null。HTTP 量到完整响应收完；嵌套 fit 时间不能再加进
tool 时间冒充总耗时。`onSpan` 同步收集数据，日志在正常运行流程写入。
