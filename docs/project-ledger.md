# 项目维护台账

更新日期：2026-10-23。仓库：[mhgd3250905/ugk-3d-pose-sdk](https://github.com/mhgd3250905/ugk-3d-pose-sdk)。

本台账统一记录维护状态、已合并成果、验证证据和待办。包版本、接口行为仍以对应清单和实现为准；发布历史保留在 CHANGELOG。表内 SHA 是核验快照，后续文档提交会推进 main，不能把快照当成永远最新的分支指针。

## 当前快照

| 项目 | 已核对状态 |
|---|---|
| 主线代码核验快照 | PR #6 已合入 main `eb29c749a52c1b226841726a3fba8e9f62e9e6be`，整树与复审 head `b84881f58c035b1fce2ff929cdb207e465821c92` 一致；保留 coach 0.3.3 源码及验收提交 a931a04。后续版本/文档提交不改变该运行时代码快照 |
| 0.4.0 候选 | 分支 `codex/coach-0.4.0-ask-user`，基于 main `f577f5724812585fffdd1cd2d0a62dac3f74cdf2` 增加 ask_user、跨消息三问计数与先问再排策略；426 项根包测试、分析无问题、6 例真实多轮评测通过，详见 [0.4.0 记录](coach-040-ask-user-eval-2026-10-23.md)。待开哥审阅同意后才合入 main、推送；尚无本次升级的 main commit |
| 0.3.3 合入状态 | 基于原 main `b26e4fd`，分支 `codex/coach-033-speed`；已获开哥批准，main 快进包含验收提交 a931a04。377 项 SDK 测试、分析 0 问题，SmartFit 最终六条正确性/性能全通过：计划均 1 步、28.6–36.3 秒，要领 1 步、25.4 秒，无回落 |
| 0.3.2 集成分支 / 来源（历史） | `codex/coach-agent-032-integration`；按指定源 `9bc392c42222d61d8c57e8dc00373ee165e56e06` 在 main `517fdbef6d9e611eff3f68bc2138f8e00e35c82e` 上 rebase 后补齐 0.3.2，已获批准合入 main；原修复分支保留，后续额外评审文档未作为集成源 |
| 最初文档对齐 baseline（历史） | `1f8be6edf9c0c57575d963448af379e8fdf8df2a`；来自原文档会话 Cockpit init 记录，已核对为当时 main 且是当前 HEAD 的祖先 |
| 最初对齐前的 stage delta（历史） | baseline..HEAD 为 0 提交、0 路径；完整工作区 tracked 0、untracked 0；不代表修复分支当前成果 |
| 根包 | main 为 `ugk_coach` 0.3.3；`publish_to: none`，已合入主线不表示已发布到 pub.dev |
| 推荐入口 | `CoachAgent`；`CoachSession` 保留作 0.2 降级，`CoachAssistant` 为 deprecated 旧接口 |
| 训练执行 | `ugk_trainer` 当前版本归档为 0.1.7：PR #6 舞台 UI 与 r9 审核修复；沿用 0.1.5 媒体缓存和 0.1.6 internal 预览门禁。完整复审 170 项 Flutter 测试、分析 0 问题，证据绑定 b84881f；旧 126 项为历史 source 的结果 |
| 版本管理 | main 的 coach 为 0.3.3，0.4.0 候选分支的根 `pubspec.yaml` 已升级至 0.4.0；训练包自己的 `pubspec.yaml` 仍管理 trainer 0.1.7。两包独立版本且均为 `publish_to: none`。PR 合并、包版本归档、Git 预览 tag 与对外发布是不同状态 |
| 验收边界 | Coach 0.3.3 的历史离线 377 项、定向 App 56 项及最终真实六条保持原 source 语境；PR #6 复审另执行根包 377 项与 trainer 170 项，trainer 分析 0 问题。真机帧率、原生媒体播放和宿主完整训练未验收 |
| Cockpit | 原文档会话已接入 working（历史记录）；文档更新不自动结束会话或生成交接 |

## 事实来源与文档分工

以下来源均已从根 README 的直接声明核对。本台账新增后，也由根 README 直接指向。

| 路径 | 类别 | current / archive-history | 用途与核对结果 |
|---|---|---|---|
| [README.md](../README.md) | 项目入口 | current | 当前接入方式与文档入口；区分 Agent、工具版和 JSON 信封旧接口 |
| [pubspec.yaml](../pubspec.yaml) | 包配置 | current | 根包名 `ugk_coach`、main 0.3.3、禁止 pub.dev 发布 |
| [docs/agent-plan.md](agent-plan.md) | Agent 设计 | current | 0.3 工具循环、技能披露、用户记忆和事件；不充当真实服务验收记录 |
| [CHANGELOG.md](../CHANGELOG.md) | 仓库版本变更记录 | current / history；按包名区分 | 根包保持 0.3.3，训练包 0.1.7 独立列出；历史测试数和待定项保留原时间语境 |
| [packages/ugk_trainer/pubspec.yaml](../packages/ugk_trainer/pubspec.yaml) | 训练包配置 | current | trainer 0.1.7，依赖和 `publish_to: none` 保留 |
| [packages/ugk_trainer/README.md](../packages/ugk_trainer/README.md) | 训练接口与接入约定 | current | 0.1.7 舞台 UI、剂量/字号/键盘行为及媒体接入；明确离线与真机边界 |
| [packages/ugk_trainer/CHANGELOG.md](../packages/ugk_trainer/CHANGELOG.md) | 训练包版本记录 | current / history | 0.1.7 为最终归档；r1–r9 是历史开发迭代，0.1.5 / 0.1.6 原记录保留 |
| [0.3.3 提速记录](coach-033-speed-2026-10-21.md) | 实测与合入状态 | current | 记录最终六条前后对比，保留先前性能未达标候选与余额不足尝试，不混用源码版本 |
| [docs/design.md](design.md) | 早期设计决策 | archive/history | 标题明确为 ugk_coach 0.1.2，不用它覆盖 0.3 行为或判定外部 PR 的当前状态 |
| [docs/smoke-2026-10-20.md](smoke-2026-10-20.md) | 历史真实调用 | archive/history | 0.1 / OpenCSG 的一次真实冒烟，不能证明 0.3 Worker 多步链路通过 |
| [docs/project-ledger.md](project-ledger.md) | 维护与验收台账 | current | 本文；承接当前合并状态、验证适用范围、未决事项和维护规则 |

最初文档对齐没有修改 profile、目录、提示词或依赖。原修复新增推理协议回传及记忆开启指令，本次 0.3.2 在指定源上集成，并补齐请求时限、推理预算口径及逐工具记忆持久化；具体变更见 CHANGELOG。源分支原 Unreleased 的必要事实已归入 0.3.2，原真实验证保留在下方历史小节。

## 合并记录

PR #1 / #3 / #4 / #5 的状态与完整 SHA 于 2026-10-21 核对；PR #6 于 2026-10-23 通过 GitHub 和本机 Git 核对。日期按 Asia/Shanghai 记录。

| PR | 成果 | 状态 / 日期 | 合入提交 |
|---|---|---|---|
| [#1](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/1) | 通用训练模块 ugk_trainer 0.1.0 | MERGED / 2026-10-20 | `68c3f32389749c04ad61a06af96e4b9841ccce87` |
| [#3](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/3) | ugk_coach 0.2.0 工具版会话与门禁 | MERGED / 2026-10-21 | `09a392bc0b736e6a23eef71d55d86108660e0e59` |
| [#4](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/4) | ugk_coach 0.3.0 Agent 与渐进式技能披露 | MERGED / 2026-10-21 | `1f8be6edf9c0c57575d963448af379e8fdf8df2a` |
| [#5](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/5) | ugk_coach 0.3.1 Agent 韧性与审核修复 | MERGED / 2026-10-21 | `517fdbef6d9e611eff3f68bc2138f8e00e35c82e` |
| [#6](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/6) | ugk_trainer 沉浸式舞台 UI 与 r9 修复，版本收束为 0.1.7 | MERGED / 2026-10-23 | `eb29c749a52c1b226841726a3fba8e9f62e9e6be` |

PR #4 的复审 head 为 `48417e03f5ff05d4434dc2e15cc36237464153d2`。合并提交的两父提交分别为 `09a392bc0b736e6a23eef71d55d86108660e0e59` 和该复审 head；合并树与复审树一致。

0.3.3 在开哥明确批准后通过 Git 快进合入 main，包含验收提交 `a931a04d6362ce8efba262556b34df3b485cc51d`；本次没有新建 PR。批准状态文档独立提交，运行时代码与已验证的 `e8c8921508139dc0f3eee1d2099eb5feefa80774` 相同。

PR #6 在开哥明确同意后合并，两个父提交为原 main `f684e02f38e652633c23fa8946a53d02b6aa3ea2` 与复审 head `b84881f58c035b1fce2ff929cdb207e465821c92`。合并树与复审树一致；后续 0.1.7 版本及文档收束不改运行时代码。0.1.5 / 0.1.6 的媒体功能已在合并前的 main 中，本次不将其冒记为 PR #6 新增。

## 验证证据与适用范围

### ugk_trainer 0.1.7：PR #6 已合并，版本与文档收束（2026-10-23）

本阶段 baseline 是 PR #6 合并前已审核的 main `f684e02f38e652633c23fa8946a53d02b6aa3ea2`（合并提交第一父提交）；收束起点 HEAD 为 `eb29c749a52c1b226841726a3fba8e9f62e9e6be`。baseline 是 HEAD 祖先，stage delta 为 12 个提交、10 个路径：6 个 trainer UI/导出文件、3 个测试文件和 1 个 CHANGELOG。收束前在主目录执行完整 `git status --porcelain=v1 --untracked-files=all` 无输出，tracked/staged/unstaged/deleted/renamed/untracked 均为 0。

收束核对的 current 来源为根 README / pubspec / CHANGELOG、本台账及训练包 README / pubspec / CHANGELOG；版本与接入事实分别按包核对。训练包 CHANGELOG 中原 10 组 Unreleased 改归 0.1.7，原迭代原文降为 history，避免旧位置/尺寸说明覆盖最终 r9 行为；既有 0.1.5 / 0.1.6 记录保留。根包维持 0.3.3，依赖和运行时代码不变。

以下测试由本会话在 2026-10-23 复审时独立执行；[通过审核记录](https://github.com/mhgd3250905/ugk-3d-pose-sdk/pull/6#pullrequestreview-5617366622) 提交于当日 00:15:49（Asia/Shanghai），绑定完整 source `b84881f58c035b1fce2ff929cdb207e465821c92`。这是复审 source 的证据，不是声称在版本/文档提交后重复跑过全套测试。

| 命令 / 检查 | 结果 | source state / 适用性 |
|---|---|---|
| trainer 目录：`$reviewTests = @(git ls-files 'test/*_test.dart'); flutter test --no-pub --reporter expanded @reviewTests` | 170 项通过，退出码 0 | b84881f 完整已跟踪测试，含 r9 新增 17 项；未计入审查工作副本的旧故障诊断文件 |
| trainer 目录：`flutter analyze --no-pub` | No issues found，退出码 0 | b84881f；包括 UI 及合并后的媒体代码 |
| 根目录：`dart test --reporter expanded` | 377 项通过，退出码 0 | b84881f；根包证据，不代替 Flutter 或真机验收 |
| `git diff --quiet b84881f58c035b1fce2ff929cdb207e465821c92 eb29c749a52c1b226841726a3fba8e9f62e9e6be` | 退出码 0，整树一致 | 合并后及本次 Preflight 重查；上述证据可复用于合并树 |
| GitHub PR #6 状态、合入 SHA 与复审记录 | MERGED；合入 eb29c74、审核 b84881f | 远端观察，不充当测试或对外发布证明 |

本次收束验证于 2026-10-23 执行，source state 为 eb29c74 加以下 6 个已归属改动：根 README、根 CHANGELOG、本台账及训练包 README、CHANGELOG、pubspec。`git diff --check` 通过；`node --input-type=module` 的只读 stdin 核对确认 41 个本地文档链接可解析，两个包版本一致，训练包 manifest 仅有 0.1.6 → 0.1.7 的版本行变化，0.1.6 及更早发布记录和 10 组历史迭代正文保留。完整状态为 tracked modified 6、staged 0、untracked 0；没有其他来源改动。

已用 `git diff --exit-code eb29c749a52c1b226841726a3fba8e9f62e9e6be -- lib test prompts skills profiles packages/ugk_trainer/lib packages/ugk_trainer/test packages/ugk_trainer/assets packages/ugk_trainer/android pubspec.yaml` 确认运行时、测试、素材、平台代码与根包配置无变化；训练包依赖也已通过 manifest 整文对比确认不变，因此复用上述测试证据。浅色和深色 Web 预览只作为外部界面观察；真机帧率、原生媒体播放、锁屏保活及宿主完整训练仍须另行验收。本地版本收束不创建 Git tag 或对外 release，不结束 Cockpit 会话。

### 0.3.3 提速：离线与真实六条通过，已批准合入 main（2026-10-21）

源码 `e8c8921508139dc0f3eee1d2099eb5feefa80774` 在独立分支上实现作用域紧凑索引、内联三条技能快路径、明确动作要领的受限详情预载，以及普通请求隐藏自检/门禁拒绝后开放。默认步数、超时、上下文和重试配置不变，跨轮 reasoning 保留官方协议。旧臀桥 badResponse 缺失原始证据，补安全诊断但未声称已确定或修复历史根因。

SDK 377 项测试与 analyze 0 问题通过；SmartFit 定向 56 项通过（仅隔离测试适配 agent-v2 元数据断言及显式自检输入，App 运行时代码未改）。候选 c4981c9 的完整六条正确性通过，问答 1 步 24.824 秒，但记忆关闭计划因两次自检达到 78.875 秒/34,515 token，不算性能验收通过；据此进一步限制自检工具的初始开放。

余额恢复后，在仅追加文档的 checkout `3a23ba0803a05efc1519efac3a231fc480e8ba1a` 完整重跑同六条，运行时代码与 e8c8921 相同。最终合计 8 步/8 请求、180.430 秒、74,130 token，较基线减少耗时 79.2%、token 80.7%；4 条计划均 1 步、28.616–36.306 秒，要领 1 步、25.397 秒，无回落，编造 id 为 0，护腰及记忆应用/关闭隔离与持久化通过。独立只读核验确认原始记录、脱敏 JSON、哈希和表格一致。先前余额不足 403 尝试保留原状态，未参与最终性能汇总；开哥批准后 main 已快进包含 a931a04。详细表格、协议对照、脱敏记录与复现测试补丁见[提速验证](coach-033-speed-2026-10-21.md)。

本次也补读了 main 0.3.2 的 SmartFit 六条证据（App b393044、SDK b26e4fd），共 39 逻辑步、43 请求、867.891 秒、384,013 token；[逐次拆解](coach-033-baseline-analysis-2026-10-21.md)保留全部 P/C 与工具路径。下面 0.3.2 集成时的“尚无新代码树实测”是当时验收边界，不能覆盖本次后来提供的基线记录。

跨轮推理对照已完成：空推理 ping 对照作为有限控制组保留，另用门禁接受的真实排课工具轮取得 1,222 个历史 reasoning token，完整/置空/省略均被当前网关接受，后两者 prompt 少 1,222 token。由于这与当前 DeepSeek 官方 tools 协议要求不一致，按“不确定先不动”保留跨轮推理；独立协议探测不计入六条性能指标，详见上述报告。

### 0.3.2 集成离线已验收并获批合入 main（2026-10-21）

本次以 `9bc392c42222d61d8c57e8dc00373ee165e56e06` 为指定源，在 `517fdbef6d9e611eff3f68bc2138f8e00e35c82e` 上集成；版本为 0.3.2，集成提交为 `31fb6f806612e0416f3bea4e32332068fd333473`。开哥审阅后明确同意合并，main 已快进包含该提交；原修复分支保留。批准状态文档单独提交，验证范围仍绑定上述源码。

当前行为为：Agent 整轮默认 360s、slow 提示 30s、单请求 60s；60k 上下文估算不计推理，仅压缩早期 read / ls 的 tool 结果。每条 assistant wire 消息均保留 `reasoning_content`，缺失使用空串；单步重试继续执行记忆隐私过滤。`remember` / `forget` 逐条等待 store.save 成功才返回 ok，失败返回工具错误；已确认前序保存可在后续取消时保留，pending 保存的迟到结果不写缓存 / 会话，并由串行队列补偿，清除记忆优先。

本次根包 `dart test` 342 项全部通过，Dart 3.12.2 的 `dart analyze` 为 0 问题，`git diff --check` 通过。新增持久化时序、失败恢复、取消/reset/清除/超时补偿和推理跨压缩/重试/清除隔离测试。训练包未改动，本次未重复执行 Flutter 验收。没有为新 0.3.2 代码树重新声明真实 Worker、真机 UI 或完整训练验收通过；下方 304 / 126 / 217 项测试数及 204.564s 等真实请求结果均保留其原 source 语境。

### 原 main 基线的离线证据（历史）

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
| `git ls-remote origin refs/heads/main` | 当时返回 `1d1aad86f516bd7121cc73c71d623043f1042dc3` | 原文档对齐时的历史远端观察，不代表当前 main |

### 原修复分支补验与真实 Worker（历史，2026-10-21）

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

以上是原修复分支的历史验收。当前 SDK 0.3.2 已获批准合入 SDK main，代码集成提交为 `31fb6f8`。SmartFit App 后续应将 git ref 固定到包含修复的 SDK main 具体提交，其主线集成待独立安排；不把临时修复分支 ref 带入 App main。

原验证记录同步只修改 README、CHANGELOG 和本文，不改当时的代码、测试、配置或生成物，复用上述验证。该历史范围不覆盖本次含代码、测试与版本变化的 0.3.2；新集成必须以自身最终离线验证记录验收。

历史 Android 编译记录不升级为本次 HEAD 的验收证据；真机语音、锁屏保活和 Web 等流程也不能由 SDK 离线测试或此次真实 Worker 验证推定通过。

## 未决事项

| 编号 | 状态 / 级别 | 事项 | 验收条件 |
|---|---|---|---|
| SDK-001 | 原 source 已验证；0.3.2 真实服务待验 | 0.3 `CoachAgent` 真实 Worker 多步链路 | 上文六类分组验证绑定 `712cb7b` / `43dfef6`；本次 0.3.2 的行为与默认时限已变化，历史记录不能证明新代码树已通过真实 Worker 验收 |
| SDK-002 | 已知非阻塞 P3 | `_withoutMemory` 的跨消息 ID 过滤：不同步骤复用工具调用 ID 时，后续普通调用和回复可能被误过滤 | 修正按消息配对或缺失 ID 的回退策略后，验证唯一 ID 正常路径及跨步骤复用 ID 场景；当前没有证据证明实际 Worker 会缺失或复用 ID |
| SDK-003 | SDK 已获批合入；App 待安排 | SDK 0.3.2 / SmartFit 主线集成 | SDK 代码集成提交为 `31fb6f8`；确认 App 固定 ref 为包含修复的 SDK main 具体提交，再独立安排 App main；历史报告随 App 修复分支保存 |
| SDK-004 | trainer 0.1.7 已合入；宿主真机待验 | 舞台 UI 真机帧率、原生媒体播放及完整训练 | 按宿主支持的设备、主题和训练链路实测；170 项离线测试与 Web 预览不能替代该验收 |

SDK-001 的真实验证只覆盖历史 source；SDK 0.3.2 主线集成已获批准，SDK-003 剩余 App 主线工作待独立安排。SDK-002 未在本次集成中处理，其条件与不阻塞合并的判断见上述 PR #4 复审评论。

## 台账维护规则

每次有效成果更新对应记录：写明目标、状态、完整提交 SHA、验证命令、执行日期与适用范围；有 PR 时补链接和合入 SHA。保留“已合并”“离线已验证”“真实服务待验证”的区别，旧版本证据保留历史标记。

台账与事实冲突时，先核对代码清单、Git/PR 和绑定到具体 source state 的验证，再修正文档。不得为了对齐文档改写未经验证的产品行为，或把待办改成已完成。不要记录凭据或一次性接入代码。

保存流程：核对完整工作区与改动归属 → 仅暂存本次明确路径 → commit → 在已获用户授权时普通 push → 条件具备时登记一次 Cockpit working 检查点。文档完成不自动结束 Cockpit 会话，不自动 relay/handoff。
