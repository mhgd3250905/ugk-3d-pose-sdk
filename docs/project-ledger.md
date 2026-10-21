# 项目维护台账

更新日期：2026-10-21。仓库：[mhgd3250905/ugk-3d-pose-sdk](https://github.com/mhgd3250905/ugk-3d-pose-sdk)。

本台账统一记录维护状态、已合并成果、验证证据和待办。包版本、接口行为仍以对应清单和实现为准；发布历史保留在 CHANGELOG。表内 SHA 是核验快照，后续文档提交会推进 main，不能把快照当成永远最新的分支指针。

## 当前快照

| 项目 | 已核对状态 |
|---|---|
| 主线核验快照 | `origin/main` = `1d1aad86f516bd7121cc73c71d623043f1042dc3`；SDK 修复尚未合入 main |
| 当前修复分支 / 运行代码 | `fix/coach-agent-reasoning-replay`；实现与测试 source 为 `43dfef637144a1e08b5eda5ed743db0671ba5a8d`；吸收上述 main 文档后的 HEAD 为 `5b5aa27747b6eeaf67c18cc8bd7bebdeea566381`，运行与测试树不变 |
| 最初文档对齐 baseline（历史） | `1f8be6edf9c0c57575d963448af379e8fdf8df2a`；来自原文档会话 Cockpit init 记录，已核对为当时 main 且是当前 HEAD 的祖先 |
| 最初对齐前的 stage delta（历史） | baseline..HEAD 为 0 提交、0 路径；完整工作区 tracked 0、untracked 0；不代表修复分支当前成果 |
| 根包 | `ugk_coach` 0.3.0；`publish_to: none`，已合并不表示已发布到 pub.dev |
| 推荐入口 | `CoachAgent`；`CoachSession` 保留作 0.2 降级，`CoachAssistant` 为 deprecated 旧接口 |
| 训练执行 | PR #1 引入 `ugk_trainer` 0.1.0，当前包清单为 0.1.4；修复分支训练包 126 项测试通过 |
| 验收边界 | SDK 根包 304 项、训练包 126 项测试及两包分析通过；SmartFit 的 0.3 Agent 真实 Worker 六类分组验证通过；SDK / App 合入 main 待开哥批准；本轮未验真机 UI 或完整训练 |
| Cockpit | 原文档会话已接入 working（历史记录）；文档更新不自动结束会话或生成交接 |

## 事实来源与文档分工

以下来源均已从根 README 的直接声明核对。本台账新增后，也由根 README 直接指向。

| 路径 | 类别 | current / archive-history | 用途与核对结果 |
|---|---|---|---|
| [README.md](../README.md) | 项目入口 | current | 当前接入方式与文档入口；区分 Agent、工具版和 JSON 信封旧接口 |
| [pubspec.yaml](../pubspec.yaml) | 包配置 | current | 根包名 `ugk_coach`、版本 0.3.0、禁止 pub.dev 发布 |
| [docs/agent-plan.md](agent-plan.md) | Agent 设计 | current | 0.3 工具循环、技能披露、用户记忆和事件；不充当真实服务验收记录 |
| [CHANGELOG.md](../CHANGELOG.md) | 版本变更记录 | history；0.3.0 条目对应当前版本 | 记录各版本与训练包成果；历史条目的测试数和待定项保留原时间语境 |
| [docs/design.md](design.md) | 早期设计决策 | archive/history | 标题明确为 ugk_coach 0.1.2，不用它覆盖 0.3 行为或判定外部 PR 的当前状态 |
| [docs/smoke-2026-10-20.md](smoke-2026-10-20.md) | 历史真实调用 | archive/history | 0.1 / OpenCSG 的一次真实冒烟，不能证明 0.3 Worker 多步链路通过 |
| [docs/project-ledger.md](project-ledger.md) | 维护与验收台账 | current | 本文；承接当前合并状态、验证适用范围、未决事项和维护规则 |

最初文档对齐未对 profile、目录、提示词或依赖做变更。之后的修复分支调整了推理协议回传及记忆开启时的指令，具体变更见 Unreleased；本次验证记录同步仅改 README、CHANGELOG 和本文。

## 合并记录

合并状态与完整 SHA 已于 2026-10-21 通过 GitHub PR 状态和本机 Git 核对。日期按 Asia/Shanghai 记录。

| PR | 成果 | 状态 / 日期 | 合入提交 |
|---|---|---|---|
| [#1](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/1) | 通用训练模块 ugk_trainer 0.1.0 | MERGED / 2026-10-20 | `68c3f32389749c04ad61a06af96e4b9841ccce87` |
| [#3](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/3) | ugk_coach 0.2.0 工具版会话与门禁 | MERGED / 2026-10-21 | `09a392bc0b736e6a23eef71d55d86108660e0e59` |
| [#4](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/4) | ugk_coach 0.3.0 Agent 与渐进式技能披露 | MERGED / 2026-10-21 | `1f8be6edf9c0c57575d963448af379e8fdf8df2a` |

PR #4 的复审 head 为 `48417e03f5ff05d4434dc2e15cc36237464153d2`。合并提交的两父提交分别为 `09a392bc0b736e6a23eef71d55d86108660e0e59` 和该复审 head；合并树与复审树一致。

## 验证证据与适用范围

以下为原 main 基线的历史验证，2026-10-21 本机执行，Dart 3.12.2。结果已发布到 [PR #4 复审评论](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/4#issuecomment-6309269982)。修复分支补验单列在后文，不覆盖这些历史结果。

| 命令 / 检查 | 结果 | 对应 source state / 来源 |
|---|---|---|
| `dart pub get` | 退出码 0 | 本会话本机验证，`48417e03f5ff05d4434dc2e15cc36237464153d2` |
| `dart test` | 284 项全部通过，退出码 0 | 同上；根包证据，不覆盖 packages 下的 Flutter 包 |
| `dart analyze` | No issues found，退出码 0 | 同上 |
| 原 Fake / Completer 复现 | 11 项记忆与目录检查通过；剩余两条记忆关闭问题修复 | 同上；复审评论记录完整请求参数清除、异步 load 边界与混合工具配对结果 |
| `git diff --quiet 48417e03f5ff05d4434dc2e15cc36237464153d2 1f8be6edf9c0c57575d963448af379e8fdf8df2a` | 退出码 0，树一致 | 2026-10-21 文档 Preflight；因此可把上述离线证据复用于合并后的代码树 |
| `git status --porcelain=v1 --untracked-files=all` | 对齐前无输出 | 2026-10-21 文档 Preflight；没有证据之后的未提交代码变更 |
| `gh pr view <1/3/4> --repo mhgd3250905/ugk-3d-pose-sdk --json number,title,state,mergedAt,mergeCommit,headRefOid,url` | 三个 PR 均为 MERGED | 2026-10-21 远端观察；不代替测试证据 |
| `git ls-remote origin refs/heads/main` | 返回上述 main 快照 SHA | 2026-10-21 远端观察；后续分支推进需重新核对 |

### 修复分支补验与真实 Worker（2026-10-21）

修复依次为 `029af4a1e735b5f1c3f1ee5cef6c82aad8a1c3f4`（推理回传）、`712cb7b3d636a5314c5aa08211c822928a0af4f4`（空推理协议字段）、`43dfef637144a1e08b5eda5ed743db0671ba5a8d`（记忆开启指令）。根包 `dart test` 304 项、`dart analyze` 0 问题，训练包 `flutter test` 126 项、`flutter analyze` 0 问题，均绑定到 `43dfef6` 的运行与测试树。吸收 main 的文档提交后，`git diff --quiet 43dfef637144a1e08b5eda5ed743db0671ba5a8d 5b5aa27747b6eeaf67c18cc8bd7bebdeea566381 -- lib test packages tool prompts skills profiles pubspec.yaml analysis_options.yaml` 退出码 0。

真实请求由 SmartFit App 链路访问 `https://api.uuugk.win/v1` / `deepseek-v4-flash-0731`，在 Flutter 测试宿主执行，记忆使用本机文件；不是假模型或真机 UI 验收。App 最终运行源码 `5743073691547d44aec891ab6d4a45b5b3fa381b`，217 项测试及分析通过。完整问题、初始失败、用量口径与本机证据目录见 [SmartFit 真实 Worker 报告](https://github.com/mhgd3250905/Sport-Helper/blob/feat/smartfit-skill-agent/docs/coach-agent-smoke-2026-10-21.md)。

| 最终采用用例 | SDK source / 记忆状态 | 步数 | 耗时（秒） | token 合计 | 结果 |
|---|---|---:|---:|---:|---|
| 在家 15 分钟练核心，徒手 | `712cb7b` / 关闭 | 7 | 140.800 | 63,487 | ok；有效核心计划，无回落 |
| 臀桥怎么做 | `712cb7b` / 关闭 | 7 | 101.670 | 39,219 | ok；有效动作卡，无回落 |
| 我腰不太舒服，想练腿 20 分钟 | `712cb7b` / 关闭 | 8 | 204.564 | 98,806 | ok；护腰条件与计划通过门禁，无回落 |
| 我是新手，家里有哑铃 | `43dfef6` / 开启 | 3 | 35.372 | 11,487 | ok；先读记忆 skill，实际保存 level=新手、equipment=家里有哑铃，文字确认且未擅自排课，无回落 |
| 请给我排一个15分钟的居家力量训练计划 | `43dfef6` / 开启、新对话 | 6 | 119.549 | 72,881 | ok；请求含记忆摘要，难度 1，实际含哑铃地板卧推和划船，无回落 |
| 同一句计划问题 | `43dfef6` / 关闭、再开新对话 | 7 | 167.122 | 80,886 | ok；无记忆摘要、无记忆工具、无哑铃动作，本机原两条记忆保留，无回落 |

这是分组复验：`43dfef6` 唯一生产代码差异是 `memory ? ... : ''` 的开启分支字符串；新增回归验证三个 profile 的关闭记忆 system/tools 完整 SHA-256 与 `712cb7b` 相同，因此复用前三条通过记录，未声称最终 SHA 再完整执行六轮。六条合计 38 步、366,766 token（prompt + completion，reasoning 不重复相加）。

当前成果仍在修复分支，尚未合入 SDK main。经开哥批准后，先合 SDK 修复并推送，再将 App 的 git ref 固定到包含修复的 SDK main 具体提交，最后合 App main；不把临时修复分支 ref 带入 App main。

本次同步只修改 README、CHANGELOG 和本文，不改代码、测试、配置或生成物，复用上述验证。文档另查相对链接、版本与 SHA 引用及 `git diff --check`，不为此文档修改重跑模型或全量测试。

历史 Android 编译记录不升级为本次 HEAD 的验收证据；真机语音、锁屏保活和 Web 等流程也不能由 SDK 离线测试或此次真实 Worker 验证推定通过。

## 未决事项

| 编号 | 状态 / 级别 | 事项 | 验收条件 |
|---|---|---|---|
| SDK-001 | 修复分支已验证，待合 main | 0.3 `CoachAgent` 真实 Worker 多步链路 | 上文六类分组验证通过，绑定 `712cb7b` / `43dfef6`；main 仍为未包含这些修复的独立状态，不能把分支验证改写成修复已合主线 |
| SDK-002 | 已知非阻塞 P3 | `_withoutMemory` 的跨消息 ID 过滤：不同步骤复用工具调用 ID 时，后续普通调用和回复可能被误过滤 | 修正按消息配对或缺失 ID 的回退策略后，验证唯一 ID 正常路径及跨步骤复用 ID 场景；当前没有证据证明实际 Worker 会缺失或复用 ID |
| SDK-003 | 待开哥批准 | SDK / SmartFit 修复合入 main 并推送 | 先合 SDK 修复，再确认 App 固定 ref 为 SDK main 具体提交，最后合 App main；详细报告随 App 修复分支保存 |

SDK-001 只在修复分支完成真实验证，主线合并与 SDK-003 仍待批准。SDK-002 未在本次修复中处理，其条件与不阻塞合并的判断见上述 PR #4 复审评论。

## 台账维护规则

每次有效成果更新对应记录：写明目标、状态、完整提交 SHA、验证命令、执行日期与适用范围；有 PR 时补链接和合入 SHA。保留“已合并”“离线已验证”“真实服务待验证”的区别，旧版本证据保留历史标记。

台账与事实冲突时，先核对代码清单、Git/PR 和绑定到具体 source state 的验证，再修正文档。不得为了对齐文档改写未经验证的产品行为，或把待办改成已完成。不要记录凭据或一次性接入代码。

保存流程：核对完整工作区与改动归属 → 仅暂存本次明确路径 → commit → 在已获用户授权时普通 push → 条件具备时登记一次 Cockpit working 检查点。文档完成不自动结束 Cockpit 会话，不自动 relay/handoff。
