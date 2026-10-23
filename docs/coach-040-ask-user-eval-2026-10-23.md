# ugk_coach 0.4.0：ask_user 验证记录

2026-10-23（Asia/Shanghai）。候选分支 `codex/coach-0.4.0-ask-user` 基于 main `f577f5724812585fffdd1cd2d0a62dac3f74cdf2`。本次升级尚待开哥同意后合入 main、推送，没有新建 tag/release 或发布包。

## 结果

- 根包 `dart test --reporter expanded`：426/426 通过，其中新增 ask_user 行为测试 49 项。
- `dart analyze`：No issues found；`git diff --check` 通过。App 文档中的完整 Dart 绑定代码抽取后分析无问题。
- 真实 Worker 六例全部通过，12 次模型请求，合计 163,499 token（输入 + completion，reasoning 是 completion 的子项，不重复相加）。逐例耗时合计 216.911 秒；这不是用户一次任务的等待时间。
- 所有询问轮一次模型调用、一步结束、零文件读取，无计划/动作卡混出；参数、计数、取消、reset、历史和工具消息配对另由离线测试覆盖。

## 真实多轮评测

调用链为 `OpenAiCompatibleClient → CoachAgent`，端点 `https://api.uuugk.win/v1`。请求模型 `deepseek-v4-flash-0731`，调用记录中有返回标签 `deepseek-flash`；上游未提供 model 时运行器回退为请求别名，因此不把全部记录标签都视为原始响应字段。复用现有 App Key 和持久设备身份；证据不保存 key、设备 ID、请求头、系统提示词或推理原文。

运行器：[tool/eval_ask_user.dart](../tool/eval_ask_user.dart)；样例：[eval/cases/ask_user.json](../eval/cases/ask_user.json)。两个批次的运行源码指纹相同，运行中及逐例均确认未变：

`a60798545e73ec1dea2ccf994be6241331582905ebd0486ef2854b9d38ef3160`

指纹覆盖 `lib/`、`profiles/`、根 pubspec、评测运行器和样例，目录快照另有 SHA-256。每例新建 Agent，同例回答复用该 Agent 的下一次 `send()`。`bboy_choice` 使用默认开启的记忆，其他例关闭记忆；评测把 `maxHistoryChars` 提到 200000，其他步数、重试和超时保持默认。因此不把这些结果描述成所有配置均默认的验收。

| 案例 | 问题数 | 模型请求 | 总耗时 | 总 token | 验证结果 |
|---|---:|---:|---:|---:|---|
| bboy_choice | 1 | 4 | 62.810s | 58,501 | 原始长句先问，多选回答沿用；记忆开启仍不延迟到读写之后才问 |
| bboy_free_text | 1 | 2 | 27.719s | 25,819 | 不点选项，直接输入完整条件；最终居家、12 分钟、level 1、仅垫子，并含肩颈/髋屈肌动作 |
| core_ready | 0 | 1 | 35.016s | 13,625 | “在家 20 分钟练核心”直接交付合法计划 |
| known_context | 0 | 1 | 32.840s | 13,391 | 直接使用 App 已知条件及筛查，不重问；计划保留膝保护和重点部位 |
| direct_after_question | 1 | 2 | 32.190s | 26,189 | 用户回答“直接出”后停止询问，按默认值交付并说明假设 |
| question_budget | 1 | 2 | 26.336s | 25,974 | 用户回答“不确定”后使用默认值交付，未重复追问 |

原始结果与汇总：[六例聚合结果](../eval/results/ask-user/2026-10-23-candidate1-summary.json)、[关键两例](../eval/results/ask-user/2026-10-23-candidate1-critical/summary.json)、[其余四例](../eval/results/ask-user/2026-10-23-candidate1-remainder/summary.json)。六例首次运行均通过，没有用后续重跑覆盖失败样本。

bboy 记忆开启样例首问为“久坐之后，你哪里觉得最紧？可以多选”，选项点击后以“髋屈大腿前侧、肩颈”作为下一条普通文字进入。最终计划实际选中 `s-kneel-hipflex`、`o-stand-quad` 及 `h-wall-angel`、`h-chair-tspine` 等动作；部位断言检查目录动作名/肌群，明确的髋屈肌答案使用严格 hip-flexor 判定，不能靠任意髋部动作或说明文字冒充采用了答案。

## 首问耗时

| 案例 | 首问模型耗时 | 首问推理 token | 模型步数 / 文件读取 |
|---|---:|---:|---|
| bboy_choice（记忆开） | 26.794s | 124 | 1 / 0 |
| bboy_free_text | 8.302s | 169 | 1 / 0 |
| direct_after_question | 11.162s | 168 | 1 / 0 |
| question_budget | 5.568s | 140 | 1 / 0 |

询问轮没有先查库、选动作或多次模型往返，推理 token 为 124–169。远端服务和缓存造成的耗时有波动，不能由本次单样本给出稳定延迟保证。bboy_choice 回答后的 3 步是读记忆 skill、保存稳定事实、交付计划；该读取发生在回答后的新轮次。

## 离线覆盖及适用边界

新增 [agent_ask_user_test.dart](../test/agent_ask_user_test.dart) 的 49 项测试覆盖 text、单/多选、2–6 个选项和 Unicode 长度边界、非法 JSON/类型/字段及参数重交、ask 与 show_* 的两种顺序和混合读取/记忆批次、立即结束、跨消息回答与 reasoning 协议配对、三问计数和第四次硬拒绝、交付/模板/reset 清零，以及异步记账和同步事件监听器中的取消/reset。

真实的含糊回答样例在第 1 问后就合理默认并交付，没有实际走满 3 问；不得用它声称已真实模型验证第三问后继续调用被拒。三问后恶意第四次调用的硬门禁及修正出方案由确定性的 SDK 测试验证。`--dry` 仅检查 fixture，明确记录 `modelCalls=0`、`modelQualityPassed=null`，不计作真实模型通过。

本次真实样例使用 SmartFit profile；其余 profile 的工具契约与既有测试通过，但没有新增各自的真实六例。没有验证 App 气泡 UI、宿主真机帧率、原生媒体、锁屏或完整训练。App 事件与接口见 [ask_user 接入说明](ask-user.md)；复现配置和命令见 [eval/README.md](../eval/README.md)。
