# 项目维护台账

更新日期：2026-10-21。仓库：[mhgd3250905/ugk-3d-pose-sdk](https://github.com/mhgd3250905/ugk-3d-pose-sdk)。

本台账统一记录维护状态、已合并成果、验证证据和待办。包版本、接口行为仍以对应清单和实现为准；发布历史保留在 CHANGELOG。表内 SHA 是核验快照，后续文档提交会推进 main，不能把快照当成永远最新的分支指针。

## 当前快照

| 项目 | 已核对状态 |
|---|---|
| 本机主线 | `main`；核验时与 `origin/main` 一致 |
| 本次文档对齐 baseline / 起始 HEAD | `1f8be6edf9c0c57575d963448af379e8fdf8df2a`；来自本会话 Cockpit init 记录，已核对为 main 且是 HEAD 的祖先 |
| 对齐开始前的 stage delta | baseline..HEAD 为 0 提交、0 路径；完整工作区 tracked 0、untracked 0 |
| 根包 | `ugk_coach` 0.3.0；`publish_to: none`，已合并不表示已发布到 pub.dev |
| 推荐入口 | `CoachAgent`；`CoachSession` 保留作 0.2 降级，`CoachAssistant` 为 deprecated 旧接口 |
| 训练执行 | PR #1 已合入，版本记录为 `ugk_trainer` 0.1.0；本轮不重新验收训练包 |
| 验收边界 | 根包离线复审通过；0.3 Agent 的真实 Worker 多步链路待验证 |
| Cockpit | 本会话已接入 working；本次文档提交只登记非终态检查点，不结束会话或生成交接 |

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

未对 profile、目录、提示词或依赖做变更；其原有事实来源与生成流程继续按 README 执行。本轮没有递归追踪历史文档中的其他项目链接。

## 合并记录

合并状态与完整 SHA 已于 2026-10-21 通过 GitHub PR 状态和本机 Git 核对。日期按 Asia/Shanghai 记录。

| PR | 成果 | 状态 / 日期 | 合入提交 |
|---|---|---|---|
| [#1](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/1) | 通用训练模块 ugk_trainer 0.1.0 | MERGED / 2026-10-20 | `68c3f32389749c04ad61a06af96e4b9841ccce87` |
| [#3](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/3) | ugk_coach 0.2.0 工具版会话与门禁 | MERGED / 2026-10-21 | `09a392bc0b736e6a23eef71d55d86108660e0e59` |
| [#4](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/4) | ugk_coach 0.3.0 Agent 与渐进式技能披露 | MERGED / 2026-10-21 | `1f8be6edf9c0c57575d963448af379e8fdf8df2a` |

PR #4 的复审 head 为 `48417e03f5ff05d4434dc2e15cc36237464153d2`。合并提交的两父提交分别为 `09a392bc0b736e6a23eef71d55d86108660e0e59` 和该复审 head；合并树与复审树一致。

## 验证证据与适用范围

根包验证在 2026-10-21 本机执行，Dart 3.12.2。结果已发布到 [PR #4 复审评论](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/4#issuecomment-6309269982)。

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

本轮收束只修改 README、CHANGELOG 和本文，不改代码、测试、配置或生成物。后续文档提交可复用上述代码验证，但应以有限 delta 证明仅有这三份 Markdown 文档变化；文档本身另查相对链接、版本与 SHA 引用及 `git diff --check`，无需为这次文档修改重跑模型或全量测试。

历史训练包测试和 Android 编译记录不升级为本次 HEAD 的验收证据；真机语音、锁屏保活和 Web 等流程也不能由根包 284 项测试推定通过。

## 未决事项

| 编号 | 状态 / 级别 | 事项 | 验收条件 |
|---|---|---|---|
| SDK-001 | 待验证 | 0.3 `CoachAgent` 真实 Worker 多步链路 | 使用本机配置请求真实服务，记录工具读取、后续调用及最终交付结果；绑定完整 source SHA。历史 0.1 冒烟和 0.2 tools 请求不能替代 |
| SDK-002 | 已知非阻塞 P3 | `_withoutMemory` 的跨消息 ID 过滤：不同步骤复用工具调用 ID 时，后续普通调用和回复可能被误过滤 | 修正按消息配对或缺失 ID 的回退策略后，验证唯一 ID 正常路径及跨步骤复用 ID 场景；当前没有证据证明实际 Worker 会缺失或复用 ID |

两项均未在本次文档对齐中宣称完成。SDK-002 的条件与不阻塞合并的判断见上述 PR #4 复审评论。

## 台账维护规则

每次有效成果更新对应记录：写明目标、状态、完整提交 SHA、验证命令、执行日期与适用范围；有 PR 时补链接和合入 SHA。保留“已合并”“离线已验证”“真实服务待验证”的区别，旧版本证据保留历史标记。

台账与事实冲突时，先核对代码清单、Git/PR 和绑定到具体 source state 的验证，再修正文档。不得为了对齐文档改写未经验证的产品行为，或把待办改成已完成。不要记录凭据或一次性接入代码。

保存流程：核对完整工作区与改动归属 → 仅暂存本次明确路径 → commit → 在已获用户授权时普通 push → 条件具备时登记一次 Cockpit working 检查点。文档完成不自动结束 Cockpit 会话，不自动 relay/handoff。
